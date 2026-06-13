///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Admin} from "../src/modules/ADMIN/Admin.sol";
import {ADMINv1} from "../src/modules/ADMIN/ADMIN.v1.sol";
import {Gateway} from "../src/policies/Gateway.sol";
import {Controller} from "enten-v1/Controller.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Module} from "enten-v1/Module.sol";
import {Policy} from "enten-v1/Policy.sol";
import {Token} from "enten-v1/Token.sol";
import {Vault} from "enten-v1/Vault.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IKernel} from "enten-v1/interfaces/IKernel.sol";
import {Keycode, Permissions, Actions, TargetNotAContract, toKeycode} from "enten-v1/Utils.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {IAccessControl} from "openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Test} from "forge-std/Test.sol";

contract GatewayHarness is Gateway {
    constructor(address controller, address initialAdmin) Gateway(controller, initialAdmin) {}

    function feeRole() external pure returns (bytes32) {
        return FEE_ROLE;
    }

    function upgradeRole() external pure returns (bytes32) {
        return UPGRADE_ROLE;
    }

    function assetRole() external pure returns (bytes32) {
        return ASSET_ROLE;
    }
}

contract AuxiliaryAdminModule is Module {
    constructor(address controller) Module(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return toKeycode("AUXAA");
    }

    function VERSION() external pure override returns (uint8, uint8) {
        return (1, 0);
    }

    function INIT() external override onlyController {}
}

contract AdminTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    Token internal token;
    Admin internal adminModule;
    GatewayHarness internal gateway;
    ERC20Mock internal asset;
    ERC20Mock internal secondAsset;

    address internal controllerAdmin = makeAddr("Controller Admin");
    address internal feeAdmin = makeAddr("Fee Admin");
    address internal assetAdmin = makeAddr("Asset Admin");
    address internal upgrader = makeAddr("Upgrader");
    address internal user = makeAddr("User");
    address internal initialGatewayAdmin = makeAddr("Initial Gateway Admin");
    address internal protocolCollector = makeAddr("Protocol Collector");

    event Gateway__Fees(address indexed feeAdmin, uint256 backing, uint256 team, uint256 treasury);
    event Gateway__AssetAdded(address indexed assetAdmin, address indexed newAsset, uint256 newAssetsLength);

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedToken = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedController = vm.computeCreateAddress(address(this), nonce + 3);

        kernel = new Kernel(predictedController, predictedVault);
        vault = new Vault(predictedController, predictedKernel);
        token = new Token("Enten", "ENTEN", predictedController, user, INITIAL_SUPPLY, type(uint256).max);
        controller =
            new Controller(controllerAdmin, protocolCollector, predictedKernel, predictedVault, predictedToken, 0);

        adminModule = new Admin(address(controller));
        gateway = new GatewayHarness(address(controller), address(this));
        asset = new ERC20Mock();
        secondAsset = new ERC20Mock();

        gateway.grantRole(gateway.feeRole(), feeAdmin);
        gateway.grantRole(gateway.assetRole(), assetAdmin);
        gateway.grantRole(gateway.upgradeRole(), upgrader);

        vm.startPrank(controllerAdmin);
        controller.executeAction(Actions.InstallModule, address(adminModule));
        controller.executeAction(Actions.ActivatePolicy, address(gateway));
        controller.grantRole(controller.EXECUTOR_ROLE(), address(adminModule));
        vm.stopPrank();
    }

    function testAdminModuleMetadataAndGatewayDependencyPermissions() public view {
        assertTrue(Keycode.unwrap(adminModule.KEYCODE()) == 0x41444d494e);
        (uint8 major, uint8 minor) = adminModule.VERSION();
        assertEq(major, 1);
        assertEq(minor, 0);
        assertEq(address(gateway.adminModule()), address(adminModule));

        Permissions[] memory permissions = gateway.requestPermissions();
        assertEq(permissions.length, 2);
        assertTrue(Keycode.unwrap(permissions[0].keycode) == 0x41444d494e);
        assertEq(permissions[0].funcSelector, ADMINv1.updateAdminState.selector);
        assertTrue(Keycode.unwrap(permissions[1].keycode) == 0x41444d494e);
        assertEq(permissions[1].funcSelector, ADMINv1.upgradeSystem.selector);
    }

    function testGatewayConstructorGrantsInitialAdminAllRoles() public {
        GatewayHarness deployedGateway = new GatewayHarness(address(controller), initialGatewayAdmin);

        assertTrue(deployedGateway.hasRole(deployedGateway.DEFAULT_ADMIN_ROLE(), initialGatewayAdmin));
        assertTrue(deployedGateway.hasRole(deployedGateway.feeRole(), initialGatewayAdmin));
        assertTrue(deployedGateway.hasRole(deployedGateway.assetRole(), initialGatewayAdmin));
        assertTrue(deployedGateway.hasRole(deployedGateway.upgradeRole(), initialGatewayAdmin));
        assertFalse(deployedGateway.hasRole(deployedGateway.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function testGatewayConstructorRejectsZeroInitialAdmin() public {
        vm.expectRevert(Gateway.Gateway__InitialAdminZeroAddress.selector);
        new GatewayHarness(address(controller), address(0));
    }

    function testInitialAdminCanGrantAndRevokeOperationalRoles() public {
        GatewayHarness deployedGateway = new GatewayHarness(address(controller), initialGatewayAdmin);
        address operator = makeAddr("Operator");
        bytes32 role = deployedGateway.assetRole();

        vm.prank(initialGatewayAdmin);
        deployedGateway.grantRole(role, operator);
        assertTrue(deployedGateway.hasRole(role, operator));

        vm.prank(initialGatewayAdmin);
        deployedGateway.revokeRole(role, operator);
        assertFalse(deployedGateway.hasRole(role, operator));
    }

    function testNonAdminCannotGrantOperationalRoles() public {
        GatewayHarness deployedGateway = new GatewayHarness(address(controller), initialGatewayAdmin);
        address operator = makeAddr("Operator");
        bytes32 defaultAdminRole = deployedGateway.DEFAULT_ADMIN_ROLE();
        bytes32 feeRole = deployedGateway.feeRole();

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, defaultAdminRole)
        );
        deployedGateway.grantRole(feeRole, operator);
    }

    function testRevokedAssetRoleCanNoLongerAddAssets() public {
        bytes32 role = gateway.assetRole();

        gateway.revokeRole(role, assetAdmin);

        vm.prank(assetAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, assetAdmin, role)
        );
        gateway.addAsset(address(asset));
    }

    function testOperationalRolesAreSeparated() public {
        bytes32 feeRole = gateway.feeRole();
        bytes32 assetRole = gateway.assetRole();
        bytes32 upgradeRole = gateway.upgradeRole();
        ADMINv1.SystemUpgrade[] memory upgrades = new ADMINv1.SystemUpgrade[](0);

        vm.prank(feeAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, feeAdmin, assetRole)
        );
        gateway.addAsset(address(asset));

        vm.prank(assetAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, assetAdmin, feeRole)
        );
        gateway.setFees(9_000, 500, 250);

        vm.prank(feeAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, feeAdmin, upgradeRole)
        );
        gateway.updateSystem(upgrades);
    }

    function testDirectAdminModuleCallsRequireActivePermittedPolicy() public {
        IController.StateUpdate[] memory updates = new IController.StateUpdate[](1);
        updates[0] =
            IController.StateUpdate({op: IController.Op.Set, slot: bytes32(uint256(777)), data: bytes32(uint256(1))});

        vm.expectRevert(abi.encodeWithSelector(Module.Module__PolicyNotPermitted.selector, address(this)));
        adminModule.updateAdminState(updates);

        ADMINv1.SystemUpgrade[] memory upgrades = new ADMINv1.SystemUpgrade[](0);
        vm.expectRevert(abi.encodeWithSelector(Module.Module__PolicyNotPermitted.selector, address(this)));
        adminModule.upgradeSystem(upgrades);
    }

    function testSetFeesStoresInitialFeeSplitOnce() public {
        vm.expectEmit(true, false, false, true, address(gateway));
        emit Gateway__Fees(feeAdmin, 9_000, 500, 250);

        vm.prank(feeAdmin);
        gateway.setFees(9_000, 500, 250);

        assertEq(uint256(kernel.viewData(Slots.BACKING_PERCENTAGE_SLOT)), 9_000);
        assertEq(uint256(kernel.viewData(Slots.TEAM_PERCENTAGE_SLOT)), 500);
        assertEq(uint256(kernel.viewData(Slots.TREASURY_PERCENTAGE_SLOT)), 250);
    }

    function testSetFeesRevertsWhenAdminModuleDisabledAndPreservesState() public {
        Keycode adminKeycode = adminModule.KEYCODE();

        vm.prank(controllerAdmin);
        controller.setModuleDisabled(adminKeycode, true);

        vm.prank(feeAdmin);
        vm.expectRevert(abi.encodeWithSelector(IController.Controller__ModuleDisabled.selector, adminKeycode));
        gateway.setFees(9_000, 500, 250);

        assertEq(uint256(kernel.viewData(Slots.BACKING_PERCENTAGE_SLOT)), 0);
        assertEq(uint256(kernel.viewData(Slots.TEAM_PERCENTAGE_SLOT)), 0);
        assertEq(uint256(kernel.viewData(Slots.TREASURY_PERCENTAGE_SLOT)), 0);
    }

    function testSetFeesRevertsWhenSettlementsPausedAndPreservesState() public {
        vm.prank(controllerAdmin);
        controller.setSettlementsPaused(true);

        vm.prank(feeAdmin);
        vm.expectRevert(IController.Controller__SettlementsPaused.selector);
        gateway.setFees(9_000, 500, 250);

        assertEq(uint256(kernel.viewData(Slots.BACKING_PERCENTAGE_SLOT)), 0);
        assertEq(uint256(kernel.viewData(Slots.TEAM_PERCENTAGE_SLOT)), 0);
        assertEq(uint256(kernel.viewData(Slots.TREASURY_PERCENTAGE_SLOT)), 0);
    }

    function testSetFeesRequiresFeeRole() public {
        bytes32 role = gateway.feeRole();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        gateway.setFees(9_000, 500, 250);
    }

    function testSetFeesRejectsInvalidSplitAndPreservesState() public {
        vm.prank(feeAdmin);
        vm.expectRevert(Gateway.Gateway__InvalidFeeConfiguration.selector);
        gateway.setFees(9_000, 500, 249);

        assertEq(uint256(kernel.viewData(Slots.BACKING_PERCENTAGE_SLOT)), 0);
        assertEq(uint256(kernel.viewData(Slots.TEAM_PERCENTAGE_SLOT)), 0);
        assertEq(uint256(kernel.viewData(Slots.TREASURY_PERCENTAGE_SLOT)), 0);
    }

    function testSetFeesCannotBeCalledAfterAnyFeeWasSet() public {
        _setRawFeeSlots(1, 0, 0);

        vm.prank(feeAdmin);
        vm.expectRevert(Gateway.Gateway__FeesSet.selector);
        gateway.setFees(9_000, 500, 250);
    }

    function testAddAssetAppendsAssetAndIncrementsLength() public {
        vm.expectEmit(true, true, false, true, address(gateway));
        emit Gateway__AssetAdded(assetAdmin, address(asset), 1);

        vm.prank(assetAdmin);
        gateway.addAsset(address(asset));

        assertEq(uint256(kernel.viewData(Slots.ASSETS_LENGTH_SLOT)), 1);
        bytes memory rawAssets = kernel.viewData(Slots.ASSETS_BASE_SLOT, 1);
        assertEq(_addressAt(rawAssets, 0), address(asset));
    }

    function testAddAssetRevertsWhenAdminModuleDisabledAndPreservesState() public {
        Keycode adminKeycode = adminModule.KEYCODE();

        vm.prank(controllerAdmin);
        controller.setModuleDisabled(adminKeycode, true);

        vm.prank(assetAdmin);
        vm.expectRevert(abi.encodeWithSelector(IController.Controller__ModuleDisabled.selector, adminKeycode));
        gateway.addAsset(address(asset));

        assertEq(uint256(kernel.viewData(Slots.ASSETS_LENGTH_SLOT)), 0);
    }

    function testAddAssetRevertsWhenSettlementsPausedAndPreservesState() public {
        vm.prank(controllerAdmin);
        controller.setSettlementsPaused(true);

        vm.prank(assetAdmin);
        vm.expectRevert(IController.Controller__SettlementsPaused.selector);
        gateway.addAsset(address(asset));

        assertEq(uint256(kernel.viewData(Slots.ASSETS_LENGTH_SLOT)), 0);
    }

    function testAddAssetAppendsSecondNonDuplicateAsset() public {
        vm.prank(assetAdmin);
        gateway.addAsset(address(asset));

        vm.prank(assetAdmin);
        gateway.addAsset(address(secondAsset));

        assertEq(uint256(kernel.viewData(Slots.ASSETS_LENGTH_SLOT)), 2);
        bytes memory rawAssets = kernel.viewData(Slots.ASSETS_BASE_SLOT, 2);
        assertEq(_addressAt(rawAssets, 0), address(asset));
        assertEq(_addressAt(rawAssets, 1), address(secondAsset));
    }

    function testAddAssetRequiresAssetRole() public {
        bytes32 role = gateway.assetRole();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        gateway.addAsset(address(asset));
    }

    function testAddAssetRejectsZeroAddress() public {
        vm.prank(assetAdmin);
        vm.expectRevert(Gateway.Gateway__AssetAddressZero.selector);
        gateway.addAsset(address(0));
    }

    function testAddAssetRejectsNonContractAddressAndPreservesLength() public {
        vm.prank(assetAdmin);
        vm.expectRevert(abi.encodeWithSelector(TargetNotAContract.selector, user));
        gateway.addAsset(user);

        assertEq(uint256(kernel.viewData(Slots.ASSETS_LENGTH_SLOT)), 0);
    }

    function testAddAssetRejectsDuplicateAndPreservesLength() public {
        vm.prank(assetAdmin);
        gateway.addAsset(address(asset));

        vm.prank(assetAdmin);
        vm.expectRevert(Gateway.Gateway__DuplicateAsset.selector);
        gateway.addAsset(address(asset));

        assertEq(uint256(kernel.viewData(Slots.ASSETS_LENGTH_SLOT)), 1);
    }

    function testV1AssetRegistryCannotBeDelistedThroughGatewayOrDirectAdminModuleCall() public {
        vm.startPrank(assetAdmin);
        gateway.addAsset(address(asset));
        gateway.addAsset(address(secondAsset));
        vm.stopPrank();

        IController.StateUpdate[] memory updates = new IController.StateUpdate[](2);
        updates[0] = IController.StateUpdate({
            op: IController.Op.Set, slot: Slots.ASSETS_LENGTH_SLOT, data: bytes32(uint256(1))
        });
        updates[1] = IController.StateUpdate({
            op: IController.Op.Set, slot: bytes32(uint256(Slots.ASSETS_BASE_SLOT) + 1), data: bytes32(0)
        });

        vm.prank(assetAdmin);
        vm.expectRevert(abi.encodeWithSelector(Module.Module__PolicyNotPermitted.selector, assetAdmin));
        adminModule.updateAdminState(updates);

        assertEq(uint256(kernel.viewData(Slots.ASSETS_LENGTH_SLOT)), 2);
        bytes memory rawAssets = kernel.viewData(Slots.ASSETS_BASE_SLOT, 2);
        assertEq(_addressAt(rawAssets, 0), address(asset));
        assertEq(_addressAt(rawAssets, 1), address(secondAsset));
    }

    function testUpdateSystemInstallsModuleThroughAdminModule() public {
        AuxiliaryAdminModule auxiliary = new AuxiliaryAdminModule(address(controller));
        ADMINv1.SystemUpgrade[] memory upgrades = new ADMINv1.SystemUpgrade[](1);
        upgrades[0] = ADMINv1.SystemUpgrade({action: Actions.InstallModule, target: address(auxiliary)});

        vm.prank(upgrader);
        gateway.updateSystem(upgrades);

        assertEq(controller.getModuleForKeycode(auxiliary.KEYCODE()), address(auxiliary));
    }

    function testUpdateSystemRequiresUpgradeRole() public {
        ADMINv1.SystemUpgrade[] memory upgrades = new ADMINv1.SystemUpgrade[](0);
        bytes32 role = gateway.upgradeRole();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        gateway.updateSystem(upgrades);
    }

    function testUpdateSystemRevertsForInvalidTargetAndDoesNotInstall() public {
        ADMINv1.SystemUpgrade[] memory upgrades = new ADMINv1.SystemUpgrade[](1);
        upgrades[0] = ADMINv1.SystemUpgrade({action: Actions.InstallModule, target: user});

        vm.prank(upgrader);
        vm.expectRevert(abi.encodeWithSelector(TargetNotAContract.selector, user));
        gateway.updateSystem(upgrades);
    }

    function testUpdateSystemBatchIsAtomicWhenLaterUpgradeReverts() public {
        AuxiliaryAdminModule auxiliary = new AuxiliaryAdminModule(address(controller));
        ADMINv1.SystemUpgrade[] memory upgrades = new ADMINv1.SystemUpgrade[](2);
        upgrades[0] = ADMINv1.SystemUpgrade({action: Actions.InstallModule, target: address(auxiliary)});
        upgrades[1] = ADMINv1.SystemUpgrade({action: Actions.InstallModule, target: user});

        vm.prank(upgrader);
        vm.expectRevert(abi.encodeWithSelector(TargetNotAContract.selector, user));
        gateway.updateSystem(upgrades);

        assertEq(controller.getModuleForKeycode(auxiliary.KEYCODE()), address(0));
    }

    function testUpdateSystemNoOpBatchSucceedsWithoutChangingAdminDependency() public {
        ADMINv1.SystemUpgrade[] memory upgrades = new ADMINv1.SystemUpgrade[](0);

        vm.prank(upgrader);
        gateway.updateSystem(upgrades);

        assertEq(address(gateway.adminModule()), address(adminModule));
    }

    function testGatewayReconfiguresToUpgradedAdminModuleAndCanStillUpdateState() public {
        Admin newAdminModule = new Admin(address(controller));
        ADMINv1.SystemUpgrade[] memory upgrades = new ADMINv1.SystemUpgrade[](1);
        upgrades[0] = ADMINv1.SystemUpgrade({action: Actions.UpgradeModule, target: address(newAdminModule)});

        vm.prank(upgrader);
        gateway.updateSystem(upgrades);

        assertEq(controller.getModuleForKeycode(adminModule.KEYCODE()), address(newAdminModule));
        assertEq(address(gateway.adminModule()), address(newAdminModule));

        vm.prank(assetAdmin);
        gateway.addAsset(address(asset));

        assertEq(uint256(kernel.viewData(Slots.ASSETS_LENGTH_SLOT)), 1);
        bytes memory rawAssets = kernel.viewData(Slots.ASSETS_BASE_SLOT, 1);
        assertEq(_addressAt(rawAssets, 0), address(asset));
    }

    function testUpdateSystemCannotDeactivateInactivePolicyAndLeavesPolicyActive() public {
        GatewayHarness inactiveGateway = new GatewayHarness(address(controller), initialGatewayAdmin);
        ADMINv1.SystemUpgrade[] memory upgrades = new ADMINv1.SystemUpgrade[](1);
        upgrades[0] = ADMINv1.SystemUpgrade({action: Actions.DeactivatePolicy, target: address(inactiveGateway)});

        vm.prank(upgrader);
        vm.expectRevert(
            abi.encodeWithSelector(IController.Controller__PolicyNotActivated.selector, address(inactiveGateway))
        );
        gateway.updateSystem(upgrades);

        assertTrue(controller.isPolicyActive(address(gateway)));
        assertFalse(controller.isPolicyActive(address(inactiveGateway)));
    }

    function _setRawFeeSlots(uint256 backing, uint256 team, uint256 treasury) internal {
        vm.startPrank(address(controller));
        kernel.updateState(Slots.BACKING_PERCENTAGE_SLOT, bytes32(backing));
        kernel.updateState(Slots.TEAM_PERCENTAGE_SLOT, bytes32(team));
        kernel.updateState(Slots.TREASURY_PERCENTAGE_SLOT, bytes32(treasury));
        vm.stopPrank();
    }

    function _addressAt(bytes memory data, uint256 index) internal pure returns (address result) {
        bytes32 word;
        assembly ("memory-safe") {
            word := mload(add(add(data, 0x20), shl(5, index)))
        }
        result = address(uint160(uint256(word)));
    }
}
