// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MINTR} from "../src/modules/MINTR/MINTR.v1.sol";
import {Minter} from "../src/modules/MINTR/Minter.sol";
import {IssuanceCurve} from "../src/policies/IssuanceCurve.sol";
import {Controller} from "enten-v1/Controller.sol";
import {EntenToken} from "enten-v1/EntenToken.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IKernel} from "enten-v1/interfaces/IKernel.sol";
import {IVault} from "enten-v1/interfaces/IVault.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Module} from "enten-v1/Module.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Actions, Keycode, Permissions} from "enten-v1/Utils.sol";
import {Vault} from "enten-v1/Vault.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract CurveMockKernel is IKernel {
    address public immutable override VAULT;
    address public override accountingWriter;
    mapping(bytes32 slot => bytes32 data) internal _data;

    constructor(address vault) {
        VAULT = vault;
        accountingWriter = vault;
    }

    function setAccountingWriter(address writer) external {
        accountingWriter = writer;
    }

    function set(bytes32 slot, uint256 data) external {
        _data[slot] = bytes32(data);
    }

    function updateState(bytes32 startSlot, bytes calldata data) external override {
        if (data.length == 0) return;
        _data[startSlot] = abi.decode(data, (bytes32));
    }

    function updateState(bytes32 slot, bytes32 data) external override {
        _data[slot] = data;
    }

    function updateState(KernelCall[] calldata calls) external override {
        for (uint256 i; i < calls.length;) {
            _data[calls[i].slot] = calls[i].data;
            unchecked {
                ++i;
            }
        }
    }

    function add(bytes32 slot, bytes32 value) external override {
        _data[slot] = bytes32(uint256(_data[slot]) + uint256(value));
    }

    function add(KernelCall[] calldata calls) external override {
        for (uint256 i; i < calls.length;) {
            _data[calls[i].slot] = bytes32(uint256(_data[calls[i].slot]) + uint256(calls[i].data));
            unchecked {
                ++i;
            }
        }
    }

    function sub(bytes32 slot, bytes32 value) external override {
        _data[slot] = bytes32(uint256(_data[slot]) - uint256(value));
    }

    function sub(KernelCall[] calldata calls) external override {
        for (uint256 i; i < calls.length;) {
            _data[calls[i].slot] = bytes32(uint256(_data[calls[i].slot]) - uint256(calls[i].data));
            unchecked {
                ++i;
            }
        }
    }

    function viewData(bytes32 startSlot, uint256 nSlots) external view override returns (bytes memory data) {
        for (uint256 i; i < nSlots;) {
            data = bytes.concat(data, _data[bytes32(uint256(startSlot) + i)]);
            unchecked {
                ++i;
            }
        }
    }

    function viewData(bytes32[] calldata slots) external view override returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        for (uint256 i; i < slots.length;) {
            values[i] = _data[slots[i]];
            unchecked {
                ++i;
            }
        }
    }

    function viewData(bytes32 slot) external view override returns (bytes32) {
        return _data[slot];
    }
}

    contract CurveMockController is IController {
        uint256 public constant BPS = 10_000;
        uint256 public immutable AUCTION_FEE_BPS;
        address public immutable KERNEL;
        address public immutable TOKEN;
        address public immutable VAULT;

        mapping(Keycode keycode => address module) internal _modules;

        constructor(address kernel, address token, address vault, uint256 feeBps) {
            KERNEL = kernel;
            TOKEN = token;
            VAULT = vault;
            AUCTION_FEE_BPS = feeBps;
        }

        function setModule(Keycode keycode, address module) external {
            _modules[keycode] = module;
        }

        function settle(Settlement[] calldata) external pure override {}

        function sync(address, IVault.Bucket) external pure override {}

        function getModuleForKeycode(Keycode keycode) external view override returns (address) {
            return _modules[keycode];
        }

        function modulePermissions(Keycode, address, bytes4) external pure override returns (bool) {
            return true;
        }

        function isPolicyActive(address) external pure override returns (bool) {
            return true;
        }
    }

    contract MockMinterModule is MINTR {
        uint256 internal constant BPS = 10_000;
        bytes32 internal constant CURVE_RESERVE_SLOT = keccak256("enten.periphery.curve.bancor.reserve");
        bytes32 internal constant CURVE_SUPPLY_SLOT = keccak256("enten.periphery.curve.bancor.supply");

        CurveMockKernel public immutable kernel;
        ERC20Mock public immutable token;
        address public immutable vault;
        uint256 public immutable protocolFeeBps;

        address public lastPayer;
        uint256 public lastReceiptCount;
        address public lastReceiptAsset;
        uint256 public lastReceiptAmount;
        uint256 public lastMintAmount;
        uint256 public lastBackingAmount;
        uint256 public lastCurveReserveDeltaWad;
        uint256 public lastCurveSupplyDeltaWad;

        constructor(address controller_, address kernel_, address token_, address vault_, uint256 protocolFeeBps_)
            MINTR(controller_)
        {
            kernel = CurveMockKernel(kernel_);
            token = ERC20Mock(token_);
            vault = vault_;
            protocolFeeBps = protocolFeeBps_;
        }

        function mint(
            address user,
            uint256 mintAmount,
            IController.Receipt[] calldata receipts,
            IController.StateUpdate[] calldata updates
        ) external override {
            require(receipts.length == 1, "EXPECTED_ONE_RECEIPT");

            IController.Receipt calldata receipt = receipts[0];
            uint256 backingAmount = _backingAmountFromGross(receipt.amount);

            lastPayer = user;
            lastReceiptCount = receipts.length;
            lastReceiptAsset = receipt.asset;
            lastReceiptAmount = receipt.amount;
            lastMintAmount = mintAmount;
            lastBackingAmount = backingAmount;

            require(IERC20(receipt.asset).transferFrom(user, vault, receipt.amount), "TRANSFER_FROM_FAILED");
            token.mint(user, mintAmount);
            kernel.add(_amountSlot(Slots.BACKING_AMOUNT_SLOT, receipt.asset), bytes32(backingAmount));

            for (uint256 i; i < updates.length;) {
                require(updates[i].op == IController.Op.Add, "EXPECTED_ADD_UPDATE");
                kernel.add(updates[i].slot, updates[i].data);
                if (updates[i].slot == CURVE_RESERVE_SLOT) {
                    lastCurveReserveDeltaWad = uint256(updates[i].data);
                } else if (updates[i].slot == CURVE_SUPPLY_SLOT) {
                    lastCurveSupplyDeltaWad = uint256(updates[i].data);
                }
                unchecked {
                    ++i;
                }
            }
        }

        function _backingAmountFromGross(uint256 grossAmount) internal view returns (uint256 backingAmount) {
            uint256 protocolFee = Math.mulDiv(grossAmount, protocolFeeBps, BPS, Math.Rounding.Ceil);
            uint256 netAmount = grossAmount - protocolFee;
            uint256 teamBps = uint256(kernel.viewData(Slots.TEAM_PERCENTAGE_SLOT));
            uint256 treasuryBps = uint256(kernel.viewData(Slots.TREASURY_PERCENTAGE_SLOT));
            uint256 teamAmount = netAmount * teamBps / BPS;
            uint256 treasuryAmount = netAmount * treasuryBps / BPS;
            backingAmount = netAmount - teamAmount - treasuryAmount;
        }

        function _amountSlot(bytes32 namespace, address asset) internal pure returns (bytes32 slot) {
            return keccak256(abi.encode(namespace, asset));
        }
    }

    contract IssuanceCurveTest is Test {
        uint256 internal constant WAD = 1e18;
        uint256 internal constant BPS = 10_000;
        uint256 internal constant FEE_BPS = 250;
        uint256 internal constant TEAM_BPS = 500;
        uint256 internal constant TREASURY_BPS = 500;
        uint256 internal constant INITIAL_SUPPLY = 1_000 ether;
        uint256 internal constant INITIAL_BACKING = 1_000 ether;
        uint256 internal constant INITIAL_CURVE_SUPPLY = 1_000 ether;
        uint256 internal constant INITIAL_CURVE_RESERVE = 500 ether;
        uint256 internal constant MAX_SUPPLY = 10_000 ether;

        CurveMockKernel internal kernel;
        CurveMockController internal controller;
        MockMinterModule internal module;
        ERC20Mock internal token;
        ERC20Mock internal reserveAsset;
        ERC20Mock internal sixDecimalReserveAsset;
        ERC20Mock internal eightDecimalReserveAsset;
        ERC20Mock internal twelveDecimalReserveAsset;
        IssuanceCurve internal curve;

        address internal admin = makeAddr("Admin");
        address internal existingHolder = makeAddr("Existing Holder");
        address internal payer = makeAddr("Payer");
        address internal vault = makeAddr("Vault");

        function setUp() public {
            kernel = new CurveMockKernel(vault);
            token = new ERC20Mock();
            reserveAsset = new ERC20Mock();
            sixDecimalReserveAsset = new ERC20Mock();
            eightDecimalReserveAsset = new ERC20Mock();
            twelveDecimalReserveAsset = new ERC20Mock();
            controller = new CurveMockController(address(kernel), address(token), vault, FEE_BPS);

            token.mint(existingHolder, INITIAL_SUPPLY);
            _setMaxSupply(MAX_SUPPLY);
            _setFeeBps(TEAM_BPS, TREASURY_BPS);
            _setBacking(address(reserveAsset), INITIAL_BACKING);

            curve = _newCurve(_oneAssetConfig(address(reserveAsset), 18), IssuanceCurve.CurveShape.SquareRoot);
            module = _newModule();

            controller.setModule(Keycode.wrap("MINTR"), address(module));
            _seedVirtualCurve(INITIAL_CURVE_SUPPLY, INITIAL_CURVE_RESERVE);
        }

        function testConstructorStoresReserveAssetsAndScalars() public view {
            assertEq(curve.reserveAssetCount(), 1);
            assertEq(curve.reserveAssetAt(0), address(reserveAsset));
            assertEq(curve.defaultReserveAsset(), address(reserveAsset));
            assertTrue(curve.isReserveAsset(address(reserveAsset)));
            assertEq(curve.reserveAssetDecimals(address(reserveAsset)), 18);
            assertEq(curve.reserveAssetScalar(address(reserveAsset)), 1);
            assertEq(curve.PROTOCOL_FEE_BPS(), FEE_BPS);
            assertEq(curve.ADMIN(), admin);
            assertEq(Keycode.unwrap(curve.KEYCODE()), bytes5("CURVE"));
        }

        function testReserveRatioMatchesCurveShape() public {
            (uint256 numerator, uint256 denominator) = curve.reserveRatio();
            assertEq(numerator, 2);
            assertEq(denominator, 3);

            IssuanceCurve fourthRoot =
                _newCurve(_oneAssetConfig(address(reserveAsset), 18), IssuanceCurve.CurveShape.FourthRoot);
            (numerator, denominator) = fourthRoot.reserveRatio();
            assertEq(numerator, 4);
            assertEq(denominator, 5);

            IssuanceCurve linear = _newCurve(
                _oneAssetConfig(address(reserveAsset), 18), IssuanceCurve.CurveShape.Linear
            );
            (numerator, denominator) = linear.reserveRatio();
            assertEq(numerator, 1);
            assertEq(denominator, 2);
        }

        function testConstructorRejectsDuplicateReserveAsset() public {
            IssuanceCurve.ReserveAssetConfig[] memory configs = new IssuanceCurve.ReserveAssetConfig[](2);
            configs[0] = IssuanceCurve.ReserveAssetConfig({asset: address(reserveAsset), decimals: 18});
            configs[1] = IssuanceCurve.ReserveAssetConfig({asset: address(reserveAsset), decimals: 18});

            vm.expectRevert(
                abi.encodeWithSelector(IssuanceCurve.Curve__DuplicateReserveAsset.selector, address(reserveAsset))
            );
            _newCurve(configs, IssuanceCurve.CurveShape.SquareRoot);
        }

        function testConstructorRejectsDecimalsAboveEighteen() public {
            vm.expectRevert(IssuanceCurve.Curve__InvalidDecimals.selector);
            _newCurve(_oneAssetConfig(address(reserveAsset), 19), IssuanceCurve.CurveShape.SquareRoot);
        }

        function testConstructorRejectsTooManyReserveAssets() public {
            IssuanceCurve.ReserveAssetConfig[] memory configs =
                new IssuanceCurve.ReserveAssetConfig[](curve.MAX_RESERVE_ASSET_COUNT() + 1);

            for (uint256 i; i < configs.length;) {
                configs[i] = IssuanceCurve.ReserveAssetConfig({asset: address(new ERC20Mock()), decimals: 18});
                unchecked {
                    ++i;
                }
            }

            vm.expectRevert(abi.encodeWithSelector(IssuanceCurve.Curve__TooManyReserveAssets.selector, configs.length));
            _newCurve(configs, IssuanceCurve.CurveShape.SquareRoot);
        }

        function testConfigureDependenciesOnlyControllerAndRequestsIssuancePermission() public {
            vm.expectRevert();
            curve.configureDependencies();

            vm.prank(address(controller));
            Keycode[] memory dependencies = curve.configureDependencies();

            assertTrue(curve.configured());
            assertEq(address(curve.MINTER()), address(module));
            assertEq(dependencies.length, 1);
            assertEq(Keycode.unwrap(dependencies[0]), bytes5("MINTR"));

            Permissions[] memory permissions = curve.requestPermissions();
            assertEq(permissions.length, 1);
            assertEq(Keycode.unwrap(permissions[0].keycode), bytes5("MINTR"));
            assertEq(permissions[0].funcSelector, MINTR.mint.selector);
        }

        function testSetPausedOnlyAdminAndBlocksBuy() public {
            _configureCurve(curve);

            vm.expectRevert(IssuanceCurve.Curve__OnlyAdmin.selector);
            curve.setPaused(true);

            vm.prank(admin);
            curve.setPaused(true);
            assertTrue(curve.paused());

            vm.expectRevert(IssuanceCurve.Curve__Paused.selector);
            curve.buyExactTokens(1 ether, type(uint256).max, block.timestamp);
        }

        function testQuoteRevertsWhenVirtualCurveNotSeeded() public {
            _seedVirtualCurve(0, INITIAL_CURVE_RESERVE);
            vm.expectRevert(IssuanceCurve.Curve__VirtualCurveNotSeeded.selector);
            curve.quoteBuyExactTokens(1 ether);

            _seedVirtualCurve(INITIAL_CURVE_SUPPLY, 0);
            vm.expectRevert(IssuanceCurve.Curve__VirtualCurveNotSeeded.selector);
            curve.quoteBuyExactTokens(1 ether);
        }

        function testQuoteRevertsForZeroAmounts() public {
            vm.expectRevert(IssuanceCurve.Curve__ZeroAmount.selector);
            curve.quoteBuyExactTokens(0);

            vm.expectRevert(IssuanceCurve.Curve__ZeroAmount.selector);
            curve.quoteBuyExactAssets(0);
        }

        function testQuoteExactTokensUsesNavFloorAndGrossesUpForDispatchFees() public view {
            IssuanceCurve.BuyQuote memory quote = curve.quoteBuyExactTokens(100 ether);

            uint256 requiredBacking = 105 ether;
            uint256 expectedGross = _grossAssetInForBacking(requiredBacking);

            assertTrue(quote.usesNavFloor);
            assertEq(quote.paymentAsset, address(reserveAsset));
            assertEq(quote.mintAmount, 100 ether);
            assertEq(quote.grossAssetIn, expectedGross);
            assertEq(quote.curveSupplyDeltaWad, 100 ether);
            assertLt(quote.curveReserveDeltaWad, requiredBacking);
            assertGe(_backingAmountFromGross(quote.grossAssetIn), requiredBacking);
            assertLt(_backingAmountFromGross(quote.grossAssetIn - 1), requiredBacking);
        }

        function testQuoteExactTokensCanUseBancorPriceWhenCurveReserveDominates() public {
            _setCurveReserve(5_000 ether);

            IssuanceCurve.BuyQuote memory quote = curve.quoteBuyExactTokens(100 ether);

            assertFalse(quote.usesNavFloor);
            assertEq(quote.mintAmount, 100 ether);
            assertEq(quote.curveSupplyDeltaWad, 100 ether);
            assertGe(_backingAmountFromGross(quote.grossAssetIn) * WAD, quote.curveReserveDeltaWad);
        }

        function testQuoteExactAssetsCalculatesMintFromBackingShareOfGrossReceipts() public view {
            uint256 grossAssetIn = 120 ether;
            uint256 backingAmount = _backingAmountFromGross(grossAssetIn);

            IssuanceCurve.BuyQuote memory quote = curve.quoteBuyExactAssets(grossAssetIn);
            IssuanceCurve.BuyQuote memory exactMintQuote = curve.quoteBuyExactTokens(quote.mintAmount);

            assertEq(quote.paymentAsset, address(reserveAsset));
            assertEq(quote.grossAssetIn, grossAssetIn);
            assertGt(quote.mintAmount, 0);
            assertEq(quote.curveSupplyDeltaWad, quote.mintAmount);
            assertLe(exactMintQuote.grossAssetIn, grossAssetIn);
            assertLe(grossAssetIn - exactMintQuote.grossAssetIn, 2);
            assertGe(backingAmount, _backingAmountFromGross(exactMintQuote.grossAssetIn));
        }

        function testQuoteExactAssetsScalesDecimalReserveAssets() public {
            IssuanceCurve decimalCurve = _newCurve(_multiDecimalAssetConfig(), IssuanceCurve.CurveShape.SquareRoot);
            _clearBacking();
            _setBacking(address(sixDecimalReserveAsset), 1_000_000e6);

            uint256 grossAssetIn = 120e6;
            IssuanceCurve.BuyQuote memory quote =
                decimalCurve.quoteBuyExactAssets(address(sixDecimalReserveAsset), grossAssetIn);
            IssuanceCurve.BuyQuote memory exactMintQuote =
                decimalCurve.quoteBuyExactTokens(address(sixDecimalReserveAsset), quote.mintAmount);

            assertEq(quote.paymentAsset, address(sixDecimalReserveAsset));
            assertEq(quote.grossAssetIn, grossAssetIn);
            assertLe(exactMintQuote.grossAssetIn, grossAssetIn);
            assertLe(grossAssetIn - exactMintQuote.grossAssetIn, 2);
            assertEq(decimalCurve.reserveBackingBalanceOfWad(address(sixDecimalReserveAsset)), 1_000_000 ether);
        }

        function testMixedDecimalReserveBackingSumsIntoAggregateWadBacking() public {
            IssuanceCurve decimalCurve = _newCurve(_multiDecimalAssetConfig(), IssuanceCurve.CurveShape.SquareRoot);

            _setBacking(address(reserveAsset), 250 ether);
            _setBacking(address(sixDecimalReserveAsset), 1_000_000e6);
            _setBacking(address(eightDecimalReserveAsset), 50e8);
            _setBacking(address(twelveDecimalReserveAsset), 123_456e12);

            assertEq(decimalCurve.reserveAssetScalar(address(reserveAsset)), 1);
            assertEq(decimalCurve.reserveAssetScalar(address(sixDecimalReserveAsset)), 1e12);
            assertEq(decimalCurve.reserveAssetScalar(address(eightDecimalReserveAsset)), 1e10);
            assertEq(decimalCurve.reserveAssetScalar(address(twelveDecimalReserveAsset)), 1e6);

            assertEq(decimalCurve.reserveBackingBalanceOfWad(address(reserveAsset)), 250 ether);
            assertEq(decimalCurve.reserveBackingBalanceOfWad(address(sixDecimalReserveAsset)), 1_000_000 ether);
            assertEq(decimalCurve.reserveBackingBalanceOfWad(address(eightDecimalReserveAsset)), 50 ether);
            assertEq(decimalCurve.reserveBackingBalanceOfWad(address(twelveDecimalReserveAsset)), 123_456 ether);
            assertEq(decimalCurve.reserveBackingBalanceWad(), 1_123_756 ether);
        }

        function testBuyExactTokensDelegatesGrossReceiptMintAndVirtualCurveDeltas() public {
            _configureCurve(curve);

            IssuanceCurve.BuyQuote memory expectedQuote = curve.quoteBuyExactTokens(100 ether);
            uint256 expectedBackingAmount = _backingAmountFromGross(expectedQuote.grossAssetIn);
            assertTrue(expectedQuote.usesNavFloor);
            assertLt(expectedQuote.curveReserveDeltaWad, expectedBackingAmount);

            reserveAsset.mint(payer, expectedQuote.grossAssetIn);
            vm.startPrank(payer);
            reserveAsset.approve(address(module), expectedQuote.grossAssetIn);
            IssuanceCurve.BuyQuote memory quote =
                curve.buyExactTokens(100 ether, expectedQuote.grossAssetIn, block.timestamp);
            vm.stopPrank();

            assertEq(quote.grossAssetIn, expectedQuote.grossAssetIn);
            assertEq(token.balanceOf(payer), 100 ether);
            assertEq(reserveAsset.balanceOf(payer), 0);
            assertEq(reserveAsset.balanceOf(vault), expectedQuote.grossAssetIn);
            assertEq(_backing(address(reserveAsset)), INITIAL_BACKING + expectedBackingAmount);
            assertEq(curve.curveSupplyBalanceWad(), INITIAL_CURVE_SUPPLY + expectedQuote.curveSupplyDeltaWad);
            assertEq(curve.curveReserveBalanceWad(), INITIAL_CURVE_RESERVE + expectedQuote.curveReserveDeltaWad);

            assertEq(module.lastPayer(), payer);
            assertEq(module.lastReceiptCount(), 1);
            assertEq(module.lastReceiptAsset(), address(reserveAsset));
            assertEq(module.lastReceiptAmount(), expectedQuote.grossAssetIn);
            assertEq(module.lastMintAmount(), expectedQuote.mintAmount);
            assertEq(module.lastBackingAmount(), expectedBackingAmount);
            assertEq(module.lastCurveReserveDeltaWad(), expectedQuote.curveReserveDeltaWad);
            assertEq(module.lastCurveSupplyDeltaWad(), expectedQuote.curveSupplyDeltaWad);
        }

        function testBuyExactAssetsDelegatesGrossReceiptAndMintsCalculatedAmountToPayer() public {
            _configureCurve(curve);

            uint256 grossAssetIn = 120 ether;
            IssuanceCurve.BuyQuote memory expectedQuote = curve.quoteBuyExactAssets(grossAssetIn);
            reserveAsset.mint(payer, grossAssetIn);

            vm.startPrank(payer);
            reserveAsset.approve(address(module), grossAssetIn);
            IssuanceCurve.BuyQuote memory quote =
                curve.buyExactAssets(grossAssetIn, expectedQuote.mintAmount, block.timestamp);
            vm.stopPrank();

            assertEq(quote.mintAmount, expectedQuote.mintAmount);
            assertEq(token.balanceOf(payer), expectedQuote.mintAmount);
            assertEq(reserveAsset.balanceOf(vault), grossAssetIn);
            assertEq(module.lastReceiptAmount(), grossAssetIn);
            assertEq(module.lastMintAmount(), expectedQuote.mintAmount);
            assertEq(curve.curveSupplyBalanceWad(), INITIAL_CURVE_SUPPLY + expectedQuote.curveSupplyDeltaWad);
            assertEq(curve.curveReserveBalanceWad(), INITIAL_CURVE_RESERVE + expectedQuote.curveReserveDeltaWad);
        }

        function testBuyExactTokensUsesDefaultReserveAsset() public {
            _configureCurve(curve);
            IssuanceCurve.BuyQuote memory expectedQuote = curve.quoteBuyExactTokens(25 ether);
            reserveAsset.mint(payer, expectedQuote.grossAssetIn);

            vm.startPrank(payer);
            reserveAsset.approve(address(module), expectedQuote.grossAssetIn);
            IssuanceCurve.BuyQuote memory quote =
                curve.buyExactTokens(25 ether, expectedQuote.grossAssetIn, block.timestamp);
            vm.stopPrank();

            assertEq(quote.paymentAsset, address(reserveAsset));
            assertEq(token.balanceOf(payer), 25 ether);
        }

        function testBuyExactTokensRevertsWhenPolicyNotConfigured() public {
            vm.expectRevert(IssuanceCurve.Curve__NotConfigured.selector);
            curve.buyExactTokens(1 ether, type(uint256).max, block.timestamp);
        }

        function testBuyExactTokensRevertsForExpiredDeadline() public {
            _configureCurve(curve);

            vm.warp(2);
            vm.expectRevert(IssuanceCurve.Curve__Expired.selector);
            curve.buyExactTokens(1 ether, type(uint256).max, 1);
        }

        function testBuyExactTokensRevertsForSlippage() public {
            _configureCurve(curve);
            IssuanceCurve.BuyQuote memory quote = curve.quoteBuyExactTokens(1 ether);

            vm.expectRevert(
                abi.encodeWithSelector(
                    IssuanceCurve.Curve__Slippage.selector, quote.grossAssetIn, quote.grossAssetIn - 1
                )
            );
            curve.buyExactTokens(1 ether, quote.grossAssetIn - 1, block.timestamp);
        }

        function testBuyExactAssetsRevertsForMintSlippage() public {
            _configureCurve(curve);
            IssuanceCurve.BuyQuote memory quote = curve.quoteBuyExactAssets(120 ether);

            vm.expectRevert(
                abi.encodeWithSelector(
                    IssuanceCurve.Curve__MintSlippage.selector, quote.mintAmount, quote.mintAmount + 1
                )
            );
            curve.buyExactAssets(120 ether, quote.mintAmount + 1, block.timestamp);
        }

        function testBurnDoesNotMoveVirtualCurveStateOrBancorDelta() public {
            IssuanceCurve.BuyQuote memory beforeBurn = curve.quoteBuyExactTokens(10 ether);

            token.burn(existingHolder, 200 ether);

            IssuanceCurve.BuyQuote memory afterBurn = curve.quoteBuyExactTokens(10 ether);

            assertEq(token.totalSupply(), INITIAL_SUPPLY - 200 ether);
            assertEq(curve.curveSupplyBalanceWad(), INITIAL_CURVE_SUPPLY);
            assertEq(curve.curveReserveBalanceWad(), INITIAL_CURVE_RESERVE);
            assertEq(afterBurn.curveSupplyDeltaWad, beforeBurn.curveSupplyDeltaWad);
            assertEq(afterBurn.curveReserveDeltaWad, beforeBurn.curveReserveDeltaWad);
        }

        function testRedemptionChangesActualStateButNotVirtualCurveState() public {
            token.burn(existingHolder, 200 ether);
            _setBacking(address(reserveAsset), 600 ether);

            IssuanceCurve.BuyQuote memory quote = curve.quoteBuyExactTokens(10 ether);

            assertEq(curve.navPriceWad(), 0.75 ether);
            assertEq(quote.curveSupplyDeltaWad, 10 ether);
            assertEq(curve.curveSupplyBalanceWad(), INITIAL_CURVE_SUPPLY);
            assertEq(curve.curveReserveBalanceWad(), INITIAL_CURVE_RESERVE);
        }

        function testQuoteRevertsForUnsupportedReserveAsset() public {
            ERC20Mock unsupported = new ERC20Mock();

            vm.expectRevert(
                abi.encodeWithSelector(IssuanceCurve.Curve__UnsupportedReserveAsset.selector, address(unsupported))
            );
            curve.quoteBuyExactTokens(address(unsupported), 1 ether);
        }

        function testQuoteRevertsWhenMaxSupplyIsMissing() public {
            _setMaxSupply(0);

            vm.expectRevert(IssuanceCurve.Curve__MaxSupplyNotSet.selector);
            curve.quoteBuyExactTokens(1 ether);
        }

        function testQuoteRevertsWhenMaxSupplyIsTooLarge() public {
            _setMaxSupply(curve.MAX_SAFE_SUPPLY() + 1);

            vm.expectRevert(
                abi.encodeWithSelector(IssuanceCurve.Curve__MaxSupplyTooLarge.selector, curve.MAX_SAFE_SUPPLY() + 1)
            );
            curve.quoteBuyExactTokens(1 ether);
        }

        function testQuoteRevertsWhenActualSupplyAlreadyExceedsMaxSupply() public {
            _setMaxSupply(INITIAL_SUPPLY - 1);

            vm.expectRevert(
                abi.encodeWithSelector(
                    IssuanceCurve.Curve__SupplyExceedsMaxSupply.selector, INITIAL_SUPPLY, INITIAL_SUPPLY - 1
                )
            );
            curve.quoteBuyExactTokens(1 ether);
        }

        function testQuoteRevertsWhenCapWouldBeExceeded() public {
            _setMaxSupply(INITIAL_SUPPLY + 1 ether - 1);

            vm.expectRevert(
                abi.encodeWithSelector(
                    IssuanceCurve.Curve__CapExceeded.selector, INITIAL_SUPPLY + 1 ether, INITIAL_SUPPLY + 1 ether - 1
                )
            );
            curve.quoteBuyExactTokens(1 ether);
        }

        function testQuoteRevertsWhenPaymentFeeConfigLeavesNoBacking() public {
            _setFeeBps(5_000, 5_000);

            vm.expectRevert(IssuanceCurve.Curve__InvalidFee.selector);
            curve.quoteBuyExactTokens(1 ether);
        }

        function _newCurve(IssuanceCurve.ReserveAssetConfig[] memory configs, IssuanceCurve.CurveShape shape)
            internal
            returns (IssuanceCurve)
        {
            return new IssuanceCurve(address(controller), configs, shape, admin);
        }

        function _newModule() internal returns (MockMinterModule) {
            return new MockMinterModule(address(controller), address(kernel), address(token), vault, FEE_BPS);
        }

        function _oneAssetConfig(address asset, uint8 decimals)
            internal
            pure
            returns (IssuanceCurve.ReserveAssetConfig[] memory configs)
        {
            configs = new IssuanceCurve.ReserveAssetConfig[](1);
            configs[0] = IssuanceCurve.ReserveAssetConfig({asset: asset, decimals: decimals});
        }

        function _multiDecimalAssetConfig() internal view returns (IssuanceCurve.ReserveAssetConfig[] memory configs) {
            configs = new IssuanceCurve.ReserveAssetConfig[](4);
            configs[0] = IssuanceCurve.ReserveAssetConfig({asset: address(reserveAsset), decimals: 18});
            configs[1] = IssuanceCurve.ReserveAssetConfig({asset: address(sixDecimalReserveAsset), decimals: 6});
            configs[2] = IssuanceCurve.ReserveAssetConfig({asset: address(eightDecimalReserveAsset), decimals: 8});
            configs[3] = IssuanceCurve.ReserveAssetConfig({asset: address(twelveDecimalReserveAsset), decimals: 12});
        }

        function _configureCurve(IssuanceCurve targetCurve) internal {
            vm.prank(address(controller));
            targetCurve.configureDependencies();
        }

        function _seedVirtualCurve(uint256 supplyWad, uint256 reserveWad) internal {
            _setCurveSupply(supplyWad);
            _setCurveReserve(reserveWad);
        }

        function _setCurveSupply(uint256 amount) internal {
            kernel.set(curve.CURVE_SUPPLY_SLOT(), amount);
        }

        function _setCurveReserve(uint256 amount) internal {
            kernel.set(curve.CURVE_RESERVE_SLOT(), amount);
        }

        function _setMaxSupply(uint256 amount) internal {
            kernel.set(Slots.MAX_SUPPLY_SLOT, amount);
        }

        function _setFeeBps(uint256 teamBps, uint256 treasuryBps) internal {
            kernel.set(Slots.TEAM_PERCENTAGE_SLOT, teamBps);
            kernel.set(Slots.TREASURY_PERCENTAGE_SLOT, treasuryBps);
        }

        function _setBacking(address asset, uint256 amount) internal {
            kernel.set(_amountSlot(Slots.BACKING_AMOUNT_SLOT, asset), amount);
        }

        function _backing(address asset) internal view returns (uint256) {
            return uint256(kernel.viewData(_amountSlot(Slots.BACKING_AMOUNT_SLOT, asset)));
        }

        function _clearBacking() internal {
            _setBacking(address(reserveAsset), 0);
            _setBacking(address(sixDecimalReserveAsset), 0);
            _setBacking(address(eightDecimalReserveAsset), 0);
            _setBacking(address(twelveDecimalReserveAsset), 0);
        }

        function _amountSlot(bytes32 namespace, address asset) internal pure returns (bytes32 slot) {
            return keccak256(abi.encode(namespace, asset));
        }

        function _grossAssetInForBacking(uint256 requiredBacking) internal pure returns (uint256 grossAssetIn) {
            uint256 backingBps = BPS - TEAM_BPS - TREASURY_BPS;
            uint256 requiredPostProtocol = Math.mulDiv(requiredBacking, BPS, backingBps, Math.Rounding.Ceil);
            uint256 upperBound = Math.mulDiv(requiredPostProtocol, BPS, BPS - FEE_BPS, Math.Rounding.Ceil);
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

        function _backingAmountFromGross(uint256 grossAmount) internal pure returns (uint256 backingAmount) {
            uint256 protocolFee = Math.mulDiv(grossAmount, FEE_BPS, BPS, Math.Rounding.Ceil);
            uint256 netAmount = grossAmount - protocolFee;
            uint256 teamAmount = netAmount * TEAM_BPS / BPS;
            uint256 treasuryAmount = netAmount * TREASURY_BPS / BPS;
            backingAmount = netAmount - teamAmount - treasuryAmount;
        }
    }

    contract IssuanceCurveIntegrationTest is Test {
        uint256 internal constant WAD = 1e18;
        uint256 internal constant BPS = 10_000;
        uint256 internal constant FEE_BPS = 250;
        uint256 internal constant TEAM_BPS = 500;
        uint256 internal constant TREASURY_BPS = 500;
        uint256 internal constant INITIAL_SUPPLY = 1_000 ether;
        uint256 internal constant INITIAL_BACKING = 1_000 ether;
        uint256 internal constant INITIAL_CURVE_SUPPLY = 1_000 ether;
        uint256 internal constant INITIAL_CURVE_RESERVE = 500 ether;
        uint256 internal constant MAX_SUPPLY = 10_000 ether;

        Controller internal controller;
        Kernel internal kernel;
        Vault internal vault;
        EntenToken internal token;
        Minter internal minter;
        IssuanceCurve internal curve;
        ERC20Mock internal reserveAsset;

        address internal admin = makeAddr("Admin");
        address internal protocolCollector = makeAddr("Protocol Collector");
        address internal existingHolder = makeAddr("Existing Holder");
        address internal payer = makeAddr("Payer");

        function setUp() public {
            uint256 nonce = vm.getNonce(address(this));
            address predictedKernel = vm.computeCreateAddress(address(this), nonce);
            address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
            address predictedToken = vm.computeCreateAddress(address(this), nonce + 2);
            address predictedController = vm.computeCreateAddress(address(this), nonce + 3);

            kernel = new Kernel(predictedController, predictedVault);
            vault = new Vault(predictedController, predictedKernel);
            token = new EntenToken("Enten", "ENTEN", predictedController, existingHolder, INITIAL_SUPPLY, MAX_SUPPLY);
            controller = new Controller(admin, protocolCollector, predictedKernel, predictedVault, predictedToken);

            reserveAsset = new ERC20Mock();
            minter = new Minter(address(controller));
            curve = _newCurve(_oneAssetConfig(address(reserveAsset), 18), IssuanceCurve.CurveShape.SquareRoot);

            _seedKernelForIssuance();
            reserveAsset.mint(address(vault), INITIAL_BACKING);

            vm.startPrank(admin);
            controller.executeAction(Actions.InstallModule, address(minter));
            controller.setMintPermission(Keycode.wrap("MINTR"), true);
            controller.executeAction(Actions.ActivatePolicy, address(curve));
            vm.stopPrank();
        }

        function testIntegrationBuyExactTokensFlowsThroughControllerVaultKernelAndToken() public {
            uint256 mintAmount = 100 ether;
            uint256 spotPriceBefore = curve.bancorSpotPriceWad();
            IssuanceCurve.BuyQuote memory expectedQuote = curve.quoteBuyExactTokens(mintAmount);
            (uint256 protocolFee, uint256 backingAmount, uint256 teamAmount, uint256 treasuryAmount) =
                _paymentSplit(expectedQuote.grossAssetIn);

            reserveAsset.mint(payer, expectedQuote.grossAssetIn);
            vm.startPrank(payer);
            reserveAsset.approve(address(vault), expectedQuote.grossAssetIn);
            IssuanceCurve.BuyQuote memory quote =
                curve.buyExactTokens(mintAmount, expectedQuote.grossAssetIn, block.timestamp);
            vm.stopPrank();

            assertEq(quote.paymentAsset, expectedQuote.paymentAsset);
            assertEq(quote.grossAssetIn, expectedQuote.grossAssetIn);
            assertEq(quote.mintAmount, mintAmount);
            assertEq(quote.curveReserveDeltaWad, expectedQuote.curveReserveDeltaWad);
            assertEq(quote.curveSupplyDeltaWad, expectedQuote.curveSupplyDeltaWad);
            assertEq(quote.usesNavFloor, expectedQuote.usesNavFloor);

            assertEq(token.balanceOf(payer), mintAmount);
            assertEq(token.totalSupply(), INITIAL_SUPPLY + mintAmount);
            assertEq(reserveAsset.balanceOf(payer), 0);
            assertEq(reserveAsset.balanceOf(address(vault)), INITIAL_BACKING + expectedQuote.grossAssetIn - protocolFee);
            assertEq(reserveAsset.balanceOf(protocolCollector), protocolFee);

            assertEq(_bucket(Slots.BACKING_AMOUNT_SLOT), INITIAL_BACKING + backingAmount);
            assertEq(_bucket(Slots.TEAM_AMOUNT_SLOT), teamAmount);
            assertEq(_bucket(Slots.TREASURY_AMOUNT_SLOT), treasuryAmount);
            assertEq(curve.curveSupplyBalanceWad(), INITIAL_CURVE_SUPPLY + expectedQuote.curveSupplyDeltaWad);
            assertEq(curve.curveReserveBalanceWad(), INITIAL_CURVE_RESERVE + expectedQuote.curveReserveDeltaWad);
            assertGt(curve.bancorSpotPriceWad(), spotPriceBefore);
        }

        function testIntegrationBuyExactAssetsFlowsThroughControllerVaultKernelAndToken() public {
            uint256 grossAssetIn = 120 ether;
            uint256 spotPriceBefore = curve.bancorSpotPriceWad();
            IssuanceCurve.BuyQuote memory expectedQuote = curve.quoteBuyExactAssets(grossAssetIn);
            (uint256 protocolFee, uint256 backingAmount, uint256 teamAmount, uint256 treasuryAmount) =
                _paymentSplit(grossAssetIn);

            reserveAsset.mint(payer, grossAssetIn);
            vm.startPrank(payer);
            reserveAsset.approve(address(vault), grossAssetIn);
            IssuanceCurve.BuyQuote memory quote =
                curve.buyExactAssets(grossAssetIn, expectedQuote.mintAmount, block.timestamp);
            vm.stopPrank();

            assertEq(quote.paymentAsset, expectedQuote.paymentAsset);
            assertEq(quote.grossAssetIn, grossAssetIn);
            assertEq(quote.mintAmount, expectedQuote.mintAmount);
            assertEq(quote.curveReserveDeltaWad, expectedQuote.curveReserveDeltaWad);
            assertEq(quote.curveSupplyDeltaWad, expectedQuote.curveSupplyDeltaWad);
            assertEq(quote.usesNavFloor, expectedQuote.usesNavFloor);

            assertEq(token.balanceOf(payer), expectedQuote.mintAmount);
            assertEq(token.totalSupply(), INITIAL_SUPPLY + expectedQuote.mintAmount);
            assertEq(reserveAsset.balanceOf(payer), 0);
            assertEq(reserveAsset.balanceOf(address(vault)), INITIAL_BACKING + grossAssetIn - protocolFee);
            assertEq(reserveAsset.balanceOf(protocolCollector), protocolFee);

            assertEq(_bucket(Slots.BACKING_AMOUNT_SLOT), INITIAL_BACKING + backingAmount);
            assertEq(_bucket(Slots.TEAM_AMOUNT_SLOT), teamAmount);
            assertEq(_bucket(Slots.TREASURY_AMOUNT_SLOT), treasuryAmount);
            assertEq(curve.curveSupplyBalanceWad(), INITIAL_CURVE_SUPPLY + expectedQuote.curveSupplyDeltaWad);
            assertEq(curve.curveReserveBalanceWad(), INITIAL_CURVE_RESERVE + expectedQuote.curveReserveDeltaWad);
            assertGt(curve.bancorSpotPriceWad(), spotPriceBefore);
        }

        function testIntegrationNavFloorHandoffLetsCurveRetakePricingWithoutJumpingVirtualReserve() public {
            uint256 startingCurveReserve = 680 ether;
            uint256 mintAmount = 100 ether;
            _store(curve.CURVE_RESERVE_SLOT(), startingCurveReserve);

            uint256 spotPriceBefore = curve.bancorSpotPriceWad();
            uint256 navFloorBefore = curve.navFloorPriceWad();
            IssuanceCurve.BuyQuote memory fallbackQuote = curve.quoteBuyExactTokens(mintAmount);
            (, uint256 backingAmount,,) = _paymentSplit(fallbackQuote.grossAssetIn);

            assertLt(spotPriceBefore, navFloorBefore);
            assertTrue(fallbackQuote.usesNavFloor);
            assertLt(fallbackQuote.curveReserveDeltaWad, backingAmount);

            reserveAsset.mint(payer, fallbackQuote.grossAssetIn);
            vm.startPrank(payer);
            reserveAsset.approve(address(vault), fallbackQuote.grossAssetIn);
            curve.buyExactTokens(mintAmount, fallbackQuote.grossAssetIn, block.timestamp);
            vm.stopPrank();

            assertEq(curve.curveSupplyBalanceWad(), INITIAL_CURVE_SUPPLY + fallbackQuote.curveSupplyDeltaWad);
            assertEq(curve.curveReserveBalanceWad(), startingCurveReserve + fallbackQuote.curveReserveDeltaWad);
            assertEq(_bucket(Slots.BACKING_AMOUNT_SLOT), INITIAL_BACKING + backingAmount);
            assertGt(curve.bancorSpotPriceWad(), spotPriceBefore);
            assertGt(curve.bancorSpotPriceWad(), curve.navFloorPriceWad());

            IssuanceCurve.BuyQuote memory curveQuote = curve.quoteBuyExactTokens(1 ether);
            assertFalse(curveQuote.usesNavFloor);
        }

        function testIntegrationBuyRevertsWhenControllerMintPermissionDisabled() public {
            uint256 mintAmount = 1 ether;
            IssuanceCurve.BuyQuote memory quote = curve.quoteBuyExactTokens(mintAmount);
            reserveAsset.mint(payer, quote.grossAssetIn);

            vm.prank(admin);
            controller.setMintPermission(Keycode.wrap("MINTR"), false);

            vm.startPrank(payer);
            reserveAsset.approve(address(vault), quote.grossAssetIn);
            vm.expectRevert(IController.Controller__MintPermissionDenied.selector);
            curve.buyExactTokens(mintAmount, quote.grossAssetIn, block.timestamp);
            vm.stopPrank();

            assertEq(token.balanceOf(payer), 0);
            assertEq(reserveAsset.balanceOf(address(vault)), INITIAL_BACKING);
            assertEq(reserveAsset.balanceOf(protocolCollector), 0);
            assertEq(_bucket(Slots.BACKING_AMOUNT_SLOT), INITIAL_BACKING);
            assertEq(curve.curveSupplyBalanceWad(), INITIAL_CURVE_SUPPLY);
            assertEq(curve.curveReserveBalanceWad(), INITIAL_CURVE_RESERVE);
        }

        function testIntegrationBuyRevertsWhenPolicyPermissionRevoked() public {
            uint256 mintAmount = 1 ether;
            IssuanceCurve.BuyQuote memory quote = curve.quoteBuyExactTokens(mintAmount);
            reserveAsset.mint(payer, quote.grossAssetIn);

            vm.prank(admin);
            controller.executeAction(Actions.DeactivatePolicy, address(curve));

            vm.startPrank(payer);
            reserveAsset.approve(address(vault), quote.grossAssetIn);
            vm.expectRevert(abi.encodeWithSelector(Module.Module__PolicyNotPermitted.selector, address(curve)));
            curve.buyExactTokens(mintAmount, quote.grossAssetIn, block.timestamp);
            vm.stopPrank();

            assertEq(token.balanceOf(payer), 0);
            assertEq(reserveAsset.balanceOf(address(vault)), INITIAL_BACKING);
            assertEq(reserveAsset.balanceOf(protocolCollector), 0);
            assertEq(_bucket(Slots.BACKING_AMOUNT_SLOT), INITIAL_BACKING);
            assertEq(curve.curveSupplyBalanceWad(), INITIAL_CURVE_SUPPLY);
            assertEq(curve.curveReserveBalanceWad(), INITIAL_CURVE_RESERVE);
        }

        function testIntegrationBuyRevertsWithoutVaultAllowanceAndLeavesStateUnchanged() public {
            uint256 mintAmount = 1 ether;
            IssuanceCurve.BuyQuote memory quote = curve.quoteBuyExactTokens(mintAmount);
            reserveAsset.mint(payer, quote.grossAssetIn);

            vm.prank(payer);
            vm.expectRevert();
            curve.buyExactTokens(mintAmount, quote.grossAssetIn, block.timestamp);

            assertEq(token.balanceOf(payer), 0);
            assertEq(reserveAsset.balanceOf(payer), quote.grossAssetIn);
            assertEq(reserveAsset.balanceOf(address(vault)), INITIAL_BACKING);
            assertEq(reserveAsset.balanceOf(protocolCollector), 0);
            assertEq(_bucket(Slots.BACKING_AMOUNT_SLOT), INITIAL_BACKING);
            assertEq(_bucket(Slots.TEAM_AMOUNT_SLOT), 0);
            assertEq(_bucket(Slots.TREASURY_AMOUNT_SLOT), 0);
            assertEq(curve.curveSupplyBalanceWad(), INITIAL_CURVE_SUPPLY);
            assertEq(curve.curveReserveBalanceWad(), INITIAL_CURVE_RESERVE);
        }

        function _newCurve(IssuanceCurve.ReserveAssetConfig[] memory configs, IssuanceCurve.CurveShape shape)
            internal
            returns (IssuanceCurve)
        {
            return new IssuanceCurve(address(controller), configs, shape, admin);
        }

        function _oneAssetConfig(address asset, uint8 decimals)
            internal
            pure
            returns (IssuanceCurve.ReserveAssetConfig[] memory configs)
        {
            configs = new IssuanceCurve.ReserveAssetConfig[](1);
            configs[0] = IssuanceCurve.ReserveAssetConfig({asset: asset, decimals: decimals});
        }

        function _seedKernelForIssuance() internal {
            _store(Slots.MAX_SUPPLY_SLOT, MAX_SUPPLY);
            _store(Slots.TEAM_PERCENTAGE_SLOT, TEAM_BPS);
            _store(Slots.TREASURY_PERCENTAGE_SLOT, TREASURY_BPS);
            _store(Slots.ASSETS_LENGTH_SLOT, 1);
            _store(Slots.ASSETS_BASE_SLOT, uint256(uint160(address(reserveAsset))));
            _store(_amountSlot(Slots.BACKING_AMOUNT_SLOT, address(reserveAsset)), INITIAL_BACKING);
            _store(curve.CURVE_SUPPLY_SLOT(), INITIAL_CURVE_SUPPLY);
            _store(curve.CURVE_RESERVE_SLOT(), INITIAL_CURVE_RESERVE);
        }

        function _paymentSplit(uint256 grossAmount)
            internal
            pure
            returns (uint256 protocolFee, uint256 backingAmount, uint256 teamAmount, uint256 treasuryAmount)
        {
            protocolFee = Math.mulDiv(grossAmount, FEE_BPS, BPS, Math.Rounding.Ceil);
            uint256 netAmount = grossAmount - protocolFee;
            teamAmount = netAmount * TEAM_BPS / BPS;
            treasuryAmount = netAmount * TREASURY_BPS / BPS;
            backingAmount = netAmount - teamAmount - treasuryAmount;
        }

        function _bucket(bytes32 namespace) internal view returns (uint256) {
            return uint256(kernel.viewData(_amountSlot(namespace, address(reserveAsset))));
        }

        function _store(bytes32 slot, uint256 value) internal {
            vm.store(address(kernel), slot, bytes32(value));
        }

        function _amountSlot(bytes32 namespace, address asset) internal pure returns (bytes32 slot) {
            return keccak256(abi.encode(namespace, asset));
        }
    }
