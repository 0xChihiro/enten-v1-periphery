///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Policy} from "enten-v1/Policy.sol";
import {ADMINv1} from "../modules/ADMIN/ADMIN.v1.sol";
import {Keycode, Permissions, toKeycode, ensureContract} from "enten-v1/Utils.sol";
import {assets, effectiveSupply} from "../Utils.sol";
import {IKernel} from "enten-v1/interfaces/IKernel.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IToken} from "enten-v1/interfaces/IToken.sol";
import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";

contract Gateway is Policy, AccessControl {
    bytes32 internal constant FEE_ROLE = keccak256("FEE_ROLE");
    bytes32 internal constant UPGRADE_ROLE = keccak256("UPGRADE_ROLE");
    bytes32 internal constant ASSET_ROLE = keccak256("ASSET_ROLE");
    /// @notice Minimum share of each payment that must accrue to backing, in bps of the gross payment.
    /// @dev    `setFees` stores backing/team/treasury so they sum to `BPS - AUCTION_FEE_BPS` (9750); the core
    ///         derives the actual backing amount as the residual `net - team - treasury`, so bounding the
    ///         `backing` argument from below is equivalent to capping `team + treasury` from above. 5000
    ///         guarantees roughly 50% of every gross payment reaches backing.
    uint256 internal constant MIN_BACKING_BPS = 5000;

    IKernel public immutable KERNEL;
    IToken public immutable TOKEN;

    ADMINv1 public adminModule;

    error Gateway__FeesSet();
    error Gateway__AssetAddressZero();
    error Gateway__InvalidFeeConfiguration();
    error Gateway__DuplicateAsset();
    error Gateway__InitialAdminZeroAddress();
    error Gateway__BackingFloorNotSet();
    error Gateway__AssetNotRegistered();
    error Gateway__SupplyAlreadyBootstrapped();

    event Gateway__Fees(address indexed feeAdmin, uint256 backing, uint256 team, uint256 treasury);
    event Gateway__AssetAdded(address indexed assetAdmin, address indexed newAsset, uint256 newAssetsLength);
    event Gateway__BackingFloorSet(address indexed assetAdmin, address indexed asset, uint256 minBackingRatioRay);
    event Gateway__SystemUpgrades(address indexed upgrader, ADMINv1.SystemUpgrade[] upgrades);

    constructor(address controller, address initialAdmin) Policy(controller) {
        if (initialAdmin == address(0)) revert Gateway__InitialAdminZeroAddress();
        KERNEL = IController(controller).KERNEL();
        TOKEN = IController(controller).TOKEN();
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

    /// @notice Register a backing asset and set its bootstrap backing floor.
    /// @param asset The backing asset to register.
    /// @param minBackingRatioRay The minimum backing-per-token the asset must satisfy while circulating
    ///        (effective) supply is zero, RAY-scaled (1e27). The core consults this only on the bootstrap
    ///        path (`startingSupply == 0`) in `Dispatch._validateBacking`; once supply exists the relative
    ///        backing ratio governs instead, so this value is effectively the launch floor.
    /// @dev   The ratio is DECIMALS-EXPLICIT: `minBackingRatioRay = asset_wei * 1e27 / token_wei`. For a
    ///        1:1 floor of a 6-decimal asset (e.g. USDC) backing an 18-decimal token this is
    ///        `1e6 * 1e27 / 1e18 = 1e15`, NOT 1e27. Passing the wrong scale either bricks the genesis seed
    ///        (`Controller__BackingBelowFloor`) or sets a near-zero floor. A zero floor is rejected here
    ///        because the core would otherwise revert every bootstrap settlement with
    ///        `Controller__BackingFloorNotSet`. Use {setBackingFloor} to correct a mistake before launch.
    ///
    ///        OPERATIONAL HAZARD: registering a second backing asset while a sale is live will brick pricing.
    ///        `PresaleAuction` requires exactly one backing asset and reverts `UnsupportedBackingAsset`
    ///        otherwise, and `Auction.getPrice` reverts `UnseededAsset` for any registered asset with zero
    ///        backing. Only add additional backing assets once the presale has concluded and the new asset
    ///        can be seeded with backing in the same operation. This is accepted, documented behavior.
    ///
    ///        FLOOR SCOPE: the bootstrap floor only binds while effective supply (totalSupply - team-locked)
    ///        is zero. This is intentional so that NON-backed launches work without a floor. But a BACKED
    ///        launch that premints UNLOCKED (non-team) supply before seeding backing makes effectiveSupply > 0
    ///        at the first settlement, so the bootstrap floor never fires and tokens can mint against zero
    ///        backing. Backed-token launchers who premint unlocked supply should seed a small amount of
    ///        backing ("dust") for the asset before/at that premint so the first backing settlement starts
    ///        above zero. Fully team-locked premints keep effectiveSupply == 0 and are unaffected.
    function addAsset(address asset, uint256 minBackingRatioRay) external onlyRole(ASSET_ROLE) {
        if (asset == address(0)) revert Gateway__AssetAddressZero();
        ensureContract(asset);
        if (isDuplicate(asset)) revert Gateway__DuplicateAsset();
        if (minBackingRatioRay == 0) revert Gateway__BackingFloorNotSet();
        uint256 currentAssetsLen = uint256(KERNEL.viewData(Slots.ASSETS_LENGTH_SLOT));
        bytes32 assetSlot = bytes32(uint256(Slots.ASSETS_BASE_SLOT) + currentAssetsLen);

        IController.StateUpdate[] memory updates = new IController.StateUpdate[](3);
        updates[0] = IController.StateUpdate({
            op: IController.Op.Add, slot: Slots.ASSETS_LENGTH_SLOT, data: bytes32(uint256(1))
        });
        updates[1] =
            IController.StateUpdate({op: IController.Op.Set, slot: assetSlot, data: bytes32(uint256(uint160(asset)))});
        updates[2] = IController.StateUpdate({
            op: IController.Op.Set,
            slot: Slots.slots(Slots.MIN_BACKING_RATIO_RAY_BASE_SLOT, asset),
            data: bytes32(minBackingRatioRay)
        });

        adminModule.updateAdminState(updates);

        emit Gateway__AssetAdded(msg.sender, asset, currentAssetsLen + 1);
        emit Gateway__BackingFloorSet(msg.sender, asset, minBackingRatioRay);
    }

    /// @notice Safety setter to correct an already-registered asset's bootstrap backing floor.
    /// @param asset The registered backing asset whose floor is being corrected.
    /// @param minBackingRatioRay The new RAY-scaled minimum backing-per-token (see {addAsset} for scaling).
    /// @dev   Only callable while effective supply is zero — i.e. before the genesis seed mint, which is the
    ///        only window in which the core consults the floor. Once the protocol has bootstrapped, the floor
    ///        is no longer read, so changing it would be misleading; this reverts with
    ///        `Gateway__SupplyAlreadyBootstrapped` instead. Exists to recover from a mis-scaled floor passed
    ///        to {addAsset} without having to redeploy.
    function setBackingFloor(address asset, uint256 minBackingRatioRay) external onlyRole(ASSET_ROLE) {
        if (!isDuplicate(asset)) revert Gateway__AssetNotRegistered();
        if (minBackingRatioRay == 0) revert Gateway__BackingFloorNotSet();
        if (effectiveSupply(KERNEL, TOKEN) != 0) revert Gateway__SupplyAlreadyBootstrapped();

        IController.StateUpdate[] memory updates = new IController.StateUpdate[](1);
        updates[0] = IController.StateUpdate({
            op: IController.Op.Set,
            slot: Slots.slots(Slots.MIN_BACKING_RATIO_RAY_BASE_SLOT, asset),
            data: bytes32(minBackingRatioRay)
        });

        adminModule.updateAdminState(updates);

        emit Gateway__BackingFloorSet(msg.sender, asset, minBackingRatioRay);
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
        // Guarantee a minimum backing share. `backing` is the residual the core actually applies
        // (net - team - treasury), so this caps team + treasury and prevents a barely-backed config.
        if (backing < MIN_BACKING_BPS) revert Gateway__InvalidFeeConfiguration();
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
