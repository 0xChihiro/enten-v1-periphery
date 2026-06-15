// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {PresaleAuction} from "../src/policies/PresaleAuction.sol";
import {Minter} from "../src/modules/MINTR/Minter.sol";
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
    uint256 internal constant PRICE_MULTIPLIER = 1.05 ether;
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
        presale = _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, PRICE_MULTIPLIER, DURATION, MIN_BID);

        _setAssets(address(asset));
        _seedBacking(asset, INITIAL_BACKING);

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(minter));
        controller.setMintPermission(Keycode.wrap("MINTR"), true);
        controller.executeAction(Actions.ActivatePolicy, address(presale));
        vm.stopPrank();
    }

    function testConstructorStoresInitialState() public view {
        assertEq(address(presale.KERNEL()), address(kernel));
        assertEq(address(presale.TOKEN()), address(token));
        assertEq(presale.ASSET(), address(asset));
        assertEq(presale.PRESALE_SIZE(), PRESALE_SIZE);
        assertEq(presale.START_PRICE(), START_PRICE);
        assertEq(presale.PRICE_MULTIPLIER(), PRICE_MULTIPLIER);
        assertEq(presale.DURATION(), DURATION);
        assertEq(presale.MIN_BID(), MIN_BID);
        assertEq(presale.remaining(), PRESALE_SIZE);
        assertEq(presale.currentPrice(), START_PRICE);
        assertEq(presale.startTime(), 1_000);
        assertEq(presale.lastPriceUpdate(), 1_000);
    }

    function testConstructorRejectsInvalidParameters() public {
        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(0), PRESALE_SIZE, START_PRICE, PRICE_MULTIPLIER, DURATION, MIN_BID);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(asset), 0, START_PRICE, PRICE_MULTIPLIER, DURATION, MIN_BID);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(asset), PRESALE_SIZE, 0, PRICE_MULTIPLIER, DURATION, MIN_BID);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, 0, DURATION, MIN_BID);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, WAD, DURATION, MIN_BID);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, PRICE_MULTIPLIER, DURATION, 0);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, PRICE_MULTIPLIER, DURATION, PRESALE_SIZE + 1);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, PRICE_MULTIPLIER, 1 hours - 1, MIN_BID);

        vm.expectRevert(PresaleAuction.PresaleAuction__InvalidConfig.selector);
        _deployPresale(address(asset), PRESALE_SIZE, START_PRICE, PRICE_MULTIPLIER, 7 days + 1, MIN_BID);
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

    function testBuyMintsAndMultipliesPriceAnchor() public {
        uint256 mintAmount = MIN_BID;
        uint256 clearingPrice = presale.price();
        uint256 nextPrice = _mulDivUp(clearingPrice, PRICE_MULTIPLIER, WAD);
        uint256 paymentAmount = _quotePayment(mintAmount);
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
        assertEq(presale.currentPrice(), nextPrice);
        assertEq(presale.lastPriceUpdate(), block.timestamp);
        assertEq(presale.price(), nextPrice);

        assertEq(asset.balanceOf(buyer), 0);
        assertEq(asset.balanceOf(protocolCollector), protocolFee);
        assertEq(asset.balanceOf(address(vault)), INITIAL_BACKING + netPayment);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_BACKING + netPayment);
    }

    function testPriceDecaysFromMultipliedPriceAfterBuy() public {
        uint256 mintAmount = MIN_BID;
        uint256 paymentAmount = _quotePayment(mintAmount);
        _fundAndApproveBuyer(paymentAmount);

        vm.prank(buyer);
        presale.buy(mintAmount, paymentAmount, block.timestamp);

        uint256 anchor = _mulDivUp(START_PRICE, PRICE_MULTIPLIER, WAD);
        uint256 floorAfterBuy = presale.minimumPrice();

        vm.warp(block.timestamp + DURATION / 2);
        assertEq(presale.price(), anchor - (anchor - floorAfterBuy) / 2);
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

    function _deployPresale(
        address asset_,
        uint256 presaleSize,
        uint256 startPrice,
        uint256 priceMultiplier,
        uint256 duration,
        uint256 minBid
    ) internal returns (PresaleAuction) {
        return new PresaleAuction(
            address(controller), asset_, presaleSize, startPrice, priceMultiplier, duration, minBid
        );
    }

    function _quotePayment(uint256 mintAmount) internal view returns (uint256) {
        return _mulDivUp(mintAmount, presale.price(), WAD);
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
