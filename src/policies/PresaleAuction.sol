///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ReentrancyGuard} from "openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MINTR} from "../modules/MINTR/MINTR.v1.sol";
import {backingPerToken} from "../Utils.sol";
import {Keycode, Permissions} from "enten-v1/Utils.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IKernel} from "enten-v1/interfaces/IKernel.sol";
import {IToken} from "enten-v1/interfaces/IToken.sol";
import {Policy} from "enten-v1/Policy.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";

contract PresaleAuction is ReentrancyGuard, Policy {
    /*----------  CONSTANTS  --------------------------------------------*/

    Keycode internal constant PRESALE_KEYCODE = Keycode.wrap("PSALE");
    Keycode internal constant MINTR_KEYCODE = Keycode.wrap("MINTR");

    uint256 public constant MAX_DURATION = 7 days;
    uint256 public constant MIN_DURATION = 1 hours;
    uint256 public constant WAD = 1e18;

    /*----------  IMMUTABLES  -------------------------------------------*/

    IKernel public immutable KERNEL;
    IToken public immutable TOKEN;
    address public immutable ASSET;
    uint256 public immutable PRESALE_SIZE;
    uint256 public immutable START_PRICE;
    uint256 public immutable VIRTUAL_TOKEN_RESERVE;
    uint256 public immutable DURATION;
    uint256 public immutable MIN_BID;

    /*----------  STATE  ------------------------------------------------*/

    MINTR public minterModule;
    uint256 public startTime;
    uint256 public remaining;
    uint256 public sold;
    uint256 public currentPremium;
    uint256 public lastPriceUpdate;
    uint256 public totalCommitted;
    bool public premiumInitialized;

    /*----------  ERRORS  -----------------------------------------------*/

    error PresaleAuction__InvalidConfig();
    error PresaleAuction__MaxPayment();
    error PresaleAuction__AuctionOver();
    error PresaleAuction__DeadlinePassed();
    error PresaleAuction__InvalidFeeConfiguration();
    error PresaleAuction__InvalidMintAmount();
    error PresaleAuction__MinimumBid();
    error PresaleAuction__TooManyTokens();
    error PresaleAuction__UnsupportedBackingAsset();
    error PresaleAuction__UnseededAsset();

    /*----------  EVENTS  -----------------------------------------------*/

    event PresaleAuction__Buy(
        address indexed buyer,
        IController.Receipt payment,
        uint256 amountMinted,
        uint256 clearingPrice,
        uint256 nextPrice
    );

    /*----------  CONSTRUCTOR  ------------------------------------------*/

    constructor(
        address controller,
        address asset,
        uint256 presaleSize,
        uint256 startPrice,
        uint256 virtualTokenReserve,
        uint256 duration,
        uint256 minBid
    ) Policy(controller) {
        if (
            asset == address(0) || presaleSize == 0 || startPrice == 0 || virtualTokenReserve == 0 || minBid == 0
                || minBid > presaleSize || duration < MIN_DURATION || duration > MAX_DURATION
        ) {
            revert PresaleAuction__InvalidConfig();
        }

        KERNEL = CONTROLLER.KERNEL();
        TOKEN = CONTROLLER.TOKEN();
        ASSET = asset;
        PRESALE_SIZE = presaleSize;
        START_PRICE = startPrice;
        VIRTUAL_TOKEN_RESERVE = virtualTokenReserve;
        DURATION = duration;
        MIN_BID = minBid;

        startTime = block.timestamp;
        lastPriceUpdate = block.timestamp;
        remaining = presaleSize;
    }

    function KEYCODE() public pure override returns (Keycode) {
        return PRESALE_KEYCODE;
    }

    function configureDependencies() external override onlyController returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](1);
        dependencies[0] = MINTR_KEYCODE;

        minterModule = MINTR(getModuleAddress(dependencies[0]));
    }

    function requestPermissions() external pure override returns (Permissions[] memory permissions) {
        permissions = new Permissions[](1);
        permissions[0] = Permissions({keycode: MINTR_KEYCODE, funcSelector: MINTR.mint.selector});
    }

    /*----------  EXTERNAL FUNCTIONS  -----------------------------------*/

    function buy(uint256 amount, uint256 maxPayment, uint256 deadline)
        external
        nonReentrant
        returns (IController.Receipt[] memory costs)
    {
        return _buy(amount, maxPayment, deadline);
    }

    function buyMax(uint256 maxPayment, uint256 deadline)
        external
        nonReentrant
        returns (IController.Receipt[] memory costs)
    {
        return _buy(remaining, maxPayment, deadline);
    }

    /*----------  VIEW FUNCTIONS  ---------------------------------------*/

    function price() public view returns (uint256) {
        uint256 minimum = minimumPrice();
        return minimum + _premium(minimum);
    }

    function quote(uint256 amount) public view returns (uint256 payment, uint256 spotPrice, uint256 nextPremium) {
        if (amount == 0) revert PresaleAuction__InvalidMintAmount();
        if (amount > remaining) revert PresaleAuction__TooManyTokens();

        uint256 minimum = minimumPrice();
        uint256 premium = _premium(minimum);
        (uint256 premiumPayment, uint256 premiumAfter) = _premiumQuote(amount, premium);

        payment = Math.mulDiv(amount, minimum, WAD, Math.Rounding.Ceil) + premiumPayment;
        spotPrice = minimum + premium;
        nextPremium = premiumAfter;
    }

    function minimumPrice() public view returns (uint256) {
        IController.Backing[] memory backings = backingPerToken(KERNEL, TOKEN);
        if (backings.length != 1 || backings[0].asset != ASSET) {
            revert PresaleAuction__UnsupportedBackingAsset();
        }
        if (backings[0].backingPerToken == 0) revert PresaleAuction__UnseededAsset();

        return _grossUpForFees(backings[0].backingPerToken);
    }

    /*----------  INTERNAL FUNCTIONS  -----------------------------------*/

    function _buy(uint256 amount, uint256 maxPayment, uint256 deadline)
        internal
        returns (IController.Receipt[] memory costs)
    {
        if (block.timestamp > deadline) revert PresaleAuction__DeadlinePassed();
        if (remaining == 0 || block.timestamp >= startTime + DURATION) revert PresaleAuction__AuctionOver();
        if (amount == 0) revert PresaleAuction__InvalidMintAmount();
        if (amount > remaining) revert PresaleAuction__TooManyTokens();
        if (amount < MIN_BID && amount != remaining) revert PresaleAuction__MinimumBid();

        (uint256 paymentAmount, uint256 clearingPrice, uint256 nextPremium) = quote(amount);
        if (paymentAmount > maxPayment) revert PresaleAuction__MaxPayment();

        costs = new IController.Receipt[](1);
        costs[0] = IController.Receipt({asset: ASSET, amount: paymentAmount});

        unchecked {
            remaining -= amount;
            sold += amount;
        }
        currentPremium = nextPremium;
        lastPriceUpdate = block.timestamp;
        premiumInitialized = true;
        totalCommitted += paymentAmount;

        minterModule.mint(msg.sender, amount, costs, new IController.StateUpdate[](0));

        emit PresaleAuction__Buy(msg.sender, costs[0], amount, clearingPrice, price());
    }

    function _premium(uint256 minimum) internal view returns (uint256) {
        uint256 anchor = premiumInitialized ? currentPremium : START_PRICE > minimum ? START_PRICE - minimum : 0;
        uint256 elapsed = block.timestamp - lastPriceUpdate;
        return elapsed >= DURATION ? 0 : anchor - Math.mulDiv(anchor, elapsed, DURATION);
    }

    function _premiumQuote(uint256 amount, uint256 premium)
        internal
        view
        returns (uint256 premiumPayment, uint256 nextPremium)
    {
        if (premium == 0) return (0, 0);

        uint256 tokenReserve = VIRTUAL_TOKEN_RESERVE + remaining;
        uint256 nextTokenReserve = tokenReserve - amount;
        uint256 quoteReserve = Math.mulDiv(premium, tokenReserve, WAD, Math.Rounding.Ceil);

        premiumPayment = Math.mulDiv(quoteReserve, amount, nextTokenReserve, Math.Rounding.Ceil);
        nextPremium = Math.mulDiv(quoteReserve + premiumPayment, WAD, nextTokenReserve, Math.Rounding.Ceil);
    }

    function _grossUpForFees(uint256 targetBackingPerToken) internal view returns (uint256) {
        uint256 bps = CONTROLLER.BPS();
        uint256 protocolFeeBps = CONTROLLER.AUCTION_FEE_BPS();
        uint256 teamBps = uint256(KERNEL.viewData(Slots.TEAM_PERCENTAGE_SLOT));
        uint256 treasuryBps = uint256(KERNEL.viewData(Slots.TREASURY_PERCENTAGE_SLOT));
        if (bps == 0 || protocolFeeBps >= bps || teamBps >= bps || treasuryBps >= bps || teamBps + treasuryBps >= bps) {
            revert PresaleAuction__InvalidFeeConfiguration();
        }

        uint256 backingBps = bps - teamBps - treasuryBps;
        uint256 postProtocolBps = bps - protocolFeeBps;
        uint256 requiredPostProtocol = Math.mulDiv(targetBackingPerToken, bps, backingBps, Math.Rounding.Ceil);
        return Math.mulDiv(requiredPostProtocol, bps, postProtocolBps, Math.Rounding.Ceil);
    }
}
