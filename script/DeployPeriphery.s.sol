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
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";

/// @notice Deploys and wires this round's periphery: Minter (MINTR), Admin (ADMIN) and Burner (BRNER) modules,
///         plus the Gateway, PresaleAuction and EntenDeflationHook policies, and finally creates + initializes
///         the ENTEN/USDm Uniswap v4 pool (0.2% fee, tickSpacing 60) wired to the hook — initialize only, no
///         liquidity. The Auction policy is intentionally out of scope. Governance is a single EOA admin (no
///         timelock handoff). The core (Kernel/Vault/Token/Controller) must already be deployed.
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
    // `CREATE2_FACTORY` (0x4e59...4956C) is inherited from forge-std's Base/Script.

    // Permission-flag bits the EntenDeflationHook's address must encode (must match getHookPermissions()).
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /*--------------------------------------------------------------------------*/
    /*  ENTEN/USDm v4 POOL — initialized (no liquidity) with the deflation hook  */
    /*--------------------------------------------------------------------------*/

    // Custom 0.2% static fee, in hundredths of a bip (1_000_000 = 100%).
    uint24 internal constant POOL_FEE = 2_000;
    // 60 matches the canonical 0.3% pools; the hook imposes no tick-spacing constraint.
    int24 internal constant POOL_TICK_SPACING = 60;

    // Starting price as a ratio of EQUAL-VALUE human amounts: PRICE_ENTEN_UNITS ENTEN == PRICE_USDM_UNITS USDm.
    // 100 ENTEN == 1 USDm => 1 ENTEN = 0.01 USDm (~100k FDV at a 10M max supply). Decimal scaling to each
    // token's wei is handled at runtime via decimals(), so these are human-unit integers only.
    uint256 internal constant PRICE_ENTEN_UNITS = 100;
    uint256 internal constant PRICE_USDM_UNITS = 1;

    /// @notice Addresses of every contract this script deploys, threaded between the helper steps.
    struct Deployed {
        Minter minter;
        Admin adminModule;
        BurnerModule burner;
        Gateway gateway;
        PresaleAuction presale;
        EntenDeflationHook hook;
    }

    function run() public returns (Deployed memory d) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        IController controller = IController(vm.envAddress("CONTROLLER_ADDRESS"));
        address backingAsset = vm.envAddress("BACKING_ASSET_ADDRESS");
        // USDm quote token for the ENTEN/USDm pool. Mainnet (megaETH): 0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7.
        address usdm = vm.envAddress("USDM_ADDRESS");

        // Single-EOA round: the broadcaster must be the admin so role-gated wiring and open() succeed.
        require(admin == vm.addr(deployerPk), "broadcaster must be ADMIN_ADDRESS");

        vm.startBroadcast(deployerPk);
        d = _deploy(controller, admin, backingAsset);
        _wire(controller, d, admin, backingAsset);
        _initializePool(d.hook, usdm);
        vm.stopBroadcast();

        _log(d);
    }

    /// @dev Step 9: create + initialize the ENTEN/USDm v4 pool wired to the deflation hook, at the starting
    ///      price above. Initialize only — no liquidity is seeded. Pool creation is permissionless; the hook's
    ///      `beforeInitialize` requires ENTEN to be one of the pool currencies. Currencies are sorted by address
    ///      and the starting `sqrtPriceX96` is computed decimal-safely from each token's `decimals()`.
    function _initializePool(EntenDeflationHook hook, address usdm) internal {
        address enten = Currency.unwrap(hook.ENTEN());
        require(usdm != address(0) && usdm != enten, "bad USDM address");

        // Equal-value raw (wei) amounts at the target price, scaled to each token's decimals.
        uint256 entenAmt = PRICE_ENTEN_UNITS * (10 ** IERC20Metadata(enten).decimals());
        uint256 usdmAmt = PRICE_USDM_UNITS * (10 ** IERC20Metadata(usdm).decimals());

        // v4 requires currency0 < currency1. token1-per-token0 (in wei) is the pool price; sqrtPriceX96 is its
        // square root in Q64.96. mulDiv carries the full 512-bit intermediate before the sqrt.
        bool entenIsZero = enten < usdm;
        (Currency currency0, Currency currency1) =
            entenIsZero ? (hook.ENTEN(), Currency.wrap(usdm)) : (Currency.wrap(usdm), hook.ENTEN());
        (uint256 amount0, uint256 amount1) = entenIsZero ? (entenAmt, usdmAmt) : (usdmAmt, entenAmt);

        uint256 sqrtPrice = Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0));
        require(sqrtPrice >= TickMath.MIN_SQRT_PRICE && sqrtPrice < TickMath.MAX_SQRT_PRICE, "sqrtPrice out of range");
        // Safe: bounded above by MAX_SQRT_PRICE (< 2^160) by the require directly above.
        uint160 sqrtPriceX96 = uint160(sqrtPrice);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        hook.POOL_MANAGER().initialize(key, sqrtPriceX96);

        console.log("Pool currency0:", Currency.unwrap(currency0));
        console.log("Pool currency1:", Currency.unwrap(currency1));
        console.log("Pool sqrtPriceX96:", sqrtPriceX96);
    }

    /// @dev Steps 1-2: deploy the modules and policies (the hook via a mined CREATE2 salt). Split out of
    ///      `run` to keep each frame's local count under the stack-too-deep limit.
    function _deploy(IController controller, address admin, address backingAsset)
        internal
        returns (Deployed memory d)
    {
        address controllerAddr = address(controller);
        address poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        address entenToken = address(controller.TOKEN());

        // 1. Deploy modules.
        d.minter = new Minter(controllerAddr);
        d.adminModule = new Admin(controllerAddr);
        d.burner = new BurnerModule(controllerAddr, address(controller.KERNEL()), address(0), 0);

        // 2. Deploy policies.
        d.gateway = new Gateway(controllerAddr, admin);
        d.presale = new PresaleAuction(
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
            CREATE2_FACTORY,
            HOOK_FLAGS,
            type(EntenDeflationHook).creationCode,
            abi.encode(controllerAddr, poolManager, entenToken)
        );
        d.hook = new EntenDeflationHook{salt: hookSalt}(controllerAddr, IPoolManager(poolManager), entenToken);
        require(address(d.hook) == minedHook, "hook address mismatch");
    }

    /// @dev Steps 3-8: install modules, activate policies, configure fees/assets, seed backing and open the
    ///      presale. Every call here is role-gated to the broadcasting admin.
    function _wire(IController controller, Deployed memory d, address admin, address backingAsset) internal {
        // 3. Install modules (must precede the policies that depend on them).
        controller.executeAction(Actions.InstallModule, address(d.minter));
        controller.executeAction(Actions.InstallModule, address(d.adminModule));
        controller.executeAction(Actions.InstallModule, address(d.burner));

        // 4. Activate policies. Each requests its module permissions on activation:
        //    Gateway -> ADMIN, PresaleAuction -> MINTR.mint, Hook -> BRNER.executeDeflationaryAction.
        controller.executeAction(Actions.ActivatePolicy, address(d.gateway));
        controller.executeAction(Actions.ActivatePolicy, address(d.presale));
        controller.executeAction(Actions.ActivatePolicy, address(d.hook));

        // 5. Enable minting for the MINTR keycode (PresaleAuction is the only activated minting policy this round).
        controller.setMintPermission(toKeycode("MINTR"), true);

        // 6. Configure fees and register the backing asset with its bootstrap floor (via the Gateway/Admin module).
        d.gateway.setFees(FEE_BACKING, FEE_TEAM, FEE_TREASURY);
        d.gateway.addAsset(backingAsset, MIN_BACKING_RATIO_RAY);

        // 7. Seed backing into the Vault's Redeem bucket: transfer the asset in, then sync to credit it.
        controller.grantRole(controller.CREDITOR_ROLE(), admin);
        require(IERC20(backingAsset).transfer(address(controller.VAULT()), BACKING_SEED_AMOUNT), "seed transfer failed");
        controller.sync(backingAsset, IVault.Bucket.Redeem);

        // 8. Open the presale: starts the decay/duration clock and validates START_PRICE > the live floor.
        //    Requires effectiveSupply > 0 (genesis seed already minted) and backing seeded above. See
        //    DEPLOYMENT_NOTES.md if this reverts on a fully team-locked genesis.
        require(effectiveSupply(controller.KERNEL(), controller.TOKEN()) > 0, "effectiveSupply == 0: seed genesis first");
        d.presale.open();
    }

    function _log(Deployed memory d) internal pure {
        console.log("Minter:        ", address(d.minter));
        console.log("Admin module:  ", address(d.adminModule));
        console.log("Burner module: ", address(d.burner));
        console.log("Gateway:       ", address(d.gateway));
        console.log("PresaleAuction:", address(d.presale));
        console.log("DeflationHook: ", address(d.hook));
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
