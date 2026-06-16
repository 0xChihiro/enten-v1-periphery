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
    address public immutable ADMIN;
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
    error PresaleAuction__NotAdmin();
    error PresaleAuction__NotOpen();
    error PresaleAuction__AlreadyOpen();
    error PresaleAuction__StartPriceBelowFloor();

    /*----------  EVENTS  -----------------------------------------------*/

    event PresaleAuction__Buy(
        address indexed buyer,
        IController.Receipt payment,
        uint256 amountMinted,
        uint256 clearingPrice,
        uint256 nextPrice
    );

    event PresaleAuction__Open(uint256 startTime, uint256 startPrice, uint256 floor);

    /*----------  MODIFIERS  --------------------------------------------*/

    modifier onlyAdmin() {
        if (msg.sender != ADMIN) revert PresaleAuction__NotAdmin();
        _;
    }

    /*----------  CONSTRUCTOR  ------------------------------------------*/

    constructor(
        address controller,
        address asset,
        address admin,
        uint256 presaleSize,
        uint256 startPrice,
        uint256 virtualTokenReserve,
        uint256 duration,
        uint256 minBid
    ) Policy(controller) {
        if (
            asset == address(0) || admin == address(0) || presaleSize == 0 || startPrice == 0
                || virtualTokenReserve == 0 || minBid == 0 || minBid > presaleSize || duration < MIN_DURATION
                || duration > MAX_DURATION
        ) {
            revert PresaleAuction__InvalidConfig();
        }

        KERNEL = CONTROLLER.KERNEL();
        TOKEN = CONTROLLER.TOKEN();
        ASSET = asset;
        ADMIN = admin;
        PRESALE_SIZE = presaleSize;
        START_PRICE = startPrice;
        VIRTUAL_TOKEN_RESERVE = virtualTokenReserve;
        DURATION = duration;
        MIN_BID = minBid;

        // The decay/duration clock is started by {open}, not at construction, so that latency between
        // deploying, seeding backing, and going live does not silently consume the premium or the sale
        // window. startTime == 0 is the "not yet opened" sentinel.
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

    /// @notice Start the presale: anchors the decay/duration clock to now and locks in that the configured
    ///         opening price is meaningful against the live floor.
    /// @dev    One-time, admin-only. Reverts `AlreadyOpen` if called twice. Reads `minimumPrice()`, which
    ///         itself reverts unless backing is seeded against exactly the configured `ASSET`, so calling
    ///         this proves the presale is fully provisioned. Requires `START_PRICE > minimumPrice()` (the
    ///         fee-grossed floor) so the Dutch-auction premium is actually live at open rather than silently
    ///         clamped to the floor. Deploy, seed backing, set fees, then `open()` immediately before going
    ///         live — the sale window and premium both run from this call, not from deployment.
    function open() external onlyAdmin {
        if (startTime != 0) revert PresaleAuction__AlreadyOpen();

        uint256 floor = minimumPrice();
        if (START_PRICE <= floor) revert PresaleAuction__StartPriceBelowFloor();

        startTime = block.timestamp;
        lastPriceUpdate = block.timestamp;

        emit PresaleAuction__Open(block.timestamp, START_PRICE, floor);
    }

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

    /// @notice The fee-grossed backing-per-token floor the presale prices against.
    /// @dev    The presale is intentionally single-asset: it requires exactly one registered backing asset,
    ///         equal to {ASSET}. Registering a second backing asset (via `Gateway.addAsset`) while the presale
    ///         is live makes `backings.length != 1`, so this and every `price`/`quote`/`buy` call will revert
    ///         `PresaleAuction__UnsupportedBackingAsset` — i.e. it bricks the presale. This is accepted
    ///         behavior; do not add a second backing asset until the presale has concluded.
    function minimumPrice() public view returns (uint256) {
        IController.Backing[] memory backings = backingPerToken(KERNEL, TOKEN);
        if (backings.length != 1 || backings[0].asset != ASSET) {
            revert PresaleAuction__UnsupportedBackingAsset();
        }
        if (backings[0].backingPerToken == 0) revert PresaleAuction__UnseededAsset();

        // backingPerToken floors `totalBacking * WAD / supply`, but the core's backing invariant requires the
        // post-mint backing to cover a CEIL-preserved ratio (Dispatch._validateBacking). Add a 1-wei cushion so
        // the grossed floor targets at least ceil(totalBacking * WAD / supply); this prevents a zero/low-premium
        // quote from producing a payment that the settlement would reject on rounding. Cost is a sub-wei-per-token
        // overcharge that only ever favors backing.
        return _grossUpForFees(backings[0].backingPerToken + 1);
    }

    /*----------  INTERNAL FUNCTIONS  -----------------------------------*/

    function _buy(uint256 amount, uint256 maxPayment, uint256 deadline)
        internal
        returns (IController.Receipt[] memory costs)
    {
        if (block.timestamp > deadline) revert PresaleAuction__DeadlinePassed();
        if (startTime == 0) revert PresaleAuction__NotOpen();
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

        minterModule.mint(msg.sender, amount, costs);

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
