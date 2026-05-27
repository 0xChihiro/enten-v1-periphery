// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";
import {BancorNavMath} from "../src/libraries/BancorNavMath.sol";

contract BancorNavMathHarness {
    function requiredBackingInWad(BancorNavMath.PricingContext memory context, uint256 mintAmount)
        external
        pure
        returns (uint256 requiredBackingWad, uint256 curveReserveDeltaWad, bool usesNavFloor)
    {
        return BancorNavMath.requiredBackingInWad(context, mintAmount);
    }

    function mintAmountForBackingWad(
        BancorNavMath.PricingContext memory context,
        uint256 maxMintAmount,
        uint256 backingInWad
    ) external pure returns (uint256 mintAmount, uint256 curveReserveDeltaWad, bool usesNavFloor) {
        return BancorNavMath.mintAmountForBackingWad(context, maxMintAmount, backingInWad);
    }

    function curveReserveDeltaForMint(uint256 supply, uint256 mintAmount, uint256 reserve, uint8 shape)
        external
        pure
        returns (uint256)
    {
        return BancorNavMath.curveReserveDeltaForMint(supply, mintAmount, reserve, shape);
    }

    function boundedCurveStateReductionForBurn(
        BancorNavMath.PricingContext memory context,
        uint256 curveBurnAmount,
        uint256 postBurnActualSupply
    ) external pure returns (uint256 curveSupplyDeltaWad, uint256 curveReserveDeltaWad) {
        return BancorNavMath.boundedCurveStateReductionForBurn(context, curveBurnAmount, postBurnActualSupply);
    }

    function curveStateReductionForBurn(uint256 supply, uint256 reserve, uint256 burnAmount, uint8 shape)
        external
        pure
        returns (uint256 curveSupplyDeltaWad, uint256 curveReserveDeltaWad)
    {
        return BancorNavMath.curveStateReductionForBurn(supply, reserve, burnAmount, shape);
    }

    function spot(uint256 supply, uint256 reserve, uint8 shape) external pure returns (uint256) {
        return BancorNavMath.bancorSpotPriceWad(supply, reserve, shape);
    }

    function navFloor(uint256 supply, uint256 backing, uint256 premiumBps) external pure returns (uint256) {
        return BancorNavMath.navFloorPriceWad(supply, backing, premiumBps);
    }
}

contract BancorNavMathBurnAdjustmentTest is Test {
    BancorNavMathHarness internal math;

    uint8 internal constant FOURTH_ROOT = 0;
    uint8 internal constant SQUARE_ROOT = 1;
    uint8 internal constant LINEAR = 2;
    uint256 internal constant NAV_PREMIUM_BPS = 500;

    function setUp() public {
        math = new BancorNavMathHarness();
    }

    function testRequiredBackingChoosesBancorPathWhenCurvePriceExceedsNavFloor() public view {
        BancorNavMath.PricingContext memory context = BancorNavMath.PricingContext({
            virtualSupply: 1_000 ether,
            curveReserveWad: 1_000 ether,
            actualSupply: 1_000 ether,
            backingBalanceWad: 100 ether,
            navPremiumBps: NAV_PREMIUM_BPS,
            shape: LINEAR
        });
        uint256 mintAmount = 25 ether;

        (uint256 requiredBacking, uint256 curveReserveDelta, bool usesNavFloor) =
            math.requiredBackingInWad(context, mintAmount);

        assertEq(requiredBacking, curveReserveDelta);
        assertFalse(usesNavFloor);
        assertGt(curveReserveDelta, 0);
    }

    function testRequiredBackingChoosesNavFloorWhenFloorExceedsCurveRequirement() public view {
        BancorNavMath.PricingContext memory context = BancorNavMath.PricingContext({
            virtualSupply: 1_000 ether,
            curveReserveWad: 100 ether,
            actualSupply: 1_000 ether,
            backingBalanceWad: 1_000 ether,
            navPremiumBps: NAV_PREMIUM_BPS,
            shape: LINEAR
        });
        uint256 mintAmount = 25 ether;

        (uint256 requiredBacking, uint256 curveReserveDelta, bool usesNavFloor) =
            math.requiredBackingInWad(context, mintAmount);

        assertEq(requiredBacking, 26.25 ether);
        assertGt(requiredBacking, curveReserveDelta);
        assertTrue(usesNavFloor);
    }

    function testMintAmountForBackingReturnsLargestSafeMintAmountAtBoundary() public view {
        BancorNavMath.PricingContext memory context = BancorNavMath.PricingContext({
            virtualSupply: 1_000 ether,
            curveReserveWad: 100 ether,
            actualSupply: 1_000 ether,
            backingBalanceWad: 1_000 ether,
            navPremiumBps: NAV_PREMIUM_BPS,
            shape: LINEAR
        });
        uint256 targetMintAmount = 25 ether;
        (uint256 exactBacking,,) = math.requiredBackingInWad(context, targetMintAmount);

        (uint256 mintAmount,, bool usesNavFloor) = math.mintAmountForBackingWad(context, 100 ether, exactBacking);
        (uint256 oneWeiShortMintAmount,,) = math.mintAmountForBackingWad(context, 100 ether, exactBacking - 1);

        assertEq(mintAmount, targetMintAmount);
        assertTrue(usesNavFloor);
        assertEq(oneWeiShortMintAmount, targetMintAmount - 1);
    }

    function testFuzzMintQuoteFunctionsAreMonotonicAndConservative(
        uint96 virtualSupplyRaw,
        uint96 virtualReserveRaw,
        uint96 actualSupplyRaw,
        uint96 backingRaw,
        uint96 backingInRaw,
        uint8 shape
    ) public view {
        uint256 virtualSupply = bound(uint256(virtualSupplyRaw), 1 ether, 1_000_000 ether);
        uint256 virtualReserve = bound(uint256(virtualReserveRaw), 1 ether, 1_000_000 ether);
        uint256 actualSupply = bound(uint256(actualSupplyRaw), 1 ether, 1_000_000 ether);
        uint256 backing = bound(uint256(backingRaw), 0, 1_000_000 ether);
        uint256 backingIn = bound(uint256(backingInRaw), 1, 10_000 ether);
        uint256 maxMintAmount = 1_000 ether;
        BancorNavMath.PricingContext memory context = BancorNavMath.PricingContext({
            virtualSupply: virtualSupply,
            curveReserveWad: virtualReserve,
            actualSupply: actualSupply,
            backingBalanceWad: backing,
            navPremiumBps: NAV_PREMIUM_BPS,
            shape: shape
        });

        (uint256 mintAmount,,) = math.mintAmountForBackingWad(context, maxMintAmount, backingIn);
        (uint256 largerMintAmount,,) = math.mintAmountForBackingWad(context, maxMintAmount, backingIn + 1 ether);

        assertGe(largerMintAmount, mintAmount);
        (uint256 requiredBacking,,) = math.requiredBackingInWad(context, mintAmount);
        assertLe(requiredBacking, backingIn);
        if (mintAmount < maxMintAmount) {
            (uint256 nextRequiredBacking,,) = math.requiredBackingInWad(context, mintAmount + 1);
            assertGt(nextRequiredBacking, backingIn);
        }
    }

    function testFuzzRequiredBackingIsMonotonicAndSelectionFlagIsExact(
        uint96 virtualSupplyRaw,
        uint96 virtualReserveRaw,
        uint96 actualSupplyRaw,
        uint96 backingRaw,
        uint96 mintAmountARaw,
        uint96 mintAmountBRaw,
        uint8 shapeRaw
    ) public view {
        uint256 mintA = bound(uint256(mintAmountARaw), 1, 500 ether);
        uint256 mintB = bound(uint256(mintAmountBRaw), mintA, 1_000 ether);
        BancorNavMath.PricingContext memory context = BancorNavMath.PricingContext({
            virtualSupply: bound(uint256(virtualSupplyRaw), 1 ether, 1_000_000 ether),
            curveReserveWad: bound(uint256(virtualReserveRaw), 1 ether, 1_000_000 ether),
            actualSupply: bound(uint256(actualSupplyRaw), 1 ether, 1_000_000 ether),
            backingBalanceWad: bound(uint256(backingRaw), 0, 1_000_000 ether),
            navPremiumBps: NAV_PREMIUM_BPS,
            shape: _shape(shapeRaw)
        });

        (uint256 requiredA, uint256 curveDeltaA, bool usesFloorA) = math.requiredBackingInWad(context, mintA);
        (uint256 requiredB, uint256 curveDeltaB,) = math.requiredBackingInWad(context, mintB);
        uint256 navRequirementA = BancorNavMath.navFloorBackingInWad(
            context.actualSupply, mintA, context.backingBalanceWad, context.navPremiumBps
        );

        assertLe(requiredA, requiredB);
        assertLe(curveDeltaA, curveDeltaB);
        assertEq(requiredA, Math.max(curveDeltaA, navRequirementA));
        assertEq(usesFloorA, navRequirementA > curveDeltaA);
    }

    function testFuzzCurveMintThenBurnIsConservativeInverse(
        uint96 supplyRaw,
        uint96 reserveRaw,
        uint96 mintRaw,
        uint8 shapeRaw
    ) public view {
        uint256 supply = bound(uint256(supplyRaw), 1 ether, 1_000_000 ether);
        uint256 reserve = bound(uint256(reserveRaw), 1 ether, 1_000_000 ether);
        uint256 mintAmount = bound(uint256(mintRaw), 1, supply / 2);
        uint8 shape = _shape(shapeRaw);

        uint256 mintReserveDelta = math.curveReserveDeltaForMint(supply, mintAmount, reserve, shape);
        (uint256 burnSupplyDelta, uint256 burnReserveDelta) =
            math.curveStateReductionForBurn(supply + mintAmount, reserve + mintReserveDelta, mintAmount, shape);

        assertEq(burnSupplyDelta, mintAmount);

        uint256 finalSupply = supply + mintAmount - burnSupplyDelta;
        uint256 finalReserve = reserve + mintReserveDelta - burnReserveDelta;
        assertEq(finalSupply, supply);
        assertApproxEqAbs(finalReserve, reserve, _inverseRoundTripTolerance(reserve));

        uint256 originalSpot = math.spot(supply, reserve, shape);
        uint256 finalSpot = math.spot(finalSupply, finalReserve, shape);
        assertApproxEqAbs(finalSpot, originalSpot, _inverseRoundTripTolerance(originalSpot));
    }

    function testSpotFormulaMatchesReserveRatioForAllShapes() public view {
        uint256 supply = 800 ether;
        uint256 reserve = 1_200 ether;

        assertEq(math.spot(supply, reserve, FOURTH_ROOT), Math.mulDiv(reserve, 5 ether, supply * 4, Math.Rounding.Ceil));
        assertEq(math.spot(supply, reserve, SQUARE_ROOT), Math.mulDiv(reserve, 3 ether, supply * 2, Math.Rounding.Ceil));
        assertEq(math.spot(supply, reserve, LINEAR), Math.mulDiv(reserve, 2 ether, supply, Math.Rounding.Ceil));
    }

    function testFuzzBoundedBurnReductionIsLargestSafeReduction(
        uint96 reserveRaw,
        uint96 backingRaw,
        uint96 burnRaw,
        uint8 shapeRaw
    ) public view {
        uint256 actualSupply = 1_000 ether;
        uint256 virtualSupply = 1_000 ether;
        uint256 burnAmount = bound(uint256(burnRaw), 1, 150 ether);
        uint8 shape = _shape(shapeRaw);
        BancorNavMath.PricingContext memory context = BancorNavMath.PricingContext({
            virtualSupply: virtualSupply,
            curveReserveWad: bound(uint256(reserveRaw), 1 ether, 2_000 ether),
            actualSupply: actualSupply,
            backingBalanceWad: bound(uint256(backingRaw), 1 ether, 2_000 ether),
            navPremiumBps: NAV_PREMIUM_BPS,
            shape: shape
        });
        uint256 postBurnActualSupply = actualSupply - Math.min(burnAmount, 500 ether);

        uint256 currentSpot = math.spot(context.virtualSupply, context.curveReserveWad, shape);
        uint256 postBurnNavFloor = math.navFloor(postBurnActualSupply, context.backingBalanceWad, context.navPremiumBps);
        (uint256 supplyDelta, uint256 reserveDelta) =
            math.boundedCurveStateReductionForBurn(context, burnAmount, postBurnActualSupply);

        if (currentSpot <= postBurnNavFloor) {
            assertEq(supplyDelta, 0);
            assertEq(reserveDelta, 0);
            return;
        }

        if (supplyDelta > 0) {
            uint256 postSpot = math.spot(virtualSupply - supplyDelta, context.curveReserveWad - reserveDelta, shape);
            assertGe(postSpot, postBurnNavFloor);
        }

        uint256 upperBound = Math.min(burnAmount, virtualSupply);
        if (postBurnNavFloor > 0 && upperBound == virtualSupply) upperBound = virtualSupply - 1;
        if (supplyDelta < upperBound) {
            (uint256 nextSupplyDelta, uint256 nextReserveDelta) =
                math.curveStateReductionForBurn(virtualSupply, context.curveReserveWad, supplyDelta + 1, shape);
            uint256 nextSpot =
                math.spot(virtualSupply - nextSupplyDelta, context.curveReserveWad - nextReserveDelta, shape);
            assertLt(nextSpot, postBurnNavFloor);
        }
    }

    function testBurnAdjustmentUsesFullEffectiveBurnWhenCurveRemainsAbovePostBurnNavFloor() public view {
        BancorNavMath.PricingContext memory context = BancorNavMath.PricingContext({
            virtualSupply: 1_000 ether,
            curveReserveWad: 1_000 ether,
            actualSupply: 1_000 ether,
            backingBalanceWad: 100 ether,
            navPremiumBps: NAV_PREMIUM_BPS,
            shape: LINEAR
        });
        uint256 burnAmount = 100 ether;

        (uint256 supplyDelta, uint256 reserveDelta) =
            math.boundedCurveStateReductionForBurn(context, burnAmount, context.actualSupply - burnAmount);
        (uint256 fullSupplyDelta, uint256 fullReserveDelta) =
            math.curveStateReductionForBurn(context.virtualSupply, context.curveReserveWad, burnAmount, context.shape);

        assertEq(supplyDelta, fullSupplyDelta);
        assertEq(reserveDelta, fullReserveDelta);
        assertEq(supplyDelta, burnAmount);
    }

    function testBurnAdjustmentStopsAtPostBurnNavFloorWhenFullBurnWouldUnderpriceCurve() public view {
        BancorNavMath.PricingContext memory context = BancorNavMath.PricingContext({
            virtualSupply: 1_000 ether,
            curveReserveWad: 300 ether,
            actualSupply: 1_000 ether,
            backingBalanceWad: 500 ether,
            navPremiumBps: NAV_PREMIUM_BPS,
            shape: LINEAR
        });
        uint256 burnAmount = 100 ether;

        (uint256 supplyDelta, uint256 reserveDelta) =
            math.boundedCurveStateReductionForBurn(context, burnAmount, context.actualSupply - burnAmount);

        assertGt(supplyDelta, 0);
        assertLt(supplyDelta, burnAmount);

        uint256 postBurnNavFloor =
            math.navFloor(context.actualSupply - burnAmount, context.backingBalanceWad, context.navPremiumBps);
        uint256 postSpot =
            math.spot(context.virtualSupply - supplyDelta, context.curveReserveWad - reserveDelta, context.shape);
        assertGe(postSpot, postBurnNavFloor);

        (uint256 nextSupplyDelta, uint256 nextReserveDelta) = math.curveStateReductionForBurn(
            context.virtualSupply, context.curveReserveWad, supplyDelta + 1, context.shape
        );
        uint256 nextSpot = math.spot(
            context.virtualSupply - nextSupplyDelta, context.curveReserveWad - nextReserveDelta, context.shape
        );
        assertLt(nextSpot, postBurnNavFloor);
    }

    function testBurnAdjustmentReturnsZeroWhenCurveAlreadyAtOrBelowPostBurnNavFloor() public view {
        BancorNavMath.PricingContext memory context = BancorNavMath.PricingContext({
            virtualSupply: 1_000 ether,
            curveReserveWad: 260 ether,
            actualSupply: 1_000 ether,
            backingBalanceWad: 500 ether,
            navPremiumBps: NAV_PREMIUM_BPS,
            shape: LINEAR
        });

        (uint256 supplyDelta, uint256 reserveDelta) =
            math.boundedCurveStateReductionForBurn(context, 100 ether, context.actualSupply - 100 ether);

        assertEq(supplyDelta, 0);
        assertEq(reserveDelta, 0);
    }

    function testBurnAdjustmentWalksBackwardAlongSameCurveShape() public view {
        BancorNavMath.PricingContext memory context = BancorNavMath.PricingContext({
            virtualSupply: 1_000 ether,
            curveReserveWad: 800 ether,
            actualSupply: 1_000 ether,
            backingBalanceWad: 100 ether,
            navPremiumBps: NAV_PREMIUM_BPS,
            shape: SQUARE_ROOT
        });
        uint256 burnAmount = 123 ether;

        (uint256 supplyDelta, uint256 reserveDelta) =
            math.boundedCurveStateReductionForBurn(context, burnAmount, context.actualSupply - burnAmount);
        (uint256 shapeSupplyDelta, uint256 shapeReserveDelta) =
            math.curveStateReductionForBurn(context.virtualSupply, context.curveReserveWad, supplyDelta, context.shape);

        assertEq(supplyDelta, shapeSupplyDelta);
        assertEq(reserveDelta, shapeReserveDelta);
    }

    function testBurnAdjustmentUsesOnlyEffectiveBurnAmount() public view {
        BancorNavMath.PricingContext memory context = BancorNavMath.PricingContext({
            virtualSupply: 1_000 ether,
            curveReserveWad: 1_000 ether,
            actualSupply: 1_000 ether,
            backingBalanceWad: 100 ether,
            navPremiumBps: NAV_PREMIUM_BPS,
            shape: FOURTH_ROOT
        });
        uint256 effectiveBurnAmount = 40 ether;

        (uint256 supplyDelta,) = math.boundedCurveStateReductionForBurn(
            context, effectiveBurnAmount, context.actualSupply - effectiveBurnAmount
        );

        assertLe(supplyDelta, effectiveBurnAmount);
    }

    function testBurnAdjustmentUsesGrossBurnAmountEvenWhenPostBurnSupplyIsUnchanged() public view {
        BancorNavMath.PricingContext memory context = BancorNavMath.PricingContext({
            virtualSupply: 1_000 ether,
            curveReserveWad: 1_000 ether,
            actualSupply: 900 ether,
            backingBalanceWad: 100 ether,
            navPremiumBps: NAV_PREMIUM_BPS,
            shape: LINEAR
        });
        uint256 grossBurnAmount = 40 ether;

        (uint256 supplyDelta,) = math.boundedCurveStateReductionForBurn(context, grossBurnAmount, context.actualSupply);

        assertEq(supplyDelta, grossBurnAmount);
    }

    function testBurnAdjustmentRevertsWhenPostBurnSupplyIsZero() public {
        BancorNavMath.PricingContext memory context = BancorNavMath.PricingContext({
            virtualSupply: 1_000 ether,
            curveReserveWad: 1_000 ether,
            actualSupply: 100 ether,
            backingBalanceWad: 100 ether,
            navPremiumBps: NAV_PREMIUM_BPS,
            shape: LINEAR
        });

        vm.expectRevert(BancorNavMath.BancorNavMath__InvalidSupply.selector);
        math.boundedCurveStateReductionForBurn(context, 100 ether, 0);
    }

    function _shape(uint8 rawShape) internal pure returns (uint8) {
        return rawShape % 3;
    }

    function _inverseRoundTripTolerance(uint256 value) internal pure returns (uint256) {
        return Math.max(1_000, value / 1_000_000_000_000);
    }
}
