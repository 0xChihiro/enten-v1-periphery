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
import {Vm} from "forge-std/Vm.sol";

contract AuctionTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;
    uint256 internal constant INITIAL_BACKING = 1_000 ether;
    uint256 internal constant LOT_SIZE = 100 ether;
    uint256 internal constant EPOCH_PERIOD = 10 hours;
    uint256 internal constant PRICE_MULTIPLIER = 2e18;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant AUCTION_FEE_BPS = 250;
    bytes32 internal constant AUCTION_BUY_TOPIC =
        keccak256("Auction__Buy(address,uint256,(address,uint256)[],uint256)");
    bytes32 internal constant AUCTION_START_TOPIC = keccak256("Auction__Start(address,uint256,uint256,uint256)");

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

    event Auction__Start(address indexed starter, uint256 epoch, uint256 startTime, uint256 lotSize);

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
        auction = _deployAuction(LOT_SIZE, EPOCH_PERIOD, PRICE_MULTIPLIER);

        _setAssets(address(asset));
        _seedBacking(asset, INITIAL_BACKING);

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(minter));
        controller.setMintPermission(Keycode.wrap("MINTR"), true);
        controller.executeAction(Actions.ActivatePolicy, address(auction));
        vm.stopPrank();
    }

    function testConstructorStoresInitialAuctionState() public view {
        assertEq(auction.LOT_SIZE(), LOT_SIZE);
        assertEq(auction.remainingLot(), LOT_SIZE);
        assertEq(auction.epochPeriod(), EPOCH_PERIOD);
        assertEq(auction.priceMultiplier(), PRICE_MULTIPLIER);
        assertEq(auction.epochId(), 0);
        assertEq(auction.startTime(), 1_000);
    }

    function testConstructorRejectsInvalidParameters() public {
        vm.expectRevert(Auction.Auction__InvalidLotSize.selector);
        _deployAuction(0, EPOCH_PERIOD, PRICE_MULTIPLIER);

        vm.expectRevert(Auction.Auction__EpochPeriodBelowMin.selector);
        _deployAuction(LOT_SIZE, 1 hours - 1, PRICE_MULTIPLIER);

        vm.expectRevert(Auction.Auction__EpochPeriodExceedsMax.selector);
        _deployAuction(LOT_SIZE, 365 days + 1, PRICE_MULTIPLIER);

        vm.expectRevert(Auction.Auction__PriceMultiplierBelowMin.selector);
        _deployAuction(LOT_SIZE, EPOCH_PERIOD, 1_099_999_999_999_999_999);

        vm.expectRevert(Auction.Auction__PriceMultiplierExceedsMax.selector);
        _deployAuction(LOT_SIZE, EPOCH_PERIOD, 3e18 + 1);
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

    function testGetPriceDecaysToMinimumScalarAndStaysThereAfterExpiry() public {
        IController.Backing[] memory price = auction.getPrice();
        assertEq(price.length, 1);
        assertEq(price[0].asset, address(asset));
        assertEq(price[0].backingPerToken, _grossedPrice(2 ether));

        vm.warp(auction.startTime() + EPOCH_PERIOD / 4);
        price = auction.getPrice();
        assertEq(price[0].backingPerToken, _grossedPrice(1.5 ether));

        vm.warp(auction.startTime() + EPOCH_PERIOD);
        price = auction.getPrice();
        assertEq(price[0].backingPerToken, _grossedPrice(1.1 ether));

        vm.warp(auction.startTime() + EPOCH_PERIOD * 2);
        price = auction.getPrice();
        assertEq(price[0].backingPerToken, _grossedPrice(1.1 ether));
    }

    function testGetPriceGrossesUpForTeamAndTreasuryFees() public {
        uint256 teamBps = 500;
        uint256 treasuryBps = 250;
        _setPaymentBps(teamBps, treasuryBps);

        IController.Backing[] memory price = auction.getPrice();
        assertEq(price.length, 1);
        assertEq(price[0].asset, address(asset));
        assertEq(price[0].backingPerToken, _grossedPrice(2 ether));

        uint256 mintAmount = 10 ether;
        IController.Receipt[] memory maxPayments = _maxPayments(mintAmount);
        uint256 paymentAmount = maxPayments[0].amount;
        uint256 protocolFee = _protocolFee(paymentAmount);
        uint256 netPayment = paymentAmount - protocolFee;
        uint256 teamAmount = netPayment * teamBps / BPS;
        uint256 treasuryAmount = netPayment * treasuryBps / BPS;
        uint256 backingAmount = netPayment - teamAmount - treasuryAmount;

        _fundAndApproveBuyer(paymentAmount);

        uint256 epoch = auction.epochId();
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp, mintAmount, maxPayments);

        assertGe(backingAmount, 20 ether);
        assertEq(asset.balanceOf(protocolCollector), protocolFee);
        assertEq(asset.balanceOf(address(vault)), INITIAL_BACKING + netPayment);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_BACKING + backingAmount);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), treasuryAmount);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), teamAmount);
    }

    function testGetPriceUsesPreviousRoundAverageWhenAboveNav() public {
        IController.Receipt[] memory maxPayments = _maxPayments(LOT_SIZE);
        uint256 previousRoundPayment = maxPayments[0].amount;
        _fundAndApproveBuyer(previousRoundPayment);

        uint256 epoch = auction.epochId();
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp, LOT_SIZE, maxPayments);

        assertEq(auction.previousRoundSold(), LOT_SIZE);
        assertEq(auction.previousRoundRevenue(address(asset)), previousRoundPayment);
        assertEq(auction.sold(), 0);
        assertEq(auction.revenue(address(asset)), 0);

        uint256 previousAveragePrice = _mulDivUp(previousRoundPayment, WAD, LOT_SIZE);

        IController.Backing[] memory price = auction.getPrice();
        assertEq(price.length, 1);
        assertEq(price[0].asset, address(asset));
        assertEq(price[0].backingPerToken, _mulDivUp(previousAveragePrice, PRICE_MULTIPLIER, WAD));

        vm.warp(auction.startTime() + EPOCH_PERIOD / 4);

        price = auction.getPrice();
        assertEq(price[0].backingPerToken, _mulDivUp(previousAveragePrice, 1.5 ether, WAD));
    }

    function testGetPriceKeepsNavFloorWhenCurrentNavExceedsPreviousAverage() public {
        IController.Receipt[] memory maxPayments = _maxPayments(LOT_SIZE);
        uint256 previousRoundPayment = maxPayments[0].amount;
        _fundAndApproveBuyer(previousRoundPayment);

        uint256 epoch = auction.epochId();
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp, LOT_SIZE, maxPayments);

        uint256 targetNav = 3 ether;
        uint256 targetBacking = token.totalSupply() * targetNav / WAD;
        uint256 currentVaultBalance = asset.balanceOf(address(vault));
        if (targetBacking > currentVaultBalance) {
            asset.mint(address(vault), targetBacking - currentVaultBalance);
        }
        _setBucket(IVault.Bucket.Redeem, address(asset), targetBacking);

        IController.Backing[] memory price = auction.getPrice();
        assertEq(price.length, 1);
        assertEq(price[0].asset, address(asset));
        assertEq(price[0].backingPerToken, _grossedPrice(targetNav * PRICE_MULTIPLIER / WAD));
    }

    function testBuyMintsTokensPullsPaymentAndUpdatesAccounting() public {
        uint256 mintAmount = 10 ether;
        IController.Receipt[] memory maxPayments = _maxPayments(mintAmount);
        uint256 paymentAmount = maxPayments[0].amount;
        uint256 protocolFee = _protocolFee(paymentAmount);
        uint256 netPayment = paymentAmount - protocolFee;

        _fundAndApproveBuyer(paymentAmount);

        uint256 epoch = auction.epochId();
        vm.prank(buyer);
        IController.Receipt[] memory receipts = auction.buy(epoch, block.timestamp, mintAmount, maxPayments);

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

    function testFullLotPurchaseAdvancesEpochResetsLotAndEmitsEvents() public {
        vm.warp(auction.startTime() + 1);
        IController.Receipt[] memory maxPayments = _maxPayments(LOT_SIZE);
        uint256 paymentAmount = maxPayments[0].amount;
        _fundAndApproveBuyer(paymentAmount);

        uint256 epoch = auction.epochId();
        vm.recordLogs();
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp, LOT_SIZE, maxPayments);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(auction.epochId(), 1);
        assertEq(auction.remainingLot(), LOT_SIZE);
        assertEq(auction.startTime(), block.timestamp);
        assertEq(token.balanceOf(buyer), LOT_SIZE);
        _assertAuctionBuyLog(entries, buyer, epoch, maxPayments, LOT_SIZE);
        _assertAuctionStartLog(entries, buyer, epoch + 1, block.timestamp, LOT_SIZE);
    }

    function testStartNextAuctionRequiresElapsedEpochAndEmitsStart() public {
        vm.expectRevert(Auction.Auction__OngoingAuction.selector);
        auction.startNextAuction();

        vm.warp(auction.startTime() + EPOCH_PERIOD - 1);
        vm.expectRevert(Auction.Auction__OngoingAuction.selector);
        auction.startNextAuction();

        vm.warp(auction.startTime() + EPOCH_PERIOD);
        vm.expectEmit(true, false, false, true, address(auction));
        emit Auction__Start(address(this), 1, block.timestamp, LOT_SIZE);
        auction.startNextAuction();

        assertEq(auction.epochId(), 1);
        assertEq(auction.remainingLot(), LOT_SIZE);
        assertEq(auction.startTime(), block.timestamp);
    }

    function testBuyRevertsForDeadlineEpochAndLotGuards() public {
        uint256 epoch = auction.epochId();

        vm.expectRevert(Auction.Auction__DeadlinePassed.selector);
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp - 1, 1 ether, _emptyMaxPayments());

        vm.expectRevert(Auction.Auction__EpochIdMismatch.selector);
        vm.prank(buyer);
        auction.buy(epoch + 1, block.timestamp, 1 ether, _emptyMaxPayments());

        vm.expectRevert(Auction.Auction__TooManyTokens.selector);
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp, LOT_SIZE + 1, _emptyMaxPayments());
    }

    function testBuyRevertsForZeroMintAndSlippageGuards() public {
        uint256 epoch = auction.epochId();

        vm.expectRevert(Auction.Auction__InvalidMintAmount.selector);
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp, 0, _emptyMaxPayments());

        uint256 mintAmount = 1 ether;

        vm.expectRevert(Auction.Auction__MaxPaymentsLengthMismatch.selector);
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp, mintAmount, _emptyMaxPayments());

        IController.Receipt[] memory maxPayments = _maxPayments(mintAmount);
        maxPayments[0].asset = address(token);
        vm.expectRevert(Auction.Auction__MaxPaymentAssetMismatch.selector);
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp, mintAmount, maxPayments);

        maxPayments = _maxPayments(mintAmount);
        maxPayments[0].amount -= 1;
        vm.expectRevert(Auction.Auction__MaxPaymentAmountExceeded.selector);
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp, mintAmount, maxPayments);
    }

    function testBuyRevertsOnceAuctionHasExpired() public {
        vm.warp(auction.startTime() + EPOCH_PERIOD);

        uint256 mintAmount = 10 ether;
        IController.Receipt[] memory maxPayments = _maxPayments(mintAmount);
        assertEq(maxPayments[0].amount, _grossedPrice(1.1 ether) * mintAmount / WAD);

        uint256 epoch = auction.epochId();
        vm.expectRevert(Auction.Auction__AuctionExpired.selector);
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp, mintAmount, maxPayments);

        vm.warp(auction.startTime() + EPOCH_PERIOD + 1);
        vm.expectRevert(Auction.Auction__AuctionExpired.selector);
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp, mintAmount, maxPayments);

        assertEq(auction.epochId(), epoch);
        assertEq(auction.remainingLot(), LOT_SIZE);
        assertEq(auction.startTime(), 1_000);
        assertEq(token.balanceOf(buyer), 0);
    }

    function testGetPriceRevertsForUnseededAsset() public {
        _setBucket(IVault.Bucket.Redeem, address(asset), 0);

        vm.expectRevert(Auction.Auction__UnseededAsset.selector);
        auction.getPrice();
    }

    function testBuyRevertsForUnseededAsset() public {
        _setBucket(IVault.Bucket.Redeem, address(asset), 0);

        uint256 epoch = auction.epochId();
        vm.expectRevert(Auction.Auction__UnseededAsset.selector);
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp, 1 ether, _emptyMaxPayments());
    }

    function testGetPriceRevertsForInvalidFeeConfiguration() public {
        _setPaymentBps(BPS, 0);

        vm.expectRevert(Auction.Auction__InvalidFeeConfiguration.selector);
        auction.getPrice();
    }

    function testBuyRevertsWhenNoRegisteredAssets() public {
        address[] memory emptyAssets = new address[](0);
        _setAssets(emptyAssets);

        uint256 epoch = auction.epochId();
        vm.expectRevert(Auction.Auction__EmptyAssets.selector);
        vm.prank(buyer);
        auction.buy(epoch, block.timestamp, 1 ether, _emptyMaxPayments());
    }

    function _deployAuction(uint256 lotSize, uint256 epochPeriod, uint256 priceMultiplier) internal returns (Auction) {
        return new Auction(address(controller), lotSize, epochPeriod, priceMultiplier);
    }

    function _maxPayments(uint256 mintAmount) internal view returns (IController.Receipt[] memory maxPayments) {
        IController.Backing[] memory price = auction.getPrice();
        maxPayments = new IController.Receipt[](price.length);
        for (uint256 i; i < price.length;) {
            maxPayments[i] =
                IController.Receipt({asset: price[i].asset, amount: price[i].backingPerToken * mintAmount / WAD});
            unchecked {
                ++i;
            }
        }
    }

    function _emptyMaxPayments() internal pure returns (IController.Receipt[] memory) {
        return new IController.Receipt[](0);
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

    function _assertAuctionBuyLog(
        Vm.Log[] memory entries,
        address expectedBuyer,
        uint256 expectedEpoch,
        IController.Receipt[] memory expectedPayment,
        uint256 expectedAmountMinted
    ) internal pure {
        bool found;
        bytes32 expectedBuyerTopic = bytes32(uint256(uint160(expectedBuyer)));

        for (uint256 i; i < entries.length;) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == AUCTION_BUY_TOPIC) {
                assertEq(entries[i].topics[1], expectedBuyerTopic);
                (uint256 epoch, IController.Receipt[] memory payment, uint256 amountMinted) =
                    abi.decode(entries[i].data, (uint256, IController.Receipt[], uint256));

                assertEq(epoch, expectedEpoch);
                assertEq(amountMinted, expectedAmountMinted);
                assertEq(payment.length, expectedPayment.length);
                for (uint256 j; j < payment.length;) {
                    assertEq(payment[j].asset, expectedPayment[j].asset);
                    assertEq(payment[j].amount, expectedPayment[j].amount);
                    unchecked {
                        ++j;
                    }
                }

                found = true;
                break;
            }

            unchecked {
                ++i;
            }
        }

        assertTrue(found, "missing buy event");
    }

    function _assertAuctionStartLog(
        Vm.Log[] memory entries,
        address expectedStarter,
        uint256 expectedEpoch,
        uint256 expectedStartTime,
        uint256 expectedLotSize
    ) internal pure {
        bool found;
        bytes32 expectedStarterTopic = bytes32(uint256(uint160(expectedStarter)));

        for (uint256 i; i < entries.length;) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == AUCTION_START_TOPIC) {
                assertEq(entries[i].topics[1], expectedStarterTopic);
                (uint256 epoch, uint256 startTime, uint256 lotSize) =
                    abi.decode(entries[i].data, (uint256, uint256, uint256));

                assertEq(epoch, expectedEpoch);
                assertEq(startTime, expectedStartTime);
                assertEq(lotSize, expectedLotSize);

                found = true;
                break;
            }

            unchecked {
                ++i;
            }
        }

        assertTrue(found, "missing start event");
    }
}
