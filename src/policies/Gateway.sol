///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Policy} from "enten-v1/Policy.sol";
import {ADMINv1} from "../modules/ADMIN/ADMIN.v1.sol";
import {Keycode, Permissions, toKeycode, ensureContract} from "enten-v1/Utils.sol";
import {assets} from "../Utils.sol";
import {IKernel} from "enten-v1/interfaces/IKernel.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {TimelockController} from "openzeppelin/contracts/governance/TimelockController.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";

contract Gateway is Policy, AccessControl {
    bytes32 internal constant FEE_ROLE = keccak256("FEE_ROLE");
    bytes32 internal constant UPGRADE_ROLE = keccak256("UPGRADE_ROLE");
    bytes32 internal constant ASSET_ROLE = keccak256("ASSET_ROLE");
    IKernel public immutable KERNEL;

    ADMINv1 public adminModule;

    error Gateway__FeesSet();
    error Gateway__AssetAddressZero();
    error Gateway__InvalidFeeConfiguration();
    error Gateway__DuplicateAsset();
    error Gateway__InitialAdminZeroAddress();

    event Gateway__Fees(address indexed feeAdmin, uint256 backing, uint256 team, uint256 treasury);
    event Gateway__AssetAdded(address indexed assetAdmin, address indexed newAsset, uint256 newAssetsLength);
    event Gateway__SystemUpgrades(address indexed upgrader, ADMINv1.SystemUpgrade[] upgrades);

    constructor(address controller, address initialAdmin) Policy(controller) {
        if (initialAdmin == address(0)) revert Gateway__InitialAdminZeroAddress();
        KERNEL = IController(controller).KERNEL();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(FEE_ROLE, initialAdmin);
        _grantRole(ASSET_ROLE, initialAdmin);
        _grantRole(UPGRADE_ROLE, initialAdmin);
    }

    function configureDependencies() external override onlyController returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](1);
        dependencies[0] = toKeycode("ADMIN");

        adminModule = ADMINv1(CONTROLLER.getModuleForKeycode(dependencies[0]));
    }

    function requestPermissions() external pure override returns (Permissions[] memory permissions) {
        permissions = new Permissions[](2);
        permissions[0] = Permissions({keycode: toKeycode("ADMIN"), funcSelector: ADMINv1.updateAdminState.selector});
        permissions[1] = Permissions({keycode: toKeycode("ADMIN"), funcSelector: ADMINv1.upgradeSystem.selector});
    }

    function addAsset(address asset) external onlyRole(ASSET_ROLE) {
        if (asset == address(0)) revert Gateway__AssetAddressZero();
        ensureContract(asset);
        if (isDuplicate(asset)) revert Gateway__DuplicateAsset();
        uint256 currentAssetsLen = uint256(KERNEL.viewData(Slots.ASSETS_LENGTH_SLOT));
        bytes32 assetSlot = bytes32(uint256(Slots.ASSETS_BASE_SLOT) + currentAssetsLen);

        IController.StateUpdate[] memory updates = new IController.StateUpdate[](2);
        updates[0] = IController.StateUpdate({
            op: IController.Op.Add, slot: Slots.ASSETS_LENGTH_SLOT, data: bytes32(uint256(1))
        });
        updates[1] =
            IController.StateUpdate({op: IController.Op.Set, slot: assetSlot, data: bytes32(uint256(uint160(asset)))});

        adminModule.updateAdminState(updates);

        emit Gateway__AssetAdded(msg.sender, asset, currentAssetsLen + 1);
    }

    function setFees(uint256 backing, uint256 team, uint256 treasury) external onlyRole(FEE_ROLE) {
        bytes32[] memory feeSlots = new bytes32[](3);
        feeSlots[0] = Slots.BACKING_PERCENTAGE_SLOT;
        feeSlots[1] = Slots.TEAM_PERCENTAGE_SLOT;
        feeSlots[2] = Slots.TREASURY_PERCENTAGE_SLOT;
        bytes32[] memory responses = KERNEL.viewData(feeSlots);
        uint256 sum;
        for (uint256 i = 0; i < responses.length;) {
            sum += uint256(responses[i]);
            unchecked {
                ++i;
            }
        }
        if (sum != 0) revert Gateway__FeesSet();
        // Remaining Percentage after protocol fee
        if (backing + team + treasury != 9750) revert Gateway__InvalidFeeConfiguration();
        IController.StateUpdate[] memory updates = new IController.StateUpdate[](3);
        updates[0] = IController.StateUpdate({
            op: IController.Op.Set, slot: Slots.BACKING_PERCENTAGE_SLOT, data: bytes32(backing)
        });
        updates[1] =
            IController.StateUpdate({op: IController.Op.Set, slot: Slots.TEAM_PERCENTAGE_SLOT, data: bytes32(team)});
        updates[2] = IController.StateUpdate({
            op: IController.Op.Set, slot: Slots.TREASURY_PERCENTAGE_SLOT, data: bytes32(treasury)
        });

        adminModule.updateAdminState(updates);

        emit Gateway__Fees(msg.sender, backing, team, treasury);
    }

    function updateSystem(ADMINv1.SystemUpgrade[] calldata upgrades) external onlyRole(UPGRADE_ROLE) {
        adminModule.upgradeSystem(upgrades);

        emit Gateway__SystemUpgrades(msg.sender, upgrades);
    }

    function isDuplicate(address asset) internal view returns (bool) {
        address[] memory assetList = assets(KERNEL);
        for (uint256 i = 0; i < assetList.length;) {
            if (asset == assetList[i]) {
                return true;
            }

            unchecked {
                ++i;
            }
        }
        return false;
    }
}
