// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";

import {DeployPeripheryScript} from "../script/DeployPeriphery.s.sol";

import {Controller} from "enten-v1/Controller.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Token} from "enten-v1/Token.sol";
import {Vault} from "enten-v1/Vault.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {toKeycode} from "enten-v1/Utils.sol";
import {effectiveSupply} from "../src/Utils.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

interface IV4PoolManagerDeployer {
    function deploy(address initialOwner) external returns (address);
}

/// @dev USDm stand-in with non-18 decimals, to exercise the script's decimal-safe sqrtPrice scaling.
contract MockUSDm is ERC20 {
    constructor() ERC20("USDm", "USDm") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice End-to-end exercise of script/DeployPeriphery.s.sol: launches a fresh core (shape A — small unlocked
///         genesis seed), runs the script's `run()` under broadcast, and asserts the full deployed/wired state.
contract DeployPeripheryTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // Deterministic deployer EOA; the script requires the broadcaster to equal ADMIN_ADDRESS.
    uint256 internal constant DEPLOYER_PK = uint256(keccak256("enten.deploy.periphery.test.deployer"));

    // Genesis: a small UNLOCKED premine so effectiveSupply > 0 before open() (script comments / DEPLOYMENT_NOTES).
    uint256 internal constant GENESIS_PREMINE = 1_000e18;
    uint256 internal constant MAX_SUPPLY = 10_000_000e18;

    // Mirror of the script's launch constants used in assertions.
    uint256 internal constant PRESALE_SIZE = 100_000e18;
    uint256 internal constant BACKING_SEED_AMOUNT = 1_000e18;
    uint256 internal constant FEE_BACKING = 9_000;
    uint256 internal constant FEE_TEAM = 0;
    uint256 internal constant FEE_TREASURY = 750;
    uint256 internal constant MIN_BACKING_RATIO_RAY = 1e27;
    // Pool: 0.2% fee, tickSpacing 60, starting price 1 ENTEN = 0.01 USDm (100 ENTEN == 1 USDm).
    uint24 internal constant POOL_FEE = 2_000;
    int24 internal constant POOL_TICK_SPACING = 60;
    uint256 internal constant PRICE_ENTEN_UNITS = 100;
    uint256 internal constant PRICE_USDM_UNITS = 1;
    uint160 internal constant HOOK_FLAG_MASK = 0x3FFF;
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    address internal admin = vm.addr(DEPLOYER_PK);
    address internal protocolCollector = makeAddr("ProtocolCollector");

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    Token internal token;
    ERC20Mock internal backingAsset;
    MockUSDm internal usdm;
    IPoolManager internal poolManager;

    DeployPeripheryScript internal script;

    function setUp() public {
        vm.warp(1_000);

        // Launch the core exactly as the script expects to find it (admin == broadcaster).
        uint256 nonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedToken = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedController = vm.computeCreateAddress(address(this), nonce + 3);

        kernel = new Kernel(predictedController, predictedVault);
        vault = new Vault(predictedController, predictedKernel);
        token = new Token("Enten", "ENTEN", predictedController, admin, GENESIS_PREMINE, MAX_SUPPLY);
        // initialTeamLockedTokens = 0 -> effectiveSupply == GENESIS_PREMINE > 0 (shape A).
        controller = new Controller(admin, protocolCollector, predictedKernel, predictedVault, predictedToken, 0);

        // v4 PoolManager (compiled at its own pragma, deployed via helper).
        IV4PoolManagerDeployer deployer =
            IV4PoolManagerDeployer(deployCode("V4PoolManagerDeployer.sol:V4PoolManagerDeployer"));
        poolManager = IPoolManager(deployer.deploy(address(this)));

        // Backing asset, with the seed the broadcaster must hold for step 7.
        backingAsset = new ERC20Mock();
        backingAsset.mint(admin, BACKING_SEED_AMOUNT);

        // USDm quote token for the ENTEN/USDm pool (6-decimal, distinct from the backing asset).
        usdm = new MockUSDm();

        // Feed the script its environment.
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(DEPLOYER_PK));
        vm.setEnv("ADMIN_ADDRESS", vm.toString(admin));
        vm.setEnv("CONTROLLER_ADDRESS", vm.toString(address(controller)));
        vm.setEnv("POOL_MANAGER_ADDRESS", vm.toString(address(poolManager)));
        vm.setEnv("BACKING_ASSET_ADDRESS", vm.toString(address(backingAsset)));
        vm.setEnv("USDM_ADDRESS", vm.toString(address(usdm)));

        script = new DeployPeripheryScript();
    }

    function testDeployWiresModulesPoliciesAndOpensPresale() public {
        // Guard first: a broadcaster that is not the controller admin reverts before any state change.
        // (Kept in this test rather than its own so the shared process-env, mutated below, isn't raced by
        //  Foundry's parallel test execution.)
        vm.setEnv("ADMIN_ADDRESS", vm.toString(makeAddr("NotTheBroadcaster")));
        vm.expectRevert(bytes("broadcaster must be ADMIN_ADDRESS"));
        script.run();
        vm.setEnv("ADMIN_ADDRESS", vm.toString(admin)); // restore for the happy path

        DeployPeripheryScript.Deployed memory d = script.run();

        // --- Modules installed under their keycodes ---
        assertEq(controller.getModuleForKeycode(toKeycode("MINTR")), address(d.minter), "MINTR module");
        assertEq(controller.getModuleForKeycode(toKeycode("ADMIN")), address(d.adminModule), "ADMIN module");
        assertEq(controller.getModuleForKeycode(toKeycode("BRNER")), address(d.burner), "BRNER module");

        // --- Policies active ---
        assertTrue(controller.isPolicyActive(address(d.gateway)), "gateway active");
        assertTrue(controller.isPolicyActive(address(d.presale)), "presale active");
        assertTrue(controller.isPolicyActive(address(d.hook)), "hook active");

        // --- Mint permission enabled for the MINTR keycode ---
        assertTrue(controller.mintPermissions(toKeycode("MINTR")), "MINTR mint permission");

        // --- Hook address encodes its permission flags (CREATE2 mining worked) ---
        assertEq(uint160(address(d.hook)) & HOOK_FLAG_MASK, HOOK_FLAGS, "hook flag bits");

        // --- Fees written to the core ---
        assertEq(uint256(kernel.viewData(Slots.BACKING_PERCENTAGE_SLOT)), FEE_BACKING, "backing fee");
        assertEq(uint256(kernel.viewData(Slots.TEAM_PERCENTAGE_SLOT)), FEE_TEAM, "team fee");
        assertEq(uint256(kernel.viewData(Slots.TREASURY_PERCENTAGE_SLOT)), FEE_TREASURY, "treasury fee");

        // --- Backing asset registered with its floor ---
        assertEq(uint256(kernel.viewData(Slots.ASSETS_LENGTH_SLOT)), 1, "assets length");
        assertEq(
            uint256(kernel.viewData(Slots.slots(Slots.MIN_BACKING_RATIO_RAY_BASE_SLOT, address(backingAsset)))),
            MIN_BACKING_RATIO_RAY,
            "backing floor"
        );

        // --- Backing seeded into the Redeem bucket ---
        assertEq(
            uint256(kernel.viewData(Slots.slots(Slots.BACKING_AMOUNT_SLOT, address(backingAsset)))),
            BACKING_SEED_AMOUNT,
            "redeem bucket backing"
        );
        assertEq(backingAsset.balanceOf(address(vault)), BACKING_SEED_AMOUNT, "vault asset balance");
        assertEq(backingAsset.balanceOf(admin), 0, "deployer drained seed");

        // --- Presale opened with the full size available ---
        assertEq(d.presale.startTime(), block.timestamp, "presale opened at now");
        assertEq(d.presale.ASSET(), address(backingAsset), "presale asset");
        assertEq(d.presale.PRESALE_SIZE(), PRESALE_SIZE, "presale size");
        assertEq(d.presale.remaining(), PRESALE_SIZE, "presale remaining");

        // --- ENTEN/USDm v4 pool created and initialized at the target price ---
        address enten = address(token);
        bool entenIsZero = enten < address(usdm);
        (Currency c0, Currency c1) = entenIsZero
            ? (Currency.wrap(enten), Currency.wrap(address(usdm)))
            : (Currency.wrap(address(usdm)), Currency.wrap(enten));
        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(address(d.hook))
        });
        (uint160 sqrtPriceX96,,, uint24 lpFee) = poolManager.getSlot0(key.toId());

        // Independent expected sqrtPriceX96 from EQUAL-VALUE wei amounts (1 ENTEN == 0.01 USDm), formulated
        // differently from the script (1-ENTEN / 0.01-USDm vs. the script's 100-ENTEN / 1-USDm) so a scaling
        // bug on either side surfaces as a mismatch.
        uint256 entenValueWei = 10 ** token.decimals();
        uint256 usdmValueWei = (10 ** usdm.decimals()) / 100;
        uint256 expectedSqrtPriceX96 = entenIsZero
            ? Math.sqrt(Math.mulDiv(usdmValueWei, 1 << 192, entenValueWei))
            : Math.sqrt(Math.mulDiv(entenValueWei, 1 << 192, usdmValueWei));

        assertTrue(sqrtPriceX96 != 0, "pool not initialized");
        assertEq(uint256(sqrtPriceX96), expectedSqrtPriceX96, "pool sqrtPriceX96");
        assertEq(lpFee, POOL_FEE, "pool lp fee"); // static-fee pool surfaces key.fee as the lp fee

        // Sanity: genesis seed left effectiveSupply > 0, as the open() precondition requires.
        assertGt(effectiveSupply(controller.KERNEL(), controller.TOKEN()), 0, "effective supply");
    }
}
