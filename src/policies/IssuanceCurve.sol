// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Math} from "openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BancorNavMath} from "../libraries/BancorNavMath.sol";
import {MINTR} from "../modules/MINTR/MINTR.v1.sol";
import {Policy} from "enten-v1/Policy.sol";
import {Keycode, Permissions} from "enten-v1/Utils.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IToken} from "enten-v1/interfaces/IToken.sol";
import {IKernel} from "enten-v1/interfaces/IKernel.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {ICurve} from "../interfaces/ICurve.sol";
import {effectiveSupply} from "../Utils.sol";

interface IControllerView {
    function BPS() external view returns (uint256);
    function AUCTION_FEE_BPS() external view returns (uint256);
    function KERNEL() external view returns (address);
    function TOKEN() external view returns (address);
    function VAULT() external view returns (address);
}

interface IWETH is IERC20 {
    function deposit() external payable;
}

interface ITokenSupply is IToken {
    function MAX_SUPPLY() external view returns (uint256);
}

contract IssuanceCurve is Policy, ICurve {
    using SafeERC20 for IERC20;
    IKernel public immutable KERNEL;
    ITokenSupply public immutable TOKEN;
    address public immutable VAULT;
    address public immutable ADMIN;
    IWETH public immutable WETH;
    CurveShape public immutable SHAPE;
    uint256 public immutable PROTOCOL_FEE_BPS;

    bool public live;
    bool public paused;
    MINTR public MINTER;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus = _NOT_ENTERED;

    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_NAV_PREMIUM_BPS = 500;
    bytes32 public constant CURVE_BASE_SLOT = keccak256("enten.bancor.curve.base.slot");

    Keycode internal constant CURVE_KEYCODE = Keycode.wrap(0x4355525645); // CURVE
    Keycode internal constant MINTR_KEYCODE = Keycode.wrap(0x4d494e5452); // MINTR

    constructor(address controller, address weth, CurveShape shape, address admin) Policy(controller) {
        if (controller == address(0) || weth == address(0) || admin == address(0)) revert Curve__ZeroAddress();
        if (controller.code.length == 0) revert Curve__TargetNotAContract(controller);
        if (weth.code.length == 0) revert Curve__TargetNotAContract(weth);

        IControllerView controller_ = IControllerView(controller);
        if (controller_.BPS() != BPS) revert Curve__InvalidController();

        uint256 protocolFeeBps = controller_.AUCTION_FEE_BPS();
        if (protocolFeeBps >= BPS) revert Curve__InvalidFee();

        address kernel = controller_.KERNEL();
        address token = controller_.TOKEN();
        address vault = controller_.VAULT();
        if (kernel == address(0) || token == address(0) || vault == address(0)) revert Curve__InvalidController();

        KERNEL = IKernel(kernel);
        TOKEN = ITokenSupply(token);
        VAULT = vault;
        ADMIN = admin;
        WETH = IWETH(weth);
        SHAPE = shape;
        PROTOCOL_FEE_BPS = protocolFeeBps;

        IERC20(weth).forceApprove(vault, type(uint256).max);
    }

    receive() external payable nonReentrant whenLive {
        BuyQuote memory quote = _buyExactEth(msg.value, 0);
        emit UnguardedEthPurchase(msg.sender, quote.grossEthIn);
    }

    modifier onlyAdmin() {
        if (msg.sender != ADMIN) revert Curve__OnlyAdmin();
        _;
    }

    modifier whenLive() {
        if (!live) revert Curve__NotLive();
        if (paused) revert Curve__Paused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert Curve__ReentrantCall();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    function KEYCODE() public pure override returns (Keycode) {
        return CURVE_KEYCODE;
    }

    function configureDependencies() external override onlyController returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](1);
        dependencies[0] = MINTR_KEYCODE;
        MINTER = MINTR(getModuleAddress(MINTR_KEYCODE));

        emit CurveConfigured(address(CONTROLLER), SHAPE, address(WETH));
    }

    function requestPermissions() external pure override returns (Permissions[] memory requests) {
        requests = new Permissions[](1);
        requests[0] = Permissions({keycode: MINTR_KEYCODE, funcSelector: MINTR.mint.selector});
    }

    function setPaused(bool paused_) external onlyAdmin {
        paused = paused_;
        emit PausedUpdated(paused_);
    }

    function seedCurve(uint256 virtualSupplyWad, uint256 virtualReserveWad) external onlyAdmin nonReentrant {
        if (virtualSupplyWad == 0 || virtualReserveWad == 0) revert Curve__ZeroAmount();
        if (live) revert Curve__AlreadySeeded();

        MINTR minter = MINTER;
        if (address(minter) == address(0)) revert Curve__MinterNotConfigured();

        CurveState memory state = curveState();
        if (state.virtualSupplyWad != 0 || state.virtualReserveWad != 0) revert Curve__AlreadySeeded();

        IController.Receipt[] memory receipts = new IController.Receipt[](0);
        IController.StateUpdate[] memory updates = new IController.StateUpdate[](2);
        updates[0] = IController.StateUpdate({
            op: IController.Op.Set, slot: curveBaseSlot(address(WETH)), data: bytes32(virtualSupplyWad)
        });
        updates[1] = IController.StateUpdate({
            op: IController.Op.Set, slot: curveReserveSlot(address(WETH)), data: bytes32(virtualReserveWad)
        });

        minter.mint(address(this), 0, receipts, updates);
        live = true;

        emit CurveSeeded(virtualSupplyWad, virtualReserveWad);
    }

    function buyExactEth(uint256 minMintAmount, uint256 deadline)
        external
        payable
        nonReentrant
        whenLive
        returns (BuyQuote memory quote)
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert Curve__Expired();

        quote = _buyExactEth(msg.value, minMintAmount);
    }

    function buyExactTokensWithEth(uint256 mintAmount, uint256 deadline)
        external
        payable
        nonReentrant
        whenLive
        returns (BuyQuote memory quote)
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert Curve__Expired();

        quote = quoteBuyExactTokens(mintAmount);
        if (quote.grossEthIn > msg.value) revert Curve__Slippage(quote.grossEthIn, msg.value);

        _wrapEth(quote.grossEthIn);
        _executeBuy(quote);
        _refundEth(msg.sender, msg.value - quote.grossEthIn);
    }

    function quoteBuyExactTokens(uint256 mintAmount) public view returns (BuyQuote memory quote) {
        if (mintAmount == 0) revert Curve__ZeroAmount();

        QuoteContext memory context = _quoteContext();
        uint256 actualEndSupply = context.pricing.actualSupply + mintAmount;
        if (actualEndSupply > context.maxSupply) revert Curve__CapExceeded(actualEndSupply, context.maxSupply);

        (uint256 requiredBackingWad, uint256 curveReserveDeltaWad, bool usesNavFloor) =
            BancorNavMath.requiredBackingInWad(context.pricing, mintAmount);
        if (requiredBackingWad == 0) revert Curve__ZeroPrice();

        quote.grossEthIn = _grossEthInForBacking(requiredBackingWad);
        quote.mintAmount = mintAmount;
        quote.curveReserveDeltaWad = curveReserveDeltaWad;
        quote.curveSupplyDeltaWad = mintAmount;
        quote.usesNavFloor = usesNavFloor;
    }

    function quoteBuyExactEth(uint256 grossEthIn) public view returns (BuyQuote memory quote) {
        if (grossEthIn == 0) revert Curve__ZeroAmount();

        QuoteContext memory context = _quoteContext();
        uint256 backingInWad = _backingAmountFromGross(grossEthIn);
        if (backingInWad == 0) revert Curve__ZeroPrice();

        uint256 maxMintAmount = context.maxSupply - context.pricing.actualSupply;
        if (maxMintAmount == 0) revert Curve__CapExceeded(context.pricing.actualSupply, context.maxSupply);

        (uint256 mintAmount, uint256 curveReserveDeltaWad, bool usesNavFloor) =
            BancorNavMath.mintAmountForBackingWad(context.pricing, maxMintAmount, backingInWad);
        if (mintAmount == 0) revert Curve__ZeroPrice();

        quote.grossEthIn = grossEthIn;
        quote.mintAmount = mintAmount;
        quote.curveReserveDeltaWad = curveReserveDeltaWad;
        quote.curveSupplyDeltaWad = mintAmount;
        quote.usesNavFloor = usesNavFloor;
    }

    function curveBaseSlot(address asset) public pure returns (bytes32) {
        return _curveBaseSlot(asset);
    }

    function curveReserveSlot(address asset) public pure returns (bytes32) {
        return bytes32(uint256(_curveBaseSlot(asset)) + 1);
    }

    function curveState() public view returns (CurveState memory state) {
        bytes memory raw = KERNEL.viewData(_curveBaseSlot(address(WETH)), 2);
        (state.virtualSupplyWad, state.virtualReserveWad) = abi.decode(raw, (uint256, uint256));
    }

    function reserveBackingBalanceWad() public view returns (uint256) {
        return uint256(KERNEL.viewData(_amountSlot(Slots.BACKING_AMOUNT_SLOT, address(WETH))));
    }

    function navPriceWad() external view returns (uint256) {
        return BancorNavMath.navPriceWad(effectiveSupply(KERNEL, TOKEN), reserveBackingBalanceWad());
    }

    function navFloorPriceWad() external view returns (uint256) {
        return
            BancorNavMath.navFloorPriceWad(
                effectiveSupply(KERNEL, TOKEN), reserveBackingBalanceWad(), MIN_NAV_PREMIUM_BPS
            );
    }

    function bancorSpotPriceWad() external view returns (uint256) {
        CurveState memory state = curveState();
        return BancorNavMath.bancorSpotPriceWad(state.virtualSupplyWad, state.virtualReserveWad, uint8(SHAPE));
    }

    function reserveRatio() external view returns (uint256 numerator, uint256 denominator) {
        return BancorNavMath.reserveRatio(uint8(SHAPE));
    }

    function _buyExactEth(uint256 grossEthIn, uint256 minMintAmount) internal returns (BuyQuote memory quote) {
        quote = quoteBuyExactEth(grossEthIn);
        if (quote.mintAmount < minMintAmount) revert Curve__MintSlippage(quote.mintAmount, minMintAmount);

        _wrapEth(grossEthIn);
        _executeBuy(quote);
    }

    function _executeBuy(BuyQuote memory quote) internal {
        MINTR minter = MINTER;
        if (address(minter) == address(0)) revert Curve__MinterNotConfigured();

        IController.Receipt[] memory receipts = new IController.Receipt[](1);
        receipts[0] = IController.Receipt({asset: address(WETH), amount: quote.grossEthIn});

        IController.StateUpdate[] memory updates = new IController.StateUpdate[](2);
        updates[0] = IController.StateUpdate({
            op: IController.Op.Add, slot: curveReserveSlot(address(WETH)), data: bytes32(quote.curveReserveDeltaWad)
        });
        updates[1] = IController.StateUpdate({
            op: IController.Op.Add, slot: curveBaseSlot(address(WETH)), data: bytes32(quote.curveSupplyDeltaWad)
        });

        minter.mint(address(this), quote.mintAmount, receipts, updates);
        IERC20(address(TOKEN)).safeTransfer(msg.sender, quote.mintAmount);

        emit TokensPurchased(
            msg.sender,
            quote.mintAmount,
            quote.grossEthIn,
            quote.curveReserveDeltaWad,
            quote.curveSupplyDeltaWad,
            quote.usesNavFloor
        );
    }

    function _quoteContext() internal view returns (QuoteContext memory context) {
        uint256 actualSupply = effectiveSupply(KERNEL, TOKEN);
        if (actualSupply == 0) revert Curve__InvalidSupply();

        context.maxSupply = TOKEN.MAX_SUPPLY() - uint256(KERNEL.viewData(Slots.TEAM_LOCKED_TOKENS_SLOT));

        CurveState memory state = curveState();
        if (state.virtualSupplyWad == 0 || state.virtualReserveWad == 0) revert Curve__VirtualCurveNotSeeded();

        context.pricing = BancorNavMath.PricingContext({
            virtualSupply: state.virtualSupplyWad,
            curveReserveWad: state.virtualReserveWad,
            actualSupply: actualSupply,
            backingBalanceWad: reserveBackingBalanceWad(),
            navPremiumBps: MIN_NAV_PREMIUM_BPS,
            shape: uint8(SHAPE)
        });
    }

    function _grossEthInForBacking(uint256 requiredBacking) internal view returns (uint256 grossEthIn) {
        (uint256 teamBps, uint256 treasuryBps) = _paymentCreditBps();
        uint256 backingBps = BPS - teamBps - treasuryBps;
        uint256 requiredPostProtocol = Math.mulDiv(requiredBacking, BPS, backingBps, Math.Rounding.Ceil);
        uint256 upperBound = Math.mulDiv(requiredPostProtocol, BPS, BPS - PROTOCOL_FEE_BPS, Math.Rounding.Ceil);
        uint256 lowerBound = requiredBacking;

        while (lowerBound < upperBound) {
            uint256 mid = (lowerBound + upperBound) / 2;
            if (_backingAmountFromGross(mid) >= requiredBacking) upperBound = mid;
            else lowerBound = mid + 1;
        }

        grossEthIn = lowerBound;
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

    function _wrapEth(uint256 amount) internal {
        if (amount == 0) revert Curve__ZeroAmount();
        WETH.deposit{value: amount}();
    }

    function _refundEth(address recipient, uint256 amount) internal {
        if (amount == 0) return;

        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert Curve__EthRefundFailed();
    }

    function _curveBaseSlot(address asset) internal pure returns (bytes32 slot) {
        bytes32 namespace = CURVE_BASE_SLOT;
        assembly ("memory-safe") {
            mstore(0x00, namespace)
            mstore(0x20, and(asset, 0xffffffffffffffffffffffffffffffffffffffff))
            slot := keccak256(0x00, 0x40)
        }
    }

    function _amountSlot(bytes32 namespace, address asset) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0x00, namespace)
            mstore(0x20, and(asset, 0xffffffffffffffffffffffffffffffffffffffff))
            slot := keccak256(0x00, 0x40)
        }
    }
}
