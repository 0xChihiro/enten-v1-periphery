// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ICurve} from "../src/interfaces/ICurve.sol";
import {IssuanceCurve} from "../src/policies/IssuanceCurve.sol";
import {Minter} from "../src/modules/MINTR/Minter.sol";
import {Controller} from "enten-v1/Controller.sol";
import {Token} from "enten-v1/Token.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Vault} from "enten-v1/Vault.sol";
import {IVault} from "enten-v1/interfaces/IVault.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Actions, Keycode} from "enten-v1/Utils.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract IssuanceCurveTest is Test {
    struct PaymentBreakdown {
        uint256 protocolFee;
        uint256 backing;
        uint256 team;
        uint256 treasury;
    }

    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;
    uint256 internal constant INITIAL_BACKING = 1_000 ether;
    uint256 internal constant MAX_SUPPLY = 10_000 ether;
    uint256 internal constant CURVE_SUPPLY = 1_000 ether;
    uint256 internal constant CURVE_RESERVE = 500 ether;
    uint256 internal constant TEAM_BPS = 500;
    uint256 internal constant TREASURY_BPS = 500;
    uint256 internal constant PROTOCOL_FEE_BPS = 250;
    uint256 internal constant BPS = 10_000;

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    Token internal token;
    MockWETH internal weth;
    Minter internal minter;
    IssuanceCurve internal curve;

    address internal admin = makeAddr("Admin");
    address internal existingHolder = makeAddr("Existing Holder");
    address internal buyer = makeAddr("Buyer");
    address internal protocolCollector = makeAddr("Protocol Collector");

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedToken = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedController = vm.computeCreateAddress(address(this), nonce + 3);

        kernel = new Kernel(predictedController, predictedVault);
        vault = new Vault(predictedController, predictedKernel);
        token = new Token("Enten", "ENTEN", predictedController, existingHolder, INITIAL_SUPPLY, MAX_SUPPLY);
        controller = new Controller(admin, protocolCollector, predictedKernel, predictedVault, predictedToken);
        weth = new MockWETH();
        minter = new Minter(address(controller));
        curve = new IssuanceCurve(address(controller), address(weth), ICurve.CurveShape.SquareRoot, admin);

        weth.mint(address(vault), INITIAL_BACKING);
        _setAssets(address(weth));
        _setBucket(IVault.Bucket.Redeem, address(weth), INITIAL_BACKING);
        _setPaymentBps(TEAM_BPS, TREASURY_BPS);

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(minter));
        controller.setMintPermission(Keycode.wrap("MINTR"), true);
        controller.executeAction(Actions.ActivatePolicy, address(curve));
        vm.stopPrank();
    }

    function testSeedCurveSetsStateAndMakesProtocolLive() public {
        assertFalse(curve.live());

        ICurve.CurveState memory state = curve.curveState();
        assertEq(state.virtualSupplyWad, 0);
        assertEq(state.virtualReserveWad, 0);

        _seedCurve();

        assertTrue(curve.live());

        state = curve.curveState();
        assertEq(state.virtualSupplyWad, CURVE_SUPPLY);
        assertEq(state.virtualReserveWad, CURVE_RESERVE);
        assertEq(uint256(kernel.viewData(curve.curveBaseSlot(address(weth)))), CURVE_SUPPLY);
        assertEq(uint256(kernel.viewData(curve.curveReserveSlot(address(weth)))), CURVE_RESERVE);
        assertEq(curve.reserveBackingBalanceWad(), INITIAL_BACKING);
        assertEq(curve.bancorSpotPriceWad(), 0.75 ether);
    }

    function testSeedCurveRequiresAdminAndNonZeroState() public {
        vm.expectRevert(ICurve.Curve__OnlyAdmin.selector);
        curve.seedCurve(CURVE_SUPPLY, CURVE_RESERVE);

        vm.startPrank(admin);
        vm.expectRevert(ICurve.Curve__ZeroAmount.selector);
        curve.seedCurve(0, CURVE_RESERVE);

        vm.expectRevert(ICurve.Curve__ZeroAmount.selector);
        curve.seedCurve(CURVE_SUPPLY, 0);
        vm.stopPrank();
    }

    function testSeedCurveCanOnlyRunOnce() public {
        _seedCurve();

        vm.prank(admin);
        vm.expectRevert(ICurve.Curve__AlreadySeeded.selector);
        curve.seedCurve(CURVE_SUPPLY, CURVE_RESERVE);
    }

    function testBuyRevertsBeforeSeedBecauseCurveIsNotLive() public {
        vm.deal(buyer, 1 ether);

        vm.prank(buyer);
        vm.expectRevert(ICurve.Curve__NotLive.selector);
        curve.buyExactEth{value: 1 ether}(0, block.timestamp);
    }

    function testQuoteRevertsBeforeSeedBecauseVirtualCurveIsMissing() public {
        vm.expectRevert(ICurve.Curve__VirtualCurveNotSeeded.selector);
        curve.quoteBuyExactEth(1 ether);
    }

    function testQuoteExactTokensUsesNavFloorWhenItIsAboveCurvePrice() public {
        _seedCurve();

        ICurve.BuyQuote memory quote = curve.quoteBuyExactTokens(100 ether);

        assertEq(quote.mintAmount, 100 ether);
        assertEq(quote.curveSupplyDeltaWad, 100 ether);
        assertEq(quote.grossEthIn, _grossEthInForBacking(105 ether));
        assertLt(quote.curveReserveDeltaWad, 105 ether);
        assertTrue(quote.usesNavFloor);
        assertGe(_paymentBreakdown(quote.grossEthIn).backing, 105 ether);
        assertLt(_paymentBreakdown(quote.grossEthIn - 1).backing, 105 ether);
    }

    function testBuyExactEthWrapsWethMintsTokensAndUpdatesCurveState() public {
        _seedCurve();

        uint256 ethIn = 120 ether;
        ICurve.BuyQuote memory quote = curve.quoteBuyExactEth(ethIn);
        PaymentBreakdown memory payment = _paymentBreakdown(ethIn);

        vm.deal(buyer, ethIn);
        vm.prank(buyer);
        ICurve.BuyQuote memory actualQuote = curve.buyExactEth{value: ethIn}(quote.mintAmount, block.timestamp);

        _assertQuoteEq(actualQuote, quote);
        assertEq(token.balanceOf(buyer), quote.mintAmount);
        assertEq(token.balanceOf(address(curve)), 0);
        assertEq(weth.balanceOf(address(curve)), 0);
        assertEq(weth.balanceOf(address(vault)), INITIAL_BACKING + ethIn - payment.protocolFee);
        assertEq(weth.balanceOf(protocolCollector), payment.protocolFee);
        assertEq(curve.reserveBackingBalanceWad(), INITIAL_BACKING + payment.backing);
        assertEq(_bucketValue(IVault.Bucket.Team, address(weth)), payment.team);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(weth)), payment.treasury);

        ICurve.CurveState memory state = curve.curveState();
        assertEq(state.virtualSupplyWad, CURVE_SUPPLY + quote.curveSupplyDeltaWad);
        assertEq(state.virtualReserveWad, CURVE_RESERVE + quote.curveReserveDeltaWad);
    }

    function testBuyExactTokensWithEthRefundsExcessEth() public {
        _seedCurve();

        uint256 mintAmount = 10 ether;
        ICurve.BuyQuote memory quote = curve.quoteBuyExactTokens(mintAmount);
        uint256 overpay = 1 ether;

        vm.deal(buyer, quote.grossEthIn + overpay);
        vm.prank(buyer);
        ICurve.BuyQuote memory actualQuote =
            curve.buyExactTokensWithEth{value: quote.grossEthIn + overpay}(mintAmount, block.timestamp);

        _assertQuoteEq(actualQuote, quote);
        assertEq(token.balanceOf(buyer), mintAmount);
        assertEq(buyer.balance, overpay);
        assertEq(address(curve).balance, 0);
        assertEq(weth.balanceOf(address(curve)), 0);
    }

    function testRawEthReceiveBuysWithoutSlippageGuard() public {
        _seedCurve();

        uint256 ethIn = 20 ether;
        vm.deal(buyer, ethIn);

        vm.prank(buyer);
        (bool success,) = address(curve).call{value: ethIn}("");

        assertTrue(success);
        assertGt(token.balanceOf(buyer), 0);
        assertEq(address(curve).balance, 0);
        assertEq(weth.balanceOf(address(curve)), 0);
    }

    function testBuyExactTokensWithEthRevertsWhenMsgValueIsBelowRequiredGrossEth() public {
        _seedCurve();

        uint256 mintAmount = 10 ether;
        ICurve.BuyQuote memory quote = curve.quoteBuyExactTokens(mintAmount);
        uint256 underpay = quote.grossEthIn - 1;

        vm.deal(buyer, underpay);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ICurve.Curve__Slippage.selector, quote.grossEthIn, underpay));
        curve.buyExactTokensWithEth{value: underpay}(mintAmount, block.timestamp);
    }

    function testBuyExactEthRevertsWhenMintAmountIsBelowMinimum() public {
        _seedCurve();

        uint256 ethIn = 20 ether;
        ICurve.BuyQuote memory quote = curve.quoteBuyExactEth(ethIn);

        vm.deal(buyer, ethIn);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(ICurve.Curve__MintSlippage.selector, quote.mintAmount, quote.mintAmount + 1)
        );
        curve.buyExactEth{value: ethIn}(quote.mintAmount + 1, block.timestamp);
    }

    function testPauseBlocksBuysAfterCurveIsLive() public {
        _seedCurve();

        vm.prank(admin);
        curve.setPaused(true);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(ICurve.Curve__Paused.selector);
        curve.buyExactEth{value: 1 ether}(0, block.timestamp);
    }

    function _seedCurve() internal {
        vm.prank(admin);
        curve.seedCurve(CURVE_SUPPLY, CURVE_RESERVE);
    }

    function _assertQuoteEq(ICurve.BuyQuote memory actualQuote, ICurve.BuyQuote memory expectedQuote) internal pure {
        assertEq(actualQuote.grossEthIn, expectedQuote.grossEthIn);
        assertEq(actualQuote.mintAmount, expectedQuote.mintAmount);
        assertEq(actualQuote.curveReserveDeltaWad, expectedQuote.curveReserveDeltaWad);
        assertEq(actualQuote.curveSupplyDeltaWad, expectedQuote.curveSupplyDeltaWad);
        assertEq(actualQuote.usesNavFloor, expectedQuote.usesNavFloor);
    }

    function _grossEthInForBacking(uint256 requiredBacking) internal pure returns (uint256 grossEthIn) {
        uint256 backingBps = BPS - TEAM_BPS - TREASURY_BPS;
        uint256 requiredPostProtocol = Math.mulDiv(requiredBacking, BPS, backingBps, Math.Rounding.Ceil);
        uint256 upperBound = Math.mulDiv(requiredPostProtocol, BPS, BPS - PROTOCOL_FEE_BPS, Math.Rounding.Ceil);
        uint256 lowerBound = requiredBacking;

        while (lowerBound < upperBound) {
            uint256 mid = (lowerBound + upperBound) / 2;
            if (_paymentBreakdown(mid).backing >= requiredBacking) upperBound = mid;
            else lowerBound = mid + 1;
        }

        grossEthIn = lowerBound;
    }

    function _paymentBreakdown(uint256 grossAmount) internal pure returns (PaymentBreakdown memory payment) {
        payment.protocolFee = Math.mulDiv(grossAmount, PROTOCOL_FEE_BPS, BPS, Math.Rounding.Ceil);
        uint256 netAmount = grossAmount - payment.protocolFee;
        payment.team = netAmount * TEAM_BPS / BPS;
        payment.treasury = netAmount * TREASURY_BPS / BPS;
        payment.backing = netAmount - payment.team - payment.treasury;
    }

    function _setPaymentBps(uint256 teamBps, uint256 treasuryBps) internal {
        vm.startPrank(address(controller));
        kernel.updateState(Slots.TEAM_PERCENTAGE_SLOT, bytes32(teamBps));
        kernel.updateState(Slots.TREASURY_PERCENTAGE_SLOT, bytes32(treasuryBps));
        vm.stopPrank();
    }

    function _setAssets(address first) internal {
        address[] memory assets = new address[](1);
        assets[0] = first;
        _setAssets(assets);
    }

    function _setAssets(address[] memory assets) internal {
        bytes memory data = new bytes(assets.length * 32);
        for (uint256 i; i < assets.length;) {
            bytes32 assetWord = bytes32(uint256(uint160(assets[i])));
            assembly ("memory-safe") {
                mstore(add(add(data, 0x20), shl(5, i)), assetWord)
            }
            unchecked {
                ++i;
            }
        }

        vm.startPrank(address(controller));
        kernel.updateState(Slots.ASSETS_LENGTH_SLOT, bytes32(assets.length));
        kernel.updateState(Slots.ASSETS_BASE_SLOT, data);
        vm.stopPrank();
    }

    function _setBucket(IVault.Bucket bucket, address token_, uint256 amount) internal {
        vm.prank(address(controller));
        kernel.updateState(_bucketSlot(bucket, token_), bytes32(amount));
    }

    function _bucketValue(IVault.Bucket bucket, address token_) internal view returns (uint256) {
        return uint256(kernel.viewData(_bucketSlot(bucket, token_)));
    }

    function _bucketSlot(IVault.Bucket bucket, address token_) internal pure returns (bytes32) {
        if (bucket == IVault.Bucket.Borrow) return _slot(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, token_);
        if (bucket == IVault.Bucket.Redeem) return _slot(Slots.BACKING_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Treasury) return _slot(Slots.TREASURY_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Team) return _slot(Slots.TEAM_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Collateral) return _slot(Slots.TOTAL_COLLATERL_SLOT, token_);
        revert("invalid bucket");
    }

    function _slot(bytes32 namespace, address token_) internal pure returns (bytes32) {
        return keccak256(abi.encode(namespace, token_));
    }
}
