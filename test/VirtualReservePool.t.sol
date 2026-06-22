// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {VirtualReservePool} from "../src/policies/VirtualReservePool.sol";
import {Minter} from "../src/modules/MINTR/Minter.sol";
import {BurnerModule} from "../src/modules/DFLT/Burner.sol";
import {BRNER} from "../src/modules/DFLT/BRNER.sol";
import {IBurner} from "../src/interfaces/IBurner.sol";
import {Module} from "enten-v1/Module.sol";
import {Controller} from "enten-v1/Controller.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Token} from "enten-v1/Token.sol";
import {Vault} from "enten-v1/Vault.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IVault} from "enten-v1/interfaces/IVault.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Actions, Keycode, Permissions, toKeycode} from "enten-v1/Utils.sol";
import {IAccessControl} from "openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract VirtualReservePoolTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;
    uint256 internal constant BACKING_A = 1_000 ether; // bpt = 1.0
    uint256 internal constant BACKING_B = 2_000 ether; // bpt = 2.0
    uint256 internal constant HALF_LIFE = 10 hours;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant AUCTION_FEE_BPS = 250;
    uint256 internal constant RESET_THRESHOLD_BPS = 8_000;
    uint256 internal constant RESET_TARGET_BPS = 2_000;
    uint256 internal constant MIN_PREMIUM_BPS = 500; // resting premium floor: 5% of the backing floor

    // Asset A: shallow curve (large reserve). Asset B: steep curve (small reserve).
    uint256 internal constant RESERVE_A = 1_000 ether;
    uint256 internal constant RESERVE_B = 200 ether;
    uint256 internal constant START_PREMIUM_A = 0.5 ether;
    uint256 internal constant START_PREMIUM_B = 0.5 ether;

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    Token internal token;
    Minter internal minter;
    BurnerModule internal burner;
    VirtualReservePool internal pool;
    ERC20Mock internal assetA;
    ERC20Mock internal assetB;

    address internal admin = makeAddr("Admin");
    address internal holder = makeAddr("Holder");
    address internal buyer = makeAddr("Buyer");
    address internal seller = makeAddr("Seller");
    address internal protocolCollector = makeAddr("Protocol Collector");
    address internal stranger = makeAddr("Stranger");

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

    function setUp() public {
        vm.warp(1_000);

        uint256 nonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedToken = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedController = vm.computeCreateAddress(address(this), nonce + 3);

        kernel = new Kernel(predictedController, predictedVault);
        vault = new Vault(predictedController, predictedKernel);
        token = new Token("Enten", "ENTEN", predictedController, holder, INITIAL_SUPPLY, type(uint256).max);
        controller = new Controller(admin, protocolCollector, predictedKernel, predictedVault, predictedToken, 0);

        assetA = new ERC20Mock();
        assetB = new ERC20Mock();
        minter = new Minter(address(controller));
        burner = new BurnerModule(address(controller), address(kernel), address(assetA), 2);
        pool = new VirtualReservePool(address(controller), admin, HALF_LIFE, RESET_THRESHOLD_BPS, RESET_TARGET_BPS, MIN_PREMIUM_BPS);

        _setAssets(address(assetA), address(assetB));
        _seedBacking(assetA, BACKING_A);
        _seedBacking(assetB, BACKING_B);

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(minter));
        controller.executeAction(Actions.InstallModule, address(burner));
        controller.setMintPermission(Keycode.wrap("MINTR"), true);
        controller.executeAction(Actions.ActivatePolicy, address(pool));
        pool.setReserve(address(assetA), RESERVE_A, START_PREMIUM_A);
        pool.setReserve(address(assetB), RESERVE_B, START_PREMIUM_B);
        pool.open();
        vm.stopPrank();
    }

    /*----------  CONSTRUCTION & WIRING  --------------------------------*/

    function testConstructorStoresInitialState() public {
        VirtualReservePool fresh =
            new VirtualReservePool(address(controller), admin, HALF_LIFE, RESET_THRESHOLD_BPS, RESET_TARGET_BPS, MIN_PREMIUM_BPS);
        assertEq(address(fresh.KERNEL()), address(kernel));
        assertEq(address(fresh.TOKEN()), address(token));
        assertTrue(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(fresh.hasRole(fresh.RESERVE_ROLE(), admin));
        assertTrue(fresh.hasRole(fresh.OPENER_ROLE(), admin));
        assertEq(fresh.HALF_LIFE(), HALF_LIFE);
        assertEq(fresh.RESET_THRESHOLD_BPS(), RESET_THRESHOLD_BPS);
        assertEq(fresh.RESET_TARGET_BPS(), RESET_TARGET_BPS);
        assertEq(fresh.MIN_PREMIUM_BPS(), MIN_PREMIUM_BPS);
        assertEq(fresh.totalMinted(), 0);
        assertEq(fresh.startTime(), 0);
    }

    function testConstructorRejectsInvalidParameters() public {
        vm.expectRevert(VirtualReservePool.VirtualReservePool__InvalidConfig.selector);
        new VirtualReservePool(address(controller), address(0), HALF_LIFE, RESET_THRESHOLD_BPS, RESET_TARGET_BPS, MIN_PREMIUM_BPS);

        vm.expectRevert(VirtualReservePool.VirtualReservePool__InvalidConfig.selector);
        new VirtualReservePool(address(controller), admin, 1 hours - 1, RESET_THRESHOLD_BPS, RESET_TARGET_BPS, MIN_PREMIUM_BPS);

        vm.expectRevert(VirtualReservePool.VirtualReservePool__InvalidConfig.selector);
        new VirtualReservePool(address(controller), admin, 3650 days + 1, RESET_THRESHOLD_BPS, RESET_TARGET_BPS, MIN_PREMIUM_BPS);

        vm.expectRevert(VirtualReservePool.VirtualReservePool__InvalidConfig.selector);
        new VirtualReservePool(address(controller), admin, HALF_LIFE, BPS, RESET_TARGET_BPS, MIN_PREMIUM_BPS);

        vm.expectRevert(VirtualReservePool.VirtualReservePool__InvalidConfig.selector);
        new VirtualReservePool(address(controller), admin, HALF_LIFE, RESET_THRESHOLD_BPS, RESET_THRESHOLD_BPS, MIN_PREMIUM_BPS);

        vm.expectRevert(VirtualReservePool.VirtualReservePool__InvalidConfig.selector);
        new VirtualReservePool(address(controller), admin, HALF_LIFE, RESET_TARGET_BPS, RESET_THRESHOLD_BPS, MIN_PREMIUM_BPS);

        // minPremiumBps must be in (0, BPS).
        vm.expectRevert(VirtualReservePool.VirtualReservePool__InvalidConfig.selector);
        new VirtualReservePool(address(controller), admin, HALF_LIFE, RESET_THRESHOLD_BPS, RESET_TARGET_BPS, 0);

        vm.expectRevert(VirtualReservePool.VirtualReservePool__InvalidConfig.selector);
        new VirtualReservePool(address(controller), admin, HALF_LIFE, RESET_THRESHOLD_BPS, RESET_TARGET_BPS, BPS);
    }

    function testPolicyConfiguresMinterDependencyAndPermission() public view {
        assertEq(address(pool.minterModule()), address(minter));
        assertEq(address(pool.burnerModule()), address(burner));
        assertTrue(controller.isPolicyActive(address(pool)));
        assertEq(Keycode.unwrap(pool.KEYCODE()), Keycode.unwrap(toKeycode("VRAMM")));
        assertTrue(controller.modulePermissions(toKeycode("MINTR"), address(pool), Minter.mint.selector));
        assertTrue(
            controller.modulePermissions(toKeycode("BRNER"), address(pool), BRNER.executeDeflationaryAction.selector)
        );

        Permissions[] memory permissions = pool.requestPermissions();
        assertEq(permissions.length, 2);
        assertEq(Keycode.unwrap(permissions[0].keycode), Keycode.unwrap(toKeycode("MINTR")));
        assertEq(permissions[0].funcSelector, Minter.mint.selector);
        assertEq(Keycode.unwrap(permissions[1].keycode), Keycode.unwrap(toKeycode("BRNER")));
        assertEq(permissions[1].funcSelector, BRNER.executeDeflationaryAction.selector);
    }

    /*----------  setReserve  ------------------------------------------*/

    function testSetReserveStoresPerAssetConfig() public {
        (uint256 vtrA, uint256 spA,,, uint256 mintedAtA,, bool configuredA) = pool.reserves(address(assetA));
        assertEq(vtrA, RESERVE_A);
        assertEq(spA, START_PREMIUM_A);
        assertEq(mintedAtA, 0);
        assertTrue(configuredA);

        (uint256 vtrB,,,,,, bool configuredB) = pool.reserves(address(assetB));
        assertEq(vtrB, RESERVE_B);
        assertTrue(configuredB);

        assertEq(pool.reserveOf(address(assetA)), RESERVE_A);
        assertEq(pool.reserveOf(address(assetB)), RESERVE_B);
    }

    function testSetReserveRevertsForNonAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, pool.RESERVE_ROLE()
            )
        );
        vm.prank(stranger);
        pool.setReserve(address(assetA), RESERVE_A, START_PREMIUM_A);
    }

    function testSetReserveRevertsForUnregisteredAsset() public {
        ERC20Mock rogue = new ERC20Mock();
        vm.expectRevert(VirtualReservePool.VirtualReservePool__UnsupportedBackingAsset.selector);
        vm.prank(admin);
        pool.setReserve(address(rogue), RESERVE_A, START_PREMIUM_A);
    }

    function testSetReserveRevertsWhenAlreadyConfigured() public {
        vm.expectRevert(VirtualReservePool.VirtualReservePool__AlreadyConfigured.selector);
        vm.prank(admin);
        pool.setReserve(address(assetA), RESERVE_A, START_PREMIUM_A);
    }

    function testSetReserveRevertsForZeroParams() public {
        ERC20Mock assetC = new ERC20Mock();
        _setAssets3(address(assetA), address(assetB), address(assetC));

        vm.startPrank(admin);
        vm.expectRevert(VirtualReservePool.VirtualReservePool__InvalidConfig.selector);
        pool.setReserve(address(assetC), 0, START_PREMIUM_A);

        vm.expectRevert(VirtualReservePool.VirtualReservePool__InvalidConfig.selector);
        pool.setReserve(address(assetC), RESERVE_A, 0);
        vm.stopPrank();
    }

    function testSetReserveRejectsStartPremiumBelowMinClampWhenSeeded() public {
        VirtualReservePool fresh = new VirtualReservePool(
            address(controller), admin, HALF_LIFE, RESET_THRESHOLD_BPS, RESET_TARGET_BPS, MIN_PREMIUM_BPS
        );
        vm.startPrank(admin);
        controller.executeAction(Actions.ActivatePolicy, address(fresh));

        // assetA is already seeded, so the floor is known and the clamp guard is active.
        uint256 minPremiumA = fresh.minimumPrice(address(assetA)) * MIN_PREMIUM_BPS / BPS;

        // Just under the clamp: rejected, because the clamp would silently raise the opening premium.
        vm.expectRevert(VirtualReservePool.VirtualReservePool__InvalidConfig.selector);
        fresh.setReserve(address(assetA), RESERVE_A, minPremiumA - 1);

        // Exactly at the clamp: accepted.
        fresh.setReserve(address(assetA), RESERVE_A, minPremiumA);
        vm.stopPrank();

        assertEq(fresh.price(address(assetA)), fresh.minimumPrice(address(assetA)) + minPremiumA);
    }

    function testSetReserveAllowsLowStartPremiumWhileUnseeded() public {
        // An unseeded asset has no known floor, so the clamp guard is a no-op: any non-zero premium is fine.
        ERC20Mock assetC = new ERC20Mock();
        _setAssets3(address(assetA), address(assetB), address(assetC));

        vm.prank(admin);
        pool.setReserve(address(assetC), RESERVE_A, 1); // 1 wei premium accepted; backing not seeded yet

        (, uint256 startPremiumC,,,,,) = pool.reserves(address(assetC));
        assertEq(startPremiumC, 1);
    }

    /*----------  deepenReserve  ---------------------------------------*/

    function testDeepenReserveIncreasesDepthAndKeepsSpotPriceContinuous() public {
        // Let the premium decay, then deepen. The spot price should not jump; only future slippage changes.
        vm.warp(block.timestamp + HALF_LIFE);
        uint256 priceBefore = pool.price(address(assetB));
        uint256 liveReserveBefore = pool.reserveOf(address(assetB));
        uint256 newReserve = RESERVE_B * 4;

        vm.expectEmit(true, false, false, true, address(pool));
        emit VirtualReservePool__ReserveDeepened(
            address(assetB), RESERVE_B, newReserve, priceBefore - pool.minimumPrice(address(assetB))
        );
        vm.prank(admin);
        pool.deepenReserve(address(assetB), newReserve);

        (uint256 vtrB,, uint256 currentPremiumB, uint256 lastUpdateB,, bool initializedB, bool configuredB) =
            pool.reserves(address(assetB));
        assertEq(vtrB, newReserve);
        assertEq(lastUpdateB, block.timestamp);
        assertTrue(initializedB);
        assertTrue(configuredB);
        assertEq(pool.price(address(assetB)), priceBefore);
        assertEq(pool.reserveOf(address(assetB)), liveReserveBefore + (newReserve - RESERVE_B));
        assertEq(currentPremiumB, priceBefore - pool.minimumPrice(address(assetB)));
    }

    function testDeepeningMakesFutureBuyCheaperForThatAsset() public {
        uint256 amount = 50 ether;
        (IController.Receipt[] memory beforeQuote,,) = pool.quote(amount);

        vm.prank(admin);
        pool.deepenReserve(address(assetB), RESERVE_B * 5);

        (IController.Receipt[] memory afterQuote,,) = pool.quote(amount);
        // Asset B was deepened: same spot premium, less price impact for the same buy size.
        assertLt(afterQuote[1].amount, beforeQuote[1].amount);
        // Asset A was untouched.
        assertEq(afterQuote[0].amount, beforeQuote[0].amount);
    }

    function testDeepenReserveBeforeOpenDoesNotStartDecayClock() public {
        (Controller c2, VirtualReservePool fresh) = _freshPoolConfiguredBoth();
        vm.warp(block.timestamp + 3 days);

        vm.prank(admin);
        fresh.deepenReserve(address(assetA), RESERVE_A * 2);

        (uint256 vtrA,, uint256 currentPremiumA, uint256 lastA,, bool initializedA,) = fresh.reserves(address(assetA));
        assertEq(vtrA, RESERVE_A * 2);
        assertEq(currentPremiumA, START_PREMIUM_A);
        assertEq(lastA, 0);
        assertTrue(initializedA);

        uint256 openTime = block.timestamp + 1 hours;
        vm.warp(openTime);
        vm.prank(admin);
        fresh.open();
        assertEq(fresh.price(address(assetA)), fresh.minimumPrice(address(assetA)) + START_PREMIUM_A);
        c2;
    }

    function testDeepenReserveRevertsForNonAdmin() public {
        bytes32 reserveRole = pool.RESERVE_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, reserveRole)
        );
        vm.prank(stranger);
        pool.deepenReserve(address(assetA), RESERVE_A * 2);
    }

    function testDeepenReserveRevertsIfNotActuallyDeepened() public {
        vm.startPrank(admin);
        vm.expectRevert(VirtualReservePool.VirtualReservePool__ReserveNotDeepened.selector);
        pool.deepenReserve(address(assetA), RESERVE_A);
        vm.expectRevert(VirtualReservePool.VirtualReservePool__ReserveNotDeepened.selector);
        pool.deepenReserve(address(assetA), RESERVE_A - 1);
        vm.stopPrank();
    }

    function testDeepenReserveRevertsForUnconfiguredOrUnsupportedAsset() public {
        ERC20Mock assetC = new ERC20Mock();
        _setAssets3(address(assetA), address(assetB), address(assetC));
        ERC20Mock rogue = new ERC20Mock();

        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(VirtualReservePool.VirtualReservePool__NotConfigured.selector, address(assetC))
        );
        pool.deepenReserve(address(assetC), RESERVE_A);

        vm.expectRevert(VirtualReservePool.VirtualReservePool__UnsupportedBackingAsset.selector);
        pool.deepenReserve(address(rogue), RESERVE_A);
        vm.stopPrank();
    }

    /*----------  open  ------------------------------------------------*/

    function testOpenAnchorsClockForEveryAsset() public {
        (Controller c2, VirtualReservePool fresh) = _freshPoolConfiguredBoth();

        uint256 openTime = block.timestamp + 5 hours;
        vm.warp(openTime);

        vm.expectEmit(false, false, false, true, address(fresh));
        emit VirtualReservePool__Open(openTime);
        vm.prank(admin);
        fresh.open();

        assertEq(fresh.startTime(), openTime);
        (,,, uint256 lastA,,,) = fresh.reserves(address(assetA));
        (,,, uint256 lastB,,,) = fresh.reserves(address(assetB));
        assertEq(lastA, openTime);
        assertEq(lastB, openTime);
        // Full premium live at open regardless of deploy->open latency.
        assertEq(fresh.price(address(assetA)), fresh.minimumPrice(address(assetA)) + START_PREMIUM_A);
        c2; // silence unused
    }

    function testOpenRevertsForNonAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, pool.OPENER_ROLE()
            )
        );
        vm.prank(stranger);
        pool.open();
    }

    function testOpenRevertsWhenAlreadyOpen() public {
        vm.expectRevert(VirtualReservePool.VirtualReservePool__AlreadyOpen.selector);
        vm.prank(admin);
        pool.open();
    }

    function testOpenRevertsWhenAnAssetIsUnconfigured() public {
        // Fresh pool: configure only A, leave B unconfigured.
        VirtualReservePool fresh =
            new VirtualReservePool(address(controller), admin, HALF_LIFE, RESET_THRESHOLD_BPS, RESET_TARGET_BPS, MIN_PREMIUM_BPS);
        vm.startPrank(admin);
        controller.executeAction(Actions.ActivatePolicy, address(fresh));
        fresh.setReserve(address(assetA), RESERVE_A, START_PREMIUM_A);
        vm.expectRevert(
            abi.encodeWithSelector(VirtualReservePool.VirtualReservePool__NotConfigured.selector, address(assetB))
        );
        fresh.open();
        vm.stopPrank();
    }

    /*----------  PRICING  --------------------------------------------*/

    function testMinimumPriceIsFeeGrossedBackingPerAsset() public view {
        assertEq(pool.minimumPrice(address(assetA)), _grossedFloor(1 ether));
        assertEq(pool.minimumPrice(address(assetB)), _grossedFloor(2 ether));
    }

    function testPriceIsFloorPlusPremiumPerAsset() public view {
        assertEq(pool.price(address(assetA)), _grossedFloor(1 ether) + START_PREMIUM_A);
        assertEq(pool.price(address(assetB)), _grossedFloor(2 ether) + START_PREMIUM_B);
    }

    function testGetPricesReturnsEveryAssetInKernelOrder() public view {
        IController.Backing[] memory prices = pool.getPrices();
        assertEq(prices.length, 2);
        assertEq(prices[0].asset, address(assetA));
        assertEq(prices[1].asset, address(assetB));
        assertEq(prices[0].backingPerToken, _grossedFloor(1 ether) + START_PREMIUM_A);
        assertEq(prices[1].backingPerToken, _grossedFloor(2 ether) + START_PREMIUM_B);
    }

    function testMinimumPriceRevertsForUnsupportedAsset() public {
        ERC20Mock rogue = new ERC20Mock();
        vm.expectRevert(VirtualReservePool.VirtualReservePool__UnsupportedBackingAsset.selector);
        pool.minimumPrice(address(rogue));
    }

    /// @notice Per-asset steepness: the steep curve (B) charges a higher premium-per-token than the shallow
    ///         curve (A) for the same trade size, even though both opened at the same premium.
    function testPerAssetSteepnessDiffersWithReserveSize() public view {
        uint256 amount = 50 ether;
        (IController.Receipt[] memory payments,,) = pool.quote(amount);

        uint256 premiumLegA = payments[0].amount - Math.mulDiv(amount, _grossedFloor(1 ether), WAD, Math.Rounding.Ceil);
        uint256 premiumLegB = payments[1].amount - Math.mulDiv(amount, _grossedFloor(2 ether), WAD, Math.Rounding.Ceil);

        // Per-token premium paid is higher on the steeper (smaller-reserve) curve.
        assertGt(premiumLegB * WAD / amount, premiumLegA * WAD / amount);
    }

    /*----------  BUY  -------------------------------------------------*/

    function testBuyMintsAndChargesAllAssetsOnOwnCurves() public {
        uint256 amount = 50 ether;
        (IController.Receipt[] memory q,, uint256[] memory nextPremiums) = pool.quote(amount);

        _fundAndApprove(buyer, address(assetA), q[0].amount);
        _fundAndApprove(buyer, address(assetB), q[1].amount);

        uint256 backingAddedA = q[0].amount - _protocolFee(q[0].amount);
        uint256 backingAddedB = q[1].amount - _protocolFee(q[1].amount);

        vm.prank(buyer);
        IController.Receipt[] memory paid = pool.buy(amount, q, block.timestamp);

        // Minted to buyer; supply grew by exactly amount.
        assertEq(token.balanceOf(buyer), amount);
        assertEq(token.totalSupply(), INITIAL_SUPPLY + amount);
        assertEq(pool.totalMinted(), amount);

        // Paid both assets at the quoted amounts.
        assertEq(paid.length, 2);
        assertEq(paid[0].amount, q[0].amount);
        assertEq(paid[1].amount, q[1].amount);

        // Protocol fee skimmed; the rest is backing (team/treasury are 0 in this harness).
        assertEq(assetA.balanceOf(protocolCollector), _protocolFee(q[0].amount));
        assertEq(assetB.balanceOf(protocolCollector), _protocolFee(q[1].amount));
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(assetA)), BACKING_A + backingAddedA);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(assetB)), BACKING_B + backingAddedB);

        // Curve state advanced for both assets, stamped at this timestamp.
        (,, uint256 curPremA, uint256 lastA,, bool initA,) = pool.reserves(address(assetA));
        (,, uint256 curPremB,,, bool initB,) = pool.reserves(address(assetB));
        assertEq(curPremA, nextPremiums[0]);
        assertEq(curPremB, nextPremiums[1]);
        assertEq(lastA, block.timestamp);
        assertTrue(initA);
        assertTrue(initB);

        // Live reserves drained by amount for both.
        assertEq(pool.reserveOf(address(assetA)), RESERVE_A - amount);
        assertEq(pool.reserveOf(address(assetB)), RESERVE_B - amount);
    }

    function testBuyCrossingResetThresholdRecyclesOnlyCrossedCurveSegment() public {
        uint256 amount = 170 ether; // 85% of steep asset B's 200-token virtual reserve; below A's 80% threshold.
        (IController.Receipt[] memory q,, uint256[] memory nextPremiums) = pool.quote(amount);
        _fundAndApprove(buyer, address(assetA), q[0].amount);
        _fundAndApprove(buyer, address(assetB), q[1].amount);

        uint256 targetConsumedB = RESERVE_B * RESET_TARGET_BPS / BPS;
        uint256 expectedMintedAtConfigB = amount - targetConsumedB;

        vm.expectEmit(true, false, false, true, address(pool));
        emit VirtualReservePool__ReserveReset(address(assetB), amount, targetConsumedB, amount);
        vm.prank(buyer);
        pool.buy(amount, q, block.timestamp);

        assertEq(pool.totalMinted(), amount);
        assertEq(pool.reserveOf(address(assetA)), RESERVE_A - amount, "asset A should not reset");
        assertEq(pool.reserveOf(address(assetB)), RESERVE_B - targetConsumedB, "asset B reset to target segment");

        (,,,, uint256 mintedAtConfigA,,) = pool.reserves(address(assetA));
        (,, uint256 currentPremiumB,, uint256 mintedAtConfigB,,) = pool.reserves(address(assetB));
        assertEq(mintedAtConfigA, 0, "asset A anchor unchanged");
        assertEq(mintedAtConfigB, expectedMintedAtConfigB, "asset B anchor moved to target consumed");
        // Reset changes curve position/depth only; the post-buy premium anchor remains exactly the quote's
        // post-trade premium, so spot price is continuous for the next buyer.
        assertEq(currentPremiumB, nextPremiums[1]);
    }

    function testSellDoesNotResetOrRewindCurvePosition() public {
        uint256 amount = 50 ether;
        (IController.Receipt[] memory q,,) = pool.quote(amount);
        _fundAndApprove(buyer, address(assetA), q[0].amount);
        _fundAndApprove(buyer, address(assetB), q[1].amount);

        vm.prank(buyer);
        pool.buy(amount, q, block.timestamp);

        uint256 reserveBeforeSell = pool.reserveOf(address(assetB));
        (,,,, uint256 mintedAtConfigBefore,,) = pool.reserves(address(assetB));
        uint256 totalMintedBefore = pool.totalMinted();
        IController.Receipt[] memory rv = pool.redemptionValue(amount);

        vm.prank(buyer);
        pool.sell(amount, _minProceeds(rv[0].amount, rv[1].amount), block.timestamp);

        assertEq(pool.totalMinted(), totalMintedBefore, "sell must not reduce cumulative curve mints");
        assertEq(pool.reserveOf(address(assetB)), reserveBeforeSell, "sell must not refill live curve reserve");
        (,,,, uint256 mintedAtConfigAfter,,) = pool.reserves(address(assetB));
        assertEq(mintedAtConfigAfter, mintedAtConfigBefore, "sell must not move curve anchor");
    }

    function testRollingResetAllowsContinuousIssuanceBeyondSingleVirtualReserve() public {
        uint256 first = 170 ether; // crosses B threshold, resets B to 20% consumed.
        (IController.Receipt[] memory q1,,) = pool.quote(first);
        _fundAndApprove(buyer, address(assetA), q1[0].amount);
        _fundAndApprove(buyer, address(assetB), q1[1].amount);
        vm.prank(buyer);
        pool.buy(first, q1, block.timestamp);

        uint256 second = 120 ether; // from B's 20% target back to its 80% threshold.
        (IController.Receipt[] memory q2,,) = pool.quote(second);
        _fundAndApprove(buyer, address(assetA), q2[0].amount);
        _fundAndApprove(buyer, address(assetB), q2[1].amount);
        vm.prank(buyer);
        pool.buy(second, q2, block.timestamp);

        assertGt(pool.totalMinted(), RESERVE_B, "cumulative issuance can exceed one curve depth");
        assertEq(pool.totalMinted(), first + second);
        assertEq(pool.reserveOf(address(assetB)), RESERVE_B - (RESERVE_B * RESET_TARGET_BPS / BPS));
    }

    function testQuoteMatchesActualPayment() public {
        uint256 amount = 33 ether;
        (IController.Receipt[] memory q,,) = pool.quote(amount);
        _fundAndApprove(buyer, address(assetA), q[0].amount);
        _fundAndApprove(buyer, address(assetB), q[1].amount);

        vm.prank(buyer);
        IController.Receipt[] memory paid = pool.buy(amount, q, block.timestamp);
        assertEq(paid[0].amount, q[0].amount);
        assertEq(paid[1].amount, q[1].amount);
    }

    function testBuyRevertsOnGuards() public {
        IController.Receipt[] memory max = _maxPayments(type(uint256).max, type(uint256).max);

        vm.expectRevert(VirtualReservePool.VirtualReservePool__DeadlinePassed.selector);
        vm.prank(buyer);
        pool.buy(1 ether, max, block.timestamp - 1);

        vm.expectRevert(VirtualReservePool.VirtualReservePool__InvalidMintAmount.selector);
        vm.prank(buyer);
        pool.buy(0, max, block.timestamp);

        // length mismatch
        IController.Receipt[] memory one = new IController.Receipt[](1);
        one[0] = IController.Receipt({asset: address(assetA), amount: type(uint256).max});
        vm.expectRevert(VirtualReservePool.VirtualReservePool__MaxPaymentsLengthMismatch.selector);
        vm.prank(buyer);
        pool.buy(1 ether, one, block.timestamp);

        // asset mismatch (wrong order)
        IController.Receipt[] memory swapped = _maxPayments(type(uint256).max, type(uint256).max);
        (swapped[0].asset, swapped[1].asset) = (address(assetB), address(assetA));
        vm.expectRevert(VirtualReservePool.VirtualReservePool__MaxPaymentAssetMismatch.selector);
        vm.prank(buyer);
        pool.buy(1 ether, swapped, block.timestamp);

        // reserve exhausted: amount >= steep asset B's reserve
        vm.expectRevert(
            abi.encodeWithSelector(VirtualReservePool.VirtualReservePool__ReserveExhausted.selector, address(assetB))
        );
        vm.prank(buyer);
        pool.buy(RESERVE_B, max, block.timestamp);
    }

    function testBuyRevertsWhenMaxPaymentExceeded() public {
        uint256 amount = 10 ether;
        (IController.Receipt[] memory q,,) = pool.quote(amount);
        // Cap asset B one wei below its quote.
        IController.Receipt[] memory max = _maxPayments(q[0].amount, q[1].amount - 1);

        vm.expectRevert(
            abi.encodeWithSelector(VirtualReservePool.VirtualReservePool__MaxPayment.selector, address(assetB))
        );
        vm.prank(buyer);
        pool.buy(amount, max, block.timestamp);
    }

    function testBuyRevertsBeforeOpen() public {
        VirtualReservePool fresh =
            new VirtualReservePool(address(controller), admin, HALF_LIFE, RESET_THRESHOLD_BPS, RESET_TARGET_BPS, MIN_PREMIUM_BPS);
        IController.Receipt[] memory max = _maxPayments(type(uint256).max, type(uint256).max);
        vm.expectRevert(VirtualReservePool.VirtualReservePool__NotOpen.selector);
        vm.prank(buyer);
        fresh.buy(1 ether, max, block.timestamp);
    }

    /*----------  SELL / REDEEM  --------------------------------------*/

    function testRedemptionValueIsPureBackingPerToken() public view {
        uint256 amount = 100 ether;
        IController.Receipt[] memory rv = pool.redemptionValue(amount);
        assertEq(rv.length, 2);
        assertEq(rv[0].asset, address(assetA));
        assertEq(rv[1].asset, address(assetB));
        // bpt is 1.0 and 2.0 -> pure backing, no premium, no fee.
        assertEq(rv[0].amount, amount * 1 ether / WAD);
        assertEq(rv[1].amount, amount * 2 ether / WAD);
    }

    function testRedemptionValueIsStrictlyBelowBuyPrice() public view {
        uint256 amount = 50 ether;
        IController.Receipt[] memory rv = pool.redemptionValue(amount);
        (IController.Receipt[] memory q,,) = pool.quote(amount);
        // No buy/sell arbitrage loop: you always get back less than you paid.
        assertLt(rv[0].amount, q[0].amount);
        assertLt(rv[1].amount, q[1].amount);
    }

    function testSellBurnsTokensAndReturnsBackingForAllAssets() public {
        // Give the seller tokens via the genesis holder.
        uint256 amount = 90 ether;
        vm.prank(holder);
        token.transfer(seller, amount);

        IController.Receipt[] memory rv = pool.redemptionValue(amount);
        IController.Receipt[] memory minOut = _minProceeds(rv[0].amount, rv[1].amount);

        uint256 supplyBefore = token.totalSupply();
        uint256 vaultABefore = assetA.balanceOf(address(vault));
        uint256 vaultBBefore = assetB.balanceOf(address(vault));

        vm.prank(seller);
        IController.Receipt[] memory proceeds = pool.sell(amount, minOut, block.timestamp);

        // Tokens burned.
        assertEq(token.balanceOf(seller), 0);
        assertEq(token.totalSupply(), supplyBefore - amount);

        // Pure backing returned, no fee skimmed to the protocol collector.
        assertEq(proceeds[0].amount, rv[0].amount);
        assertEq(proceeds[1].amount, rv[1].amount);
        assertEq(assetA.balanceOf(seller), rv[0].amount);
        assertEq(assetB.balanceOf(seller), rv[1].amount);
        assertEq(assetA.balanceOf(address(vault)), vaultABefore - rv[0].amount);
        assertEq(assetB.balanceOf(address(vault)), vaultBBefore - rv[1].amount);
        assertEq(assetA.balanceOf(protocolCollector), 0);
        assertEq(assetB.balanceOf(protocolCollector), 0);
        // Redeem buckets reduced by the proceeds.
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(assetA)), BACKING_A - rv[0].amount);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(assetB)), BACKING_B - rv[1].amount);
    }

    function testSellWorksBeforeOpen() public {
        // Redemption is independent of the pool being opened.
        VirtualReservePool fresh =
            new VirtualReservePool(address(controller), admin, HALF_LIFE, RESET_THRESHOLD_BPS, RESET_TARGET_BPS, MIN_PREMIUM_BPS);
        vm.prank(admin);
        controller.executeAction(Actions.ActivatePolicy, address(fresh));
        assertEq(fresh.startTime(), 0);

        uint256 amount = 10 ether;
        vm.prank(holder);
        token.transfer(seller, amount);

        IController.Receipt[] memory rv = fresh.redemptionValue(amount);
        IController.Receipt[] memory minOut = _minProceeds(rv[0].amount, rv[1].amount);

        vm.prank(seller);
        fresh.sell(amount, minOut, block.timestamp);
        assertEq(assetA.balanceOf(seller), rv[0].amount);
        assertEq(assetB.balanceOf(seller), rv[1].amount);
    }

    function testSellRevertsOnGuards() public {
        uint256 amount = 10 ether;
        vm.prank(holder);
        token.transfer(seller, amount);
        IController.Receipt[] memory rv = pool.redemptionValue(amount);

        // deadline
        vm.expectRevert(VirtualReservePool.VirtualReservePool__DeadlinePassed.selector);
        vm.prank(seller);
        pool.sell(amount, _minProceeds(rv[0].amount, rv[1].amount), block.timestamp - 1);

        // zero amount
        vm.expectRevert(VirtualReservePool.VirtualReservePool__InvalidRedeemAmount.selector);
        vm.prank(seller);
        pool.sell(0, _minProceeds(0, 0), block.timestamp);

        // minProceeds length mismatch
        IController.Receipt[] memory one = new IController.Receipt[](1);
        one[0] = IController.Receipt({asset: address(assetA), amount: 0});
        vm.expectRevert(VirtualReservePool.VirtualReservePool__MinProceedsLengthMismatch.selector);
        vm.prank(seller);
        pool.sell(amount, one, block.timestamp);

        // minProceeds asset mismatch (wrong order)
        IController.Receipt[] memory swapped = _minProceeds(0, 0);
        (swapped[0].asset, swapped[1].asset) = (address(assetB), address(assetA));
        vm.expectRevert(VirtualReservePool.VirtualReservePool__MinProceedsAssetMismatch.selector);
        vm.prank(seller);
        pool.sell(amount, swapped, block.timestamp);

        // slippage: require one wei more than redemption value on asset B
        vm.expectRevert(
            abi.encodeWithSelector(VirtualReservePool.VirtualReservePool__MinProceeds.selector, address(assetB))
        );
        vm.prank(seller);
        pool.sell(amount, _minProceeds(rv[0].amount, rv[1].amount + 1), block.timestamp);
    }

    function testSellRevertsWhenSellerLacksTokens() public {
        uint256 amount = 10 ether;
        IController.Receipt[] memory rv = pool.redemptionValue(amount);
        vm.expectRevert(); // burnFrom underflows on zero balance
        vm.prank(seller);
        pool.sell(amount, _minProceeds(rv[0].amount, rv[1].amount), block.timestamp);
    }

    function testSellThenBuyRoundTripLosesValue() public {
        // A buy followed by an immediate sell of the same amount returns less than was paid: the premium
        // plus protocol fee are unrecoverable. Proves the curve cannot be farmed.
        uint256 amount = 20 ether;
        (IController.Receipt[] memory q,,) = pool.quote(amount);
        _fundAndApprove(buyer, address(assetA), q[0].amount);
        _fundAndApprove(buyer, address(assetB), q[1].amount);

        vm.prank(buyer);
        pool.buy(amount, q, block.timestamp);

        IController.Receipt[] memory rv = pool.redemptionValue(amount);
        vm.prank(buyer);
        IController.Receipt[] memory proceeds =
            pool.sell(amount, _minProceeds(rv[0].amount, rv[1].amount), block.timestamp);

        assertLt(proceeds[0].amount, q[0].amount);
        assertLt(proceeds[1].amount, q[1].amount);
    }

    /*----------  DECAY  ----------------------------------------------*/

    function testPremiumDecaysOnSharedHalfLife() public {
        uint256 premA0 = _premiumOf(address(assetA));
        uint256 premB0 = _premiumOf(address(assetB));
        assertEq(premA0, START_PREMIUM_A);
        assertEq(premB0, START_PREMIUM_B);

        vm.warp(block.timestamp + HALF_LIFE);
        // After exactly one half-life, each premium ~= half its anchor (wadExp approx, tight tolerance).
        assertApproxEqRel(_premiumOf(address(assetA)), START_PREMIUM_A / 2, 1e13);
        assertApproxEqRel(_premiumOf(address(assetB)), START_PREMIUM_B / 2, 1e13);

        // The shared clock decays both assets by the identical factor (same anchor here => equal premium).
        assertEq(_premiumOf(address(assetA)), _premiumOf(address(assetB)));
    }

    function testPremiumConvergesToFloorRelativeMinimum() public {
        // Far past the point where raw decay underflows to zero, the premium rests at the floor-relative
        // minimum rather than collapsing to the bare floor.
        vm.warp(block.timestamp + HALF_LIFE * 60);
        assertEq(_premiumOf(address(assetA)), _minPremiumOf(address(assetA)));
        assertEq(_premiumOf(address(assetB)), _minPremiumOf(address(assetB)));
        assertEq(pool.price(address(assetA)), pool.minimumPrice(address(assetA)) + _minPremiumOf(address(assetA)));
        assertEq(pool.price(address(assetB)), pool.minimumPrice(address(assetB)) + _minPremiumOf(address(assetB)));
        // Never zero: the curve keeps a live quote-side base.
        assertGt(_premiumOf(address(assetA)), 0);
        assertGt(_premiumOf(address(assetB)), 0);
    }

    /// @notice After the premium has fully decayed to its minimum, a buy must still produce real price
    ///         impact — i.e. the multiplicative curve can revive off the clamped base rather than being
    ///         stuck at zero. This is the whole point of the floor clamp.
    function testBuyRevivesPremiumFromMinimumFloor() public {
        vm.warp(block.timestamp + HALF_LIFE * 60);
        uint256 restingPremiumB = _premiumOf(address(assetB));
        assertEq(restingPremiumB, _minPremiumOf(address(assetB)));

        uint256 amount = 20 ether; // ~10% of assetB's reserve: a meaningful ratchet
        (IController.Receipt[] memory q,, uint256[] memory nextPremiums) = pool.quote(amount);
        // The quote ratchets the premium above the resting minimum off the clamped base.
        assertGt(nextPremiums[1], restingPremiumB);

        _fundAndApprove(buyer, address(assetA), q[0].amount);
        _fundAndApprove(buyer, address(assetB), q[1].amount);
        vm.prank(buyer);
        pool.buy(amount, q, block.timestamp);

        // Post-buy spot premium is now strictly above the minimum: the pool is alive again.
        assertGt(_premiumOf(address(assetB)), _minPremiumOf(address(assetB)));
    }

    function testPriceNeverDropsBelowFloor() public {
        for (uint256 i = 1; i <= 80; i++) {
            vm.warp(block.timestamp + HALF_LIFE / 4);
            assertGe(pool.price(address(assetA)), pool.minimumPrice(address(assetA)));
            assertGe(pool.price(address(assetB)), pool.minimumPrice(address(assetB)));
        }
    }

    /*----------  LATE-ADDED ASSET  -----------------------------------*/

    /// @notice An asset registered after open must (a) pause buys until configured, and (b) start its curve
    ///         fresh from the current totalMinted and decay from its own config time.
    function testLateAddedAssetPausesBuysThenStartsFreshCurve() public {
        // First do a buy so totalMinted > 0.
        uint256 amount = 40 ether;
        (IController.Receipt[] memory q,,) = pool.quote(amount);
        _fundAndApprove(buyer, address(assetA), q[0].amount);
        _fundAndApprove(buyer, address(assetB), q[1].amount);
        vm.prank(buyer);
        pool.buy(amount, q, block.timestamp);
        assertEq(pool.totalMinted(), amount);

        // Register a third backing asset without configuring it: buys must now revert.
        ERC20Mock assetC = new ERC20Mock();
        _setAssets3(address(assetA), address(assetB), address(assetC));
        _seedBacking(assetC, 3_000 ether); // bpt 3.0

        IController.Receipt[] memory max3 = new IController.Receipt[](3);
        max3[0] = IController.Receipt({asset: address(assetA), amount: type(uint256).max});
        max3[1] = IController.Receipt({asset: address(assetB), amount: type(uint256).max});
        max3[2] = IController.Receipt({asset: address(assetC), amount: type(uint256).max});
        vm.expectRevert(
            abi.encodeWithSelector(VirtualReservePool.VirtualReservePool__NotConfigured.selector, address(assetC))
        );
        vm.prank(buyer);
        pool.buy(1 ether, max3, block.timestamp);

        // Configure C live: its curve starts fresh from current totalMinted, clock anchored now.
        uint256 configTime = block.timestamp + 1 hours;
        vm.warp(configTime);
        vm.prank(admin);
        pool.setReserve(address(assetC), 500 ether, START_PREMIUM_A);

        {
            (,,, uint256 lastC, uint256 mintedAtC,,) = pool.reserves(address(assetC));
            assertEq(lastC, configTime);
            assertEq(mintedAtC, amount);
        }
        // Full reserve available despite prior mints (not pre-drained).
        assertEq(pool.reserveOf(address(assetC)), 500 ether);
        // Full premium live right after config (no decay yet).
        assertEq(_premiumOf(address(assetC)), START_PREMIUM_A);

        // And buys work again across all three.
        (IController.Receipt[] memory q3,,) = pool.quote(5 ether);
        _fundAndApprove(buyer, address(assetA), q3[0].amount);
        _fundAndApprove(buyer, address(assetB), q3[1].amount);
        _fundAndApprove(buyer, address(assetC), q3[2].amount);
        vm.prank(buyer);
        pool.buy(5 ether, q3, block.timestamp);
        assertEq(pool.totalMinted(), amount + 5 ether);
    }

    /*----------  FEE ACCOUNTING  -------------------------------------*/

    function testBackingFloorAccountsForTeamAndTreasuryFees() public {
        uint256 teamBps = 500;
        uint256 treasuryBps = 250;
        _setPaymentBps(teamBps, treasuryBps);

        uint256 amount = 20 ether;
        (IController.Receipt[] memory q,,) = pool.quote(amount);
        _fundAndApprove(buyer, address(assetA), q[0].amount);
        _fundAndApprove(buyer, address(assetB), q[1].amount);

        vm.prank(buyer);
        pool.buy(amount, q, block.timestamp);

        // Per-asset split lands in the right buckets.
        for (uint256 i = 0; i < 2; i++) {
            address a = i == 0 ? address(assetA) : address(assetB);
            uint256 payment = q[i].amount;
            uint256 net = payment - _protocolFee(payment);
            uint256 teamAmt = net * teamBps / BPS;
            uint256 treasuryAmt = net * treasuryBps / BPS;
            assertEq(_bucketValue(IVault.Bucket.Team, a), teamAmt);
            assertEq(_bucketValue(IVault.Bucket.Treasury, a), treasuryAmt);
        }
        // Backing per token never went down for either asset (core invariant respected).
        assertGe(_backingPerToken(address(assetA)), 1 ether);
        assertGe(_backingPerToken(address(assetB)), 2 ether);
    }

    function testPriceRevertsForInvalidFeeConfiguration() public {
        _setPaymentBps(BPS, 0); // team == BPS, invalid
        vm.expectRevert(VirtualReservePool.VirtualReservePool__InvalidFeeConfiguration.selector);
        pool.price(address(assetA));
    }

    /*----------  MODULE PERMISSIONING  -------------------------------*/

    function testMinterMintRevertsForUnpermissionedCaller() public {
        IController.Receipt[] memory receipts = new IController.Receipt[](1);
        receipts[0] = IController.Receipt({asset: address(assetA), amount: 1});
        vm.expectRevert(abi.encodeWithSelector(Module.Module__PolicyNotPermitted.selector, address(this)));
        minter.mint(address(this), 1 ether, receipts);
    }

    /*==================  FUZZ TESTS  =================================*/

    /// @notice Across arbitrary fee splits and buy sequences, every asset's backing-per-token is
    ///         non-decreasing — the core's central invariant, exercised through this pool.
    function testFuzzBackingPerTokenNeverDecreases(uint256 teamBps, uint256 treasuryBps, uint96[5] memory rawAmounts)
        public
    {
        teamBps = bound(teamBps, 0, 4_500);
        treasuryBps = bound(treasuryBps, 0, 4_500);
        _setPaymentBps(teamBps, treasuryBps);

        uint256 prevA = _backingPerToken(address(assetA));
        uint256 prevB = _backingPerToken(address(assetB));

        for (uint256 i = 0; i < rawAmounts.length; i++) {
            uint256 cap = _minReserve();
            if (cap <= 1) break;
            uint256 amount = bound(uint256(rawAmounts[i]), 1, cap - 1);

            (IController.Receipt[] memory q,,) = pool.quote(amount);
            _fundAndApprove(buyer, address(assetA), q[0].amount);
            _fundAndApprove(buyer, address(assetB), q[1].amount);

            vm.prank(buyer);
            pool.buy(amount, q, block.timestamp);

            uint256 curA = _backingPerToken(address(assetA));
            uint256 curB = _backingPerToken(address(assetB));
            assertGe(curA, prevA);
            assertGe(curB, prevB);
            prevA = curA;
            prevB = curB;
        }
    }

    /// @notice V2 price-impact monotonicity per asset: a larger buy pays a strictly higher average
    ///         price-per-token than a smaller buy on the same curve.
    function testFuzzLargerBuysPayHigherAveragePrice(uint96 smallSeed, uint96 largeSeed) public {
        uint256 cap = _minReserve();
        vm.assume(cap > 2 ether);
        // Bound away from dust: at sub-wei-per-token scales the floor leg's ceil-rounding dominates the
        // average and is not a meaningful test of curve monotonicity.
        uint256 small = bound(uint256(smallSeed), 0.01 ether, cap / 2);
        // Require a meaningful gap so the curve's price impact dominates per-leg ceil-rounding (~1 wei).
        uint256 large = bound(uint256(largeSeed), small + 0.01 ether, cap - 1);

        (IController.Receipt[] memory qs,,) = pool.quote(small);
        (IController.Receipt[] memory ql,,) = pool.quote(large);

        // Average price per token, asset B (steep). Larger trade => higher avg price.
        assertGe(_mulDivUp(ql[1].amount, WAD, large), _mulDivUp(qs[1].amount, WAD, small));
        assertGe(_mulDivUp(ql[0].amount, WAD, large), _mulDivUp(qs[0].amount, WAD, small));
    }

    /// @notice Steeper curve (smaller reserve) always charges >= per-token premium than a shallower one
    ///         for the same trade and same start premium.
    function testFuzzSteepnessOrdering(uint96 amountSeed) public {
        uint256 amount = bound(uint256(amountSeed), 1, RESERVE_B - 1);
        (IController.Receipt[] memory q,,) = pool.quote(amount);

        uint256 premPerTokenA =
            (q[0].amount - Math.mulDiv(amount, _grossedFloor(1 ether), WAD, Math.Rounding.Ceil)) * WAD / amount;
        uint256 premPerTokenB =
            (q[1].amount - Math.mulDiv(amount, _grossedFloor(2 ether), WAD, Math.Rounding.Ceil)) * WAD / amount;
        assertGe(premPerTokenB, premPerTokenA);
    }

    /// @notice Premium decay is monotonic non-increasing in elapsed time and never negative; price stays
    ///         at or above floor for any elapsed time.
    function testFuzzDecayMonotonicAndFloored(uint32 dt1, uint32 dt2) public {
        uint256 start = block.timestamp;
        vm.warp(start + dt1);
        uint256 pA1 = _premiumOf(address(assetA));
        uint256 priceA1 = pool.price(address(assetA));
        assertGe(priceA1, pool.minimumPrice(address(assetA)));

        // Warp further forward; premium must not increase.
        vm.warp(start + dt1 + dt2);
        uint256 pA2 = _premiumOf(address(assetA));
        assertLe(pA2, pA1);
        assertGe(pool.price(address(assetA)), pool.minimumPrice(address(assetA)));
    }

    /// @notice Selling any valid amount returns exactly the floored pure-backing value for every asset, and
    ///         is always strictly below the buy price for the same amount (no risk-free round trip).
    function testFuzzSellReturnsPureBackingBelowBuyPrice(uint96 amountSeed) public {
        // Bound below the steep asset's reserve so the buy-price comparison (quote) is valid, and within the
        // seller's funded balance. Redemption itself supports larger amounts; this focuses the comparison.
        uint256 amount = bound(uint256(amountSeed), 1, RESERVE_B - 1);
        vm.prank(holder);
        token.transfer(seller, amount);

        IController.Receipt[] memory rv = pool.redemptionValue(amount);
        // Exact pure backing-per-token, floored.
        assertEq(rv[0].amount, amount * 1 ether / WAD);
        assertEq(rv[1].amount, amount * 2 ether / WAD);

        (IController.Receipt[] memory q,,) = pool.quote(amount);
        assertLe(rv[0].amount, q[0].amount);
        assertLe(rv[1].amount, q[1].amount);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(seller);
        IController.Receipt[] memory proceeds =
            pool.sell(amount, _minProceeds(rv[0].amount, rv[1].amount), block.timestamp);

        assertEq(proceeds[0].amount, rv[0].amount);
        assertEq(proceeds[1].amount, rv[1].amount);
        assertEq(assetA.balanceOf(seller), rv[0].amount);
        assertEq(assetB.balanceOf(seller), rv[1].amount);
        assertEq(token.totalSupply(), supplyBefore - amount);
    }

    /*----------  ACCESS CONTROL  -------------------------------------*/

    function testDefaultAdminCanGrantAndRevokeRoles() public {
        address newOpener = makeAddr("New Opener");
        bytes32 openerRole = pool.OPENER_ROLE();
        bytes32 reserveRole = pool.RESERVE_ROLE();

        // Default admin grants OPENER_ROLE to a new account; it can then open a fresh pool.
        vm.prank(admin);
        pool.grantRole(openerRole, newOpener);
        assertTrue(pool.hasRole(openerRole, newOpener));

        VirtualReservePool fresh =
            new VirtualReservePool(address(controller), admin, HALF_LIFE, RESET_THRESHOLD_BPS, RESET_TARGET_BPS, MIN_PREMIUM_BPS);
        vm.startPrank(admin);
        controller.executeAction(Actions.ActivatePolicy, address(fresh));
        fresh.setReserve(address(assetA), RESERVE_A, START_PREMIUM_A);
        fresh.setReserve(address(assetB), RESERVE_B, START_PREMIUM_B);
        fresh.grantRole(openerRole, newOpener);
        vm.stopPrank();

        vm.prank(newOpener);
        fresh.open();
        assertEq(fresh.startTime(), block.timestamp);

        // Revoke and confirm the account loses access.
        vm.prank(admin);
        pool.revokeRole(reserveRole, admin);
        assertFalse(pool.hasRole(reserveRole, admin));
    }

    function testNonAdminCannotGrantRoles() public {
        bytes32 openerRole = pool.OPENER_ROLE();
        bytes32 adminRole = pool.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        vm.prank(stranger);
        pool.grantRole(openerRole, stranger);
    }

    /*----------  INTERNAL HELPERS  -----------------------------------*/

    function _premiumOf(address asset_) internal view returns (uint256) {
        return pool.price(asset_) - pool.minimumPrice(asset_);
    }

    function _minPremiumOf(address asset_) internal view returns (uint256) {
        return pool.minimumPrice(asset_) * MIN_PREMIUM_BPS / BPS;
    }

    function _backingPerToken(address asset_) internal view returns (uint256) {
        uint256 backing = _bucketValue(IVault.Bucket.Redeem, asset_);
        uint256 supply = token.totalSupply();
        return supply == 0 ? 0 : backing * WAD / supply;
    }

    function _minReserve() internal view returns (uint256) {
        uint256 ra = pool.reserveOf(address(assetA));
        uint256 rb = pool.reserveOf(address(assetB));
        return ra < rb ? ra : rb;
    }

    function _maxPayments(uint256 a, uint256 b) internal view returns (IController.Receipt[] memory m) {
        m = new IController.Receipt[](2);
        m[0] = IController.Receipt({asset: address(assetA), amount: a});
        m[1] = IController.Receipt({asset: address(assetB), amount: b});
    }

    function _minProceeds(uint256 a, uint256 b) internal view returns (IController.Receipt[] memory m) {
        m = new IController.Receipt[](2);
        m[0] = IController.Receipt({asset: address(assetA), amount: a});
        m[1] = IController.Receipt({asset: address(assetB), amount: b});
    }

    function _freshPoolConfiguredBoth() internal returns (Controller, VirtualReservePool) {
        VirtualReservePool fresh =
            new VirtualReservePool(address(controller), admin, HALF_LIFE, RESET_THRESHOLD_BPS, RESET_TARGET_BPS, MIN_PREMIUM_BPS);
        vm.startPrank(admin);
        controller.executeAction(Actions.ActivatePolicy, address(fresh));
        fresh.setReserve(address(assetA), RESERVE_A, START_PREMIUM_A);
        fresh.setReserve(address(assetB), RESERVE_B, START_PREMIUM_B);
        vm.stopPrank();
        return (controller, fresh);
    }

    function _fundAndApprove(address who, address asset_, uint256 amount) internal {
        ERC20Mock(asset_).mint(who, amount);
        vm.prank(who);
        ERC20Mock(asset_).approve(address(vault), amount);
    }

    function _seedBacking(ERC20Mock token_, uint256 amount) internal {
        token_.mint(address(vault), amount);
        _setBucket(IVault.Bucket.Redeem, address(token_), amount);
    }

    function _setAssets(address first, address second) internal {
        address[] memory a = new address[](2);
        a[0] = first;
        a[1] = second;
        _setAssetsRaw(a);
    }

    function _setAssets3(address first, address second, address third) internal {
        address[] memory a = new address[](3);
        a[0] = first;
        a[1] = second;
        a[2] = third;
        _setAssetsRaw(a);
    }

    function _setAssetsRaw(address[] memory a) internal {
        bytes memory data = new bytes(a.length * 32);
        for (uint256 i; i < a.length;) {
            bytes32 assetWord = bytes32(uint256(uint160(a[i])));
            assembly ("memory-safe") {
                mstore(add(add(data, 0x20), shl(5, i)), assetWord)
            }
            unchecked {
                ++i;
            }
        }
        vm.startPrank(address(controller));
        kernel.updateState(Slots.ASSETS_LENGTH_SLOT, bytes32(a.length));
        kernel.updateState(Slots.ASSETS_BASE_SLOT, data);
        vm.stopPrank();
    }

    function _setBucket(IVault.Bucket bucket, address token_, uint256 amount) internal {
        vm.prank(address(controller));
        kernel.updateState(_bucketSlot(bucket, token_), bytes32(amount));
    }

    function _setPaymentBps(uint256 teamBps, uint256 treasuryBps) internal {
        vm.startPrank(address(controller));
        kernel.updateState(Slots.TEAM_PERCENTAGE_SLOT, bytes32(teamBps));
        kernel.updateState(Slots.TREASURY_PERCENTAGE_SLOT, bytes32(treasuryBps));
        vm.stopPrank();
    }

    function _bucketValue(IVault.Bucket bucket, address token_) internal view returns (uint256) {
        return uint256(kernel.viewData(_bucketSlot(bucket, token_)));
    }

    function _bucketSlot(IVault.Bucket bucket, address token_) internal pure returns (bytes32) {
        if (bucket == IVault.Bucket.Redeem) return _slot(Slots.BACKING_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Treasury) return _slot(Slots.TREASURY_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Team) return _slot(Slots.TEAM_AMOUNT_SLOT, token_);
        revert("invalid bucket");
    }

    function _slot(bytes32 namespace, address token_) internal pure returns (bytes32) {
        return keccak256(abi.encode(namespace, token_));
    }

    function _grossedFloor(uint256 backingPerTokenAmount) internal view returns (uint256) {
        uint256 target = backingPerTokenAmount + 1; // mirror +1 cushion
        uint256 teamBps = uint256(kernel.viewData(Slots.TEAM_PERCENTAGE_SLOT));
        uint256 treasuryBps = uint256(kernel.viewData(Slots.TREASURY_PERCENTAGE_SLOT));
        uint256 backingBps = BPS - teamBps - treasuryBps;
        uint256 requiredPostProtocol = _mulDivUp(target, BPS, backingBps);
        return _mulDivUp(requiredPostProtocol, BPS, BPS - AUCTION_FEE_BPS);
    }

    function _protocolFee(uint256 amount) internal pure returns (uint256) {
        return _mulDivUp(amount, AUCTION_FEE_BPS, BPS);
    }

    function _mulDivUp(uint256 value, uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        uint256 product = value * numerator;
        uint256 result = product / denominator;
        if (product % denominator != 0) {
            unchecked {
                ++result;
            }
        }
        return result;
    }
}
