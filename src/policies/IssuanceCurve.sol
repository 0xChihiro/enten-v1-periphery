// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Math} from "openzeppelin/contracts/utils/math/Math.sol";
import {MINTR} from "../modules/MINTR/MINTR.v1.sol";
import {Policy} from "enten-v1/Policy.sol";
import {Keycode, Permissions} from "enten-v1/Utils.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IEntenToken} from "enten-v1/interfaces/IEntenToken.sol";
import {IKernel} from "enten-v1/interfaces/IKernel.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";

interface IControllerView {
    function BPS() external view returns (uint256);
    function AUCTION_FEE_BPS() external view returns (uint256);
    function KERNEL() external view returns (address);
    function TOKEN() external view returns (address);
    function VAULT() external view returns (address);
}

contract IssuanceCurve is Policy {
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_NAV_PREMIUM_BPS = 500;
    uint256 public constant MAX_SAFE_SUPPLY = type(uint120).max;
    uint256 public constant MAX_RESERVE_ASSET_COUNT = 16;
    bytes32 public constant CURVE_RESERVE_SLOT = keccak256("enten.periphery.curve.bancor.reserve");
    bytes32 public constant CURVE_SUPPLY_SLOT = keccak256("enten.periphery.curve.bancor.supply");

    Keycode internal constant CURVE_KEYCODE = Keycode.wrap(0x4355525645); // CURVE
    Keycode internal constant MINTR_KEYCODE = Keycode.wrap(0x4d494e5452); // MINTR

    enum CurveShape {
        FourthRoot, // y = x^(1/4), reserve ratio = 80%
        SquareRoot, // y = x^(1/2), reserve ratio = 66.67%
        Linear // y = x, reserve ratio = 50%
    }

    struct ReserveAssetConfig {
        address asset;
        uint8 decimals;
    }

    struct ReserveAsset {
        bool enabled;
        uint8 decimals;
        uint256 scalar;
    }

    struct BuyQuote {
        address paymentAsset;
        uint256 grossAssetIn;
        uint256 mintAmount;
        uint256 curveReserveDeltaWad;
        uint256 curveSupplyDeltaWad;
        bool usesNavFloor;
    }

    struct QuoteContext {
        ReserveAsset assetConfig;
        uint256 actualSupply;
        uint256 maxSupply;
        uint256 virtualSupply;
        uint256 curveReserveWad;
        uint256 backingBalanceWad;
    }

    IKernel public immutable KERNEL;
    IEntenToken public immutable TOKEN;
    address public immutable VAULT;
    address public immutable ADMIN;
    CurveShape public immutable SHAPE;
    uint256 public immutable PROTOCOL_FEE_BPS;

    bool public configured;
    bool public paused;
    MINTR public MINTER;

    address[] private _reserveAssets;
    mapping(address asset => ReserveAsset config) private _reserveAssetConfigs;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus = _NOT_ENTERED;

    event CurveConfigured(address indexed controller, CurveShape indexed shape, uint256 reserveAssetCount);
    event ReserveAssetConfigured(address indexed asset, uint8 decimals);
    event PausedUpdated(bool paused);
    event TokensPurchased(
        address indexed payer,
        address indexed paymentAsset,
        uint256 mintAmount,
        uint256 grossAssetIn,
        uint256 curveReserveDeltaWad,
        uint256 curveSupplyDeltaWad,
        bool usesNavFloor
    );

    error Curve__ZeroAddress();
    error Curve__TargetNotAContract(address target);
    error Curve__InvalidController();
    error Curve__InvalidDecimals();
    error Curve__InvalidFee();
    error Curve__NoReserveAssets();
    error Curve__TooManyReserveAssets(uint256 count);
    error Curve__DuplicateReserveAsset(address asset);
    error Curve__UnsupportedReserveAsset(address asset);
    error Curve__OnlyAdmin();
    error Curve__NotConfigured();
    error Curve__MinterNotConfigured();
    error Curve__Paused();
    error Curve__ReentrantCall();
    error Curve__Expired();
    error Curve__ZeroAmount();
    error Curve__ZeroPrice();
    error Curve__MaxSupplyNotSet();
    error Curve__MaxSupplyTooLarge(uint256 maxSupply);
    error Curve__InvalidSupply();
    error Curve__VirtualCurveNotSeeded();
    error Curve__SupplyExceedsMaxSupply(uint256 supply, uint256 maxSupply);
    error Curve__CapExceeded(uint256 endSupply, uint256 maxSupply);
    error Curve__Slippage(uint256 requiredAssetIn, uint256 maxAssetIn);
    error Curve__MintSlippage(uint256 mintAmount, uint256 minMintAmount);

    constructor(address controller, ReserveAssetConfig[] memory reserveAssets_, CurveShape shape, address admin)
        Policy(controller)
    {
        if (controller == address(0) || admin == address(0)) revert Curve__ZeroAddress();
        if (reserveAssets_.length == 0) revert Curve__NoReserveAssets();
        if (reserveAssets_.length > MAX_RESERVE_ASSET_COUNT) {
            revert Curve__TooManyReserveAssets(reserveAssets_.length);
        }
        if (controller.code.length == 0) revert Curve__TargetNotAContract(controller);

        IControllerView controller_ = IControllerView(controller);
        if (controller_.BPS() != BPS) revert Curve__InvalidController();

        uint256 protocolFeeBps = controller_.AUCTION_FEE_BPS();
        if (protocolFeeBps >= BPS) revert Curve__InvalidFee();

        address kernel = controller_.KERNEL();
        address token = controller_.TOKEN();
        address vault = controller_.VAULT();
        if (kernel == address(0) || token == address(0) || vault == address(0)) revert Curve__InvalidController();

        KERNEL = IKernel(kernel);
        TOKEN = IEntenToken(token);
        VAULT = vault;
        ADMIN = admin;
        SHAPE = shape;
        PROTOCOL_FEE_BPS = protocolFeeBps;

        for (uint256 i; i < reserveAssets_.length;) {
            _configureReserveAsset(reserveAssets_[i]);

            unchecked {
                ++i;
            }
        }
    }

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    modifier whenLive() {
        _whenLive();
        _;
    }

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function KEYCODE() public pure override returns (Keycode) {
        return CURVE_KEYCODE;
    }

    function configureDependencies() external override onlyController returns (Keycode[] memory dependencies) {
        configured = true;
        dependencies = new Keycode[](1);
        dependencies[0] = MINTR_KEYCODE;
        MINTER = MINTR(getModuleAddress(MINTR_KEYCODE));

        emit CurveConfigured(address(CONTROLLER), SHAPE, _reserveAssets.length);
    }

    function requestPermissions() external pure override returns (Permissions[] memory requests) {
        requests = new Permissions[](1);
        requests[0] = Permissions({keycode: MINTR_KEYCODE, funcSelector: MINTR.mint.selector});
    }

    function setPaused(bool paused_) external onlyAdmin {
        paused = paused_;

        emit PausedUpdated(paused_);
    }

    function buyExactTokens(uint256 mintAmount, uint256 maxAssetIn, uint256 deadline)
        external
        nonReentrant
        whenLive
        returns (BuyQuote memory quote)
    {
        quote = _buyExactTokens(defaultReserveAsset(), mintAmount, maxAssetIn, deadline);
    }

    function buyExactTokens(address paymentAsset, uint256 mintAmount, uint256 maxAssetIn, uint256 deadline)
        external
        nonReentrant
        whenLive
        returns (BuyQuote memory quote)
    {
        quote = _buyExactTokens(paymentAsset, mintAmount, maxAssetIn, deadline);
    }

    function buyExactAssets(uint256 grossAssetIn, uint256 minMintAmount, uint256 deadline)
        external
        nonReentrant
        whenLive
        returns (BuyQuote memory quote)
    {
        quote = _buyExactAssets(defaultReserveAsset(), grossAssetIn, minMintAmount, deadline);
    }

    function buyExactAssets(address paymentAsset, uint256 grossAssetIn, uint256 minMintAmount, uint256 deadline)
        external
        nonReentrant
        whenLive
        returns (BuyQuote memory quote)
    {
        quote = _buyExactAssets(paymentAsset, grossAssetIn, minMintAmount, deadline);
    }

    function quoteBuyExactTokens(uint256 mintAmount) public view returns (BuyQuote memory quote) {
        quote = quoteBuyExactTokens(defaultReserveAsset(), mintAmount);
    }

    function quoteBuyExactTokens(address paymentAsset, uint256 mintAmount) public view returns (BuyQuote memory quote) {
        if (mintAmount == 0) revert Curve__ZeroAmount();

        QuoteContext memory context = _quoteContext(paymentAsset);
        uint256 actualEndSupply = context.actualSupply + mintAmount;
        if (actualEndSupply > context.maxSupply) revert Curve__CapExceeded(actualEndSupply, context.maxSupply);

        (uint256 requiredBackingWad, uint256 curveReserveDeltaWad, bool usesNavFloor) = _requiredBackingInWad(
            context.virtualSupply, mintAmount, context.curveReserveWad, context.actualSupply, context.backingBalanceWad
        );
        if (requiredBackingWad == 0) revert Curve__ZeroPrice();

        quote.paymentAsset = paymentAsset;
        quote.grossAssetIn = _grossAssetInForBacking(_fromWadUp(requiredBackingWad, context.assetConfig.scalar));
        quote.mintAmount = mintAmount;
        quote.curveReserveDeltaWad = curveReserveDeltaWad;
        quote.curveSupplyDeltaWad = mintAmount;
        quote.usesNavFloor = usesNavFloor;
    }

    function quoteBuyExactAssets(uint256 grossAssetIn) public view returns (BuyQuote memory quote) {
        quote = quoteBuyExactAssets(defaultReserveAsset(), grossAssetIn);
    }

    function quoteBuyExactAssets(address paymentAsset, uint256 grossAssetIn)
        public
        view
        returns (BuyQuote memory quote)
    {
        if (grossAssetIn == 0) revert Curve__ZeroAmount();

        QuoteContext memory context = _quoteContext(paymentAsset);
        uint256 backingInWad = _toWad(_backingAmountFromGross(grossAssetIn), context.assetConfig.scalar);
        if (backingInWad == 0) revert Curve__ZeroPrice();

        uint256 maxMintAmount = context.maxSupply - context.actualSupply;
        if (maxMintAmount == 0) revert Curve__CapExceeded(context.actualSupply, context.maxSupply);

        (uint256 mintAmount, uint256 curveReserveDeltaWad, bool usesNavFloor) = _mintAmountForBackingWad(
            context.virtualSupply,
            context.curveReserveWad,
            context.actualSupply,
            context.backingBalanceWad,
            maxMintAmount,
            backingInWad
        );
        if (mintAmount == 0) revert Curve__ZeroPrice();

        quote.paymentAsset = paymentAsset;
        quote.grossAssetIn = grossAssetIn;
        quote.mintAmount = mintAmount;
        quote.curveReserveDeltaWad = curveReserveDeltaWad;
        quote.curveSupplyDeltaWad = mintAmount;
        quote.usesNavFloor = usesNavFloor;
    }

    function reserveRatio() external view returns (uint256 numerator, uint256 denominator) {
        return _reserveRatio();
    }

    function reserveAssetCount() external view returns (uint256) {
        return _reserveAssets.length;
    }

    function reserveAssetAt(uint256 index) external view returns (address) {
        return _reserveAssets[index];
    }

    function defaultReserveAsset() public view returns (address) {
        return _reserveAssets[0];
    }

    function isReserveAsset(address asset) public view returns (bool) {
        return _reserveAssetConfigs[asset].enabled;
    }

    function reserveAssetDecimals(address asset) external view returns (uint8) {
        return _reserveAssetConfig(asset).decimals;
    }

    function reserveAssetScalar(address asset) external view returns (uint256) {
        return _reserveAssetConfig(asset).scalar;
    }

    function curveReserveBalance() public view returns (uint256) {
        return curveReserveBalanceWad();
    }

    function curveReserveBalanceWad() public view returns (uint256) {
        return uint256(KERNEL.viewData(CURVE_RESERVE_SLOT));
    }

    function curveSupplyBalance() public view returns (uint256) {
        return curveSupplyBalanceWad();
    }

    function curveSupplyBalanceWad() public view returns (uint256) {
        return uint256(KERNEL.viewData(CURVE_SUPPLY_SLOT));
    }

    function reserveBackingBalance() public view returns (uint256) {
        return reserveBackingBalanceWad();
    }

    function reserveBackingBalanceWad() public view returns (uint256 totalBackingWad) {
        for (uint256 i; i < _reserveAssets.length;) {
            address asset = _reserveAssets[i];
            ReserveAsset memory assetConfig = _reserveAssetConfigs[asset];
            totalBackingWad += _toWad(reserveBackingBalanceOf(asset), assetConfig.scalar);

            unchecked {
                ++i;
            }
        }
    }

    function reserveBackingBalanceOf(address asset) public view returns (uint256) {
        _requireReserveAsset(asset);

        return uint256(KERNEL.viewData(_amountSlot(Slots.BACKING_AMOUNT_SLOT, asset)));
    }

    function reserveBackingBalanceOfWad(address asset) external view returns (uint256) {
        ReserveAsset memory assetConfig = _reserveAssetConfig(asset);

        return _toWad(reserveBackingBalanceOf(asset), assetConfig.scalar);
    }

    function navPriceWad() external view returns (uint256) {
        return _navPriceWad(TOKEN.totalSupply(), reserveBackingBalanceWad());
    }

    function navFloorPriceWad() external view returns (uint256) {
        return
            Math.mulDiv(_navPriceWad(TOKEN.totalSupply(), reserveBackingBalanceWad()), BPS + MIN_NAV_PREMIUM_BPS, BPS);
    }

    function bancorSpotPriceWad() external view returns (uint256) {
        return _bancorSpotPriceWad(curveSupplyBalanceWad(), curveReserveBalanceWad());
    }

    function maxSupply() external view returns (uint256) {
        return _maxSupply();
    }

    function _buyExactTokens(address paymentAsset, uint256 mintAmount, uint256 maxAssetIn, uint256 deadline)
        internal
        returns (BuyQuote memory quote)
    {
        if (block.timestamp > deadline) revert Curve__Expired();

        quote = quoteBuyExactTokens(paymentAsset, mintAmount);
        if (quote.grossAssetIn > maxAssetIn) revert Curve__Slippage(quote.grossAssetIn, maxAssetIn);

        _executeBuy(quote);
    }

    function _buyExactAssets(address paymentAsset, uint256 grossAssetIn, uint256 minMintAmount, uint256 deadline)
        internal
        returns (BuyQuote memory quote)
    {
        if (block.timestamp > deadline) revert Curve__Expired();

        quote = quoteBuyExactAssets(paymentAsset, grossAssetIn);
        if (quote.mintAmount < minMintAmount) revert Curve__MintSlippage(quote.mintAmount, minMintAmount);

        _executeBuy(quote);
    }

    function _executeBuy(BuyQuote memory quote) internal {
        MINTR minter = MINTER;
        if (address(minter) == address(0)) revert Curve__MinterNotConfigured();

        IController.Receipt[] memory receipts = new IController.Receipt[](1);
        receipts[0] = IController.Receipt({asset: quote.paymentAsset, amount: quote.grossAssetIn});

        IController.StateUpdate[] memory updates = new IController.StateUpdate[](2);
        updates[0] = IController.StateUpdate({
            op: IController.Op.Add, slot: CURVE_RESERVE_SLOT, data: bytes32(quote.curveReserveDeltaWad)
        });
        updates[1] = IController.StateUpdate({
            op: IController.Op.Add, slot: CURVE_SUPPLY_SLOT, data: bytes32(quote.curveSupplyDeltaWad)
        });

        minter.mint(msg.sender, quote.mintAmount, receipts, updates);

        emit TokensPurchased(
            msg.sender,
            quote.paymentAsset,
            quote.mintAmount,
            quote.grossAssetIn,
            quote.curveReserveDeltaWad,
            quote.curveSupplyDeltaWad,
            quote.usesNavFloor
        );
    }

    function _quoteContext(address paymentAsset) internal view returns (QuoteContext memory context) {
        context.assetConfig = _reserveAssetConfig(paymentAsset);

        context.actualSupply = TOKEN.totalSupply();
        if (context.actualSupply == 0) revert Curve__InvalidSupply();

        context.maxSupply = _maxSupply();
        _validateSupply(context.actualSupply, context.maxSupply);

        context.virtualSupply = curveSupplyBalanceWad();
        context.curveReserveWad = curveReserveBalanceWad();
        if (context.virtualSupply == 0 || context.curveReserveWad == 0) revert Curve__VirtualCurveNotSeeded();

        context.backingBalanceWad = reserveBackingBalanceWad();
    }

    function _configureReserveAsset(ReserveAssetConfig memory assetConfig) internal {
        if (assetConfig.asset == address(0)) revert Curve__ZeroAddress();
        if (assetConfig.asset.code.length == 0) revert Curve__TargetNotAContract(assetConfig.asset);
        if (assetConfig.decimals > 18) revert Curve__InvalidDecimals();
        if (_reserveAssetConfigs[assetConfig.asset].enabled) revert Curve__DuplicateReserveAsset(assetConfig.asset);

        _reserveAssets.push(assetConfig.asset);
        _reserveAssetConfigs[assetConfig.asset] =
            ReserveAsset({enabled: true, decimals: assetConfig.decimals, scalar: 10 ** (18 - assetConfig.decimals)});

        emit ReserveAssetConfigured(assetConfig.asset, assetConfig.decimals);
    }

    function _reserveAssetConfig(address asset) internal view returns (ReserveAsset memory assetConfig) {
        assetConfig = _reserveAssetConfigs[asset];
        if (!assetConfig.enabled) revert Curve__UnsupportedReserveAsset(asset);
    }

    function _requireReserveAsset(address asset) internal view {
        if (!_reserveAssetConfigs[asset].enabled) revert Curve__UnsupportedReserveAsset(asset);
    }

    function _onlyAdmin() internal view {
        if (msg.sender != ADMIN) revert Curve__OnlyAdmin();
    }

    function _whenLive() internal view {
        if (!configured) revert Curve__NotConfigured();
        if (paused) revert Curve__Paused();
    }

    function _nonReentrantBefore() internal {
        if (_reentrancyStatus == _ENTERED) revert Curve__ReentrantCall();
        _reentrancyStatus = _ENTERED;
    }

    function _nonReentrantAfter() internal {
        _reentrancyStatus = _NOT_ENTERED;
    }

    function _maxSupply() internal view returns (uint256 value) {
        value = uint256(KERNEL.viewData(Slots.MAX_SUPPLY_SLOT));
        if (value == 0) revert Curve__MaxSupplyNotSet();
        if (value > MAX_SAFE_SUPPLY) revert Curve__MaxSupplyTooLarge(value);
    }

    function _validateSupply(uint256 supply, uint256 maxSupply_) internal pure {
        if (supply > maxSupply_) revert Curve__SupplyExceedsMaxSupply(supply, maxSupply_);
    }

    function _bancorBackingInWad(uint256 supply, uint256 tokenAmount, uint256 curveReserveWad)
        internal
        view
        returns (uint256)
    {
        if (curveReserveWad == 0) return 0;

        uint256 ratioWad = Math.mulDiv(supply + tokenAmount, WAD, supply, Math.Rounding.Ceil);
        uint256 growthWad = _growthWad(ratioWad);

        return Math.mulDiv(curveReserveWad, growthWad - WAD, WAD, Math.Rounding.Ceil);
    }

    function _requiredBackingInWad(
        uint256 virtualSupply,
        uint256 mintAmount,
        uint256 curveReserveWad,
        uint256 actualSupply,
        uint256 backingBalanceWad
    ) internal view returns (uint256 requiredBackingWad, uint256 curveReserveDeltaWad, bool usesNavFloor) {
        curveReserveDeltaWad = _bancorBackingInWad(virtualSupply, mintAmount, curveReserveWad);
        uint256 navFloorBackingWad = _navFloorBackingInWad(actualSupply, mintAmount, backingBalanceWad);

        requiredBackingWad = Math.max(curveReserveDeltaWad, navFloorBackingWad);
        usesNavFloor = navFloorBackingWad > curveReserveDeltaWad;
    }

    function _mintAmountForBackingWad(
        uint256 virtualSupply,
        uint256 curveReserveWad,
        uint256 actualSupply,
        uint256 backingBalanceWad,
        uint256 maxMintAmount,
        uint256 backingInWad
    ) internal view returns (uint256 mintAmount, uint256 curveReserveDeltaWad, bool usesNavFloor) {
        uint256 low;
        uint256 high = maxMintAmount;

        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            (uint256 requiredBackingWad,,) =
                _requiredBackingInWad(virtualSupply, mid, curveReserveWad, actualSupply, backingBalanceWad);

            if (requiredBackingWad <= backingInWad) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        mintAmount = low;
        (, curveReserveDeltaWad, usesNavFloor) =
            _requiredBackingInWad(virtualSupply, mintAmount, curveReserveWad, actualSupply, backingBalanceWad);
    }

    function _navFloorBackingInWad(uint256 supply, uint256 tokenAmount, uint256 backingBalanceWad)
        internal
        pure
        returns (uint256)
    {
        if (backingBalanceWad == 0) return 0;

        uint256 navPrice = _navPriceWad(supply, backingBalanceWad);
        uint256 floorPrice = Math.mulDiv(navPrice, BPS + MIN_NAV_PREMIUM_BPS, BPS, Math.Rounding.Ceil);

        return Math.mulDiv(tokenAmount, floorPrice, WAD, Math.Rounding.Ceil);
    }

    function _navPriceWad(uint256 supply, uint256 backingBalanceWad) internal pure returns (uint256) {
        if (supply == 0) revert Curve__InvalidSupply();
        if (backingBalanceWad == 0) return 0;

        return Math.mulDiv(backingBalanceWad, WAD, supply);
    }

    function _bancorSpotPriceWad(uint256 supply, uint256 curveReserveWad) internal view returns (uint256) {
        if (supply == 0) revert Curve__InvalidSupply();
        if (curveReserveWad == 0) return 0;

        (uint256 numerator, uint256 denominator) = _reserveRatio();
        uint256 reservePerTokenWad = Math.mulDiv(curveReserveWad, WAD, supply);

        return Math.mulDiv(reservePerTokenWad, denominator, numerator, Math.Rounding.Ceil);
    }

    function _growthWad(uint256 ratioWad) internal view returns (uint256) {
        if (SHAPE == CurveShape.FourthRoot) {
            uint256 fourthRootRatioWad = _sqrtWad(_sqrtWad(ratioWad));
            return Math.mulDiv(ratioWad, fourthRootRatioWad, WAD, Math.Rounding.Ceil);
        }

        if (SHAPE == CurveShape.SquareRoot) {
            uint256 sqrtRatioWad = _sqrtWad(ratioWad);
            return Math.mulDiv(ratioWad, sqrtRatioWad, WAD, Math.Rounding.Ceil);
        }

        return Math.mulDiv(ratioWad, ratioWad, WAD, Math.Rounding.Ceil);
    }

    function _sqrtWad(uint256 xWad) internal pure returns (uint256) {
        return Math.sqrt(xWad * WAD, Math.Rounding.Ceil);
    }

    function _reserveRatio() internal view returns (uint256 numerator, uint256 denominator) {
        if (SHAPE == CurveShape.FourthRoot) return (4, 5);
        if (SHAPE == CurveShape.SquareRoot) return (2, 3);
        return (1, 2);
    }

    function _amountSlot(bytes32 namespace, address asset) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0x00, namespace)
            mstore(0x20, and(asset, 0xffffffffffffffffffffffffffffffffffffffff))
            slot := keccak256(0x00, 0x40)
        }
    }

    function _grossAssetInForBacking(uint256 requiredBacking) internal view returns (uint256 grossAssetIn) {
        if (requiredBacking == 0) return 0;

        (uint256 teamBps, uint256 treasuryBps) = _paymentCreditBps();
        uint256 backingBps = BPS - teamBps - treasuryBps;

        uint256 requiredPostProtocol = Math.mulDiv(requiredBacking, BPS, backingBps, Math.Rounding.Ceil);
        uint256 upperBound = Math.mulDiv(requiredPostProtocol, BPS, BPS - PROTOCOL_FEE_BPS, Math.Rounding.Ceil);
        uint256 lowerBound = requiredBacking;

        while (lowerBound < upperBound) {
            uint256 mid = (lowerBound + upperBound) / 2;
            if (_backingAmountFromGross(mid) >= requiredBacking) {
                upperBound = mid;
            } else {
                lowerBound = mid + 1;
            }
        }

        grossAssetIn = lowerBound;
    }

    function _backingAmountFromGross(uint256 grossAmount) internal view returns (uint256 backingAmount) {
        (uint256 teamBps, uint256 treasuryBps) = _paymentCreditBps();

        uint256 protocolFee = Math.mulDiv(grossAmount, PROTOCOL_FEE_BPS, BPS, Math.Rounding.Ceil);
        uint256 netAmount = grossAmount - protocolFee;
        uint256 teamAmount = netAmount * teamBps / BPS;
        uint256 treasuryAmount = netAmount * treasuryBps / BPS;

        backingAmount = netAmount - teamAmount - treasuryAmount;
    }

    function _paymentCreditBps() internal view returns (uint256 teamBps, uint256 treasuryBps) {
        teamBps = uint256(KERNEL.viewData(Slots.TEAM_PERCENTAGE_SLOT));
        treasuryBps = uint256(KERNEL.viewData(Slots.TREASURY_PERCENTAGE_SLOT));
        if (teamBps + treasuryBps >= BPS) revert Curve__InvalidFee();
    }

    function _toWad(uint256 amount, uint256 scalar) internal pure returns (uint256) {
        return amount * scalar;
    }

    function _fromWadUp(uint256 amountWad, uint256 scalar) internal pure returns (uint256) {
        return Math.ceilDiv(amountWad, scalar);
    }
}
