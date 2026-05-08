///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IBorrower} from "../src/interfaces/IBorrower.sol";
import {Borrower} from "../src/modules/BRWR/Borrower.sol";
import {Controller} from "enten-v1/Controller.sol";
import {EntenToken} from "enten-v1/EntenToken.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Module} from "enten-v1/Module.sol";
import {Policy} from "enten-v1/Policy.sol";
import {Vault} from "enten-v1/Vault.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IVault} from "enten-v1/interfaces/IVault.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Actions, Keycode, Permissions} from "enten-v1/Utils.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Test} from "forge-std/Test.sol";

contract BorrowerTestPolicy is Policy {
    Keycode internal constant BRWR_KEYCODE = Keycode.wrap("BRRWR");

    constructor(address controller) Policy(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap("BRPOL");
    }

    function configureDependencies() external pure override returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](1);
        dependencies[0] = BRWR_KEYCODE;
    }

    function requestPermissions() external pure override returns (Permissions[] memory requests) {
        requests = new Permissions[](1);
        requests[0] = Permissions({keycode: BRWR_KEYCODE, funcSelector: Borrower.executeBorrowAction.selector});
    }

    function executeBorrowAction(IBorrower.Action action, address user, IBorrower.ActionData memory actionData)
        external
    {
        Borrower(getModuleAddress(BRWR_KEYCODE)).executeBorrowAction(action, user, abi.encode(actionData));
    }
}

contract BorrowerHarness is Borrower {
    constructor(address controller, address kernel) Borrower(controller, kernel) {}

    function buildUpdatedPosition(
        IBorrower.Action action,
        IBorrower.UserPosition memory oldPosition,
        IBorrower.ActionData memory actionData
    ) external pure returns (IBorrower.UserPosition memory) {
        return _buildUpdatedPosition(action, oldPosition, actionData);
    }

    function updatedSlots(
        IBorrower.UserPosition memory oldPosition,
        IBorrower.UserPosition memory newPosition,
        uint256 startingSlot
    ) external pure returns (IController.StateUpdate[] memory) {
        return _updatedSlots(oldPosition, newPosition, startingSlot);
    }

    function buildAndUpdatedSlots(
        IBorrower.Action action,
        IBorrower.UserPosition memory oldPosition,
        IBorrower.ActionData memory actionData,
        uint256 startingSlot
    ) external pure returns (IBorrower.UserPosition memory, IController.StateUpdate[] memory) {
        IBorrower.UserPosition memory updatedPosition = _buildUpdatedPosition(action, oldPosition, actionData);
        return (updatedPosition, _updatedSlots(oldPosition, updatedPosition, startingSlot));
    }
}

contract BorrowerTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    EntenToken internal token;
    BorrowerHarness internal borrower;
    BorrowerTestPolicy internal policy;
    ERC20Mock internal asset;
    ERC20Mock internal secondAsset;
    ERC20Mock internal thirdAsset;

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
        token = new EntenToken("Enten", "ENTEN", predictedController, user, INITIAL_SUPPLY, type(uint256).max);
        controller = new Controller(admin, protocolCollector, predictedKernel, predictedVault, predictedToken);

        borrower = new BorrowerHarness(address(controller), address(kernel));
        policy = new BorrowerTestPolicy(address(controller));
        asset = new ERC20Mock();
        secondAsset = new ERC20Mock();
        thirdAsset = new ERC20Mock();

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(borrower));
        controller.executeAction(Actions.ActivatePolicy, address(policy));
        vm.stopPrank();

        _setAssets(address(asset));
    }

    function testDepositUpdatesPositionAndReceivesTokenCollateral() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _approveToken(user, 100 ether);

        _execute(IBorrower.Action.Deposit, user, 100 ether, new IController.Receipt[](0));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 0);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 100 ether);
        assertEq(token.balanceOf(address(vault)), 100 ether);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(token)), 100 ether);
        assertEq(uint256(kernel.viewData(_userSlot(user))), 100 ether);
        assertEq(uint256(kernel.viewData(bytes32(uint256(_userSlot(user)) + 1))), 0);
    }

    function testBuildUpdatedPositionIncreasesExistingDebtInMemory() public view {
        IBorrower.DebtPosition[] memory debt = new IBorrower.DebtPosition[](1);
        debt[0] = IBorrower.DebtPosition({asset: address(asset), amount: 40 ether});
        IBorrower.UserPosition memory oldPosition = IBorrower.UserPosition({collateral: 100 ether, debt: debt});

        IBorrower.UserPosition memory updatedPosition = borrower.buildUpdatedPosition(
            IBorrower.Action.Borrow,
            oldPosition,
            IBorrower.ActionData({collateralAmount: 0, receipts: _oneReceipt(address(asset), 15 ether)})
        );

        assertEq(oldPosition.debt[0].amount, 40 ether);
        assertEq(updatedPosition.debt.length, 1);
        assertEq(updatedPosition.debt[0].asset, address(asset));
        assertEq(updatedPosition.debt[0].amount, 55 ether);
    }

    function testBuildAndUpdatedSlotsDetectsExistingDebtAmountChange() public view {
        IBorrower.DebtPosition[] memory debt = new IBorrower.DebtPosition[](1);
        debt[0] = IBorrower.DebtPosition({asset: address(asset), amount: 40 ether});
        IBorrower.UserPosition memory oldPosition = IBorrower.UserPosition({collateral: 100 ether, debt: debt});

        (IBorrower.UserPosition memory updatedPosition, IController.StateUpdate[] memory updates) = borrower.buildAndUpdatedSlots(
            IBorrower.Action.Borrow,
            oldPosition,
            IBorrower.ActionData({collateralAmount: 0, receipts: _oneReceipt(address(asset), 15 ether)}),
            1000
        );

        assertEq(oldPosition.debt[0].amount, 40 ether);
        assertEq(updatedPosition.debt[0].amount, 55 ether);
        assertEq(updates.length, 1);
        assertEq(updates[0].slot, bytes32(uint256(1003)));
        assertEq(updates[0].data, bytes32(uint256(55 ether)));
    }

    function testUpdatedSlotsDetectsExplicitExistingDebtAmountChange() public view {
        IBorrower.DebtPosition[] memory oldDebt = new IBorrower.DebtPosition[](1);
        oldDebt[0] = IBorrower.DebtPosition({asset: address(asset), amount: 40 ether});
        IBorrower.UserPosition memory oldPosition = IBorrower.UserPosition({collateral: 100 ether, debt: oldDebt});

        IBorrower.DebtPosition[] memory newDebt = new IBorrower.DebtPosition[](1);
        newDebt[0] = IBorrower.DebtPosition({asset: address(asset), amount: 55 ether});
        IBorrower.UserPosition memory newPosition = IBorrower.UserPosition({collateral: 100 ether, debt: newDebt});

        IController.StateUpdate[] memory updates = borrower.updatedSlots(oldPosition, newPosition, 1000);

        assertEq(updates.length, 1);
        assertEq(updates[0].slot, bytes32(uint256(1003)));
        assertEq(updates[0].data, bytes32(uint256(55 ether)));
    }

    function testDepositAndBorrowExistingDebtBuildsOnlyCollateralAndAmountUpdates() public view {
        IBorrower.DebtPosition[] memory debt = new IBorrower.DebtPosition[](1);
        debt[0] = IBorrower.DebtPosition({asset: address(asset), amount: 40 ether});
        IBorrower.UserPosition memory oldPosition = IBorrower.UserPosition({collateral: 100 ether, debt: debt});

        (IBorrower.UserPosition memory updatedPosition, IController.StateUpdate[] memory updates) = borrower.buildAndUpdatedSlots(
            IBorrower.Action.DepositAndBorrow,
            oldPosition,
            IBorrower.ActionData({collateralAmount: 25 ether, receipts: _oneReceipt(address(asset), 15 ether)}),
            1000
        );

        assertEq(updatedPosition.collateral, 125 ether);
        assertEq(updatedPosition.debt.length, 1);
        assertEq(updatedPosition.debt[0].amount, 55 ether);
        assertEq(updates.length, 2);
        assertEq(updates[0].slot, bytes32(uint256(1000)));
        assertEq(updates[0].data, bytes32(uint256(125 ether)));
        assertEq(updates[1].slot, bytes32(uint256(1003)));
        assertEq(updates[1].data, bytes32(uint256(55 ether)));
    }

    function testRepayAndWithdrawToZeroDebtBuildsOnlyCollateralAndAmountUpdates() public view {
        IBorrower.DebtPosition[] memory debt = new IBorrower.DebtPosition[](1);
        debt[0] = IBorrower.DebtPosition({asset: address(asset), amount: 40 ether});
        IBorrower.UserPosition memory oldPosition = IBorrower.UserPosition({collateral: 100 ether, debt: debt});

        (IBorrower.UserPosition memory updatedPosition, IController.StateUpdate[] memory updates) = borrower.buildAndUpdatedSlots(
            IBorrower.Action.RepayAndWithdraw,
            oldPosition,
            IBorrower.ActionData({collateralAmount: 60 ether, receipts: _oneReceipt(address(asset), 40 ether)}),
            1000
        );

        assertEq(updatedPosition.collateral, 40 ether);
        assertEq(updatedPosition.debt.length, 1);
        assertEq(updatedPosition.debt[0].asset, address(asset));
        assertEq(updatedPosition.debt[0].amount, 0);
        assertEq(updates.length, 2);
        assertEq(updates[0].slot, bytes32(uint256(1000)));
        assertEq(updates[0].data, bytes32(uint256(40 ether)));
        assertEq(updates[1].slot, bytes32(uint256(1003)));
        assertEq(updates[1].data, bytes32(uint256(0)));
    }

    function testAppendSecondDebtBuildsOnlyLengthAssetAndAmountUpdates() public view {
        IBorrower.DebtPosition[] memory debt = new IBorrower.DebtPosition[](1);
        debt[0] = IBorrower.DebtPosition({asset: address(asset), amount: 40 ether});
        IBorrower.UserPosition memory oldPosition = IBorrower.UserPosition({collateral: 100 ether, debt: debt});

        (IBorrower.UserPosition memory updatedPosition, IController.StateUpdate[] memory updates) = borrower.buildAndUpdatedSlots(
            IBorrower.Action.Borrow,
            oldPosition,
            IBorrower.ActionData({collateralAmount: 0, receipts: _oneReceipt(address(secondAsset), 30 ether)}),
            1000
        );

        assertEq(updatedPosition.debt.length, 2);
        assertEq(updatedPosition.debt[0].asset, address(asset));
        assertEq(updatedPosition.debt[0].amount, 40 ether);
        assertEq(updatedPosition.debt[1].asset, address(secondAsset));
        assertEq(updatedPosition.debt[1].amount, 30 ether);
        assertEq(updates.length, 3);
        assertEq(updates[0].slot, bytes32(uint256(1001)));
        assertEq(updates[0].data, bytes32(uint256(2)));
        assertEq(updates[1].slot, bytes32(uint256(1004)));
        assertEq(updates[1].data, bytes32(uint256(uint160(address(secondAsset)))));
        assertEq(updates[2].slot, bytes32(uint256(1005)));
        assertEq(updates[2].data, bytes32(uint256(30 ether)));
    }

    function testAppendThirdDebtBuildsOnlyLengthAssetAndAmountUpdates() public view {
        IBorrower.DebtPosition[] memory debt = new IBorrower.DebtPosition[](2);
        debt[0] = IBorrower.DebtPosition({asset: address(asset), amount: 40 ether});
        debt[1] = IBorrower.DebtPosition({asset: address(secondAsset), amount: 30 ether});
        IBorrower.UserPosition memory oldPosition = IBorrower.UserPosition({collateral: 100 ether, debt: debt});

        (IBorrower.UserPosition memory updatedPosition, IController.StateUpdate[] memory updates) = borrower.buildAndUpdatedSlots(
            IBorrower.Action.Borrow,
            oldPosition,
            IBorrower.ActionData({collateralAmount: 0, receipts: _oneReceipt(address(thirdAsset), 20 ether)}),
            1000
        );

        assertEq(updatedPosition.debt.length, 3);
        assertEq(updatedPosition.debt[0].asset, address(asset));
        assertEq(updatedPosition.debt[0].amount, 40 ether);
        assertEq(updatedPosition.debt[1].asset, address(secondAsset));
        assertEq(updatedPosition.debt[1].amount, 30 ether);
        assertEq(updatedPosition.debt[2].asset, address(thirdAsset));
        assertEq(updatedPosition.debt[2].amount, 20 ether);
        assertEq(updates.length, 3);
        assertEq(updates[0].slot, bytes32(uint256(1001)));
        assertEq(updates[0].data, bytes32(uint256(3)));
        assertEq(updates[1].slot, bytes32(uint256(1006)));
        assertEq(updates[1].data, bytes32(uint256(uint160(address(thirdAsset)))));
        assertEq(updates[2].slot, bytes32(uint256(1007)));
        assertEq(updates[2].data, bytes32(uint256(20 ether)));
    }

    function testUpdatedSlotsRevertsWhenExistingDebtAssetChanges() public {
        IBorrower.DebtPosition[] memory oldDebt = new IBorrower.DebtPosition[](1);
        oldDebt[0] = IBorrower.DebtPosition({asset: address(asset), amount: 40 ether});
        IBorrower.UserPosition memory oldPosition = IBorrower.UserPosition({collateral: 100 ether, debt: oldDebt});

        IBorrower.DebtPosition[] memory newDebt = new IBorrower.DebtPosition[](1);
        newDebt[0] = IBorrower.DebtPosition({asset: address(secondAsset), amount: 40 ether});
        IBorrower.UserPosition memory newPosition = IBorrower.UserPosition({collateral: 100 ether, debt: newDebt});

        vm.expectRevert(IBorrower.Borrower__DebtAssetChanged.selector);
        borrower.updatedSlots(oldPosition, newPosition, 1000);
    }

    function testUpdatedSlotsRevertsWhenNewDebtLengthShrinks() public {
        IBorrower.DebtPosition[] memory oldDebt = new IBorrower.DebtPosition[](2);
        oldDebt[0] = IBorrower.DebtPosition({asset: address(asset), amount: 40 ether});
        oldDebt[1] = IBorrower.DebtPosition({asset: address(secondAsset), amount: 30 ether});
        IBorrower.UserPosition memory oldPosition = IBorrower.UserPosition({collateral: 100 ether, debt: oldDebt});

        IBorrower.DebtPosition[] memory newDebt = new IBorrower.DebtPosition[](1);
        newDebt[0] = IBorrower.DebtPosition({asset: address(asset), amount: 40 ether});
        IBorrower.UserPosition memory newPosition = IBorrower.UserPosition({collateral: 100 ether, debt: newDebt});

        vm.expectRevert(IBorrower.Borrower__DebtAssetChanged.selector);
        borrower.updatedSlots(oldPosition, newPosition, 1000);
    }

    function testNoOpDebtReceiptsDoNotBuildStateUpdates() public view {
        IBorrower.DebtPosition[] memory debt = new IBorrower.DebtPosition[](1);
        debt[0] = IBorrower.DebtPosition({asset: address(asset), amount: 40 ether});
        IBorrower.UserPosition memory oldPosition = IBorrower.UserPosition({collateral: 100 ether, debt: debt});

        (IBorrower.UserPosition memory borrowedPosition, IController.StateUpdate[] memory borrowUpdates) = borrower.buildAndUpdatedSlots(
            IBorrower.Action.Borrow,
            oldPosition,
            IBorrower.ActionData({collateralAmount: 0, receipts: _oneReceipt(address(asset), 0)}),
            1000
        );
        assertEq(borrowedPosition.collateral, 100 ether);
        assertEq(borrowedPosition.debt.length, 1);
        assertEq(borrowedPosition.debt[0].amount, 40 ether);
        assertEq(borrowUpdates.length, 0);

        (IBorrower.UserPosition memory repaidPosition, IController.StateUpdate[] memory repayUpdates) = borrower.buildAndUpdatedSlots(
            IBorrower.Action.Repay,
            oldPosition,
            IBorrower.ActionData({collateralAmount: 0, receipts: _oneReceipt(address(asset), 0)}),
            1000
        );
        assertEq(repaidPosition.collateral, 100 ether);
        assertEq(repaidPosition.debt.length, 1);
        assertEq(repaidPosition.debt[0].amount, 40 ether);
        assertEq(repayUpdates.length, 0);
    }

    function testBorrowAppendsDebtAndTransfersBacking() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);

        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 60 ether));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 60 ether);
        assertEq(asset.balanceOf(user), 60 ether);
        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY - 60 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY - 60 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 60 ether);

        bytes32 userSlot = _userSlot(user);
        assertEq(uint256(kernel.viewData(userSlot)), 100 ether);
        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 1))), 1);
        assertEq(address(uint160(uint256(kernel.viewData(bytes32(uint256(userSlot) + 2))))), address(asset));
        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 3))), 60 ether);
    }

    function testBorrowExistingDebtOnlyUpdatesAmountSlot() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 40 ether));

        bytes32 userSlot = _userSlot(user);
        bytes32 assetWordBefore = kernel.viewData(bytes32(uint256(userSlot) + 2));

        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 15 ether));

        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 1))), 1);
        assertEq(kernel.viewData(bytes32(uint256(userSlot) + 2)), assetWordBefore);
        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 3))), 55 ether);
        assertEq(asset.balanceOf(user), 55 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 55 ether);
    }

    function testBorrowWithMultipleReceiptsForDifferentAssets() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _seedBacking(secondAsset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);

        _execute(
            IBorrower.Action.Borrow, user, 0, _twoReceipts(address(asset), 40 ether, address(secondAsset), 30 ether)
        );

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 2);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 40 ether);
        assertEq(position.debt[1].asset, address(secondAsset));
        assertEq(position.debt[1].amount, 30 ether);
        assertEq(asset.balanceOf(user), 40 ether);
        assertEq(secondAsset.balanceOf(user), 30 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 40 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(secondAsset)), 30 ether);

        bytes32 userSlot = _userSlot(user);
        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 1))), 2);
        assertEq(address(uint160(uint256(kernel.viewData(bytes32(uint256(userSlot) + 2))))), address(asset));
        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 3))), 40 ether);
        assertEq(address(uint160(uint256(kernel.viewData(bytes32(uint256(userSlot) + 4))))), address(secondAsset));
        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 5))), 30 ether);
    }

    function testBorrowWithMultipleReceiptsForSameAssetAggregatesDebt() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);

        _execute(IBorrower.Action.Borrow, user, 0, _twoReceipts(address(asset), 25 ether, address(asset), 15 ether));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 40 ether);
        assertEq(asset.balanceOf(user), 40 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 40 ether);

        bytes32 userSlot = _userSlot(user);
        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 1))), 1);
        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 3))), 40 ether);
    }

    function testBorrowWithMixedExistingAndNewDebtReceipts() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _seedBacking(secondAsset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 20 ether));

        bytes32 userSlot = _userSlot(user);
        bytes32 assetWordBefore = kernel.viewData(bytes32(uint256(userSlot) + 2));

        _execute(
            IBorrower.Action.Borrow, user, 0, _twoReceipts(address(asset), 15 ether, address(secondAsset), 25 ether)
        );

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.debt.length, 2);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 35 ether);
        assertEq(position.debt[1].asset, address(secondAsset));
        assertEq(position.debt[1].amount, 25 ether);
        assertEq(asset.balanceOf(user), 35 ether);
        assertEq(secondAsset.balanceOf(user), 25 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 35 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(secondAsset)), 25 ether);
        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 1))), 2);
        assertEq(kernel.viewData(bytes32(uint256(userSlot) + 2)), assetWordBefore);
        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 3))), 35 ether);
        assertEq(address(uint160(uint256(kernel.viewData(bytes32(uint256(userSlot) + 4))))), address(secondAsset));
        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 5))), 25 ether);
    }

    function testBorrowValidatesEachAssetAgainstMultiAssetBacking() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _seedBacking(secondAsset, INITIAL_SUPPLY / 2);
        _depositCollateral(100 ether);

        _execute(
            IBorrower.Action.Borrow, user, 0, _twoReceipts(address(asset), 80 ether, address(secondAsset), 50 ether)
        );

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.debt.length, 2);
        assertEq(position.debt[0].amount, 80 ether);
        assertEq(position.debt[1].amount, 50 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 80 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(secondAsset)), 50 ether);
    }

    function testBorrowRevertsWhenOneAssetExceedsItsMultiAssetBackingLimit() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _seedBacking(secondAsset, INITIAL_SUPPLY / 2);
        _depositCollateral(100 ether);

        vm.expectRevert(IBorrower.Borrower__PositionNotCollateralized.selector);
        _execute(
            IBorrower.Action.Borrow, user, 0, _twoReceipts(address(asset), 80 ether, address(secondAsset), 50 ether + 1)
        );

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 0);
        assertEq(asset.balanceOf(user), 0);
        assertEq(secondAsset.balanceOf(user), 0);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(secondAsset)), 0);
    }

    function testValidationAggregatesDuplicateDebtEntriesForSameAsset() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);

        IBorrower.DebtPosition[] memory debt = new IBorrower.DebtPosition[](2);
        debt[0] = IBorrower.DebtPosition({asset: address(asset), amount: 60 ether});
        debt[1] = IBorrower.DebtPosition({asset: address(asset), amount: 40 ether});
        _writePosition(user, 100 ether, debt);

        vm.expectRevert(IBorrower.Borrower__PositionNotCollateralized.selector);
        _execute(IBorrower.Action.Withdraw, user, 1, new IController.Receipt[](0));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 2);
        assertEq(position.debt[0].amount, 60 ether);
        assertEq(position.debt[1].amount, 40 ether);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 100 ether);
        assertEq(token.balanceOf(address(vault)), 100 ether);
    }

    function testFullRepayLeavesInactiveDebtSlotAndCanReuseIt() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 60 ether));

        _approveAsset(user, asset, 60 ether);
        _execute(IBorrower.Action.Repay, user, 0, _oneReceipt(address(asset), 60 ether));

        bytes32 userSlot = _userSlot(user);
        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 1))), 1);
        assertEq(address(uint160(uint256(kernel.viewData(bytes32(uint256(userSlot) + 2))))), address(asset));
        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 3))), 0);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY);

        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 25 ether));

        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 1))), 1);
        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 3))), 25 ether);
        assertEq(asset.balanceOf(user), 25 ether);
    }

    function testRepayMoreThanOwedRevertsAndLeavesStateUnchanged() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 40 ether));

        vm.expectRevert(IBorrower.Borrower__RepayTooMuch.selector);
        _execute(IBorrower.Action.Repay, user, 0, _oneReceipt(address(asset), 40 ether + 1));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].amount, 40 ether);
        assertEq(asset.balanceOf(user), 40 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 40 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY - 40 ether);
    }

    function testRepayMissingDebtAssetRevertsAndLeavesStateUnchanged() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _seedBacking(secondAsset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 40 ether));

        vm.expectRevert(IBorrower.Borrower__DebtAssetNotFound.selector);
        _execute(IBorrower.Action.Repay, user, 0, _oneReceipt(address(secondAsset), 1 ether));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 40 ether);
        assertEq(asset.balanceOf(user), 40 ether);
        assertEq(secondAsset.balanceOf(user), 0);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 40 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(secondAsset)), 0);
    }

    function testRepayZeroAmountLeavesPositionAndAccountingUnchanged() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 40 ether));

        IBorrower.UserPosition memory oldPosition = borrower.positions(user);
        (IBorrower.UserPosition memory updatedPosition, IController.StateUpdate[] memory updates) = borrower.buildAndUpdatedSlots(
            IBorrower.Action.Repay,
            oldPosition,
            IBorrower.ActionData({collateralAmount: 0, receipts: _oneReceipt(address(asset), 0)}),
            uint256(_userSlot(user))
        );
        assertEq(updatedPosition.debt[0].amount, 40 ether);
        assertEq(updates.length, 0);

        _execute(IBorrower.Action.Repay, user, 0, _oneReceipt(address(asset), 0));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].amount, 40 ether);
        assertEq(asset.balanceOf(user), 40 ether);
        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY - 40 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 40 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY - 40 ether);
    }

    function testBorrowZeroAddressAssetRevertsAndLeavesStateUnchanged() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);

        vm.expectRevert(IBorrower.Borrower__DebtAssetZeroAddress.selector);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(0), 1 ether));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 0);
        assertEq(asset.balanceOf(user), 0);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 0);
    }

    function testRepayZeroAddressAssetRevertsAndLeavesStateUnchanged() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 40 ether));

        vm.expectRevert(IBorrower.Borrower__DebtAssetZeroAddress.selector);
        _execute(IBorrower.Action.Repay, user, 0, _oneReceipt(address(0), 1 ether));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].amount, 40 ether);
        assertEq(asset.balanceOf(user), 40 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 40 ether);
    }

    function testDepositAndBorrowUpdatesCollateralDebtAndFlows() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _approveToken(user, 100 ether);

        _execute(IBorrower.Action.DepositAndBorrow, user, 100 ether, _oneReceipt(address(asset), 40 ether));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 40 ether);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 100 ether);
        assertEq(token.balanceOf(address(vault)), 100 ether);
        assertEq(asset.balanceOf(user), 40 ether);
        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY - 40 ether);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(token)), 100 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 40 ether);
    }

    function testWithdrawRevertsIfPositionWouldBecomeUndercollateralized() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 60 ether));

        vm.expectRevert(IBorrower.Borrower__PositionNotCollateralized.selector);
        _execute(IBorrower.Action.Withdraw, user, 50 ether, new IController.Receipt[](0));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt[0].amount, 60 ether);
        assertEq(token.balanceOf(address(vault)), 100 ether);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 100 ether);
    }

    function testRepayAndWithdrawUpdatesDebtCollateralAndFlows() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 60 ether));

        _approveAsset(user, asset, 30 ether);
        _execute(IBorrower.Action.RepayAndWithdraw, user, 70 ether, _oneReceipt(address(asset), 30 ether));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 30 ether);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].amount, 30 ether);
        assertEq(asset.balanceOf(user), 30 ether);
        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY - 30 ether);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 30 ether);
        assertEq(token.balanceOf(address(vault)), 30 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY - 30 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 30 ether);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(token)), 30 ether);
    }

    function testRepayAndWithdrawToZeroDebtLeavesAssetSlotAndZerosAmount() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 40 ether));

        bytes32 userSlot = _userSlot(user);
        bytes32 assetWordBefore = kernel.viewData(bytes32(uint256(userSlot) + 2));

        _approveAsset(user, asset, 40 ether);
        _execute(IBorrower.Action.RepayAndWithdraw, user, 60 ether, _oneReceipt(address(asset), 40 ether));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 40 ether);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 0);
        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 1))), 1);
        assertEq(kernel.viewData(bytes32(uint256(userSlot) + 2)), assetWordBefore);
        assertEq(uint256(kernel.viewData(bytes32(uint256(userSlot) + 3))), 0);
        assertEq(asset.balanceOf(user), 0);
        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 40 ether);
        assertEq(token.balanceOf(address(vault)), 40 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(token)), 40 ether);
    }

    function testActiveDebtWithZeroTokenSupplyReverts() public {
        _burnToken(user, INITIAL_SUPPLY);

        IBorrower.DebtPosition[] memory debt = new IBorrower.DebtPosition[](1);
        debt[0] = IBorrower.DebtPosition({asset: address(asset), amount: 1 ether});
        _writePosition(user, 100 ether, debt);

        vm.expectRevert(IBorrower.Borrower__ZeroTokenSupply.selector);
        _execute(IBorrower.Action.Withdraw, user, 0, new IController.Receipt[](0));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 1 ether);
        assertEq(token.totalSupply(), 0);
    }

    function testActiveDebtWithNoRegisteredAssetsRevertsAsNotBacked() public {
        address[] memory assets = new address[](0);
        _setAssets(assets);

        IBorrower.DebtPosition[] memory debt = new IBorrower.DebtPosition[](1);
        debt[0] = IBorrower.DebtPosition({asset: address(asset), amount: 1 ether});
        _writePosition(user, 100 ether, debt);

        vm.expectRevert(IBorrower.Borrower__DebtAssetNotBacked.selector);
        _execute(IBorrower.Action.Withdraw, user, 0, new IController.Receipt[](0));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 1 ether);
    }

    function testBorrowAtExactCollateralBackedLimitPasses() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);

        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 100 ether));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 100 ether);
        assertEq(asset.balanceOf(user), 100 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 100 ether);
    }

    function testBorrowOneWeiOverCollateralBackedLimitReverts() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);

        vm.expectRevert(IBorrower.Borrower__PositionNotCollateralized.selector);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 100 ether + 1));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 0);
        assertEq(asset.balanceOf(user), 0);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY);
    }

    function testBorrowRoundingSensitiveLimitUsesRoundedDownBackingPerToken() public {
        uint256 roundedBorrowLimit = 100 ether - 100;
        _seedBacking(asset, INITIAL_SUPPLY - 1);
        _depositCollateral(100 ether);

        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), roundedBorrowLimit));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].amount, roundedBorrowLimit);
        assertEq(asset.balanceOf(user), roundedBorrowLimit);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), roundedBorrowLimit);

        vm.expectRevert(IBorrower.Borrower__PositionNotCollateralized.selector);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 1));

        position = borrower.positions(user);
        assertEq(position.debt[0].amount, roundedBorrowLimit);
        assertEq(asset.balanceOf(user), roundedBorrowLimit);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), roundedBorrowLimit);
    }

    function testWithdrawToExactMinimumValidCollateralPassesThenOneWeiBelowReverts() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 60 ether));

        _execute(IBorrower.Action.Withdraw, user, 40 ether, new IController.Receipt[](0));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 60 ether);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].amount, 60 ether);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 60 ether);
        assertEq(token.balanceOf(address(vault)), 60 ether);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(token)), 60 ether);

        vm.expectRevert(IBorrower.Borrower__PositionNotCollateralized.selector);
        _execute(IBorrower.Action.Withdraw, user, 1, new IController.Receipt[](0));

        position = borrower.positions(user);
        assertEq(position.collateral, 60 ether);
        assertEq(position.debt[0].amount, 60 ether);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 60 ether);
        assertEq(token.balanceOf(address(vault)), 60 ether);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(token)), 60 ether);
    }

    function testBorrowRevertsWhenDebtExceedsCollateralBackingValue() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(50 ether);

        vm.expectRevert(IBorrower.Borrower__PositionNotCollateralized.selector);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 51 ether));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 50 ether);
        assertEq(position.debt.length, 0);
        assertEq(asset.balanceOf(user), 0);
        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 0);
    }

    function testBorrowUnsupportedAssetRevertsBeforeTransfers() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);

        vm.expectRevert(IBorrower.Borrower__DebtAssetNotBacked.selector);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(secondAsset), 10 ether));

        assertEq(secondAsset.balanceOf(user), 0);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(secondAsset)), 0);
    }

    function testDepositWithReceiptsRequiresDepositAndBorrowAction() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _approveToken(user, 100 ether);

        vm.expectRevert(IBorrower.Borrower__UseDepositAndBorrow.selector);
        _execute(IBorrower.Action.Deposit, user, 100 ether, _oneReceipt(address(asset), 10 ether));
    }

    function testDepositWithInsufficientCollateralAllowanceRevertsAtomically() public {
        _seedBacking(asset, INITIAL_SUPPLY);

        vm.expectRevert();
        _execute(IBorrower.Action.Deposit, user, 100 ether, new IController.Receipt[](0));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 0);
        assertEq(position.debt.length, 0);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(token)), 0);
    }

    function testRepayWithInsufficientAssetAllowanceRevertsAtomically() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 40 ether));

        vm.expectRevert();
        _execute(IBorrower.Action.Repay, user, 0, _oneReceipt(address(asset), 20 ether));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 1);
        assertEq(position.debt[0].amount, 40 ether);
        assertEq(asset.balanceOf(user), 40 ether);
        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY - 40 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 40 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY - 40 ether);
    }

    function testBorrowWithoutEnoughVaultBackingRevertsAtomically() public {
        _setBucket(IVault.Bucket.Redeem, address(asset), INITIAL_SUPPLY);
        _depositCollateral(100 ether);

        vm.expectRevert();
        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), 40 ether));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 0);
        assertEq(asset.balanceOf(user), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY);
    }

    function testDirectUnpermissionedExecuteBorrowActionReverts() public {
        bytes memory data =
            abi.encode(IBorrower.ActionData({collateralAmount: 0, receipts: new IController.Receipt[](0)}));

        vm.expectRevert(abi.encodeWithSelector(Module.Module__PolicyNotPermitted.selector, address(this)));
        borrower.executeBorrowAction(IBorrower.Action.Deposit, user, data);

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 0);
        assertEq(position.debt.length, 0);
    }

    function testPositionsDecodesMultipleDebtEntriesFromRawKernelSlots() public {
        IBorrower.DebtPosition[] memory debt = new IBorrower.DebtPosition[](2);
        debt[0] = IBorrower.DebtPosition({asset: address(asset), amount: 40 ether});
        debt[1] = IBorrower.DebtPosition({asset: address(secondAsset), amount: 30 ether});
        _writePosition(user, 100 ether, debt);

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 2);
        assertEq(position.debt[0].asset, address(asset));
        assertEq(position.debt[0].amount, 40 ether);
        assertEq(position.debt[1].asset, address(secondAsset));
        assertEq(position.debt[1].amount, 30 ether);
    }

    function testPositionsDecodesEmptyPosition() public view {
        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 0);
        assertEq(position.debt.length, 0);
    }

    function testMalformedActionDataRevertsWithoutStateOrTokenChanges() public {
        _seedBacking(asset, INITIAL_SUPPLY);

        vm.prank(address(policy));
        vm.expectRevert();
        borrower.executeBorrowAction(IBorrower.Action.Deposit, user, hex"1234");

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 0);
        assertEq(position.debt.length, 0);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(token)), 0);
    }

    function testUnsupportedExternalRawActionRevertsBeforeStateChanges() public {
        bytes memory data =
            abi.encode(IBorrower.ActionData({collateralAmount: 0, receipts: new IController.Receipt[](0)}));

        vm.prank(address(policy));
        (bool success, bytes memory revertData) =
            address(borrower).call(abi.encodeWithSelector(Borrower.executeBorrowAction.selector, uint8(6), user, data));

        assertFalse(success);
        assertEq(revertData.length, 0);

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 0);
        assertEq(position.debt.length, 0);
    }

    function testControllerSettlementFailureLeavesBorrowerPositionUnchanged() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        _depositCollateral(100 ether);

        vm.expectRevert();
        _execute(IBorrower.Action.DepositAndBorrow, user, 10 ether, _oneReceipt(address(asset), 20 ether));

        IBorrower.UserPosition memory position = borrower.positions(user);
        assertEq(position.collateral, 100 ether);
        assertEq(position.debt.length, 0);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 100 ether);
        assertEq(token.balanceOf(address(vault)), 100 ether);
        assertEq(asset.balanceOf(user), 0);
        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(token)), 100 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY);
    }

    function _depositCollateral(uint256 amount) internal {
        _approveToken(user, amount);
        _execute(IBorrower.Action.Deposit, user, amount, new IController.Receipt[](0));
    }

    function _execute(
        IBorrower.Action action,
        address account,
        uint256 collateralAmount,
        IController.Receipt[] memory receipts
    ) internal {
        policy.executeBorrowAction(
            action, account, IBorrower.ActionData({collateralAmount: collateralAmount, receipts: receipts})
        );
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

    function _approveToken(address account, uint256 amount) internal {
        vm.prank(account);
        token.approve(address(vault), amount);
    }

    function _approveAsset(address account, ERC20Mock token_, uint256 amount) internal {
        vm.prank(account);
        token_.approve(address(vault), amount);
    }

    function _burnToken(address account, uint256 amount) internal {
        vm.prank(address(controller));
        token.burnFrom(account, amount);
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

    function _writePosition(address account, uint256 collateral, IBorrower.DebtPosition[] memory debt) internal {
        bytes32 userSlot = _userSlot(account);

        vm.startPrank(address(controller));
        kernel.updateState(userSlot, bytes32(collateral));
        kernel.updateState(bytes32(uint256(userSlot) + 1), bytes32(debt.length));

        for (uint256 i; i < debt.length;) {
            uint256 assetSlot = uint256(userSlot) + 2 + (i * 2);
            kernel.updateState(bytes32(assetSlot), bytes32(uint256(uint160(debt[i].asset))));
            kernel.updateState(bytes32(assetSlot + 1), bytes32(debt[i].amount));

            unchecked {
                ++i;
            }
        }

        vm.stopPrank();
    }

    function _bucketValue(IVault.Bucket bucket, address token_) internal view returns (uint256) {
        return uint256(kernel.viewData(_bucketSlot(bucket, token_)));
    }

    function _bucketSlot(IVault.Bucket bucket, address token_) internal pure returns (bytes32) {
        if (bucket == IVault.Bucket.Borrow) return _slot(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, token_);
        if (bucket == IVault.Bucket.Redeem) return _slot(Slots.BACKING_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Treasury) return _slot(Slots.TREASURY_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Team) return _slot(Slots.TEAM_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Collateral) return _slot(Slots.TOTAL_COLLATERL_SLOT, token_);
        revert("invalid bucket");
    }

    function _slot(bytes32 namespace, address token_) internal pure returns (bytes32) {
        return keccak256(abi.encode(namespace, token_));
    }

    function _userSlot(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode(Slots.USER_POSITION_BASE_SLOT, account));
    }
}
