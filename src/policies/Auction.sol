// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ReentrancyGuard} from "openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Policy} from "enten-v1/Policy.sol";
import {Permissions, Keycode} from "enten-v1/Utils.sol";
import {backingPerToken, assets} from "../Utils.sol";
import {IKernel} from "enten-v1/interfaces/IKernel.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IToken} from "enten-v1/interfaces/IToken.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {MINTR} from "../modules/MINTR/MINTR.v1.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";

interface ITokenSupply {
    function MAX_SUPPLY() external view returns (uint256);
}

interface IControllerFeeView {
    function BPS() external view returns (uint256);
    function AUCTION_FEE_BPS() external view returns (uint256);
}

/**
 * @title Auction
 * @author 0xChihiro
 * @notice A Dutch auction contract for selling newly minted tokens in exchange for assets.
 *         The price decays linearly from the configured multiplier to a minimum scalar price over each epoch. When purchased,
 *         a call is sent to the accompanying module to mint new tokens and send them to the buyer.
 *         A new auction resets the lot and decay clock while pricing continues from current backing.
 * @dev Forked and modified from Euler Fee Flow, then further modified from heesho's version.
 */
contract Auction is ReentrancyGuard, Policy {
    struct Revenue {
        address asset;
        uint256 revenue;
    }
    /*----------  CONSTANTS  --------------------------------------------*/

    Keycode internal constant AUCTION_KEYCODE = Keycode.wrap("AUCTN");
    Keycode internal constant MINTR_KEYCODE = Keycode.wrap("MINTR");

    uint256 public constant MIN_EPOCH_PERIOD = 1 hours;
    uint256 public constant MAX_EPOCH_PERIOD = 365 days;
    uint256 public constant MIN_PRICE_MULTIPLIER = 1.1e18; // 1.1x minimum
    uint256 public constant MAX_PRICE_MULTIPLIER = 3e18; // 3x maximum
    uint256 public constant PRICE_MULTIPLIER_SCALE = 1e18;

    /*----------  IMMUTABLES  -------------------------------------------*/

    IKernel public immutable KERNEL;
    IToken public immutable TOKEN;
    uint256 public immutable LOT_SIZE;
    uint256 public immutable epochPeriod; // duration of each Dutch auction
    uint256 public immutable priceMultiplier; // multiplier for next epoch's starting price

    /*----------  STATE  ------------------------------------------------*/

    uint256 public epochId; // current epoch counter
    uint256 public startTime; // timestamp when current epoch began
    MINTR public minter; // Associated Minter Module that goes with the Auction
    uint256 public remainingLot; // Remaining lot size of the current auction
    uint256 public previousRoundSold; // Amount of tokens sold in the previous round
    mapping(address => uint256) public previousRoundRevenue; // Amount of each asset brought in in the previous round.
    uint256 public sold; // Amount of tokens that have been sold during the current round
    mapping(address => uint256) public revenue; // Amount of tokens brought in for this round

    /*----------  ERRORS  -----------------------------------------------*/

    error Auction__DeadlinePassed();
    error Auction__AuctionExpired();
    error Auction__EpochIdMismatch();
    error Auction__EmptyAssets();
    error Auction__InvalidMintAmount();
    error Auction__MaxPaymentAmountExceeded();
    error Auction__MaxPaymentAssetMismatch();
    error Auction__MaxPaymentsLengthMismatch();
    error Auction__EpochPeriodBelowMin();
    error Auction__EpochPeriodExceedsMax();
    error Auction__PriceMultiplierBelowMin();
    error Auction__PriceMultiplierExceedsMax();
    error Auction__InvalidLotSize();
    error Auction__TooManyTokens();
    error Auction__OngoingAuction();
    error Auction__UnseededAsset();
    error Auction__InvalidFeeConfiguration();

    /*----------  EVENTS  -----------------------------------------------*/

    event Auction__Buy(address indexed buyer, uint256 epoch, IController.Receipt[] payment, uint256 amountMinted);
    event Auction__Start(address indexed starter, uint256 epoch, uint256 startTime, uint256 lotSize);

    /*----------  CONSTRUCTOR  ------------------------------------------*/

    /**
     * @notice Deploy a new Auction contract.
     * @param _lotSize Amount of tokens available in each epoch
     * @param _epochPeriod Duration of each auction epoch
     * @param _priceMultiplier Price multiplier for calculating next epoch's starting price
     */
    constructor(address controller, uint256 _lotSize, uint256 _epochPeriod, uint256 _priceMultiplier)
        Policy(controller)
    {
        if (_lotSize == 0) revert Auction__InvalidLotSize();
        if (_epochPeriod < MIN_EPOCH_PERIOD) revert Auction__EpochPeriodBelowMin();
        if (_epochPeriod > MAX_EPOCH_PERIOD) revert Auction__EpochPeriodExceedsMax();
        if (_priceMultiplier < MIN_PRICE_MULTIPLIER) revert Auction__PriceMultiplierBelowMin();
        if (_priceMultiplier > MAX_PRICE_MULTIPLIER) revert Auction__PriceMultiplierExceedsMax();

        startTime = block.timestamp;
        LOT_SIZE = _lotSize;
        remainingLot = _lotSize;

        epochPeriod = _epochPeriod;
        priceMultiplier = _priceMultiplier;

        KERNEL = CONTROLLER.KERNEL();
        TOKEN = CONTROLLER.TOKEN();
    }

    function KEYCODE() public pure override returns (Keycode) {
        return AUCTION_KEYCODE;
    }

    function configureDependencies() external override onlyController returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](1);
        dependencies[0] = MINTR_KEYCODE;

        minter = MINTR(getModuleAddress(dependencies[0]));
    }

    function requestPermissions() external pure override returns (Permissions[] memory permissions) {
        permissions = new Permissions[](1);
        permissions[0] = Permissions({keycode: MINTR_KEYCODE, funcSelector: MINTR.mint.selector});
    }

    /*----------  EXTERNAL FUNCTIONS  -----------------------------------*/

    function buy(uint256 _epochId, uint256 deadline, uint256 mintAmount, IController.Receipt[] calldata maxPayments)
        public
        nonReentrant
        returns (IController.Receipt[] memory)
    {
        uint256 currentEpoch = epochId;

        if (block.timestamp > deadline) revert Auction__DeadlinePassed();
        if (block.timestamp >= startTime + epochPeriod) revert Auction__AuctionExpired();
        if (_epochId != currentEpoch) revert Auction__EpochIdMismatch();
        if (mintAmount == 0) revert Auction__InvalidMintAmount();
        if (mintAmount > remainingLot) revert Auction__TooManyTokens();

        IController.Backing[] memory backings = getPrice();
        if (backings.length == 0) revert Auction__EmptyAssets();
        if (maxPayments.length != backings.length) revert Auction__MaxPaymentsLengthMismatch();
        IController.Receipt[] memory receipts = new IController.Receipt[](backings.length);

        for (uint256 i = 0; i < backings.length;) {
            if (maxPayments[i].asset != backings[i].asset) revert Auction__MaxPaymentAssetMismatch();

            uint256 paymentAmount =
                Math.mulDiv(backings[i].backingPerToken, mintAmount, PRICE_MULTIPLIER_SCALE, Math.Rounding.Ceil);
            if (paymentAmount > maxPayments[i].amount) revert Auction__MaxPaymentAmountExceeded();

            receipts[i] = IController.Receipt({asset: backings[i].asset, amount: paymentAmount});
            unchecked {
                i++;
            }
        }

        remainingLot -= mintAmount;
        minter.mint(msg.sender, mintAmount, receipts);
        sold += mintAmount;
        for (uint256 i = 0; i < receipts.length;) {
            revenue[receipts[i].asset] += receipts[i].amount;
            unchecked {
                i++;
            }
        }

        emit Auction__Buy(msg.sender, currentEpoch, receipts, mintAmount);

        if (remainingLot == 0) {
            _startNextAuction();
        }

        return receipts;
    }

    function buyMax(uint256 _epochId, uint256 deadline, IController.Receipt[] calldata maxPayments)
        external
        nonReentrant
        returns (IController.Receipt[] memory)
    {
        return buy(_epochId, deadline, remainingLot, maxPayments);
    }

    function startNextAuction() external nonReentrant {
        if (block.timestamp < startTime + epochPeriod) revert Auction__OngoingAuction();
        _startNextAuction();
    }

    function _startNextAuction() internal {
        previousRoundSold = sold;
        delete sold;
        address[] memory _assets = auctionAssets();
        for (uint256 i = 0; i < _assets.length;) {
            previousRoundRevenue[_assets[i]] = revenue[_assets[i]];
            delete revenue[_assets[i]];
            unchecked {
                i++;
            }
        }
        remainingLot = TOKEN.totalSupply() + LOT_SIZE > ITokenSupply(address(TOKEN)).MAX_SUPPLY()
            ? ITokenSupply(address(TOKEN)).MAX_SUPPLY() - TOKEN.totalSupply()
            : LOT_SIZE;
        startTime = block.timestamp;
        unchecked {
            epochId++;
        }

        emit Auction__Start(msg.sender, epochId, startTime, remainingLot);
    }

    /*----------  VIEW FUNCTIONS  ---------------------------------------*/

    /**
     * @notice Get the current Dutch auction price.
     * @dev returns the current NAV of the Tokens then adjusts the price to be backing to a scalar.
     * important to note that price is not static, as NAV per token increases through buys this actually pushes price up momentarily
     * due to the fact we use a scalar and not pure NAV pricing
     */
    function getPrice() public view returns (IController.Backing[] memory backings) {
        uint256 delta = block.timestamp - startTime;
        uint256 expectedScalar;
        if (delta < epochPeriod) {
            expectedScalar = priceMultiplier - priceMultiplier * delta / epochPeriod;
        }
        uint256 scalar = expectedScalar > MIN_PRICE_MULTIPLIER ? expectedScalar : MIN_PRICE_MULTIPLIER;
        uint256 bps = IControllerFeeView(address(CONTROLLER)).BPS();
        uint256 backingBps;
        uint256 postProtocolBps;
        {
            uint256 protocolFeeBps = IControllerFeeView(address(CONTROLLER)).AUCTION_FEE_BPS();
            uint256 teamBps = uint256(KERNEL.viewData(Slots.TEAM_PERCENTAGE_SLOT));
            uint256 treasuryBps = uint256(KERNEL.viewData(Slots.TREASURY_PERCENTAGE_SLOT));
            if (
                bps == 0 || protocolFeeBps >= bps || teamBps >= bps || treasuryBps >= bps
                    || teamBps + treasuryBps >= bps
            ) {
                revert Auction__InvalidFeeConfiguration();
            }
            backingBps = bps - teamBps - treasuryBps;
            postProtocolBps = bps - protocolFeeBps;
        }

        backings = backingPerToken(KERNEL, TOKEN);

        for (uint256 i = 0; i < backings.length;) {
            uint256 price;
            {
                uint256 scaledBacking = Math.mulDiv(backings[i].backingPerToken, scalar, PRICE_MULTIPLIER_SCALE);
                if (scaledBacking == 0) revert Auction__UnseededAsset();

                uint256 requiredPostProtocol = Math.mulDiv(scaledBacking, bps, backingBps, Math.Rounding.Ceil);
                price = Math.mulDiv(requiredPostProtocol, bps, postProtocolBps, Math.Rounding.Ceil);
            }

            if (previousRoundSold > 0) {
                uint256 previousAveragePrice = Math.mulDiv(
                    previousRoundRevenue[backings[i].asset],
                    PRICE_MULTIPLIER_SCALE,
                    previousRoundSold,
                    Math.Rounding.Ceil
                );
                uint256 averagePrice =
                    Math.mulDiv(previousAveragePrice, scalar, PRICE_MULTIPLIER_SCALE, Math.Rounding.Ceil);
                price = averagePrice > price ? averagePrice : price;
            }

            backings[i].backingPerToken = price;

            unchecked {
                i++;
            }
        }
    }

    function auctionAssets() public view returns (address[] memory) {
        address[] memory _assets = assets(KERNEL);
        return _assets;
    }
}
