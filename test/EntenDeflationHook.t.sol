///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// import {Test} from "forge-std/Test.sol";
// import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";

// import {Hooks} from "v4-core/src/libraries/Hooks.sol";
// import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
// import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
// import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
// import {Currency} from "v4-core/src/types/Currency.sol";
// import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
// import {PoolKey} from "v4-core/src/types/PoolKey.sol";
// import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
// import {TickMath} from "v4-core/src/libraries/TickMath.sol";
// import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
// import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

// import {BurnerModule} from "../src/modules/DFLT/Burner.sol";
// import {EntenDeflationHook} from "../src/policies/EntenDeflationHook.sol";

// import {Controller} from "enten-v1/Controller.sol";
// import {EntenToken} from "enten-v1/EntenToken.sol";
// import {Kernel} from "enten-v1/Kernel.sol";
// import {Vault} from "enten-v1/Vault.sol";
// import {Actions} from "enten-v1/Utils.sol";

// interface IV4PoolManagerDeployer {
//     function deploy(address initialOwner) external returns (address);
// }

// contract EntenDeflationHookTest is Test {
//     using SafeCast for uint256;

//     uint256 internal constant INITIAL_SUPPLY = 1_000_000 ether;
//     uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
//     uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
//     uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
//     bytes internal constant ZERO_BYTES = "";

//     Controller internal controller;
//     EntenToken internal enten;
//     ERC20Mock internal quote;
//     BurnerModule internal burner;
//     EntenDeflationHook internal hook;
//     IPoolManager internal manager;
//     PoolModifyLiquidityTest internal modifyLiquidityRouter;
//     PoolSwapTest internal swapRouter;
//     PoolKey internal entenKey;

//     address internal admin = makeAddr("Admin");
//     address internal protocolCollector = makeAddr("Protocol Collector");

//     function setUp() public {
//         IV4PoolManagerDeployer deployer =
//             IV4PoolManagerDeployer(deployCode("V4PoolManagerDeployer.sol:V4PoolManagerDeployer"));
//         manager = IPoolManager(deployer.deploy(address(this)));
//         modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
//         swapRouter = new PoolSwapTest(manager);

//         _deployEntenCore();

//         quote = new ERC20Mock();
//         quote.mint(address(this), INITIAL_SUPPLY);

//         burner = new BurnerModule(address(controller));

//         address hookAddress = address(
//             uint160(
//                 Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
//                     | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
//             )
//         );
//         deployCodeTo(
//             "EntenDeflationHook.sol:EntenDeflationHook",
//             abi.encode(address(controller), manager, address(enten)),
//             hookAddress
//         );
//         hook = EntenDeflationHook(hookAddress);

//         vm.startPrank(admin);
//         controller.executeAction(Actions.InstallModule, address(burner));
//         controller.executeAction(Actions.ActivatePolicy, address(hook));
//         vm.stopPrank();

//         enten.approve(address(modifyLiquidityRouter), type(uint256).max);
//         enten.approve(address(swapRouter), type(uint256).max);
//         quote.approve(address(modifyLiquidityRouter), type(uint256).max);
//         quote.approve(address(swapRouter), type(uint256).max);

//         (Currency currency0, Currency currency1) = _sort(address(enten), address(quote));
//         entenKey = PoolKey({
//             currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
//         });
//         manager.initialize(entenKey, SQRT_PRICE_1_1);
//         modifyLiquidityRouter.modifyLiquidity(
//             entenKey,
//             ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}),
//             ZERO_BYTES
//         );
//     }

//     function testSellAccruesAndBurnsInputEntenThroughModule() public {
//         bool zeroForOne = _entenIsCurrency0();
//         uint256 amountIn = 1_000 ether;
//         uint256 expectedBurn = amountIn * hook.BURN_BPS() / hook.BPS();
//         uint256 supplyBefore = enten.totalSupply();

//         _swap(zeroForOne, amountIn);

//         assertEq(enten.totalSupply(), supplyBefore);
//         assertEq(hook.accruedSellBurns(), expectedBurn);

//         hook.burnAccrued();

//         assertEq(supplyBefore - enten.totalSupply(), expectedBurn);
//         assertEq(enten.balanceOf(address(hook)), 0);
//         assertEq(hook.accruedSellBurns(), 0);
//     }

//     function testBuyBurnsOutputEntenImmediatelyThroughModule() public {
//         bool zeroForOne = !_entenIsCurrency0();
//         uint256 entenBefore = enten.balanceOf(address(this));
//         uint256 supplyBefore = enten.totalSupply();

//         _swap(zeroForOne, 1_000 ether);

//         uint256 burned = supplyBefore - enten.totalSupply();
//         uint256 received = enten.balanceOf(address(this)) - entenBefore;
//         uint256 rawEntenOutput = received + burned;

//         assertGt(burned, 0);
//         assertEq(burned, rawEntenOutput * hook.BURN_BPS() / hook.BPS());
//         assertEq(enten.balanceOf(address(hook)), 0);
//     }

//     function testExactOutputSwapsRevert() public {
//         vm.expectRevert();
//         swapRouter.swap(
//             entenKey,
//             SwapParams({
//                 zeroForOne: _entenIsCurrency0(), amountSpecified: 100 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT
//             }),
//             PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
//             ZERO_BYTES
//         );
//     }

//     function _deployEntenCore() internal {
//         uint256 nonce = vm.getNonce(address(this));
//         address predictedKernel = vm.computeCreateAddress(address(this), nonce);
//         address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
//         address predictedToken = vm.computeCreateAddress(address(this), nonce + 2);
//         address predictedController = vm.computeCreateAddress(address(this), nonce + 3);

//         new Kernel(predictedController, predictedVault);
//         new Vault(predictedController, predictedKernel);
//         enten = new EntenToken("Enten", "ENTEN", predictedController, address(this), INITIAL_SUPPLY, type(uint256).max);
//         controller = new Controller(admin, protocolCollector, predictedKernel, predictedVault, predictedToken);
//     }

//     function _swap(bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
//         return swapRouter.swap(
//             entenKey,
//             SwapParams({
//                 zeroForOne: zeroForOne,
//                 amountSpecified: -amountIn.toInt256(),
//                 sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
//             }),
//             PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
//             ZERO_BYTES
//         );
//     }

//     function _entenIsCurrency0() internal view returns (bool) {
//         return Currency.unwrap(entenKey.currency0) == address(enten);
//     }

//     function _sort(address a, address b) internal pure returns (Currency currency0, Currency currency1) {
//         (currency0, currency1) = a < b ? (Currency.wrap(a), Currency.wrap(b)) : (Currency.wrap(b), Currency.wrap(a));
//     }
// }
