// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Auction} from "../src/policies/Auction.sol";
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

contract AuctionTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;
    uint256 internal constant INITIAL_BACKING = 1_000 ether;
    uint256 internal constant INIT_PRICE = 1 ether;
    uint256 internal constant MIN_INIT_PRICE = 1e6;
    uint256 internal constant LOT_SIZE = 100 ether;
    uint256 internal constant EPOCH_PERIOD = 10 hours;
    uint256 internal constant PRICE_MULTIPLIER = 2e18;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant AUCTION_FEE_BPS = 250;

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    Token internal token;
    Minter internal minter;
    Auction internal auction;
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
        controller = new Controller(admin, protocolCollector, predictedKernel, predictedVault, predictedToken);

        asset = new ERC20Mock();
        minter = new Minter(address(controller));
        auction = _deployAuction(INIT_PRICE, LOT_SIZE, EPOCH_PERIOD, PRICE_MULTIPLIER);

        _setAssets(address(asset));
        _seedBacking(asset, INITIAL_BACKING);

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(minter));
        controller.setMintPermission(Keycode.wrap("MINTR"), true);
        controller.executeAction(Actions.ActivatePolicy, address(auction));
        vm.stopPrank();
    }

    function testConstructorStoresInitialAuctionState() public view {
        assertEq(auction.initPrice(), INIT_PRICE);
        assertEq(auction.LOT_SIZE(), LOT_SIZE);
        assertEq(auction.remainingLot(), LOT_SIZE);
        assertEq(auction.epochPeriod(), EPOCH_PERIOD);
        assertEq(auction.priceMultiplier(), PRICE_MULTIPLIER);
        assertEq(auction.epochId(), 0);
        assertEq(auction.startTime(), 1_000);
    }

    function testConstructorRejectsInvalidParameters() public {
        vm.expectRevert(Auction.Auction__InvalidLotSize.selector);
        _deployAuction(INIT_PRICE, 0, EPOCH_PERIOD, PRICE_MULTIPLIER);

        vm.expectRevert(Auction.Auction__InitPriceBelowMin.selector);
        _deployAuction(MIN_INIT_PRICE - 1, LOT_SIZE, EPOCH_PERIOD, PRICE_MULTIPLIER);

        vm.expectRevert(Auction.Auction__InitPriceExceedsMax.selector);
        _deployAuction(uint256(type(uint192).max) + 1, LOT_SIZE, EPOCH_PERIOD, PRICE_MULTIPLIER);

        vm.expectRevert(Auction.Auction__EpochPeriodBelowMin.selector);
        _deployAuction(INIT_PRICE, LOT_SIZE, 1 hours - 1, PRICE_MULTIPLIER);

        vm.expectRevert(Auction.Auction__EpochPeriodExceedsMax.selector);
        _deployAuction(INIT_PRICE, LOT_SIZE, 365 days + 1, PRICE_MULTIPLIER);

        vm.expectRevert(Auction.Auction__PriceMultiplierBelowMin.selector);
        _deployAuction(INIT_PRICE, LOT_SIZE, EPOCH_PERIOD, 1_099_999_999_999_999_999);

        vm.expectRevert(Auction.Auction__PriceMultiplierExceedsMax.selector);
        _deployAuction(INIT_PRICE, LOT_SIZE, EPOCH_PERIOD, 3e18 + 1);
    }

    function testPolicyConfiguresMinterDependencyAndPermission() public view {
        assertEq(address(auction.minter()), address(minter));
        assertTrue(controller.isPolicyActive(address(auction)));
        assertEq(Keycode.unwrap(auction.KEYCODE()), Keycode.unwrap(toKeycode("AUCTN")));
        assertTrue(controller.modulePermissions(toKeycode("MINTR"), address(auction), Minter.mint.selector));

        Permissions[] memory permissions = auction.requestPermissions();
        assertEq(permissions.length, 1);
        assertEq(Keycode.unwrap(permissions[0].keycode), Keycode.unwrap(toKeycode("MINTR")));
        assertEq(permissions[0].funcSelector, Minter.mint.selector);
    }

    function testGetPriceDecaysToMinimumScalar() public {
        IController.Backing[] memory price = auction.getPrice();
        assertEq(price.length, 1);
        assertEq(price[0].asset, address(asset));
        assertEq(price[0].backingPerToken, 2 ether);

        vm.warp(auction.startTime() + EPOCH_PERIOD / 4);
        price = auction.getPrice();
        assertEq(price[0].backingPerToken, 1.5 ether);

        vm.warp(auction.startTime() + EPOCH_PERIOD);
        price = auction.getPrice();
        assertEq(price[0].backingPerToken, 1.1 ether);
    }

    function testBuyMintsTokensPullsPaymentAndUpdatesAccounting() public {
        uint256 mintAmount = 10 ether;
        uint256 paymentAmount = _currentPaymentAmount(mintAmount);
        uint256 protocolFee = _protocolFee(paymentAmount);
        uint256 netPayment = paymentAmount - protocolFee;

        _fundAndApproveBuyer(paymentAmount);

        uint256 epoch = auction.epochId();
        vm.prank(buyer);
        IController.Receipt[] memory receipts = auction.buy(epoch, block.timestamp, mintAmount);

        assertEq(receipts.length, 1);
        assertEq(receipts[0].asset, address(asset));
        assertEq(receipts[0].amount, paymentAmount);
        assertEq(token.balanceOf(buyer), mintAmount);
        assertEq(token.totalSupply(), INITIAL_SUPPLY + mintAmount);
        assertEq(auction.remainingLot(), LOT_SIZE - mintAmount);

        assertEq(asset.balanceOf(buyer), 0);
        assertEq(asset.balanceOf(protocolCollector), protocolFee);
        assertEq(asset.balanceOf(address(vault)), INITIAL_BACKING + netPayment);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_BACKING + netPayment);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 0);
    }

    function testFullLotPurchaseAdvancesEpochAndResetsLot() public {
        vm.warp(auction.startTime() + 1);
        uint256 paymentAmount = _currentPaymentAmount(LOT_SIZE);
        _fundAndApproveBuyer(paymentAmount);

        uint256 epoch = auction.epochId();
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp, LOT_SIZE);

        assertEq(auction.epochId(), 1);
        assertEq(auction.remainingLot(), LOT_SIZE);
        assertEq(auction.startTime(), block.timestamp);
        assertEq(token.balanceOf(buyer), LOT_SIZE);
    }

    function testStartNextAuctionRequiresElapsedEpoch() public {
        vm.expectRevert(Auction.Auction__OngoingAuction.selector);
        auction.startNextAuction();

        vm.warp(auction.startTime() + EPOCH_PERIOD + 1);
        auction.startNextAuction();

        assertEq(auction.epochId(), 1);
        assertEq(auction.remainingLot(), LOT_SIZE);
        assertEq(auction.startTime(), block.timestamp);
    }

    function testBuyRevertsForDeadlineEpochAndLotGuards() public {
        uint256 epoch = auction.epochId();

        vm.expectRevert(Auction.Auction__DeadlinePassed.selector);
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp - 1, 1 ether);

        vm.expectRevert(Auction.Auction__EpochIdMismatch.selector);
        vm.prank(buyer);
        auction.buy(epoch + 1, block.timestamp, 1 ether);

        vm.expectRevert(Auction.Auction__TooManyTokens.selector);
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp, LOT_SIZE + 1);
    }

    function testBuyRevertsWhenNoRegisteredAssets() public {
        address[] memory emptyAssets = new address[](0);
        _setAssets(emptyAssets);

        uint256 epoch = auction.epochId();
        vm.expectRevert(Auction.Auction__EmptyAssets.selector);
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp, 1 ether);
    }

    function _deployAuction(uint256 initPrice, uint256 lotSize, uint256 epochPeriod, uint256 priceMultiplier)
        internal
        returns (Auction)
    {
        return new Auction(address(controller), initPrice, lotSize, epochPeriod, priceMultiplier);
    }

    function _currentPaymentAmount(uint256 mintAmount) internal view returns (uint256) {
        IController.Backing[] memory price = auction.getPrice();
        assertEq(price.length, 1);
        return price[0].backingPerToken * mintAmount / WAD;
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

    function _protocolFee(uint256 amount) internal pure returns (uint256) {
        uint256 product = amount * AUCTION_FEE_BPS;
        uint256 result = product / BPS;
        if (product % BPS != 0) {
            unchecked {
                ++result;
            }
        }
        return result;
    }
}
