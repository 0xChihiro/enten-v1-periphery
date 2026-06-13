///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Admin} from "../src/modules/ADMIN/Admin.sol";
import {ADMINv1} from "../src/modules/ADMIN/ADMIN.v1.sol";
import {Gateway} from "../src/policies/Gateway.sol";
import {SystemUpgradeTimelock} from "../src/governance/SystemUpgradeTimelock.sol";
import {Controller} from "enten-v1/Controller.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Module} from "enten-v1/Module.sol";
import {Token} from "enten-v1/Token.sol";
import {Vault} from "enten-v1/Vault.sol";
import {Actions, Keycode, toKeycode} from "enten-v1/Utils.sol";
import {IAccessControl} from "openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";

contract TimelockGatewayHarness is Gateway {
    constructor(address controller, address initialAdmin) Gateway(controller, initialAdmin) {}

    function upgradeRole() external pure returns (bytes32) {
        return UPGRADE_ROLE;
    }
}

contract TimelockAuxiliaryModule is Module {
    constructor(address controller) Module(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return toKeycode("TLKAA");
    }

    function VERSION() external pure override returns (uint8, uint8) {
        return (1, 0);
    }

    function INIT() external override onlyController {}
}

contract SystemUpgradeTimelockTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    Token internal token;
    Admin internal adminModule;
    TimelockGatewayHarness internal gateway;
    SystemUpgradeTimelock internal timelock;

    address internal controllerAdmin = makeAddr("Controller Admin");
    address internal protocolCollector = makeAddr("Protocol Collector");
    address internal gatewayAdmin = makeAddr("Gateway Admin");
    address internal timelockAdmin = makeAddr("Timelock Admin");
    address internal newTimelockAdmin = makeAddr("New Timelock Admin");
    address internal user = makeAddr("User");
    address internal tokenRecipient = makeAddr("Token Recipient");

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedToken = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedController = vm.computeCreateAddress(address(this), nonce + 3);

        kernel = new Kernel(predictedController, predictedVault);
        vault = new Vault(predictedController, predictedKernel);
        token = new Token("Enten", "ENTEN", predictedController, tokenRecipient, INITIAL_SUPPLY, type(uint256).max);
        controller =
            new Controller(controllerAdmin, protocolCollector, predictedKernel, predictedVault, predictedToken, 0);

        adminModule = new Admin(address(controller));
        gateway = new TimelockGatewayHarness(address(controller), gatewayAdmin);
        timelock = new SystemUpgradeTimelock(address(gateway), timelockAdmin);

        bytes32 upgradeRole = gateway.upgradeRole();
        vm.prank(gatewayAdmin);
        gateway.grantRole(upgradeRole, address(timelock));

        vm.startPrank(controllerAdmin);
        controller.executeAction(Actions.InstallModule, address(adminModule));
        controller.executeAction(Actions.ActivatePolicy, address(gateway));
        controller.grantRole(controller.EXECUTOR_ROLE(), address(adminModule));
        vm.stopPrank();
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(SystemUpgradeTimelock.SystemUpgradeTimelock__ZeroAddress.selector);
        new SystemUpgradeTimelock(address(0), timelockAdmin);

        vm.expectRevert(SystemUpgradeTimelock.SystemUpgradeTimelock__ZeroAddress.selector);
        new SystemUpgradeTimelock(address(gateway), address(0));
    }

    function testAdminCanQueueGatewayUpdateSystemCalldata() public {
        bytes memory data = _installModuleCalldata(new TimelockAuxiliaryModule(address(controller)));

        vm.prank(timelockAdmin);
        bytes32 id = timelock.queue(data);

        assertEq(id, timelock.hashOperation(data));
        assertEq(timelock.executableAt(id), block.timestamp + timelock.DELAY());
        assertFalse(timelock.executed(id));
        assertFalse(timelock.cancelled(id));
    }

    function testNonAdminCannotQueueOrCancel() public {
        bytes memory data = _installModuleCalldata(new TimelockAuxiliaryModule(address(controller)));
        bytes32 id = timelock.hashOperation(data);

        vm.prank(user);
        vm.expectRevert(SystemUpgradeTimelock.SystemUpgradeTimelock__NotAdmin.selector);
        timelock.queue(data);

        vm.prank(timelockAdmin);
        timelock.queue(data);

        vm.prank(user);
        vm.expectRevert(SystemUpgradeTimelock.SystemUpgradeTimelock__NotAdmin.selector);
        timelock.cancel(id);
    }

    function testQueueRejectsWrongSelectorAndDuplicateOperation() public {
        bytes memory wrongSelectorData = abi.encodeWithSelector(Gateway.setFees.selector, 9_000, 500, 250);
        vm.prank(timelockAdmin);
        vm.expectRevert(SystemUpgradeTimelock.SystemUpgradeTimelock__InvalidSelector.selector);
        timelock.queue(wrongSelectorData);

        bytes memory data = _installModuleCalldata(new TimelockAuxiliaryModule(address(controller)));
        vm.startPrank(timelockAdmin);
        timelock.queue(data);
        vm.expectRevert(SystemUpgradeTimelock.SystemUpgradeTimelock__AlreadyQueued.selector);
        timelock.queue(data);
        vm.stopPrank();
    }

    function testExecuteRejectsUnqueuedMutatedOrEarlyOperation() public {
        TimelockAuxiliaryModule auxiliary = new TimelockAuxiliaryModule(address(controller));
        bytes memory data = _installModuleCalldata(auxiliary);
        bytes memory mutatedData = _installModuleCalldata(new TimelockAuxiliaryModule(address(controller)));

        vm.prank(timelockAdmin);
        timelock.queue(data);

        vm.expectRevert(SystemUpgradeTimelock.SystemUpgradeTimelock__NotQueued.selector);
        timelock.execute(mutatedData);

        vm.expectRevert(SystemUpgradeTimelock.SystemUpgradeTimelock__DelayNotElapsed.selector);
        timelock.execute(data);

        assertEq(controller.getModuleForKeycode(auxiliary.KEYCODE()), address(0));
    }

    function testAnyoneCanExecuteQueuedUpgradeAfterDelayOnce() public {
        TimelockAuxiliaryModule auxiliary = new TimelockAuxiliaryModule(address(controller));
        bytes memory data = _installModuleCalldata(auxiliary);

        vm.prank(timelockAdmin);
        bytes32 id = timelock.queue(data);

        vm.warp(block.timestamp + timelock.DELAY());

        vm.prank(user);
        bytes32 executedId = timelock.execute(data);

        assertEq(executedId, id);
        assertTrue(timelock.executed(id));
        assertEq(controller.getModuleForKeycode(auxiliary.KEYCODE()), address(auxiliary));

        vm.expectRevert(SystemUpgradeTimelock.SystemUpgradeTimelock__AlreadyExecuted.selector);
        timelock.execute(data);
    }

    function testPostLaunchRoleTransferLeavesTimelockAsOnlyUpgradePath() public {
        TimelockAuxiliaryModule auxiliary = new TimelockAuxiliaryModule(address(controller));
        bytes memory data = _installModuleCalldata(auxiliary);
        bytes32 upgradeRole = gateway.upgradeRole();

        vm.prank(gatewayAdmin);
        gateway.revokeRole(upgradeRole, gatewayAdmin);

        vm.prank(gatewayAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, gatewayAdmin, upgradeRole)
        );
        gateway.updateSystem(_singleInstallUpgrade(auxiliary));

        vm.prank(timelockAdmin);
        timelock.queue(data);

        vm.warp(block.timestamp + timelock.DELAY());
        timelock.execute(data);

        assertEq(controller.getModuleForKeycode(auxiliary.KEYCODE()), address(auxiliary));
    }

    function testCancelledOperationCannotExecute() public {
        bytes memory data = _installModuleCalldata(new TimelockAuxiliaryModule(address(controller)));

        vm.startPrank(timelockAdmin);
        bytes32 id = timelock.queue(data);
        timelock.cancel(id);
        vm.stopPrank();

        vm.warp(block.timestamp + timelock.DELAY());

        vm.expectRevert(SystemUpgradeTimelock.SystemUpgradeTimelock__Cancelled.selector);
        timelock.execute(data);
    }

    function testCancelledOrExpiredOperationCanBeRequeuedWithFreshDelay() public {
        TimelockAuxiliaryModule cancelledAuxiliary = new TimelockAuxiliaryModule(address(controller));
        bytes memory cancelledData = _installModuleCalldata(cancelledAuxiliary);

        vm.startPrank(timelockAdmin);
        bytes32 cancelledId = timelock.queue(cancelledData);
        timelock.cancel(cancelledId);
        uint256 requeueTime = block.timestamp + 1 days;
        vm.warp(requeueTime);
        timelock.queue(cancelledData);
        vm.stopPrank();

        assertEq(timelock.executableAt(cancelledId), requeueTime + timelock.DELAY());
        assertFalse(timelock.cancelled(cancelledId));

        vm.warp(requeueTime + timelock.DELAY());
        timelock.execute(cancelledData);
        assertEq(controller.getModuleForKeycode(cancelledAuxiliary.KEYCODE()), address(cancelledAuxiliary));

        TimelockAuxiliaryModule expiredAuxiliary = new TimelockAuxiliaryModule(address(controller));
        bytes memory expiredData = _installModuleCalldata(expiredAuxiliary);

        vm.prank(timelockAdmin);
        bytes32 expiredId = timelock.queue(expiredData);

        uint256 expiredRequeueTime = block.timestamp + timelock.DELAY() + timelock.GRACE_PERIOD() + 1;
        vm.warp(expiredRequeueTime);

        vm.prank(timelockAdmin);
        timelock.queue(expiredData);

        assertEq(timelock.executableAt(expiredId), expiredRequeueTime + timelock.DELAY());
    }

    function testExpiredOperationCannotExecute() public {
        bytes memory data = _installModuleCalldata(new TimelockAuxiliaryModule(address(controller)));

        vm.prank(timelockAdmin);
        timelock.queue(data);

        vm.warp(block.timestamp + timelock.DELAY() + timelock.GRACE_PERIOD() + 1);

        vm.expectRevert(SystemUpgradeTimelock.SystemUpgradeTimelock__OperationExpired.selector);
        timelock.execute(data);
    }

    function testExecutionFailureRevertsAndLeavesOperationExecutable() public {
        TimelockAuxiliaryModule auxiliary = new TimelockAuxiliaryModule(address(controller));
        bytes memory data = _installModuleCalldata(auxiliary);
        bytes32 upgradeRole = gateway.upgradeRole();

        vm.prank(gatewayAdmin);
        gateway.revokeRole(upgradeRole, address(timelock));

        vm.prank(timelockAdmin);
        bytes32 id = timelock.queue(data);

        vm.warp(block.timestamp + timelock.DELAY());

        vm.expectRevert(SystemUpgradeTimelock.SystemUpgradeTimelock__ExecutionFailed.selector);
        timelock.execute(data);

        assertFalse(timelock.executed(id));
        assertEq(controller.getModuleForKeycode(auxiliary.KEYCODE()), address(0));
    }

    function testAdminCanTransferTimelockAdmin() public {
        vm.prank(user);
        vm.expectRevert(SystemUpgradeTimelock.SystemUpgradeTimelock__NotAdmin.selector);
        timelock.transferAdmin(newTimelockAdmin);

        vm.prank(timelockAdmin);
        timelock.transferAdmin(newTimelockAdmin);

        assertEq(timelock.admin(), newTimelockAdmin);

        bytes memory data = _installModuleCalldata(new TimelockAuxiliaryModule(address(controller)));
        vm.prank(newTimelockAdmin);
        timelock.queue(data);
    }

    function _installModuleCalldata(TimelockAuxiliaryModule auxiliary) internal pure returns (bytes memory) {
        return abi.encodeCall(Gateway.updateSystem, (_singleInstallUpgrade(auxiliary)));
    }

    function _singleInstallUpgrade(TimelockAuxiliaryModule auxiliary)
        internal
        pure
        returns (ADMINv1.SystemUpgrade[] memory upgrades)
    {
        upgrades = new ADMINv1.SystemUpgrade[](1);
        upgrades[0] = ADMINv1.SystemUpgrade({action: Actions.InstallModule, target: address(auxiliary)});
    }
}
