///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ReentrancyGuard} from "openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {MINTR} from "../modules/MINTR/MINTR.v1.sol";
import {BRNER} from "../modules/DFLT/BRNER.sol";
import {IBurner} from "../interfaces/IBurner.sol";
import {backingPerToken, assets} from "../Utils.sol";
import {Keycode, Permissions, toKeycode} from "enten-v1/Utils.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IKernel} from "enten-v1/interfaces/IKernel.sol";
import {IToken} from "enten-v1/interfaces/IToken.sol";
import {Policy} from "enten-v1/Policy.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";
import {wadExp} from "solmate/src/utils/SignedWadMath.sol";

/**
 * @title  VirtualReservePool
 * @author 0xChihiro
 * @notice A buy-only, multi-asset virtual-reserve AMM that mints new tokens against per-asset
 *         constant-product (`x * y = k`) premium curves, identical in price-impact to Uniswap V2 pools,
 *         each layered on top of its asset's live backing-per-token floor.
 *
 *         For every registered backing asset the price is:
 *
 *             price_i = backingFloor_i + premium_i
 *
 *         - `backingFloor_i` is the fee-grossed backing-per-token of asset `i`, read live from the core. It
 *           is the floor that asset's curve can never trade below, and it rises as buys add backing. It is
 *           also the asymptote the spot price decays toward.
 *         - `premium_i` rides that asset's own virtual constant-product curve. Steepness is *knowable up
 *           front* per asset, set entirely by its {Reserve.virtualTokenReserve} (`x`) relative to trade
 *           size: small reserve = steep, large = shallow.
 *
 *         WHY PAY-IN-ALL. The core's backing invariant (`Dispatch._validateBacking`) requires that after any
 *         mint, the backing-per-token of *every* registered asset is preserved — each must scale up with the
 *         supply increase. A buy therefore cannot settle in a single asset; it must bring proportional
 *         backing for all of them, exactly like {Auction}. So one buy mints `amount` tokens and the buyer
 *         pays across every registered asset, each priced on its own curve. Separate one-asset-at-a-time
 *         pools are impossible here: they would tank the untouched assets' backing and revert.
 *
 *         DECAY. The premium of each asset decays on a single, shared exponential half-life ({HALF_LIFE}):
 *         premium(t) = anchor * 2^(-elapsed / HALF_LIFE), clamped to a floor-relative minimum
 *         ({MIN_PREMIUM_BPS}) so it never collapses to zero. With no trading the spot prices drift smoothly
 *         down toward `floor + floor * MIN_PREMIUM_BPS / BPS` — a thin resting premium that keeps each curve
 *         live, so a later buy always has price impact to ratchet rather than getting stuck at the bare floor
 *         (where the multiplicative curve could never revive). Because every buy stamps every asset at the
 *         same timestamp, the decay anchor is effectively shared; it is nonetheless tracked per asset so that
 *         an asset registered after launch decays from its own configuration point rather than inheriting a
 *         stale anchor.
 *
 *         FEES. Minting routes through MINTR -> controller `Payment` settlement, which applies the protocol's
 *         configured fee waterfall (protocol fee -> team -> treasury -> backing residual). Destinations are
 *         protocol-chosen and read live from the kernel; this contract only grosses the *floor* leg up
 *         through that waterfall so the backing invariant holds. The premium leg is surplus over the required
 *         backing floor and is routed through the normal payment fee waterfall.
 *
 * @dev    Every registered backing asset MUST have a configured reserve ({setReserve}) before it can be
 *         bought against; a buy reverts if any registered asset is unconfigured or unseeded. Adding a
 *         backing asset via the Gateway without configuring it here therefore pauses buys until the admin
 *         configures it — an accepted, fail-safe behavior.
 *
 *         SELL/REDEEM. Holders can {sell} (redeem) tokens back to the protocol for their pure backing value
 *         via the BRNER module: tokens are burned and the caller receives `amount * backingPerToken` of
 *         every backing asset, with NO premium and NO fee. This is the redemption floor — always strictly
 *         below the pool's buy price (which is grossed-up floor + premium), so there is no buy/sell loop to
 *         arbitrage. Redemption is independent of {open} and of reserve configuration.
 *
 *         CONTINUOUS ISSUANCE. The virtual reserve is a curve-depth parameter, not a lifetime max issuance
 *         cap. Buys advance each asset through a bounded curve segment; once consumption reaches
 *         {RESET_THRESHOLD_BPS}, that asset's curve position automatically resets to {RESET_TARGET_BPS}
 *         consumed while preserving the post-buy premium anchor. This avoids living in the near-exhausted
 *         vertical tail while still charging the triggering buy on the pre-reset curve. Redemptions do not
 *         rewind curve position.
 *
 *         ACCESS CONTROL. Uses OpenZeppelin {AccessControl}. `RESERVE_ROLE` may {setReserve} and
 *         {deepenReserve}; `OPENER_ROLE` may {open}. Both, plus `DEFAULT_ADMIN_ROLE`, are granted to
 *         `initialAdmin` at deploy; the default admin can re-delegate or revoke them. Trading ({buy}/{sell})
 *         and all views are permissionless.
 */
contract VirtualReservePool is ReentrancyGuard, AccessControl, Policy {
    /*----------  TYPES  ------------------------------------------------*/

    /// @notice Per-asset virtual reserve and live premium-curve state.
    struct Reserve {
        // --- admin configuration ---
        uint256 virtualTokenReserve; // token-side depth `x`: sets this asset's curve steepness
        uint256 startPremium; // opening premium per token (asset wei, WAD-scaled) over the floor
        // --- live curve state ---
        uint256 currentPremium; // premium per token anchored as of `lastUpdate`, pre-decay
        uint256 lastUpdate; // timestamp the premium was last anchored (open, buy, or live config)
        uint256 mintedAtConfig; // {totalMinted} when this asset was configured, so its curve starts fresh
        bool premiumInitialized; // once true, `currentPremium` is the anchor; before, `startPremium` is
        bool configured; // admin has set this asset's reserve
    }

    /*----------  CONSTANTS  --------------------------------------------*/

    Keycode internal constant VRAMM_KEYCODE = Keycode.wrap("VRAMM");
    Keycode internal constant MINTR_KEYCODE = Keycode.wrap("MINTR");
    Keycode internal constant BRNER_KEYCODE = Keycode.wrap("BRNER");

    /// @notice Role permitted to configure per-asset reserves via {setReserve}.
    bytes32 public constant RESERVE_ROLE = keccak256("RESERVE_ROLE");
    /// @notice Role permitted to {open} the pool (start the decay clock and go live).
    bytes32 public constant OPENER_ROLE = keccak256("OPENER_ROLE");

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    /// @notice ln(2) scaled to WAD; converts a half-life into the exp() decay rate.
    int256 internal constant LN2_WAD = 693147180559945309;

    uint256 public constant MIN_HALF_LIFE = 1 hours;
    uint256 public constant MAX_HALF_LIFE = 3650 days;

    /*----------  IMMUTABLES  -------------------------------------------*/

    IKernel public immutable KERNEL;
    IToken public immutable TOKEN;

    /// @notice Single, shared exponential decay half-life for every asset's premium, in seconds. One knob
    ///         set once at deploy — there is no reason for assets to differ here, and every buy advances
    ///         them all on the same clock.
    uint256 public immutable HALF_LIFE;

    /// @notice Consumption percentage that triggers an automatic curve-position reset after a buy.
    uint256 public immutable RESET_THRESHOLD_BPS;
    /// @notice Consumption percentage the curve resets to once the threshold is reached.
    uint256 public immutable RESET_TARGET_BPS;

    /// @notice Floor-relative minimum premium, in bps of the live backing floor. The decayed premium is
    ///         clamped up to `floor * MIN_PREMIUM_BPS / BPS`, so it never decays into the absorbing zero
    ///         state: the curve always keeps a live quote-side base for buys to ratchet from, and the pool's
    ///         resting price settles at `floor + floor * MIN_PREMIUM_BPS / BPS` instead of the bare floor.
    uint256 public immutable MIN_PREMIUM_BPS;

    /*----------  STATE  ------------------------------------------------*/

    MINTR public minterModule;
    BRNER public burnerModule;

    /// @notice Cumulative tokens minted by this pool. Each asset's live token reserve is
    ///         `virtualTokenReserve - (totalMinted - mintedAtConfig)`.
    uint256 public totalMinted;
    /// @notice 0 until {open}; doubles as the "not yet opened" sentinel.
    uint256 public startTime;

    /// @notice Per-asset virtual reserve + curve state, keyed by backing asset address.
    mapping(address => Reserve) public reserves;

    /*----------  ERRORS  -----------------------------------------------*/

    error VirtualReservePool__InvalidConfig();
    error VirtualReservePool__AlreadyOpen();
    error VirtualReservePool__NotOpen();
    error VirtualReservePool__AlreadyConfigured();
    error VirtualReservePool__ReserveNotDeepened();
    error VirtualReservePool__NotConfigured(address asset);
    error VirtualReservePool__DeadlinePassed();
    error VirtualReservePool__InvalidMintAmount();
    error VirtualReservePool__InvalidRedeemAmount();
    error VirtualReservePool__ReserveExhausted(address asset);
    error VirtualReservePool__EmptyAssets();
    error VirtualReservePool__MaxPaymentsLengthMismatch();
    error VirtualReservePool__MaxPaymentAssetMismatch();
    error VirtualReservePool__MaxPayment(address asset);
    error VirtualReservePool__MinProceedsLengthMismatch();
    error VirtualReservePool__MinProceedsAssetMismatch();
    error VirtualReservePool__MinProceeds(address asset);
    error VirtualReservePool__UnsupportedBackingAsset();
    error VirtualReservePool__UnseededAsset(address asset);
    error VirtualReservePool__InvalidFeeConfiguration();

    /*----------  EVENTS  -----------------------------------------------*/

    event VirtualReservePool__ReserveSet(
        address indexed asset, uint256 virtualTokenReserve, uint256 startPremium, uint256 mintedAtConfig
    );
    event VirtualReservePool__ReserveDeepened(
        address indexed asset, uint256 oldVirtualTokenReserve, uint256 newVirtualTokenReserve, uint256 anchoredPremium
    );
    event VirtualReservePool__ReserveReset(
        address indexed asset, uint256 consumedBeforeReset, uint256 consumedAfterReset, uint256 totalMinted
    );
    event VirtualReservePool__Open(uint256 startTime);
    event VirtualReservePool__Buy(
        address indexed buyer, uint256 amountMinted, IController.Receipt[] payments, uint256 totalMinted
    );
    event VirtualReservePool__Sell(address indexed seller, uint256 amountRedeemed, IController.Receipt[] proceeds);

    /*----------  CONSTRUCTOR  ------------------------------------------*/

    /**
     * @param controller   The Enten controller this policy installs against.
     * @param initialAdmin Address granted DEFAULT_ADMIN_ROLE, RESERVE_ROLE, and OPENER_ROLE at deploy.
     * @param halfLife          Shared premium decay half-life in seconds (applies to every asset).
     * @param resetThresholdBps Curve-consumption threshold that triggers a post-buy reset.
     * @param resetTargetBps    Curve-consumption percentage reset to after threshold is reached.
     * @param minPremiumBps     Floor-relative minimum premium in bps; the premium never decays below this.
     */
    constructor(
        address controller,
        address initialAdmin,
        uint256 halfLife,
        uint256 resetThresholdBps,
        uint256 resetTargetBps,
        uint256 minPremiumBps
    ) Policy(controller) {
        if (
            initialAdmin == address(0) || halfLife < MIN_HALF_LIFE || halfLife > MAX_HALF_LIFE || resetThresholdBps == 0
                || resetThresholdBps >= BPS || resetTargetBps >= resetThresholdBps || minPremiumBps == 0
                || minPremiumBps >= BPS
        ) {
            revert VirtualReservePool__InvalidConfig();
        }

        KERNEL = CONTROLLER.KERNEL();
        TOKEN = CONTROLLER.TOKEN();
        HALF_LIFE = halfLife;
        RESET_THRESHOLD_BPS = resetThresholdBps;
        RESET_TARGET_BPS = resetTargetBps;
        MIN_PREMIUM_BPS = minPremiumBps;

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(RESERVE_ROLE, initialAdmin);
        _grantRole(OPENER_ROLE, initialAdmin);

        // Reserves are configured per asset via {setReserve}; the decay clock is anchored by {open}, not
        // construction, so latency between deploy, seeding, and going live does not bleed the premium.
    }

    function KEYCODE() public pure override returns (Keycode) {
        return VRAMM_KEYCODE;
    }

    function configureDependencies() external override onlyController returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](2);
        dependencies[0] = MINTR_KEYCODE;
        dependencies[1] = BRNER_KEYCODE;

        minterModule = MINTR(getModuleAddress(dependencies[0]));
        burnerModule = BRNER(getModuleAddress(dependencies[1]));
    }

    function requestPermissions() external pure override returns (Permissions[] memory permissions) {
        permissions = new Permissions[](2);
        permissions[0] = Permissions({keycode: MINTR_KEYCODE, funcSelector: MINTR.mint.selector});
        permissions[1] = Permissions({keycode: BRNER_KEYCODE, funcSelector: BRNER.executeDeflationaryAction.selector});
    }

    /*----------  ADMIN FUNCTIONS  --------------------------------------*/

    /// @notice Configure the virtual reserve for one backing asset. One-time per asset.
    /// @param  asset                The registered backing asset to configure.
    /// @param  virtualTokenReserve  Token-side depth `x`: sets this asset's curve steepness.
    /// @param  startPremium         Opening premium per token (asset wei, WAD-scaled) over the floor.
    /// @dev    The asset must already be registered as backing in the kernel. Configuring before {open}
    ///         leaves the decay clock unstarted (open anchors it); configuring after {open} anchors the
    ///         clock to now so a late-added asset decays from its own start, not a stale timestamp. The
    ///         curve starts fresh from the current {totalMinted}, so prior mints do not pre-drain it. If the
    ///         asset's backing is already seeded, `startPremium` must clear the floor-relative minimum clamp
    ///         ({MIN_PREMIUM_BPS}); otherwise the clamp would silently open the asset above the configured
    ///         premium. The check is a no-op while backing is unseeded (the floor is unknown then).
    function setReserve(address asset, uint256 virtualTokenReserve, uint256 startPremium)
        external
        onlyRole(RESERVE_ROLE)
    {
        if (asset == address(0) || virtualTokenReserve == 0 || startPremium == 0) {
            revert VirtualReservePool__InvalidConfig();
        }
        if (!_isRegistered(asset)) revert VirtualReservePool__UnsupportedBackingAsset();

        Reserve storage r = reserves[asset];
        if (r.configured) revert VirtualReservePool__AlreadyConfigured();

        // Reject an opening premium the min clamp would override, but only once a floor exists to compare to.
        uint256 bpt = _backingPerTokenOf(asset);
        if (bpt != 0 && startPremium < Math.mulDiv(_grossUpForFees(bpt + 1), MIN_PREMIUM_BPS, BPS)) {
            revert VirtualReservePool__InvalidConfig();
        }

        r.virtualTokenReserve = virtualTokenReserve;
        r.startPremium = startPremium;
        r.mintedAtConfig = totalMinted;
        r.configured = true;
        // If the pool is already live, start this asset's decay clock now. Otherwise {open} will anchor it.
        if (startTime != 0) r.lastUpdate = block.timestamp;

        emit VirtualReservePool__ReserveSet(asset, virtualTokenReserve, startPremium, totalMinted);
    }

    /// @notice Increase an existing asset's virtual token reserve, flattening future price impact.
    /// @param  asset                   Registered backing asset whose curve should be deepened.
    /// @param  newVirtualTokenReserve  New token-side depth. Must be strictly greater than the current depth.
    /// @dev    This can only add virtual liquidity, never remove it. The current decayed premium is
    ///         checkpointed before the depth changes, so the spot premium is continuous at the update moment
    ///         while subsequent buys see deeper/liquid price impact.
    function deepenReserve(address asset, uint256 newVirtualTokenReserve) external onlyRole(RESERVE_ROLE) {
        if (asset == address(0) || newVirtualTokenReserve == 0) revert VirtualReservePool__InvalidConfig();
        if (!_isRegistered(asset)) revert VirtualReservePool__UnsupportedBackingAsset();

        Reserve storage r = reserves[asset];
        if (!r.configured) revert VirtualReservePool__NotConfigured(asset);

        uint256 oldVirtualTokenReserve = r.virtualTokenReserve;
        if (newVirtualTokenReserve <= oldVirtualTokenReserve) revert VirtualReservePool__ReserveNotDeepened();

        uint256 anchoredPremium = _decayedPremium(r);
        r.currentPremium = anchoredPremium;
        r.premiumInitialized = true;
        if (startTime != 0) r.lastUpdate = block.timestamp;
        r.virtualTokenReserve = newVirtualTokenReserve;

        emit VirtualReservePool__ReserveDeepened(asset, oldVirtualTokenReserve, newVirtualTokenReserve, anchoredPremium);
    }

    /// @notice Anchor the decay clock to now and go live. One-time, admin-only.
    /// @dev    Requires at least one registered backing asset and that *every* registered asset already has
    ///         a configured reserve, so a successful call proves the pool is fully provisioned across all
    ///         assets. Each configured asset's decay clock is anchored to this timestamp.
    function open() external onlyRole(OPENER_ROLE) {
        if (startTime != 0) revert VirtualReservePool__AlreadyOpen();

        address[] memory assetList = assets(KERNEL);
        if (assetList.length == 0) revert VirtualReservePool__EmptyAssets();

        startTime = block.timestamp;
        for (uint256 i = 0; i < assetList.length;) {
            Reserve storage r = reserves[assetList[i]];
            if (!r.configured) revert VirtualReservePool__NotConfigured(assetList[i]);
            r.lastUpdate = block.timestamp;
            unchecked {
                ++i;
            }
        }

        emit VirtualReservePool__Open(block.timestamp);
    }

    /*----------  EXTERNAL FUNCTIONS  -----------------------------------*/

    /// @notice Buy `amount` tokens, paying across every registered backing asset on its own curve.
    /// @param  amount       Tokens to mint.
    /// @param  maxPayments  Per-asset payment ceilings, ordered to match the kernel's registered-asset list
    ///                      (the same order {quote} and {getPrices} return).
    /// @param  deadline     Latest timestamp this buy may execute.
    function buy(uint256 amount, IController.Receipt[] calldata maxPayments, uint256 deadline)
        external
        nonReentrant
        returns (IController.Receipt[] memory payments)
    {
        if (block.timestamp > deadline) revert VirtualReservePool__DeadlinePassed();
        if (startTime == 0) revert VirtualReservePool__NotOpen();
        if (amount == 0) revert VirtualReservePool__InvalidMintAmount();

        IController.Backing[] memory backings = backingPerToken(KERNEL, TOKEN);
        if (backings.length == 0) revert VirtualReservePool__EmptyAssets();
        if (maxPayments.length != backings.length) revert VirtualReservePool__MaxPaymentsLengthMismatch();

        payments = new IController.Receipt[](backings.length);
        uint256[] memory nextPremiums = new uint256[](backings.length);

        for (uint256 i = 0; i < backings.length;) {
            address asset = backings[i].asset;
            if (maxPayments[i].asset != asset) revert VirtualReservePool__MaxPaymentAssetMismatch();
            if (backings[i].backingPerToken == 0) revert VirtualReservePool__UnseededAsset(asset);

            Reserve storage r = reserves[asset];
            if (!r.configured) revert VirtualReservePool__NotConfigured(asset);

            (uint256 paymentAmount, uint256 nextPremium) = _quoteAsset(r, asset, amount, backings[i].backingPerToken);
            if (paymentAmount > maxPayments[i].amount) revert VirtualReservePool__MaxPayment(asset);

            payments[i] = IController.Receipt({asset: asset, amount: paymentAmount});
            nextPremiums[i] = nextPremium;
            unchecked {
                ++i;
            }
        }

        // Effects before the mint interaction. Advance every asset's curve: the shared token side drains by
        // `amount`, and each premium ratchets to its post-trade value, all stamped at this timestamp.
        totalMinted += amount;
        for (uint256 i = 0; i < backings.length;) {
            Reserve storage r = reserves[backings[i].asset];
            r.currentPremium = nextPremiums[i];
            r.lastUpdate = block.timestamp;
            r.premiumInitialized = true;
            _maybeResetReserve(backings[i].asset, r);
            unchecked {
                ++i;
            }
        }

        minterModule.mint(msg.sender, amount, payments);

        emit VirtualReservePool__Buy(msg.sender, amount, payments, totalMinted);
    }

    /// @notice Sell (redeem) `amount` tokens back to the protocol for their pure backing value.
    /// @param  amount       Tokens to burn.
    /// @param  minProceeds  Per-asset minimum acceptable proceeds, ordered to match the kernel's
    ///                      registered-asset list (the order {redemptionValue} returns). Slippage guard.
    /// @param  deadline     Latest timestamp this sell may execute.
    /// @return proceeds     Per-asset backing returned to the caller (kernel order).
    /// @dev    Routes through the BRNER module, which burns the caller's tokens and returns
    ///         `amount * backingPerToken / WAD` of every backing asset — NO premium, NO fee. This is the
    ///         redemption floor and is always below the pool's buy price, so it cannot be round-tripped for
    ///         profit. Independent of {open} and reserve configuration: a holder can always redeem. The
    ///         BRNER module enforces its own guards (effective supply non-zero, not redeeming the entire
    ///         supply, sufficient redeemable backing); those revert atomically here.
    function sell(uint256 amount, IController.Receipt[] calldata minProceeds, uint256 deadline)
        external
        nonReentrant
        returns (IController.Receipt[] memory proceeds)
    {
        if (block.timestamp > deadline) revert VirtualReservePool__DeadlinePassed();
        if (amount == 0) revert VirtualReservePool__InvalidRedeemAmount();

        proceeds = redemptionValue(amount);
        if (minProceeds.length != proceeds.length) revert VirtualReservePool__MinProceedsLengthMismatch();

        for (uint256 i = 0; i < proceeds.length;) {
            if (minProceeds[i].asset != proceeds[i].asset) revert VirtualReservePool__MinProceedsAssetMismatch();
            if (proceeds[i].amount < minProceeds[i].amount) revert VirtualReservePool__MinProceeds(proceeds[i].asset);
            unchecked {
                ++i;
            }
        }

        burnerModule.executeDeflationaryAction(IBurner.Action.Redeem, msg.sender, amount);

        emit VirtualReservePool__Sell(msg.sender, amount, proceeds);
    }

    /*----------  VIEW FUNCTIONS  ---------------------------------------*/

    /// @notice The pure backing value returned for redeeming `amount` tokens: `amount * backingPerToken` of
    ///         every registered asset, with no premium or fee. Mirrors the BRNER module's receipt math
    ///         (floored), so it matches the proceeds {sell} will deliver. Reverts on unseeded/empty assets.
    function redemptionValue(uint256 amount) public view returns (IController.Receipt[] memory proceeds) {
        IController.Backing[] memory backings = backingPerToken(KERNEL, TOKEN);
        if (backings.length == 0) revert VirtualReservePool__EmptyAssets();

        proceeds = new IController.Receipt[](backings.length);
        for (uint256 i = 0; i < backings.length;) {
            uint256 assetAmount = Math.mulDiv(amount, backings[i].backingPerToken, WAD);
            proceeds[i] = IController.Receipt({asset: backings[i].asset, amount: assetAmount});
            unchecked {
                ++i;
            }
        }
    }

    /// @notice The registered backing assets, in the canonical kernel order used by {buy}/{quote}.
    function registeredAssets() external view returns (address[] memory) {
        return assets(KERNEL);
    }

    /// @notice Live virtual token reserve (`x`) remaining for one asset's curve.
    function reserveOf(address asset) public view returns (uint256) {
        Reserve storage r = reserves[asset];
        if (!r.configured) revert VirtualReservePool__NotConfigured(asset);
        return r.virtualTokenReserve - (totalMinted - r.mintedAtConfig);
    }

    /// @notice Current spot price per token for one asset: backing floor plus its decayed premium.
    function price(address asset) public view returns (uint256) {
        uint256 floor = minimumPrice(asset);
        return floor + _premium(reserves[asset], floor);
    }

    /// @notice Spot price per token for every registered asset, as Backing entries (kernel order).
    function getPrices() public view returns (IController.Backing[] memory prices) {
        prices = backingPerToken(KERNEL, TOKEN);
        for (uint256 i = 0; i < prices.length;) {
            address asset = prices[i].asset;
            if (prices[i].backingPerToken == 0) revert VirtualReservePool__UnseededAsset(asset);
            uint256 floor = _grossUpForFees(prices[i].backingPerToken + 1);
            prices[i].backingPerToken = floor + _premium(reserves[asset], floor);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Quote a buy of `amount` tokens across all registered assets.
     * @return payments     Per-asset total owed (grossed floor leg + constant-product premium leg), kernel order.
     * @return spotPrices   Per-asset pre-trade spot price per token (floor + decayed premium).
     * @return nextPremiums Per-asset premium per token after the trade (the new `currentPremium`).
     */
    function quote(uint256 amount)
        public
        view
        returns (IController.Receipt[] memory payments, uint256[] memory spotPrices, uint256[] memory nextPremiums)
    {
        if (amount == 0) {
            revert VirtualReservePool__InvalidMintAmount();
        }

        IController.Backing[] memory backings = backingPerToken(KERNEL, TOKEN);
        if (backings.length == 0) revert VirtualReservePool__EmptyAssets();

        payments = new IController.Receipt[](backings.length);
        spotPrices = new uint256[](backings.length);
        nextPremiums = new uint256[](backings.length);

        for (uint256 i = 0; i < backings.length;) {
            address asset = backings[i].asset;
            if (backings[i].backingPerToken == 0) revert VirtualReservePool__UnseededAsset(asset);

            Reserve storage r = reserves[asset];
            if (!r.configured) revert VirtualReservePool__NotConfigured(asset);

            (uint256 paymentAmount, uint256 nextPremium) = _quoteAsset(r, asset, amount, backings[i].backingPerToken);
            uint256 floor = _grossUpForFees(backings[i].backingPerToken + 1);
            payments[i] = IController.Receipt({asset: asset, amount: paymentAmount});
            spotPrices[i] = floor + _premium(r, floor);
            nextPremiums[i] = nextPremium;
            unchecked {
                ++i;
            }
        }
    }

    /// @notice The fee-grossed backing-per-token floor for one asset.
    function minimumPrice(address asset) public view returns (uint256) {
        IController.Backing[] memory backings = backingPerToken(KERNEL, TOKEN);
        for (uint256 i = 0; i < backings.length;) {
            if (backings[i].asset == asset) {
                if (backings[i].backingPerToken == 0) revert VirtualReservePool__UnseededAsset(asset);
                // +1 wei cushion so the grossed floor targets at least ceil(totalBacking * WAD / supply),
                // matching the CEIL-preserving post-mint check in Dispatch._validateBacking.
                return _grossUpForFees(backings[i].backingPerToken + 1);
            }
            unchecked {
                ++i;
            }
        }
        revert VirtualReservePool__UnsupportedBackingAsset();
    }

    /*----------  INTERNAL FUNCTIONS  -----------------------------------*/

    /// @notice Quote one asset's leg of a buy: grossed floor charge plus constant-product premium fill.
    function _quoteAsset(Reserve storage r, address asset, uint256 amount, uint256 backingPerTokenAmount)
        internal
        view
        returns (uint256 paymentAmount, uint256 nextPremium)
    {
        // x = this asset's live virtual token reserve. Leave a non-zero remainder so the curve never divides
        // by zero and spot stays finite — the last token of the reserve is unmintable by design.
        uint256 tokenReserve = r.virtualTokenReserve - (totalMinted - r.mintedAtConfig);
        if (amount >= tokenReserve) revert VirtualReservePool__ReserveExhausted(asset);

        uint256 floor = _grossUpForFees(backingPerTokenAmount + 1);
        uint256 premium = _premium(r, floor);

        // Premium leg: V2 constant product. Reconstruct quote reserve y = premium * x, then the fill for
        // taking `amount` tokens out is dy = y * amount / (x - amount), rounded up.
        uint256 premiumPayment;
        if (premium != 0) {
            uint256 nextTokenReserve = tokenReserve - amount;
            uint256 quoteReserve = Math.mulDiv(premium, tokenReserve, WAD, Math.Rounding.Ceil);
            premiumPayment = Math.mulDiv(quoteReserve, amount, nextTokenReserve, Math.Rounding.Ceil);
            nextPremium = Math.mulDiv(quoteReserve + premiumPayment, WAD, nextTokenReserve, Math.Rounding.Ceil);
        }

        // Floor leg: charge grossed backing-per-token for every minted token. Only this leg defends the
        // backing invariant; the premium is surplus routed through the protocol's normal fee waterfall.
        paymentAmount = Math.mulDiv(amount, floor, WAD, Math.Rounding.Ceil) + premiumPayment;
    }

    /// @notice Recycle an asset's curve position to the target segment once post-buy consumption reaches
    ///         the configured threshold. Only buys call this; redemptions intentionally do not rewind it.
    function _maybeResetReserve(address asset, Reserve storage r) internal {
        uint256 consumed = totalMinted - r.mintedAtConfig;
        uint256 thresholdConsumed = Math.mulDiv(r.virtualTokenReserve, RESET_THRESHOLD_BPS, BPS);
        if (consumed < thresholdConsumed) return;

        uint256 targetConsumed = Math.mulDiv(r.virtualTokenReserve, RESET_TARGET_BPS, BPS);
        r.mintedAtConfig = totalMinted - targetConsumed;

        emit VirtualReservePool__ReserveReset(asset, consumed, targetConsumed, totalMinted);
    }

    /// @notice One asset's effective premium for pricing: the decayed anchor clamped up to the floor-relative
    ///         minimum (`floor * MIN_PREMIUM_BPS / BPS`) so it can never collapse into the absorbing zero
    ///         state. Returns 0 for an unconfigured asset, which carries no premium and no clamp.
    /// @dev    The clamp lives here (the read path), not in the stored anchor: buys, {price}, {getPrices} and
    ///         {quote} all price through this, so even a fully-decayed anchor still yields a live premium for
    ///         the next buy to ratchet from. {deepenReserve} checkpoints the raw decayed anchor directly;
    ///         spot continuity holds because every read re-applies this clamp.
    function _premium(Reserve storage r, uint256 floor) internal view returns (uint256) {
        if (!r.configured) return 0;
        uint256 decayed = _decayedPremium(r);
        uint256 minPremium = Math.mulDiv(floor, MIN_PREMIUM_BPS, BPS);
        return decayed < minPremium ? minPremium : decayed;
    }

    /// @notice One asset's RAW premium anchor decayed forward to now on the shared exponential half-life,
    ///         before the floor-relative minimum clamp. Callers price through {_premium}, never this directly
    ///         (except {deepenReserve}'s checkpoint), so the saturation-to-zero below is recovered by the clamp.
    /// @dev    premium(t) = anchor * 2^(-elapsed / HALF_LIFE) = anchor * exp(-ln2 * elapsed / HALF_LIFE).
    ///         For large `elapsed`, wadExp saturates to 0; {_premium} then lifts the result to the minimum.
    function _decayedPremium(Reserve storage r) internal view returns (uint256) {
        uint256 anchor = r.premiumInitialized ? r.currentPremium : r.startPremium;
        if (anchor == 0) return 0;

        uint256 last = r.lastUpdate;
        // last == 0 means configured before {open}: the clock has not started, so no decay yet.
        if (last == 0) return anchor;

        uint256 elapsed = block.timestamp - last;
        if (elapsed == 0) return anchor;

        // LN2_WAD is a fixed positive constant (~0.69e18); the product cannot approach int256 max for any
        // realistic elapsed/HALF_LIFE.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 exponent = -int256(Math.mulDiv(uint256(LN2_WAD), elapsed, HALF_LIFE));
        int256 factor = wadExp(exponent); // bounded to [0, 1e18] for exponent <= 0
        if (factor <= 0) return 0;

        // factor is non-negative (checked) and <= 1e18, so the uint256 cast is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        return Math.mulDiv(anchor, uint256(factor), WAD);
    }

    /// @notice Gross a target backing-per-token up through the protocol's live fee waterfall so that, after
    ///         the protocol fee and the team/treasury skims, the residual that actually lands as backing
    ///         still meets the target. Mirrors {PresaleAuction}/{Auction}; fee destinations are
    ///         protocol-chosen and read live from the kernel, so this adapts to any configured split.
    function _grossUpForFees(uint256 targetBackingPerToken) internal view returns (uint256) {
        uint256 bps = CONTROLLER.BPS();
        uint256 protocolFeeBps = CONTROLLER.AUCTION_FEE_BPS();
        uint256 teamBps = uint256(KERNEL.viewData(Slots.TEAM_PERCENTAGE_SLOT));
        uint256 treasuryBps = uint256(KERNEL.viewData(Slots.TREASURY_PERCENTAGE_SLOT));
        if (bps == 0 || protocolFeeBps >= bps || teamBps >= bps || treasuryBps >= bps || teamBps + treasuryBps >= bps) {
            revert VirtualReservePool__InvalidFeeConfiguration();
        }

        uint256 backingBps = bps - teamBps - treasuryBps;
        uint256 postProtocolBps = bps - protocolFeeBps;
        uint256 requiredPostProtocol = Math.mulDiv(targetBackingPerToken, bps, backingBps, Math.Rounding.Ceil);
        return Math.mulDiv(requiredPostProtocol, bps, postProtocolBps, Math.Rounding.Ceil);
    }

    /// @notice This asset's live backing-per-token, or 0 if unseeded/unregistered. Non-reverting lookup for
    ///         paths that must tolerate an unseeded asset (e.g. pre-seed {setReserve} validation).
    function _backingPerTokenOf(address asset) internal view returns (uint256) {
        IController.Backing[] memory backings = backingPerToken(KERNEL, TOKEN);
        for (uint256 i = 0; i < backings.length;) {
            if (backings[i].asset == asset) return backings[i].backingPerToken;
            unchecked {
                ++i;
            }
        }
        return 0;
    }

    /// @notice True if `asset` is a registered backing asset in the kernel.
    function _isRegistered(address asset) internal view returns (bool) {
        address[] memory assetList = assets(KERNEL);
        for (uint256 i = 0; i < assetList.length;) {
            if (assetList[i] == asset) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }
}
