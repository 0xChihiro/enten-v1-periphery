///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BancorNavMath} from "../libraries/BancorNavMath.sol";

interface ICurve {
    enum CurveShape {
        FourthRoot, // y = x^(1/4), reserve ratio = 80%
        SquareRoot, // y = x^(1/2), reserve ratio = 66.67%
        Linear // y = x, reserve ratio = 50%
    }

    struct BuyQuote {
        uint256 grossEthIn;
        uint256 mintAmount;
        uint256 curveReserveDeltaWad;
        uint256 curveSupplyDeltaWad;
        bool usesNavFloor;
    }

    struct CurveState {
        uint256 virtualSupplyWad;
        uint256 virtualReserveWad;
    }

    struct QuoteContext {
        uint256 maxSupply;
        BancorNavMath.PricingContext pricing;
    }

    event CurveConfigured(address indexed controller, CurveShape indexed shape, address indexed reserveAsset);
    event CurveSeeded(uint256 virtualSupplyWad, uint256 virtualReserveWad);
    event PausedUpdated(bool paused);
    event UnguardedEthPurchase(address indexed payer, uint256 ethIn);
    event TokensPurchased(
        address indexed payer,
        uint256 mintAmount,
        uint256 grossEthIn,
        uint256 curveReserveDeltaWad,
        uint256 curveSupplyDeltaWad,
        bool usesNavFloor
    );

    error Curve__ZeroAddress();
    error Curve__TargetNotAContract(address target);
    error Curve__InvalidController();
    error Curve__InvalidFee();
    error Curve__OnlyAdmin();
    error Curve__NotLive();
    error Curve__AlreadySeeded();
    error Curve__MinterNotConfigured();
    error Curve__Paused();
    error Curve__ReentrantCall();
    error Curve__Expired();
    error Curve__ZeroAmount();
    error Curve__ZeroPrice();
    error Curve__InvalidSupply();
    error Curve__VirtualCurveNotSeeded();
    error Curve__CapExceeded(uint256 endSupply, uint256 maxSupply);
    error Curve__Slippage(uint256 requiredEthIn, uint256 maxEthIn);
    error Curve__MintSlippage(uint256 mintAmount, uint256 minMintAmount);
    error Curve__EthRefundFailed();
}
