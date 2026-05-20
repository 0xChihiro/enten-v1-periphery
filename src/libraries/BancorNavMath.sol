// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Math} from "openzeppelin/contracts/utils/math/Math.sol";

library BancorNavMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint8 internal constant FOURTH_ROOT = 0;
    uint8 internal constant SQUARE_ROOT = 1;

    struct PricingContext {
        uint256 virtualSupply;
        uint256 curveReserveWad;
        uint256 actualSupply;
        uint256 backingBalanceWad;
        uint256 navPremiumBps;
        uint8 shape;
    }

    error BancorNavMath__InvalidSupply();
    error BancorNavMath__BurnExceedsSupply(uint256 burnAmount, uint256 supply);

    function requiredBackingInWad(PricingContext memory context, uint256 mintAmount)
        internal
        pure
        returns (uint256 requiredBackingWad, uint256 curveReserveDeltaWad, bool usesNavFloor)
    {
        curveReserveDeltaWad =
            curveReserveDeltaForMint(context.virtualSupply, mintAmount, context.curveReserveWad, context.shape);
        uint256 navFloorBackingWad =
            navFloorBackingInWad(context.actualSupply, mintAmount, context.backingBalanceWad, context.navPremiumBps);

        requiredBackingWad = Math.max(curveReserveDeltaWad, navFloorBackingWad);
        usesNavFloor = navFloorBackingWad > curveReserveDeltaWad;
    }

    function mintAmountForBackingWad(PricingContext memory context, uint256 maxMintAmount, uint256 backingInWad)
        internal
        pure
        returns (uint256 mintAmount, uint256 curveReserveDeltaWad, bool usesNavFloor)
    {
        uint256 low;
        uint256 high = maxMintAmount;

        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            (uint256 requiredBackingWad,,) = requiredBackingInWad(context, mid);

            if (requiredBackingWad <= backingInWad) low = mid;
            else high = mid - 1;
        }

        mintAmount = low;
        (, curveReserveDeltaWad, usesNavFloor) = requiredBackingInWad(context, mintAmount);
    }

    function curveReserveDeltaForMint(uint256 supply, uint256 tokenAmount, uint256 curveReserveWad, uint8 shape)
        internal
        pure
        returns (uint256)
    {
        uint256 ratioWad = Math.mulDiv(supply + tokenAmount, WAD, supply, Math.Rounding.Ceil);
        uint256 growth = growthWad(ratioWad, shape);
        return Math.mulDiv(curveReserveWad, growth - WAD, WAD, Math.Rounding.Ceil);
    }

    function curveStateReductionForBurn(
        uint256 virtualSupplyWad,
        uint256 virtualReserveWad,
        uint256 burnAmount,
        uint8 shape
    ) internal pure returns (uint256 curveSupplyDeltaWad, uint256 curveReserveDeltaWad) {
        if (burnAmount > virtualSupplyWad) {
            revert BancorNavMath__BurnExceedsSupply(burnAmount, virtualSupplyWad);
        }

        curveSupplyDeltaWad = burnAmount;
        if (burnAmount == virtualSupplyWad) return (curveSupplyDeltaWad, virtualReserveWad);

        uint256 ratioWad = Math.mulDiv(virtualSupplyWad - burnAmount, WAD, virtualSupplyWad);
        uint256 decay = growthWad(ratioWad, shape);
        curveReserveDeltaWad = Math.mulDiv(virtualReserveWad, WAD - decay, WAD);
    }

    function boundedCurveStateReductionForBurn(
        PricingContext memory context,
        uint256 curveBurnAmount,
        uint256 postBurnActualSupply
    ) internal pure returns (uint256 curveSupplyDeltaWad, uint256 curveReserveDeltaWad) {
        if (curveBurnAmount == 0) return (0, 0);
        if (postBurnActualSupply == 0 || postBurnActualSupply > context.actualSupply) {
            revert BancorNavMath__InvalidSupply();
        }
        uint256 virtualSupply = context.virtualSupply;
        uint256 virtualReserve = context.curveReserveWad;
        uint8 shape = context.shape;
        if (virtualSupply == 0) revert BancorNavMath__InvalidSupply();

        uint256 postBurnNavFloor =
            navFloorPriceWad(postBurnActualSupply, context.backingBalanceWad, context.navPremiumBps);
        uint256 currentSpot = bancorSpotPriceWad(virtualSupply, virtualReserve, shape);
        if (currentSpot <= postBurnNavFloor) return (0, 0);

        uint256 upperBound = Math.min(curveBurnAmount, virtualSupply);
        if (postBurnNavFloor > 0 && upperBound == virtualSupply) upperBound = virtualSupply - 1;
        if (upperBound == 0) return (0, 0);

        uint256 low;
        uint256 high = upperBound;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            uint256 candidateSpot = _curveSpotAfterBurnReduction(virtualSupply, virtualReserve, mid, shape);

            if (candidateSpot >= postBurnNavFloor) low = mid;
            else high = mid - 1;
        }

        if (low == 0) return (0, 0);
        return curveStateReductionForBurn(virtualSupply, virtualReserve, low, shape);
    }

    function _curveSpotAfterBurnReduction(
        uint256 virtualSupplyWad,
        uint256 virtualReserveWad,
        uint256 burnAmount,
        uint8 shape
    ) private pure returns (uint256) {
        (uint256 supplyDelta, uint256 reserveDelta) =
            curveStateReductionForBurn(virtualSupplyWad, virtualReserveWad, burnAmount, shape);
        uint256 newSupply = virtualSupplyWad - supplyDelta;
        if (newSupply == 0) return 0;
        return bancorSpotPriceWad(newSupply, virtualReserveWad - reserveDelta, shape);
    }

    function navFloorBackingInWad(uint256 supply, uint256 tokenAmount, uint256 backingBalanceWad, uint256 navPremiumBps)
        internal
        pure
        returns (uint256)
    {
        if (backingBalanceWad == 0) return 0;

        uint256 floorPrice = navFloorPriceWad(supply, backingBalanceWad, navPremiumBps);
        return Math.mulDiv(tokenAmount, floorPrice, WAD, Math.Rounding.Ceil);
    }

    function navFloorPriceWad(uint256 supply, uint256 backingBalanceWad, uint256 navPremiumBps)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(navPriceWad(supply, backingBalanceWad), BPS + navPremiumBps, BPS, Math.Rounding.Ceil);
    }

    function navPriceWad(uint256 supply, uint256 backingBalanceWad) internal pure returns (uint256) {
        if (supply == 0) revert BancorNavMath__InvalidSupply();
        if (backingBalanceWad == 0) return 0;
        return Math.mulDiv(backingBalanceWad, WAD, supply);
    }

    function bancorSpotPriceWad(uint256 supply, uint256 curveReserveWad, uint8 shape) internal pure returns (uint256) {
        if (supply == 0) revert BancorNavMath__InvalidSupply();
        if (curveReserveWad == 0) return 0;

        (uint256 numerator, uint256 denominator) = reserveRatio(shape);
        uint256 reservePerTokenWad = Math.mulDiv(curveReserveWad, WAD, supply);
        return Math.mulDiv(reservePerTokenWad, denominator, numerator, Math.Rounding.Ceil);
    }

    function reserveRatio(uint8 shape) internal pure returns (uint256 numerator, uint256 denominator) {
        if (shape == FOURTH_ROOT) return (4, 5);
        if (shape == SQUARE_ROOT) return (2, 3);
        return (1, 2);
    }

    function growthWad(uint256 ratioWad, uint8 shape) internal pure returns (uint256) {
        if (shape == FOURTH_ROOT) {
            return Math.mulDiv(ratioWad, sqrtWad(sqrtWad(ratioWad)), WAD, Math.Rounding.Ceil);
        }

        if (shape == SQUARE_ROOT) {
            return Math.mulDiv(ratioWad, sqrtWad(ratioWad), WAD, Math.Rounding.Ceil);
        }

        return Math.mulDiv(ratioWad, ratioWad, WAD, Math.Rounding.Ceil);
    }

    function sqrtWad(uint256 xWad) internal pure returns (uint256) {
        return Math.sqrt(xWad * WAD, Math.Rounding.Ceil);
    }
}
