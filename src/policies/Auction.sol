// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ReentrancyGuard} from "openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Policy} from "enten-v1/Policy.sol";
import {Permissions, Keycode} from "enten-v1/Utils.sol";
import {backingPerToken} from "../Utils.sol";
import {IKernel} from "enten-v1/interfaces/IKernel.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IToken} from "enten-v1/interfaces/IToken.sol";
import {MINTR} from "../modules/MINTR/MINTR.v1.sol";

/**
 * @title Auction
 * @author 0xChihiro
 * @notice A Dutch auction contract for selling newly minted tokens in exchange for assets.
 *         The price decays linearly from initPrice to a minimum scalar price over each epoch. When purchased,
 *         a call is sent to the accompanying module to mint new tokens and send them to the buyer.
 *         A new auction begins with a price based on the previous sales.
 * @dev Forked and modified from Euler Fee Flow, then further modified from heesho's version.
 */
contract Auction is ReentrancyGuard, Policy {
    /*----------  CONSTANTS  --------------------------------------------*/

    Keycode internal constant AUCTION_KEYCODE = Keycode.wrap("AUCTN");
    Keycode internal constant MINTR_KEYCODE = Keycode.wrap("MINTR");

    uint256 public constant MIN_EPOCH_PERIOD = 1 hours;
    uint256 public constant MAX_EPOCH_PERIOD = 365 days;
    uint256 public constant MIN_PRICE_MULTIPLIER = 1.1e18; // 1.1x minimum
    uint256 public constant MAX_PRICE_MULTIPLIER = 3e18; // 3x maximum
    uint256 public constant ABS_MIN_INIT_PRICE = 1e6;
    uint256 public constant ABS_MAX_INIT_PRICE = type(uint192).max;
    uint256 public constant PRICE_MULTIPLIER_SCALE = 1e18;

    /*----------  IMMUTABLES  -------------------------------------------*/

    IKernel public immutable KERNEL;
    IToken public immutable TOKEN;
    uint256 public immutable LOT_SIZE;
    uint256 public immutable epochPeriod; // duration of each Dutch auction
    uint256 public immutable priceMultiplier; // multiplier for next epoch's starting price

    /*----------  STATE  ------------------------------------------------*/

    uint256 public epochId; // current epoch counter
    uint256 public initPrice; // starting price for current epoch
    uint256 public startTime; // timestamp when current epoch began
    MINTR public minter; // Associated Minter Module that goes with the Auction
    uint256 public remainingLot; // Remaining lot size of the current auction

    /*----------  ERRORS  -----------------------------------------------*/

    error Auction__DeadlinePassed();
    error Auction__EpochIdMismatch();
    error Auction__EmptyAssets();
    error Auction__InitPriceBelowMin();
    error Auction__InitPriceExceedsMax();
    error Auction__EpochPeriodBelowMin();
    error Auction__EpochPeriodExceedsMax();
    error Auction__PriceMultiplierBelowMin();
    error Auction__PriceMultiplierExceedsMax();
    error Auction__InvalidLotSize();
    error Auction__TooManyTokens();
    error Auction__OngoingAuction();

    /*----------  EVENTS  -----------------------------------------------*/

    event Auction__Buy(address indexed buyer, uint256 epoch, IController.Receipt[] payment, uint256 amountMinted);

    /*----------  CONSTRUCTOR  ------------------------------------------*/

    /**
     * @notice Deploy a new Auction contract.
     * @param _initPrice Starting price for the first epoch
     * @param _lotSize Amount of tokens available in each epoch
     * @param _epochPeriod Duration of each auction epoch
     * @param _priceMultiplier Price multiplier for calculating next epoch's starting price
     */
    constructor(
        address controller,
        uint256 _initPrice,
        uint256 _lotSize,
        uint256 _epochPeriod,
        uint256 _priceMultiplier
    ) Policy(controller) {
        if (_lotSize == 0) revert Auction__InvalidLotSize();
        if (_initPrice < ABS_MIN_INIT_PRICE) revert Auction__InitPriceBelowMin();
        if (_initPrice > ABS_MAX_INIT_PRICE) revert Auction__InitPriceExceedsMax();
        if (_epochPeriod < MIN_EPOCH_PERIOD) revert Auction__EpochPeriodBelowMin();
        if (_epochPeriod > MAX_EPOCH_PERIOD) revert Auction__EpochPeriodExceedsMax();
        if (_priceMultiplier < MIN_PRICE_MULTIPLIER) revert Auction__PriceMultiplierBelowMin();
        if (_priceMultiplier > MAX_PRICE_MULTIPLIER) revert Auction__PriceMultiplierExceedsMax();

        initPrice = _initPrice;
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

    /**
     */
    function buy(uint256 _epochId, uint256 deadline, uint256 mintAmount)
        external
        nonReentrant
        returns (IController.Receipt[] memory)
    {
        if (block.timestamp > deadline) revert Auction__DeadlinePassed();
        if (_epochId != epochId) revert Auction__EpochIdMismatch();
        if (mintAmount > remainingLot) revert Auction__TooManyTokens();

        IController.Backing[] memory backings = getPrice();
        if (backings.length == 0) revert Auction__EmptyAssets();
        IController.Receipt[] memory receipts = new IController.Receipt[](backings.length);

        for (uint256 i = 0; i < backings.length;) {
            uint256 paymentAmount = backings[i].backingPerToken * mintAmount / PRICE_MULTIPLIER_SCALE;
            receipts[i] = IController.Receipt({asset: backings[i].asset, amount: paymentAmount});
            unchecked {
                i++;
            }
        }

        IController.StateUpdate[] memory updates = new IController.StateUpdate[](0);
        remainingLot -= mintAmount;
        minter.mint(msg.sender, mintAmount, receipts, updates);

        if (remainingLot == 0 || block.timestamp > startTime + epochPeriod) {
            // TODO: check available supply to sell
            startTime = block.timestamp;
            remainingLot = LOT_SIZE;
            unchecked {
                epochId++;
            }
        }

        emit Auction__Buy(msg.sender, epochId, receipts, mintAmount);

        return receipts;
    }
    // TODO: check avaiable supply to actually sell.
    function startNextAuction() external {
        if (block.timestamp <= startTime + epochPeriod) revert Auction__OngoingAuction();
        remainingLot = LOT_SIZE;
        startTime = block.timestamp;
        unchecked {
            epochId++;
        }
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
        uint256 expectedScalar = priceMultiplier - priceMultiplier * delta / epochPeriod;
        uint256 scalar = expectedScalar > MIN_PRICE_MULTIPLIER ? expectedScalar : MIN_PRICE_MULTIPLIER;
        backings = backingPerToken(KERNEL, TOKEN);
        for (uint256 i = 0; i < backings.length;) {
            uint256 scaledBacking = backings[i].backingPerToken * scalar / PRICE_MULTIPLIER_SCALE;
            backings[i].backingPerToken = scaledBacking > 0 ? scaledBacking : initPrice;
            unchecked {
                i++;
            }
        }
    }
}
