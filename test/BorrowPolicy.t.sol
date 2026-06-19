///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BorrowPolicy} from "../src/policies/BorrowPolicy.sol";
import {Borrower} from "../src/modules/BRWR/Borrower.sol";
import {Admin} from "../src/modules/ADMIN/Admin.sol";
import {Gateway} from "../src/policies/Gateway.sol";
import {IBorrower} from "../src/interfaces/IBorrower.sol";
import {Controller} from "enten-v1/Controller.sol";
import {Token} from "enten-v1/Token.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Vault} from "enten-v1/Vault.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IVault} from "enten-v1/interfaces/IVault.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Actions, Keycode, Permissions} from "enten-v1/Utils.sol";
import {AssetNotBorrowable} from "../src/Utils.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract BorrowPolicyTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    Token internal token;
    Borrower internal borrower;
    BorrowPolicy internal policy;
    ERC20Mock internal asset;
    ERC20Mock internal secondAsset;

    address internal admin = makeAddr("Admin");
    address internal user = makeAddr("User");
    address internal protocolCollector = makeAddr("Protocol Collector");

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedToken = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedController = vm.computeCreateAddress(address(this), nonce + 3);

        kernel = new Kernel(predictedController, predictedVault);
        vault = new Vault(predictedController, predictedKernel);
        token = new Token("Enten", "ENTEN", predictedController, user, INITIAL_SUPPLY, type(uint256).max);
        controller = new Controller(admin, protocolCollector, predictedKernel, predictedVault, predictedToken, 0);

        borrower = new Borrower(address(controller));
        policy = new BorrowPolicy(address(controller));
        asset = new ERC20Mock();
        secondAsset = new ERC20Mock();

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(borrower));
        controller.executeAction(Actions.ActivatePolicy, address(policy));
        vm.stopPrank();
    }

    function testPolicyConfiguresBorrowerDependencyAndPermission() public view {
        assertEq(address(policy.borrowerModule()), address(borrower));
        assertTrue(Keycode.unwrap(policy.KEYCODE()) == 0x4252504f4c);

        Permissions[] memory permissions = policy.requestPermissions();
        assertEq(permissions.length, 1);
        assertTrue(Keycode.unwrap(permissions[0].keycode) == 0x4252525752);
        assertEq(permissions[0].funcSelector, Borrower.executeBorrowAction.selector);
    }

    function testDepositWrapperRoutesThroughModule() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 0);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 100 ether);
        assertEq(token.balanceOf(address(vault)), 100 ether);
    }

    function testWithdrawWrapperRoutesThroughModule() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);

        vm.prank(user);
        policy.withdraw(40 ether);

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 60 ether);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 60 ether);
        assertEq(token.balanceOf(address(vault)), 60 ether);
    }

    function testDepositAndBorrowWrapperRoutesThroughModule() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);

        vm.prank(user);
        token.approve(address(vault), 100 ether);

        vm.prank(user);
        policy.depositAndBorrow(100 ether, _oneReceipt(address(asset), 40 ether));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 40 ether);
        assertEq(asset.balanceOf(user), 40 ether);
    }

    function testRepayAndWithdrawWrapperRoutesThroughModule() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _borrow(_oneReceipt(address(asset), 40 ether));
        _approveAsset(asset, 25 ether);

        vm.prank(user);
        policy.repayAndWithdraw(_oneReceipt(address(asset), 25 ether), 50 ether);

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 50 ether);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 15 ether);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 50 ether);
        assertEq(asset.balanceOf(user), 15 ether);
    }

    function testTotalCollateralReadsTokenCollateralBucket() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(123 ether);

        assertEq(policy.totalCollateral(address(token)), 123 ether);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(token)), 123 ether);
    }

    function testRepayAllStillClearsDebtIfRawAssetRegistryNoLongerContainsDebtAsset() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _borrow(_oneReceipt(address(asset), 40 ether));
        _approveAsset(asset, 40 ether);

        address[] memory remainingAssets = new address[](1);
        remainingAssets[0] = address(secondAsset);
        _setAssets(remainingAssets);

        vm.prank(user);
        policy.repayAll();

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 0);
        assertEq(asset.balanceOf(user), 0);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY);
    }

    function testPartialRepayOfRawRemovedAssetIsBlockedByPolicyAssetValidation() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _borrow(_oneReceipt(address(asset), 40 ether));
        _approveAsset(asset, 10 ether);

        address[] memory remainingAssets = new address[](1);
        remainingAssets[0] = address(secondAsset);
        _setAssets(remainingAssets);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AssetNotBorrowable.selector, address(asset)));
        policy.repay(_oneReceipt(address(asset), 10 ether));
    }

    function testFuzzBorrowLimitMatchesModuleEnforcedRoundedCapacity(uint96 collateralSeed, uint96 backingSeed) public {
        uint256 collateral = bound(uint256(collateralSeed), 1, INITIAL_SUPPLY);
        uint256 backing = bound(uint256(backingSeed), 1, INITIAL_SUPPLY * 5);
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, backing);
        _depositCollateral(collateral);

        uint256 maxBorrow = policy.maxBorrowForAsset(user, address(asset));
        uint256 expectedMax = Math.mulDiv(collateral, Math.mulDiv(backing, 1e18, INITIAL_SUPPLY), 1e18);
        assertEq(maxBorrow, expectedMax);

        if (maxBorrow != 0) {
            _borrow(_oneReceipt(address(asset), maxBorrow));
            assertEq(policy.currentDebtForAsset(user, address(asset)), maxBorrow);
        }

        vm.prank(user);
        vm.expectRevert(IBorrower.Borrower__PositionNotCollateralized.selector);
        policy.borrow(_oneReceipt(address(asset), 1));
    }

    function testBorrowableReturnsFullCapacityForAssetsWithoutDebt() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _seedBacking(secondAsset, 500 ether);
        _depositCollateral(100 ether);

        IController.Receipt[] memory receipts = policy.borrowable(user);

        assertEq(receipts.length, 2);
        assertEq(receipts[0].asset, address(asset));
        assertEq(receipts[0].amount, 100 ether);
        assertEq(receipts[1].asset, address(secondAsset));
        assertEq(receipts[1].amount, 50 ether);
    }

    function testBorrowableSubtractsExistingDebtAndOmitsMaxedAssets() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _seedBacking(secondAsset, 500 ether);
        _depositCollateral(100 ether);
        _borrow(_oneReceipt(address(asset), 100 ether));

        IController.Receipt[] memory receipts = policy.borrowable(user);

        assertEq(receipts.length, 1);
        assertEq(receipts[0].asset, address(secondAsset));
        assertEq(receipts[0].amount, 50 ether);
    }

    function testBorrowMaxBorrowsOnlyRemainingCapacityThroughModule() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _seedBacking(secondAsset, 500 ether);
        _depositCollateral(100 ether);
        _borrow(_oneReceipt(address(asset), 40 ether));

        vm.prank(user);
        policy.borrowMax();

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 2);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 100 ether);
        assertEq(position.debt[1].asset, address(secondAsset));
        assertEq(position.debt[1].amount, 50 ether);
        assertEq(asset.balanceOf(user), 100 ether);
        assertEq(secondAsset.balanceOf(user), 50 ether);
    }

    function testBorrowableReturnsEmptyWhenUserHasNoCollateral() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _seedBacking(secondAsset, 500 ether);

        IController.Receipt[] memory receipts = policy.borrowable(user);

        assertEq(receipts.length, 0);
    }

    function testBorrowMaxDoesNotChangePositionWhenAlreadyMaxed() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _seedBacking(secondAsset, 500 ether);
        _depositCollateral(100 ether);
        _borrow(_twoReceipts(address(asset), 100 ether, address(secondAsset), 50 ether));

        vm.prank(user);
        policy.borrowMax();

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 2);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 100 ether);
        assertEq(position.debt[1].asset, address(secondAsset));
        assertEq(position.debt[1].amount, 50 ether);
        assertEq(asset.balanceOf(user), 100 ether);
        assertEq(secondAsset.balanceOf(user), 50 ether);
    }

    function testBorrowableIncludesAssetWhenDebtEntryExistsAtZero() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _seedBacking(secondAsset, 500 ether);
        _depositCollateral(100 ether);
        _borrow(_oneReceipt(address(asset), 40 ether));
        _approveAsset(asset, 40 ether);

        vm.prank(user);
        policy.repay(_oneReceipt(address(asset), 40 ether));

        IController.Receipt[] memory receipts = policy.borrowable(user);

        assertEq(receipts.length, 2);
        assertEq(receipts[0].asset, address(asset));
        assertEq(receipts[0].amount, 100 ether);
        assertEq(receipts[1].asset, address(secondAsset));
        assertEq(receipts[1].amount, 50 ether);
    }

    function testBorrowableForAssetAndDebtViewsMatchPosition() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _seedBacking(secondAsset, 500 ether);
        _depositCollateral(100 ether);
        _borrow(_oneReceipt(address(asset), 40 ether));

        assertEq(policy.maxBorrowForAsset(user, address(asset)), 100 ether);
        assertEq(policy.borrowableForAsset(user, address(asset)), 60 ether);
        assertEq(policy.currentDebtForAsset(user, address(asset)), 40 ether);
        assertEq(policy.maxBorrowForAsset(user, address(secondAsset)), 50 ether);
        assertEq(policy.borrowableForAsset(user, address(secondAsset)), 50 ether);
        assertEq(policy.currentDebtForAsset(user, address(secondAsset)), 0);
    }

    function testBorrowRejectsAssetThatIsNotBorrowable() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        ERC20Mock unsupportedAsset = new ERC20Mock();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AssetNotBorrowable.selector, address(unsupportedAsset)));
        policy.borrow(_oneReceipt(address(unsupportedAsset), 1 ether));
    }

    function testRepayAllRepaysOnlyNonZeroDebtsThroughModule() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _seedBacking(secondAsset, 500 ether);
        _depositCollateral(100 ether);
        _borrow(_twoReceipts(address(asset), 40 ether, address(secondAsset), 10 ether));
        _approveAsset(asset, 40 ether);
        _approveAsset(secondAsset, 10 ether);

        vm.prank(user);
        policy.repayAll();

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 2);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 0);
        assertEq(position.debt[1].asset, address(secondAsset));
        assertEq(position.debt[1].amount, 0);
        assertEq(asset.balanceOf(user), 0);
        assertEq(secondAsset.balanceOf(user), 0);
    }

    function testFractionalBackingRoundsMaxBorrowDown() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY / 3);
        _seedBacking(secondAsset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);

        uint256 expectedMax = _expectedBorrowLimit(100 ether, INITIAL_SUPPLY / 3);

        assertEq(policy.maxBorrowForAsset(user, address(asset)), expectedMax);
        assertEq(policy.borrowableForAsset(user, address(asset)), expectedMax);
    }

    function testBorrowingExactlyRoundedMaxSucceedsAndMaxPlusOneReverts() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY / 3);
        _seedBacking(secondAsset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);

        uint256 roundedMax = _expectedBorrowLimit(100 ether, INITIAL_SUPPLY / 3);

        _borrow(_oneReceipt(address(asset), roundedMax));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, roundedMax);

        vm.prank(user);
        vm.expectRevert(IBorrower.Borrower__PositionNotCollateralized.selector);
        policy.borrow(_oneReceipt(address(asset), 1));
    }

    function testBorrowMaxUsesFractionalBackingCapacity() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, 500 ether);
        _seedBacking(secondAsset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);

        vm.prank(user);
        policy.borrowMax();

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.debt.length, 2);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 50 ether);
        assertEq(position.debt[1].asset, address(secondAsset));
        assertEq(position.debt[1].amount, 100 ether);
    }

    function testTinyCollateralAndLowBackingRoundsBorrowableToZero() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, 1);
        _depositCollateral(1);

        assertEq(policy.maxBorrowForAsset(user, address(asset)), 0);
        assertEq(policy.borrowableForAsset(user, address(asset)), 0);

        IController.Receipt[] memory receipts = policy.borrowable(user);
        assertEq(receipts.length, 0);

        vm.prank(user);
        policy.borrowMax();

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 1);
        assertEq(position.debt.length, 0);
    }

    function testBorrowableReturnsHeterogeneousPerAssetCapacities() public {
        ERC20Mock thirdAsset = new ERC20Mock();
        address[] memory assets = new address[](3);
        assets[0] = address(asset);
        assets[1] = address(secondAsset);
        assets[2] = address(thirdAsset);
        _setAssets(assets);
        _seedBacking(asset, 500 ether);
        _seedBacking(secondAsset, INITIAL_SUPPLY);
        _seedBacking(thirdAsset, 3_000 ether);
        _depositCollateral(100 ether);

        IController.Receipt[] memory receipts = policy.borrowable(user);

        assertEq(receipts.length, 3);
        assertEq(receipts[0].asset, address(asset));
        assertEq(receipts[0].amount, 50 ether);
        assertEq(receipts[1].asset, address(secondAsset));
        assertEq(receipts[1].amount, 100 ether);
        assertEq(receipts[2].asset, address(thirdAsset));
        assertEq(receipts[2].amount, 300 ether);
    }

    function testBorrowMaxSubtractsExistingDebtUnderFractionalBacking() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, 500 ether);
        _depositCollateral(100 ether);
        _borrow(_oneReceipt(address(asset), 20 ether));

        assertEq(policy.borrowableForAsset(user, address(asset)), 30 ether);

        vm.prank(user);
        policy.borrowMax();

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 50 ether);
        assertEq(asset.balanceOf(user), 50 ether);
    }

    function testFullSupplyBorrowMaxExhaustsAllBackingWithoutOverborrowing() public {
        ERC20Mock thirdAsset = new ERC20Mock();
        address[] memory assets = new address[](3);
        assets[0] = address(asset);
        assets[1] = address(secondAsset);
        assets[2] = address(thirdAsset);
        _setAssets(assets);
        _seedBacking(asset, 500 ether);
        _seedBacking(secondAsset, INITIAL_SUPPLY);
        _seedBacking(thirdAsset, 3_000 ether);
        _depositCollateral(INITIAL_SUPPLY);

        vm.prank(user);
        policy.borrowMax();

        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 500 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(secondAsset)), INITIAL_SUPPLY);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(secondAsset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(thirdAsset)), 3_000 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(thirdAsset)), 0);
        assertEq(asset.balanceOf(user), 500 ether);
        assertEq(secondAsset.balanceOf(user), INITIAL_SUPPLY);
        assertEq(thirdAsset.balanceOf(user), 3_000 ether);
    }

    function testPartialParticipationCanOnlyBorrowProRataBackingShare() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, 500 ether);
        _seedBacking(secondAsset, 200 ether);
        _depositCollateral(100 ether);

        vm.prank(user);
        policy.borrowMax();

        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 50 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 450 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(secondAsset)), 20 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(secondAsset)), 180 ether);
        assertEq(asset.balanceOf(user), 50 ether);
        assertEq(secondAsset.balanceOf(user), 20 ether);
    }

    function testBorrowCapacityIsProportionalAcrossMultipleUsers() public {
        address alice = makeAddr("Alice");
        address bob = makeAddr("Bob");
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, 500 ether);
        _seedBacking(secondAsset, 200 ether);

        vm.startPrank(user);
        assertTrue(token.transfer(alice, 100 ether));
        assertTrue(token.transfer(bob, 300 ether));
        vm.stopPrank();

        _depositCollateralFor(alice, 100 ether);
        _depositCollateralFor(bob, 300 ether);

        _borrowMaxFor(alice);
        _borrowMaxFor(bob);

        assertEq(policy.maxBorrowForAsset(alice, address(asset)), 50 ether);
        assertEq(policy.maxBorrowForAsset(bob, address(asset)), 150 ether);
        assertEq(policy.maxBorrowForAsset(alice, address(secondAsset)), 20 ether);
        assertEq(policy.maxBorrowForAsset(bob, address(secondAsset)), 60 ether);
        assertEq(asset.balanceOf(alice), 50 ether);
        assertEq(asset.balanceOf(bob), 150 ether);
        assertEq(secondAsset.balanceOf(alice), 20 ether);
        assertEq(secondAsset.balanceOf(bob), 60 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 200 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 300 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(secondAsset)), 80 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(secondAsset)), 120 ether);
    }

    function testEndToEndBorrowLifecycleThroughGatewayRegisteredAssets() public {
        _registerAssetsThroughGateway(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _seedBacking(secondAsset, 500 ether);

        _depositCollateral(200 ether);
        _borrow(_oneReceipt(address(asset), 60 ether));

        vm.prank(user);
        policy.borrowMax();

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 200 ether);
        assertEq(position.debt.length, 2);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 200 ether);
        assertEq(position.debt[1].asset, address(secondAsset));
        assertEq(position.debt[1].amount, 100 ether);

        _approveAsset(asset, 40 ether);
        vm.prank(user);
        policy.repay(_oneReceipt(address(asset), 40 ether));

        position = borrower.positions(user);
        assertEq(position.collateral, 200 ether);
        assertEq(position.debt[0].amount, 160 ether);
        assertEq(position.debt[1].amount, 100 ether);

        _approveAsset(asset, 160 ether);
        _approveAsset(secondAsset, 100 ether);
        vm.prank(user);
        policy.repayAll();

        vm.prank(user);
        policy.withdraw(200 ether);

        position = borrower.positions(user);
        assertEq(position.collateral, 0);
        assertEq(position.debt.length, 2);
        assertEq(position.debt[0].amount, 0);
        assertEq(position.debt[1].amount, 0);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY);
        assertEq(asset.balanceOf(user), 0);
        assertEq(secondAsset.balanceOf(user), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(token)), 0);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(secondAsset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(secondAsset)), 500 ether);
    }

    function testWithdrawCannotMakePositionUndercollateralized() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, 500 ether);
        _depositCollateral(100 ether);
        _borrow(_oneReceipt(address(asset), 50 ether));

        vm.prank(user);
        vm.expectRevert(IBorrower.Borrower__PositionNotCollateralized.selector);
        policy.withdraw(1);

        _approveAsset(asset, 1 ether);
        vm.prank(user);
        policy.repayAndWithdraw(_oneReceipt(address(asset), 1 ether), 2 ether);

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 98 ether);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 49 ether);
    }

    /// @notice Documents M-2: while settlements are paused, a user cannot repay or withdraw — even when the
    ///         position is over-collateralised — so collateral is trapped for the duration of the pause.
    function testRepayAndWithdrawRevertWhileSettlementsPaused() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _borrow(_oneReceipt(address(asset), 40 ether));
        _approveAsset(asset, 40 ether);

        vm.prank(admin);
        controller.setSettlementsPaused(true);

        vm.prank(user);
        vm.expectRevert(IController.Controller__SettlementsPaused.selector);
        policy.repay(_oneReceipt(address(asset), 10 ether));

        vm.prank(user);
        vm.expectRevert(IController.Controller__SettlementsPaused.selector);
        policy.withdraw(1 ether);

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt[0].amount, 40 ether);
    }

    /// @notice Documents M-2: disabling the borrower module blocks repayment the same way.
    function testRepayRevertsWhileBorrowerModuleDisabled() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _borrow(_oneReceipt(address(asset), 40 ether));
        _approveAsset(asset, 40 ether);

        vm.prank(admin);
        controller.setModuleDisabled(Keycode.wrap("BRRWR"), true);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IController.Controller__ModuleDisabled.selector, Keycode.wrap("BRRWR")));
        policy.repay(_oneReceipt(address(asset), 10 ether));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt[0].amount, 40 ether);
    }

    function _depositCollateral(uint256 amount) internal {
        _depositCollateralFor(user, amount);
    }

    function _depositCollateralFor(address account, uint256 amount) internal {
        vm.prank(account);
        token.approve(address(vault), amount);

        vm.prank(account);
        policy.deposit(amount);
    }

    function _borrowMaxFor(address account) internal {
        vm.prank(account);
        policy.borrowMax();
    }

    function _registerAssetsThroughGateway(address first, address second) internal {
        Admin adminModule = new Admin(address(controller));
        Gateway gateway = new Gateway(address(controller), admin);

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(adminModule));
        controller.executeAction(Actions.ActivatePolicy, address(gateway));
        controller.grantRole(controller.EXECUTOR_ROLE(), address(adminModule));
        gateway.addAsset(first, 1e27);
        gateway.addAsset(second, 1e27);
        vm.stopPrank();
    }

    function _borrow(IController.Receipt[] memory receipts) internal {
        vm.prank(user);
        policy.borrow(receipts);
    }

    function _approveAsset(ERC20Mock token_, uint256 amount) internal {
        vm.prank(user);
        token_.approve(address(vault), amount);
    }

    function _oneReceipt(address receiptAsset, uint256 amount)
        internal
        pure
        returns (IController.Receipt[] memory receipts)
    {
        receipts = new IController.Receipt[](1);
        receipts[0] = IController.Receipt({asset: receiptAsset, amount: amount});
    }

    function _twoReceipts(address firstAsset, uint256 firstAmount, address secondAsset_, uint256 secondAmount)
        internal
        pure
        returns (IController.Receipt[] memory receipts)
    {
        receipts = new IController.Receipt[](2);
        receipts[0] = IController.Receipt({asset: firstAsset, amount: firstAmount});
        receipts[1] = IController.Receipt({asset: secondAsset_, amount: secondAmount});
    }

    function _seedBacking(ERC20Mock token_, uint256 amount) internal {
        token_.mint(address(vault), amount);
        _setBucket(IVault.Bucket.Redeem, address(token_), amount);
    }

    function _expectedBorrowLimit(uint256 collateral, uint256 totalBacking) internal pure returns (uint256) {
        uint256 backingPerToken = Math.mulDiv(totalBacking, 1e18, INITIAL_SUPPLY);
        return Math.mulDiv(collateral, backingPerToken, 1e18);
    }

    function _setAssets(address first, address second) internal {
        address[] memory assets = new address[](2);
        assets[0] = first;
        assets[1] = second;
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
        if (bucket == IVault.Bucket.Borrow) return _slot(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, token_);
        if (bucket == IVault.Bucket.Redeem) return _slot(Slots.BACKING_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Treasury) return _slot(Slots.TREASURY_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Team) return _slot(Slots.TEAM_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Collateral) return _slot(Slots.TOTAL_COLLATERAL_SLOT, token_);
        revert("invalid bucket");
    }

    function _slot(bytes32 namespace, address token_) internal pure returns (bytes32) {
        return keccak256(abi.encode(namespace, token_));
    }
}
