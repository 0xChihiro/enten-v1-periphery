// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/Test.sol";

import {Minter} from "../src/modules/MINTR/Minter.sol";
import {Admin} from "../src/modules/ADMIN/Admin.sol";
import {BurnerModule} from "../src/modules/DFLT/Burner.sol";
import {Gateway} from "../src/policies/Gateway.sol";
import {PresaleAuction} from "../src/policies/PresaleAuction.sol";
import {EntenDeflationHook} from "../src/policies/EntenDeflationHook.sol";
import {effectiveSupply} from "../src/Utils.sol";

import {IController} from "enten-v1/interfaces/IController.sol";
import {IVault} from "enten-v1/interfaces/IVault.sol";
import {Actions, toKeycode} from "enten-v1/Utils.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploys and wires this round's periphery: Minter (MINTR), Admin (ADMIN) and Burner (BRNER) modules,
///         plus the Gateway, PresaleAuction and EntenDeflationHook policies. The Auction policy is intentionally
///         out of scope. Governance is a single EOA admin (no timelock handoff). The audited core
///         (Kernel/Vault/Token/Controller) must already be deployed.
///
/// @dev    The broadcasting key MUST be the controller admin: every wiring call below is role-gated
///         (EXECUTOR_ROLE / MINT_PERMISSION_ROLE / DEFAULT_ADMIN / CREDITOR_ROLE), and `presale.open()` is
///         restricted to the presale ADMIN. See script/DEPLOYMENT_NOTES.md, especially the genesis bootstrap
///         caveat: this script expects the core to have been launched with a small UNLOCKED genesis seed so
///         that effectiveSupply > 0 before `open()` (shape A). Otherwise `open()` reverts.
contract DeployPeripheryScript is Script {
    /*--------------------------------------------------------------------------*/
    /*  LAUNCH PARAMETERS — SET THESE PER LAUNCH (and decimal-scale to the asset) */
    /*--------------------------------------------------------------------------*/

    // Fee split of the post-protocol-fee remainder; must sum to 9750 and backing >= 5000 (Gateway guard).
    uint256 internal constant FEE_BACKING = 9_000;
    uint256 internal constant FEE_TEAM = 0;
    uint256 internal constant FEE_TREASURY = 750;

    // Per-asset bootstrap floor, RAY-scaled: minBackingRatioRay = asset_wei * 1e27 / token_wei.
    // Example below is a 1:1 floor for an 18-decimal asset backing an 18-decimal token. For a 6-decimal
    // asset (e.g. USDC) a 1:1 floor would be 1e15, NOT 1e27.
    uint256 internal constant MIN_BACKING_RATIO_RAY = 1e27;

    // PresaleAuction config. START_PRICE/VIRTUAL_TOKEN_RESERVE/MIN_BID are in the asset's "wei per 1e18 token".
    uint256 internal constant PRESALE_SIZE = 100_000e18;
    uint256 internal constant PRESALE_START_PRICE = 2e18;
    uint256 internal constant PRESALE_VIRTUAL_TOKEN_RESERVE = 200_000e18;
    uint256 internal constant PRESALE_DURATION = 1 days;
    uint256 internal constant PRESALE_MIN_BID = 100e18;

    // Backing to seed into the Vault's Redeem bucket before opening the presale (in asset wei).
    // The broadcaster must hold at least this much of the backing asset.
    uint256 internal constant BACKING_SEED_AMOUNT = 1_000e18;

    // Canonical deterministic CREATE2 factory that Foundry routes salted `new{salt:...}` through.
    address internal constant CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Permission-flag bits the EntenDeflationHook's address must encode (must match getHookPermissions()).
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function run() public {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address controllerAddr = vm.envAddress("CONTROLLER_ADDRESS");
        address poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        address backingAsset = vm.envAddress("BACKING_ASSET_ADDRESS");

        // Single-EOA round: the broadcaster must be the admin so role-gated wiring and open() succeed.
        require(admin == vm.addr(deployerPk), "broadcaster must be ADMIN_ADDRESS");

        IController controller = IController(controllerAddr);
        address kernel = address(controller.KERNEL());
        address vault = address(controller.VAULT());
        address entenToken = address(controller.TOKEN());

        vm.startBroadcast(deployerPk);

        // 1. Deploy modules.
        Minter minter = new Minter(controllerAddr);
        Admin adminModule = new Admin(controllerAddr);
        BurnerModule burner = new BurnerModule(controllerAddr, kernel, address(0), 0);

        // 2. Deploy policies.
        Gateway gateway = new Gateway(controllerAddr, admin);
        PresaleAuction presale = new PresaleAuction(
            controllerAddr,
            backingAsset,
            admin,
            PRESALE_SIZE,
            PRESALE_START_PRICE,
            PRESALE_VIRTUAL_TOKEN_RESERVE,
            PRESALE_DURATION,
            PRESALE_MIN_BID
        );

        // 2b. Mine a CREATE2 salt so the hook deploys to an address encoding its permission flags, then deploy.
        (address minedHook, bytes32 hookSalt) = HookMiner.find(
            CREATE2_FACTORY, HOOK_FLAGS, type(EntenDeflationHook).creationCode, abi.encode(controllerAddr, poolManager, entenToken)
        );
        EntenDeflationHook hook =
            new EntenDeflationHook{salt: hookSalt}(controllerAddr, IPoolManager(poolManager), entenToken);
        require(address(hook) == minedHook, "hook address mismatch");

        // 3. Install modules (must precede the policies that depend on them).
        controller.executeAction(Actions.InstallModule, address(minter));
        controller.executeAction(Actions.InstallModule, address(adminModule));
        controller.executeAction(Actions.InstallModule, address(burner));

        // 4. Activate policies. Each requests its module permissions on activation:
        //    Gateway -> ADMIN, PresaleAuction -> MINTR.mint, Hook -> BRNER.executeDeflationaryAction.
        controller.executeAction(Actions.ActivatePolicy, address(gateway));
        controller.executeAction(Actions.ActivatePolicy, address(presale));
        controller.executeAction(Actions.ActivatePolicy, address(hook));

        // 5. Enable minting for the MINTR keycode (PresaleAuction is the only activated minting policy this round).
        controller.setMintPermission(toKeycode("MINTR"), true);

        // 6. Configure fees and register the backing asset with its bootstrap floor (via the Gateway/Admin module).
        gateway.setFees(FEE_BACKING, FEE_TEAM, FEE_TREASURY);
        gateway.addAsset(backingAsset, MIN_BACKING_RATIO_RAY);

        // 7. Seed backing into the Vault's Redeem bucket: transfer the asset in, then sync to credit it.
        controller.grantRole(controller.CREDITOR_ROLE(), admin);
        require(IERC20(backingAsset).transfer(vault, BACKING_SEED_AMOUNT), "seed transfer failed");
        controller.sync(backingAsset, IVault.Bucket.Redeem);

        // 8. Open the presale: starts the decay/duration clock and validates START_PRICE > the live floor.
        //    Requires effectiveSupply > 0 (genesis seed already minted) and backing seeded above. See
        //    DEPLOYMENT_NOTES.md if this reverts on a fully team-locked genesis.
        require(effectiveSupply(controller.KERNEL(), controller.TOKEN()) > 0, "effectiveSupply == 0: seed genesis first");
        presale.open();

        vm.stopBroadcast();

        console.log("Minter:        ", address(minter));
        console.log("Admin module:  ", address(adminModule));
        console.log("Burner module: ", address(burner));
        console.log("Gateway:       ", address(gateway));
        console.log("PresaleAuction:", address(presale));
        console.log("DeflationHook: ", address(hook));
    }
}

/// @notice Minimal CREATE2 salt miner for Uniswap v4 hook addresses (vendored; no HookMiner in deps).
library HookMiner {
    // The low 14 bits of a hook address encode its permission flags (Hooks.ALL_HOOK_MASK).
    uint160 internal constant FLAG_MASK = 0x3FFF;
    uint256 internal constant MAX_LOOP = 160_444;

    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i = 0; i < MAX_LOOP; i++) {
            hookAddress = _computeAddress(deployer, i, initCodeHash);
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(i));
            }
        }
        revert("HookMiner: no salt found");
    }

    function _computeAddress(address deployer, uint256 salt, bytes32 initCodeHash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(salt), initCodeHash)))));
    }
}
