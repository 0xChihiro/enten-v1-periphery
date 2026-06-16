// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {PresaleAuction} from "../src/policies/PresaleAuction.sol";
import {Minter} from "../src/modules/MINTR/Minter.sol";
import {Module} from "enten-v1/Module.sol";
import {Controller} from "enten-v1/Controller.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Token} from "enten-v1/Token.sol";
import {Vault} from "enten-v1/Vault.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IVault} from "enten-v1/interfaces/IVault.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Actions, Keycode, Permissions, toKeycode} from "enten-v1/Utils.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Test} from "forge-std/Test.sol";

contract PresaleAuctionTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;
    uint256 internal constant INITIAL_BACKING = 1_000 ether;
    uint256 internal constant PRESALE_SIZE = 100 ether;
    uint256 internal constant START_PRICE = 2 ether;
    uint256 internal constant VIRTUAL_TOKEN_RESERVE = 200 ether;
    uint256 internal constant DURATION = 10 hours;
    uint256 internal constant MIN_BID = 10 ether;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant AUCTION_FEE_BPS = 250;

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    Token internal token;
    Minter internal minter;
    PresaleAuction internal presale;
    ERC20Mock internal asset;

    address internal admin = makeAddr("Admin");
    address internal holder = makeAddr("Holder");
    address internal buyer = makeAddr("Buyer");
    address internal protocolCollector = makeAddr("Protocol Collector");
    address internal stranger = makeAddr("Stranger");

    event PresaleAuction__Open(uint256 startTime, uint256 startPrice, uint256 floor);

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

        asset = new ERC20Mock();
        minter = new Minter(address(controller));
        presale = _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, VIRTUAL_TOKEN_RESERVE, DURATION, MIN_BID);

        _setAssets(address(asset));
        _seedBacking(asset, INITIAL_BACKING);

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(minter));
        controller.setMintPermission(Keycode.wrap("MINTR"), true);
        controller.executeAction(Actions.ActivatePolicy, address(presale));
        presale.open();
        vm.stopPrank();
    }

    function testConstructorStoresInitialState() public {
        PresaleAuction fresh =
            _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, VIRTUAL_TOKEN_RESERVE, DURATION, MIN_BID);

        assertEq(address(fresh.KERNEL()), address(kernel));
        assertEq(address(fresh.TOKEN()), address(token));
        assertEq(fresh.ASSET(), address(asset));
        assertEq(fresh.ADMIN(), admin);
        assertEq(fresh.PRESALE_SIZE(), PRESALE_SIZE);
        assertEq(fresh.START_PRICE(), START_PRICE);
        assertEq(fresh.VIRTUAL_TOKEN_RESERVE(), VIRTUAL_TOKEN_RESERVE);
        assertEq(fresh.DURATION(), DURATION);
        assertEq(fresh.MIN_BID(), MIN_BID);
        assertEq(fresh.remaining(), PRESALE_SIZE);
        assertEq(fresh.currentPremium(), 0);
        assertFalse(fresh.premiumInitialized());
        // The clock is not started at construction; open() anchors it.
        assertEq(fresh.startTime(), 0);
        assertEq(fresh.lastPriceUpdate(), 0);
    }

    function testConstructorRejectsInvalidParameters() public {
        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(0), PRESALE_SIZE, START_PRICE, VIRTUAL_TOKEN_RESERVE, DURATION, MIN_BID);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(asset), 0, START_PRICE, VIRTUAL_TOKEN_RESERVE, DURATION, MIN_BID);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(asset), PRESALE_SIZE, 0, VIRTUAL_TOKEN_RESERVE, DURATION, MIN_BID);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, 0, DURATION, MIN_BID);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, VIRTUAL_TOKEN_RESERVE, DURATION, 0);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, VIRTUAL_TOKEN_RESERVE, DURATION, PRESALE_SIZE + 1);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, VIRTUAL_TOKEN_RESERVE, 1 hours - 1, MIN_BID);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, VIRTUAL_TOKEN_RESERVE, 7 days + 1, MIN_BID);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        new PresaleAuction(
            address(controller),
            address(asset),
            address(0),
            PRESALE_SIZE,
            START_PRICE,
            VIRTUAL_TOKEN_RESERVE,
            DURATION,
            MIN_BID
        );
    }

    function testPolicyConfiguresMinterDependencyAndPermission() public view {
        assertEq(address(presale.minterModule()), address(minter));
        assertTrue(controller.isPolicyActive(address(presale)));
        assertEq(Keycode.unwrap(presale.KEYCODE()), Keycode.unwrap(toKeycode("PSALE")));
        assertTrue(controller.modulePermissions(toKeycode("MINTR"), address(presale), Minter.mint.selector));

        Permissions[] memory permissions = presale.requestPermissions();
        assertEq(permissions.length, 1);
        assertEq(Keycode.unwrap(permissions[0].keycode), Keycode.unwrap(toKeycode("MINTR")));
        assertEq(permissions[0].funcSelector, Minter.mint.selector);
    }

    function testOpenStartsClockFromCallTimeAndEmits() public {
        PresaleAuction fresh =
            _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, VIRTUAL_TOKEN_RESERVE, DURATION, MIN_BID);

        // Clock must run from open(), not construction: warp well past deploy before opening.
        uint256 openTime = block.timestamp + 5 hours;
        vm.warp(openTime);

        uint256 floor = fresh.minimumPrice();

        vm.expectEmit(false, false, false, true, address(fresh));
        emit PresaleAuction__Open(openTime, START_PRICE, floor);

        vm.prank(admin);
        fresh.open();

        assertEq(fresh.startTime(), openTime);
        assertEq(fresh.lastPriceUpdate(), openTime);
        // Full premium is live at open regardless of the deploy->open delay.
        assertEq(fresh.price(), START_PRICE);

        // Decay and the sale window are measured from open(), not from deployment.
        vm.warp(openTime + DURATION / 2);
        assertEq(fresh.price(), START_PRICE - (START_PRICE - floor) / 2);

        vm.warp(openTime + DURATION);
        assertEq(fresh.price(), floor);
    }

    function testBuyRevertsBeforeOpen() public {
        PresaleAuction fresh =
            _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, VIRTUAL_TOKEN_RESERVE, DURATION, MIN_BID);

        vm.expectRevert(PresaleAuction.PresaleAuction__NotOpen.selector);
        vm.prank(buyer);
        fresh.buy(MIN_BID, type(uint256).max, block.timestamp);
    }

    function testOpenRevertsForNonAdmin() public {
        PresaleAuction fresh =
            _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, VIRTUAL_TOKEN_RESERVE, DURATION, MIN_BID);

        vm.expectRevert(PresaleAuction.PresaleAuction__NotAdmin.selector);
        vm.prank(stranger);
        fresh.open();
    }

    function testOpenRevertsWhenAlreadyOpen() public {
        vm.expectRevert(PresaleAuction.PresaleAuction__AlreadyOpen.selector);
        vm.prank(admin);
        presale.open();
    }

    function testOpenRevertsWhenStartPriceBelowFloor() public {
        PresaleAuction lowStart =
            _deployPresale(address(asset), PRESALE_SIZE, 1 ether, VIRTUAL_TOKEN_RESERVE, DURATION, MIN_BID);

        // 1 ether is below the fee-grossed floor, so the premium would be a no-op; open() must reject it.
        assertLt(1 ether, lowStart.minimumPrice());

        vm.expectRevert(PresaleAuction.PresaleAuction__StartPriceBelowFloor.selector);
        vm.prank(admin);
        lowStart.open();
    }

    function testOpenRevertsWhenBackingUnseeded() public {
        PresaleAuction fresh =
            _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, VIRTUAL_TOKEN_RESERVE, DURATION, MIN_BID);

        _setBucket(IVault.Bucket.Redeem, address(asset), 0);

        vm.expectRevert(PresaleAuction.PresaleAuction__UnseededAsset.selector);
        vm.prank(admin);
        fresh.open();
    }

    function testPriceDecaysFromStartPriceToFeeGrossedBackingFloor() public {
        uint256 floor = _grossedPrice(1 ether);

        assertEq(presale.minimumPrice(), floor);
        assertEq(presale.price(), START_PRICE);

        vm.warp(presale.startTime() + DURATION / 2);
        assertEq(presale.price(), START_PRICE - (START_PRICE - floor) / 2);

        vm.warp(presale.startTime() + DURATION);
        assertEq(presale.price(), floor);

        vm.warp(presale.startTime() + DURATION * 2);
        assertEq(presale.price(), floor);
    }

    function testBuyMintsAndMovesPremiumAlongCurve() public {
        uint256 mintAmount = MIN_BID;
        (uint256 paymentAmount,, uint256 nextPremium) = presale.quote(mintAmount);
        uint256 protocolFee = _protocolFee(paymentAmount);
        uint256 netPayment = paymentAmount - protocolFee;

        _fundAndApproveBuyer(paymentAmount);

        vm.prank(buyer);
        IController.Receipt[] memory receipts = presale.buy(mintAmount, paymentAmount, block.timestamp);

        assertEq(receipts.length, 1);
        assertEq(receipts[0].asset, address(asset));
        assertEq(receipts[0].amount, paymentAmount);
        assertEq(token.balanceOf(buyer), mintAmount);
        assertEq(token.totalSupply(), INITIAL_SUPPLY + mintAmount);
        assertEq(presale.remaining(), PRESALE_SIZE - mintAmount);
        assertEq(presale.sold(), mintAmount);
        assertEq(presale.currentPremium(), nextPremium);
        assertTrue(presale.premiumInitialized());
        assertEq(presale.lastPriceUpdate(), block.timestamp);
        assertEq(presale.price(), presale.minimumPrice() + nextPremium);

        assertEq(asset.balanceOf(buyer), 0);
        assertEq(asset.balanceOf(protocolCollector), protocolFee);
        assertEq(asset.balanceOf(address(vault)), INITIAL_BACKING + netPayment);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_BACKING + netPayment);
    }

    function testPriceDecaysFromCurvePremiumAfterBuy() public {
        uint256 mintAmount = MIN_BID;
        (uint256 paymentAmount,, uint256 nextPremium) = presale.quote(mintAmount);
        _fundAndApproveBuyer(paymentAmount);

        vm.prank(buyer);
        presale.buy(mintAmount, paymentAmount, block.timestamp);

        uint256 floorAfterBuy = presale.minimumPrice();

        vm.warp(block.timestamp + DURATION / 2);
        assertEq(presale.price(), floorAfterBuy + nextPremium - nextPremium / 2);
    }

    function testLargerBuysPayHigherAverageCurvePrice() public view {
        (uint256 smallPayment,,) = presale.quote(MIN_BID);
        (uint256 largePayment,,) = presale.quote(MIN_BID * 2);

        assertGt(_mulDivUp(largePayment, WAD, MIN_BID * 2), _mulDivUp(smallPayment, WAD, MIN_BID));
    }

    function testBackingFloorAccountsForAllMintFees() public {
        uint256 teamBps = 500;
        uint256 treasuryBps = 250;
        uint256 targetNav = 3 ether;
        uint256 targetBacking = token.totalSupply() * targetNav / WAD;

        _setPaymentBps(teamBps, treasuryBps);
        asset.mint(address(vault), targetBacking - INITIAL_BACKING);
        _setBucket(IVault.Bucket.Redeem, address(asset), targetBacking);

        uint256 floor = _grossedPrice(targetNav);
        assertEq(presale.minimumPrice(), floor);
        assertEq(presale.price(), floor);

        uint256 mintAmount = MIN_BID;
        uint256 paymentAmount = _quotePayment(mintAmount);
        uint256 protocolFee = _protocolFee(paymentAmount);
        uint256 netPayment = paymentAmount - protocolFee;
        uint256 teamAmount = netPayment * teamBps / BPS;
        uint256 treasuryAmount = netPayment * treasuryBps / BPS;
        uint256 backingAmount = netPayment - teamAmount - treasuryAmount;

        _fundAndApproveBuyer(paymentAmount);

        vm.prank(buyer);
        presale.buy(mintAmount, paymentAmount, block.timestamp);

        assertGe(backingAmount, targetNav * mintAmount / WAD);
        assertEq(asset.balanceOf(protocolCollector), protocolFee);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), targetBacking + backingAmount);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), teamAmount);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), treasuryAmount);
    }

    function testBuyRevertsForMinimumBidButAllowsFinalDust() public {
        vm.expectRevert(PresaleAuction.PresaleAuction__MinimumBid.selector);
        vm.prank(buyer);
        presale.buy(MIN_BID - 1, type(uint256).max, block.timestamp);

        uint256 firstAmount = PRESALE_SIZE - MIN_BID / 2;
        uint256 firstPayment = _quotePayment(firstAmount);
        _fundAndApproveBuyer(firstPayment);

        vm.prank(buyer);
        presale.buy(firstAmount, firstPayment, block.timestamp);

        uint256 finalAmount = presale.remaining();
        assertLt(finalAmount, MIN_BID);

        uint256 finalPayment = _quotePayment(finalAmount);
        _fundAndApproveBuyer(finalPayment);

        vm.prank(buyer);
        presale.buy(finalAmount, finalPayment, block.timestamp);

        assertEq(presale.remaining(), 0);
        assertEq(presale.sold(), PRESALE_SIZE);
    }

    function testBuyRevertsForDeadlineAmountAndAuctionEndGuards() public {
        vm.expectRevert(PresaleAuction.PresaleAuction__DeadlinePassed.selector);
        vm.prank(buyer);
        presale.buy(MIN_BID, type(uint256).max, block.timestamp - 1);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidMintAmount.selector);
        vm.prank(buyer);
        presale.buy(0, type(uint256).max, block.timestamp);

        vm.expectRevert(PresaleAuction.PresaleAuction__TooManyTokens.selector);
        vm.prank(buyer);
        presale.buy(PRESALE_SIZE + 1, type(uint256).max, block.timestamp);

        vm.warp(presale.startTime() + DURATION);
        vm.expectRevert(PresaleAuction.PresaleAuction__AuctionOver.selector);
        vm.prank(buyer);
        presale.buy(MIN_BID, type(uint256).max, block.timestamp);
    }

    function testPriceRevertsForUnsupportedBackingAsset() public {
        address[] memory emptyAssets = new address[](0);
        _setAssets(emptyAssets);

        vm.expectRevert(PresaleAuction.PresaleAuction__UnsupportedBackingAsset.selector);
        presale.price();
    }

    function testPriceRevertsForInvalidFeeConfiguration() public {
        _setPaymentBps(BPS, 0);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidFeeConfiguration.selector);
        presale.price();
    }

    // --- T3: floor rises across consecutive buys ---

    function testMultipleBuysRaiseFloor() public {
        // At open the premium is live, so each buy deposits strictly more than backingPerToken*amount
        // into backing, raising the floor for the next buyer.
        uint256 floorBefore = presale.minimumPrice();

        for (uint256 i = 0; i < 3; i++) {
            uint256 payment = _quotePayment(MIN_BID);
            _fundAndApproveBuyer(payment);
            vm.prank(buyer);
            presale.buy(MIN_BID, payment, block.timestamp);

            uint256 floorAfter = presale.minimumPrice();
            assertGt(floorAfter, floorBefore);
            floorBefore = floorAfter;
        }
    }

    // --- #8: low-premium buy with a fractional backing ratio must not revert on the core invariant ---

    function testBuyAtLowPremiumWithFractionalBackingSucceeds() public {
        // Make totalBacking*WAD/supply non-integer so the floored backingPerToken loses sub-wei precision
        // relative to the core's ceil-preserved backing requirement.
        asset.mint(address(vault), 777);
        _setBucket(IVault.Bucket.Redeem, address(asset), INITIAL_BACKING + 777);

        // Drive the premium to its minimum reachable value, just before the hard close.
        vm.warp(presale.startTime() + DURATION - 1);

        uint256 bptBefore = _backingPerToken();
        uint256 amount = MIN_BID + 3; // non-round amount to stress the rounding
        uint256 payment = _quotePayment(amount);
        _fundAndApproveBuyer(payment);

        // Must settle without tripping Controller__BackingBelowFloor on rounding.
        vm.prank(buyer);
        presale.buy(amount, payment, block.timestamp);

        assertGe(_backingPerToken(), bptBefore);
    }

    // --- T1: backing-per-token never decreases across arbitrary buy sequences ---

    function testFuzzBackingPerTokenNeverDecreasesAcrossBuys(
        uint256 teamBps,
        uint256 treasuryBps,
        uint96[4] memory rawAmounts
    ) public {
        // Arbitrary (valid) fee split: team + treasury < BPS so backing keeps a positive residual.
        teamBps = bound(teamBps, 0, 4_500);
        treasuryBps = bound(treasuryBps, 0, 4_500);
        _setPaymentBps(teamBps, treasuryBps);

        uint256 prev = _backingPerToken();

        for (uint256 i = 0; i < rawAmounts.length; i++) {
            uint256 remaining = presale.remaining();
            if (remaining < MIN_BID) break;

            uint256 amount = bound(uint256(rawAmounts[i]), MIN_BID, remaining);
            uint256 payment = _quotePayment(amount);
            _fundAndApproveBuyer(payment);

            vm.prank(buyer);
            presale.buy(amount, payment, block.timestamp);

            uint256 current = _backingPerToken();
            assertGe(current, prev);
            prev = current;
        }
    }

    // --- T5: buy reverts (atomically) when the buyer cannot pay ---

    function testBuyRevertsWhenBuyerHasNotApproved() public {
        uint256 payment = _quotePayment(MIN_BID);
        asset.mint(buyer, payment); // funded, but no allowance to the vault

        vm.expectRevert();
        vm.prank(buyer);
        presale.buy(MIN_BID, payment, block.timestamp);

        assertEq(token.balanceOf(buyer), 0);
        assertEq(presale.remaining(), PRESALE_SIZE);
        assertEq(presale.sold(), 0);
    }

    function testBuyRevertsWhenBuyerUnderfunded() public {
        uint256 payment = _quotePayment(MIN_BID);
        vm.prank(buyer);
        asset.approve(address(vault), payment); // approved, but holds no balance

        vm.expectRevert();
        vm.prank(buyer);
        presale.buy(MIN_BID, payment, block.timestamp);

        assertEq(token.balanceOf(buyer), 0);
        assertEq(presale.remaining(), PRESALE_SIZE);
        assertEq(presale.sold(), 0);
    }

    // --- T4: Minter module rejects unpermissioned callers ---

    function testMinterMintRevertsForUnpermissionedCaller() public {
        IController.Receipt[] memory receipts = new IController.Receipt[](1);
        receipts[0] = IController.Receipt({asset: address(asset), amount: 1});

        vm.expectRevert(abi.encodeWithSelector(Module.Module__PolicyNotPermitted.selector, address(this)));
        minter.mint(address(this), MIN_BID, receipts);
    }

    function _backingPerToken() internal view returns (uint256) {
        uint256 backing = _bucketValue(IVault.Bucket.Redeem, address(asset));
        uint256 supply = token.totalSupply(); // team-locked tokens are zero in this harness
        return supply == 0 ? 0 : backing * WAD / supply;
    }

    function _deployPresale(
        address asset_,
        uint256 presaleSize,
        uint256 startPrice,
        uint256 virtualTokenReserve,
        uint256 duration,
        uint256 minBid
    ) internal returns (PresaleAuction) {
        return new PresaleAuction(
            address(controller), asset_, admin, presaleSize, startPrice, virtualTokenReserve, duration, minBid
        );
    }

    function _quotePayment(uint256 mintAmount) internal view returns (uint256) {
        (uint256 payment,,) = presale.quote(mintAmount);
        return payment;
    }

    function _fundAndApproveBuyer(uint256 amount) internal {
        asset.mint(buyer, amount);
        vm.prank(buyer);
        asset.approve(address(vault), amount);
    }

    function _seedBacking(ERC20Mock token_, uint256 amount) internal {
        token_.mint(address(vault), amount);
        _setBucket(IVault.Bucket.Redeem, address(token_), amount);
    }

    function _setAssets(address first) internal {
        address[] memory assets = new address[](1);
        assets[0] = first;
        _setAssets(assets);
    }

    function _setAssets(address[] memory assets) internal {
        bytes memory data = new bytes(assets.length * 32);
        for (uint256 i; i < assets.length;) {
            bytes32 assetWord = bytes32(uint256(uint160(assets[i])));
            assembly ("memory-safe") {
                mstore(add(add(data, 0x20), shl(5, i)), assetWord)
            }
            unchecked {
                ++i;
            }
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

    function _grossedPrice(uint256 targetBackingPerToken) internal view returns (uint256) {
        // Mirror the +1-wei ceil cushion applied in PresaleAuction.minimumPrice.
        targetBackingPerToken += 1;
        uint256 teamBps = uint256(kernel.viewData(Slots.TEAM_PERCENTAGE_SLOT));
        uint256 treasuryBps = uint256(kernel.viewData(Slots.TREASURY_PERCENTAGE_SLOT));
        uint256 backingBps = BPS - teamBps - treasuryBps;
        uint256 requiredPostProtocol = _mulDivUp(targetBackingPerToken, BPS, backingBps);
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
