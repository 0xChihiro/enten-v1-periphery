// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BancorNavMath} from "../src/libraries/BancorNavMath.sol";
import {BurnerModule} from "../src/modules/DFLT/Burner.sol";
import {BurnerPolicy} from "../src/policies/BurnerPolicy.sol";
import {ICurve} from "../src/interfaces/ICurve.sol";
import {IssuanceCurve} from "../src/policies/IssuanceCurve.sol";
import {Minter} from "../src/modules/MINTR/Minter.sol";

import {Controller} from "enten-v1/Controller.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Token} from "enten-v1/Token.sol";
import {Vault} from "enten-v1/Vault.sol";
import {IVault} from "enten-v1/interfaces/IVault.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Actions, Keycode} from "enten-v1/Utils.sol";

import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract BurnIssuanceIntegrationWETH is ERC20 {
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

contract BurnIssuanceIntegrationTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;
    uint256 internal constant INITIAL_BACKING = 1_000 ether;
    uint256 internal constant MAX_SUPPLY = 10_000 ether;
    uint256 internal constant CURVE_SUPPLY = 1_000 ether;
    uint256 internal constant CURVE_RESERVE = 2_000 ether;
    uint256 internal constant TEAM_BPS = 250;
    uint256 internal constant TREASURY_BPS = 250;
    uint256 internal constant MIN_NAV_PREMIUM_BPS = 500;

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    Token internal token;
    BurnIssuanceIntegrationWETH internal weth;
    Minter internal minter;
    BurnerModule internal burner;
    BurnerPolicy internal burnerPolicy;
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
        weth = new BurnIssuanceIntegrationWETH();
        minter = new Minter(address(controller));
        burner =
            new BurnerModule(address(controller), address(kernel), address(weth), uint8(ICurve.CurveShape.SquareRoot));
        burnerPolicy = new BurnerPolicy(address(controller));
        curve = new IssuanceCurve(address(controller), address(weth), ICurve.CurveShape.SquareRoot, admin);

        weth.mint(address(vault), INITIAL_BACKING);
        _setAssets(address(weth));
        _setBucket(IVault.Bucket.Redeem, address(weth), INITIAL_BACKING);
        _setPaymentBps(TEAM_BPS, TREASURY_BPS);

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(minter));
        controller.executeAction(Actions.InstallModule, address(burner));
        controller.setMintPermission(Keycode.wrap("MINTR"), true);
        controller.executeAction(Actions.ActivatePolicy, address(curve));
        controller.executeAction(Actions.ActivatePolicy, address(burnerPolicy));
        curve.seedCurve(CURVE_SUPPLY, CURVE_RESERVE);
        vm.stopPrank();
    }

    function testBuyBurnQuoteBuyLifecycleKeepsCurveAndNavCoherent() public {
        _buyExactTokens(50 ether);
        ICurve.CurveState memory beforeBurn = curve.curveState();
        uint256 backingBeforeBurn = curve.reserveBackingBalanceWad();
        uint256 supplyBeforeBurn = _effectiveSupply();

        vm.prank(buyer);
        burnerPolicy.burn(20 ether);

        ICurve.CurveState memory afterBurn = curve.curveState();
        assertLt(afterBurn.virtualSupplyWad, beforeBurn.virtualSupplyWad);
        assertLt(afterBurn.virtualReserveWad, beforeBurn.virtualReserveWad);
        assertEq(curve.reserveBackingBalanceWad(), backingBeforeBurn);
        assertEq(_effectiveSupply(), supplyBeforeBurn - 20 ether);
        _assertSpotAtOrAboveNavFloor();

        ICurve.BuyQuote memory postBurnQuote = curve.quoteBuyExactEth(25 ether);
        uint256 curveSupplyBeforeSecondBuy = afterBurn.virtualSupplyWad;
        vm.deal(buyer, 25 ether);
        vm.prank(buyer);
        ICurve.BuyQuote memory executedQuote =
            curve.buyExactEth{value: 25 ether}(postBurnQuote.mintAmount, block.timestamp);

        assertEq(executedQuote.mintAmount, postBurnQuote.mintAmount);
        assertEq(executedQuote.curveSupplyDeltaWad, postBurnQuote.curveSupplyDeltaWad);
        assertEq(curve.curveState().virtualSupplyWad, curveSupplyBeforeSecondBuy + postBurnQuote.curveSupplyDeltaWad);
        _assertSpotAtOrAboveNavFloor();
    }

    function testLockedOnlyBurnStillLowersSharedIssuanceCurveSlotsWithoutChangingEffectiveSupply() public {
        _setLocked(100 ether);
        _buyExactTokens(50 ether);
        uint256 effectiveBefore = _effectiveSupply();
        ICurve.CurveState memory beforeBurn = curve.curveState();

        vm.prank(buyer);
        burnerPolicy.burn(20 ether);

        assertEq(_locked(), 80 ether);
        assertEq(_effectiveSupply(), effectiveBefore);
        assertEq(curve.curveState().virtualSupplyWad, beforeBurn.virtualSupplyWad - 20 ether);
        assertLt(curve.curveState().virtualReserveWad, beforeBurn.virtualReserveWad);
        _assertSpotAtOrAboveNavFloor();
    }

    function testPartialLockedBurnUsesGrossCurveReductionAndPostBurnEffectiveSupplyForNavFloor() public {
        _setLocked(10 ether);
        _buyExactTokens(50 ether);
        uint256 effectiveBefore = _effectiveSupply();
        ICurve.CurveState memory beforeBurn = curve.curveState();

        vm.prank(buyer);
        burnerPolicy.burn(25 ether);

        assertEq(_locked(), 0);
        assertEq(_effectiveSupply(), effectiveBefore - 15 ether);
        assertEq(curve.curveState().virtualSupplyWad, beforeBurn.virtualSupplyWad - 25 ether);
        assertLt(curve.curveState().virtualReserveWad, beforeBurn.virtualReserveWad);
        _assertSpotAtOrAboveNavFloor();
    }

    function testBurnReductionStopsAtPostBurnNavFloorBeforeNextIssuanceQuote() public {
        _overwriteCurveState(1_000 ether, 720 ether);
        vm.prank(existingHolder);
        assertTrue(token.transfer(buyer, 20 ether));
        ICurve.CurveState memory beforeBurn = curve.curveState();

        vm.prank(buyer);
        burnerPolicy.burn(20 ether);

        ICurve.CurveState memory afterBurn = curve.curveState();
        uint256 supplyDelta = beforeBurn.virtualSupplyWad - afterBurn.virtualSupplyWad;
        assertGt(supplyDelta, 0);
        assertLt(supplyDelta, 20 ether);
        _assertSpotAtOrAboveNavFloor();

        ICurve.BuyQuote memory quote = curve.quoteBuyExactTokens(1 ether);
        assertGt(quote.grossEthIn, 0);
    }

    function testFuzzBurnAppliesExpectedLockedEffectiveAndCurveDeltas(
        uint96 amountRaw,
        uint96 lockedRaw,
        uint96 virtualReserveRaw
    ) public {
        uint256 burnAmount = bound(uint256(amountRaw), 1, 100 ether);
        uint256 lockedBefore = uint256(lockedRaw) % 300 ether;
        uint256 virtualReserve = bound(uint256(virtualReserveRaw), 1_500 ether, 3_000 ether);
        _setLocked(lockedBefore);
        _overwriteCurveState(1_000 ether, virtualReserve);
        vm.prank(existingHolder);
        assertTrue(token.transfer(buyer, burnAmount));

        uint256 totalSupplyBefore = token.totalSupply();
        uint256 effectiveBefore = _effectiveSupply();
        uint256 backingBefore = curve.reserveBackingBalanceWad();
        ICurve.CurveState memory stateBefore = curve.curveState();
        uint256 unlocked = Math.min(burnAmount, lockedBefore);
        uint256 effectiveBurn = burnAmount - unlocked;
        BancorNavMath.PricingContext memory context = BancorNavMath.PricingContext({
            virtualSupply: stateBefore.virtualSupplyWad,
            curveReserveWad: stateBefore.virtualReserveWad,
            actualSupply: effectiveBefore,
            backingBalanceWad: backingBefore,
            navPremiumBps: MIN_NAV_PREMIUM_BPS,
            shape: uint8(ICurve.CurveShape.SquareRoot)
        });
        (uint256 expectedCurveSupplyDelta, uint256 expectedCurveReserveDelta) =
            BancorNavMath.boundedCurveStateReductionForBurn(context, burnAmount, effectiveBefore - effectiveBurn);

        vm.prank(buyer);
        burnerPolicy.burn(burnAmount);

        ICurve.CurveState memory stateAfter = curve.curveState();
        assertEq(token.totalSupply(), totalSupplyBefore - burnAmount);
        assertEq(_locked(), lockedBefore - unlocked);
        assertEq(_effectiveSupply(), effectiveBefore - effectiveBurn);
        assertEq(curve.reserveBackingBalanceWad(), backingBefore);
        assertEq(stateAfter.virtualSupplyWad, stateBefore.virtualSupplyWad - expectedCurveSupplyDelta);
        assertEq(stateAfter.virtualReserveWad, stateBefore.virtualReserveWad - expectedCurveReserveDelta);
        _assertSpotAtOrAboveNavFloor();
    }

    function testQuoteExecutionExactTokensMatchesAfterLockedOnlyBurn() public {
        _setLocked(100 ether);
        _transferAndBurnFromBuyer(40 ether);

        assertEq(_locked(), 60 ether);
        _assertQuoteBuyExactTokensExecutesFromCurrentState(12 ether);
    }

    function testQuoteExecutionExactEthMatchesAfterPartialLockedBurn() public {
        _setLocked(15 ether);
        _transferAndBurnFromBuyer(40 ether);

        assertEq(_locked(), 0);
        _assertQuoteBuyExactEthExecutesFromCurrentState(30 ether);
    }

    function testQuoteExecutionMatchesAfterNavFloorStoppedBurn() public {
        _overwriteCurveState(1_000 ether, 720 ether);
        _transferAndBurnFromBuyer(20 ether);

        _assertSpotAtOrAboveNavFloor();
        _assertQuoteBuyExactTokensExecutesFromCurrentState(1 ether);
        _assertQuoteBuyExactEthExecutesFromCurrentState(2 ether);
    }

    function _buyExactTokens(uint256 mintAmount) internal returns (ICurve.BuyQuote memory quote) {
        quote = curve.quoteBuyExactTokens(mintAmount);
        vm.deal(buyer, quote.grossEthIn);
        vm.prank(buyer);
        ICurve.BuyQuote memory actualQuote =
            curve.buyExactTokensWithEth{value: quote.grossEthIn}(mintAmount, block.timestamp);
        assertEq(actualQuote.grossEthIn, quote.grossEthIn);
        assertEq(actualQuote.mintAmount, quote.mintAmount);
        assertEq(actualQuote.curveReserveDeltaWad, quote.curveReserveDeltaWad);
        assertEq(actualQuote.curveSupplyDeltaWad, quote.curveSupplyDeltaWad);
    }

    function _transferAndBurnFromBuyer(uint256 burnAmount) internal {
        vm.prank(existingHolder);
        assertTrue(token.transfer(buyer, burnAmount));
        vm.prank(buyer);
        burnerPolicy.burn(burnAmount);
    }

    function _assertQuoteBuyExactTokensExecutesFromCurrentState(uint256 mintAmount) internal {
        ICurve.BuyQuote memory quote = curve.quoteBuyExactTokens(mintAmount);
        ICurve.CurveState memory stateBefore = curve.curveState();
        uint256 backingBefore = curve.reserveBackingBalanceWad();

        vm.deal(buyer, quote.grossEthIn);
        vm.prank(buyer);
        ICurve.BuyQuote memory actualQuote =
            curve.buyExactTokensWithEth{value: quote.grossEthIn}(mintAmount, block.timestamp);

        assertEq(actualQuote.grossEthIn, quote.grossEthIn);
        assertEq(actualQuote.mintAmount, quote.mintAmount);
        assertEq(actualQuote.curveReserveDeltaWad, quote.curveReserveDeltaWad);
        assertEq(actualQuote.curveSupplyDeltaWad, quote.curveSupplyDeltaWad);
        assertEq(curve.curveState().virtualSupplyWad, stateBefore.virtualSupplyWad + quote.curveSupplyDeltaWad);
        assertEq(curve.curveState().virtualReserveWad, stateBefore.virtualReserveWad + quote.curveReserveDeltaWad);
        assertEq(curve.reserveBackingBalanceWad(), backingBefore + _backingAmountFromGross(quote.grossEthIn));
        _assertSpotAtOrAboveNavFloor();
    }

    function _assertQuoteBuyExactEthExecutesFromCurrentState(uint256 ethIn) internal {
        ICurve.BuyQuote memory quote = curve.quoteBuyExactEth(ethIn);
        ICurve.CurveState memory stateBefore = curve.curveState();
        uint256 backingBefore = curve.reserveBackingBalanceWad();

        vm.deal(buyer, ethIn);
        vm.prank(buyer);
        ICurve.BuyQuote memory actualQuote = curve.buyExactEth{value: ethIn}(quote.mintAmount, block.timestamp);

        assertEq(actualQuote.grossEthIn, quote.grossEthIn);
        assertEq(actualQuote.mintAmount, quote.mintAmount);
        assertEq(actualQuote.curveReserveDeltaWad, quote.curveReserveDeltaWad);
        assertEq(actualQuote.curveSupplyDeltaWad, quote.curveSupplyDeltaWad);
        assertEq(curve.curveState().virtualSupplyWad, stateBefore.virtualSupplyWad + quote.curveSupplyDeltaWad);
        assertEq(curve.curveState().virtualReserveWad, stateBefore.virtualReserveWad + quote.curveReserveDeltaWad);
        assertEq(curve.reserveBackingBalanceWad(), backingBefore + _backingAmountFromGross(quote.grossEthIn));
        _assertSpotAtOrAboveNavFloor();
    }

    function _backingAmountFromGross(uint256 grossAmount) internal view returns (uint256 backingAmount) {
        uint256 protocolFee = Math.mulDiv(grossAmount, curve.PROTOCOL_FEE_BPS(), 10_000, Math.Rounding.Ceil);
        uint256 netAmount = grossAmount - protocolFee;
        uint256 teamAmount = netAmount * TEAM_BPS / 10_000;
        uint256 treasuryAmount = netAmount * TREASURY_BPS / 10_000;
        backingAmount = netAmount - teamAmount - treasuryAmount;
    }

    function _assertSpotAtOrAboveNavFloor() internal view {
        ICurve.CurveState memory state = curve.curveState();
        uint256 spot = BancorNavMath.bancorSpotPriceWad(
            state.virtualSupplyWad, state.virtualReserveWad, uint8(ICurve.CurveShape.SquareRoot)
        );
        uint256 floor =
            BancorNavMath.navFloorPriceWad(_effectiveSupply(), curve.reserveBackingBalanceWad(), MIN_NAV_PREMIUM_BPS);
        assertGe(spot, floor);
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
        bytes memory data = new bytes(32);
        bytes32 assetWord = bytes32(uint256(uint160(assets[0])));
        assembly ("memory-safe") {
            mstore(add(data, 0x20), assetWord)
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

    function _setLocked(uint256 amount) internal {
        vm.prank(address(controller));
        kernel.updateState(Slots.TEAM_LOCKED_TOKENS_SLOT, bytes32(amount));
    }

    function _overwriteCurveState(uint256 virtualSupply, uint256 virtualReserve) internal {
        vm.startPrank(address(controller));
        kernel.updateState(curve.curveBaseSlot(address(weth)), bytes32(virtualSupply));
        kernel.updateState(curve.curveReserveSlot(address(weth)), bytes32(virtualReserve));
        vm.stopPrank();
    }

    function _locked() internal view returns (uint256) {
        return uint256(kernel.viewData(Slots.TEAM_LOCKED_TOKENS_SLOT));
    }

    function _effectiveSupply() internal view returns (uint256) {
        return token.totalSupply() - _locked();
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
