///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {IBurner} from "../src/interfaces/IBurner.sol";
import {BurnerModule} from "../src/modules/DFLT/Burner.sol";
import {BRNER} from "../src/modules/DFLT/BRNER.sol";
import {BurnerPolicy} from "../src/policies/BurnerPolicy.sol";
import {EntenDeflationHook} from "../src/policies/EntenDeflationHook.sol";

import {Controller} from "enten-v1/Controller.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Token} from "enten-v1/Token.sol";
import {Vault} from "enten-v1/Vault.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Actions, Keycode, Permissions, toKeycode} from "enten-v1/Utils.sol";

interface IV4PoolManagerDeployer {
    function deploy(address initialOwner) external returns (address);
}

contract EntenDeflationHookTest is Test {
    using SafeCast for uint256;

    uint256 internal constant INITIAL_SUPPLY = 1_000_000 ether;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    bytes internal constant ZERO_BYTES = "";

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    Token internal enten;
    ERC20Mock internal quote;
    BurnerModule internal burner;
    EntenDeflationHook internal hook;
    BurnerPolicy internal directBurnPolicy;
    IPoolManager internal manager;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    PoolSwapTest internal swapRouter;
    PoolKey internal entenKey;

    address internal admin = makeAddr("Admin");
    address internal protocolCollector = makeAddr("Protocol Collector");

    event EntenBurnAccrued(uint256 amount);
    event EntenBurned(uint256 amount);

    struct BurnSnapshot {
        uint256 totalSupply;
        uint256 locked;
        uint256 effectiveSupply;
        uint256 redeemBacking;
    }

    function testPolicyConfiguresBurnerDependencyAndPermission() public {
        _deployFixture(true);

        assertEq(hook.deflationBurner(), address(burner));
        assertTrue(controller.isPolicyActive(address(hook)));
        assertTrue(
            controller.modulePermissions(toKeycode("BRNER"), address(hook), BRNER.executeDeflationaryAction.selector)
        );

        Permissions[] memory permissions = hook.requestPermissions();
        assertEq(permissions.length, 1);
        assertEq(Keycode.unwrap(permissions[0].keycode), Keycode.unwrap(toKeycode("BRNER")));
        assertEq(permissions[0].funcSelector, IBurner.executeDeflationaryAction.selector);
    }

    function testSellAccruesAndBurnsInputEntenThroughModuleWhenEntenIsCurrency0() public {
        _deployFixture(true);
        assertTrue(_entenIsCurrency0());
        _assertSellAccruesAndBurnsInputEntenThroughModule();
    }

    function testSellAccruesAndBurnsInputEntenThroughModuleWhenEntenIsCurrency1() public {
        _deployFixture(false);
        assertFalse(_entenIsCurrency0());
        _assertSellAccruesAndBurnsInputEntenThroughModule();
    }

    function testBuyBurnsOutputEntenImmediatelyThroughModuleWhenEntenIsCurrency0() public {
        _deployFixture(true);
        assertTrue(_entenIsCurrency0());
        _assertBuyBurnsOutputEntenImmediatelyThroughModule();
    }

    function testBuyBurnsOutputEntenImmediatelyThroughModuleWhenEntenIsCurrency1() public {
        _deployFixture(false);
        assertFalse(_entenIsCurrency0());
        _assertBuyBurnsOutputEntenImmediatelyThroughModule();
    }

    function testSellSwapEmitsBurnAccruedAndBurnAccruedEmitsBurned() public {
        _deployFixture(true);
        uint256 amountIn = 1_000 ether;
        uint256 expectedBurn = _feeAmount(amountIn);

        vm.expectEmit(address(hook));
        emit EntenBurnAccrued(expectedBurn);
        _swap(_entenIsCurrency0(), amountIn);

        vm.expectEmit(address(hook));
        emit EntenBurned(expectedBurn);
        hook.burnAccrued();
    }

    function testBuySwapEmitsBurned() public {
        _deployFixture(true);
        uint256 supplyBefore = enten.totalSupply();

        vm.expectEmit(false, false, false, false, address(hook));
        emit EntenBurned(0);
        _swap(!_entenIsCurrency0(), 1_000 ether);

        assertGt(supplyBefore - enten.totalSupply(), 0);
    }

    function testBuyBurnNoOpsWhenBurnerModuleDisabledAndPoolRemainsUsable() public {
        _deployFixture(true);
        uint256 supplyBefore = enten.totalSupply();
        uint256 balanceBefore = enten.balanceOf(address(this));

        vm.prank(admin);
        controller.setModuleDisabled(toKeycode("BRNER"), true);

        _swap(!_entenIsCurrency0(), 1_000 ether);

        assertEq(enten.totalSupply(), supplyBefore);
        assertGt(enten.balanceOf(address(this)), balanceBefore);
        assertEq(enten.balanceOf(address(hook)), 0);
        assertEq(hook.accruedSellBurns(), 0);
    }

    function testExactOutputSellBurnsInputEntenWhenEntenIsCurrency0() public {
        _deployFixture(true);
        assertTrue(_entenIsCurrency0());
        _assertExactOutputSellBurnsInputEnten();
    }

    function testExactOutputSellBurnsInputEntenWhenEntenIsCurrency1() public {
        _deployFixture(false);
        assertFalse(_entenIsCurrency0());
        _assertExactOutputSellBurnsInputEnten();
    }

    function testExactOutputBuyBurnsOutputEntenWhenEntenIsCurrency0() public {
        _deployFixture(true);
        assertTrue(_entenIsCurrency0());
        _assertExactOutputBuyBurnsOutputEnten();
    }

    function testExactOutputBuyBurnsOutputEntenWhenEntenIsCurrency1() public {
        _deployFixture(false);
        assertFalse(_entenIsCurrency0());
        _assertExactOutputBuyBurnsOutputEnten();
    }

    function testHookPolicyDeactivationNoOpsAndPoolRemainsUsable() public {
        _deployFixture(true);
        uint256 supplyBefore = enten.totalSupply();

        vm.prank(admin);
        controller.executeAction(Actions.DeactivatePolicy, address(hook));

        _swap(_entenIsCurrency0(), 1_000 ether);
        _swap(!_entenIsCurrency0(), 1_000 ether);

        assertEq(enten.totalSupply(), supplyBefore);
        assertEq(hook.accruedSellBurns(), 0);
        assertEq(enten.balanceOf(address(hook)), 0);
    }

    function testMultipleEntenPoolsAccrueGlobalSellBurnsAndBurnOnce() public {
        _deployFixture(true);
        PoolKey memory secondKey = _deployAdditionalEntenPool(2);
        uint256 firstAmountIn = 1_000 ether;
        uint256 secondAmountIn = 2_000 ether;
        uint256 expectedBurn = _feeAmount(firstAmountIn) + _feeAmount(secondAmountIn);
        uint256 supplyBefore = enten.totalSupply();

        _swap(entenKey, _entenIsCurrency0(entenKey), firstAmountIn);
        _swap(secondKey, _entenIsCurrency0(secondKey), secondAmountIn);

        assertEq(hook.accruedSellBurns(), expectedBurn);
        assertEq(enten.totalSupply(), supplyBefore);

        hook.burnAccrued();

        assertEq(supplyBefore - enten.totalSupply(), expectedBurn);
        assertEq(hook.accruedSellBurns(), 0);
        assertEq(enten.balanceOf(address(hook)), 0);
    }

    function testMultipleEntenPoolsHandleSellAndBuyBurnsIndependently() public {
        _deployFixture(true);
        PoolKey memory secondKey = _deployAdditionalEntenPool(2);
        uint256 supplyBefore = enten.totalSupply();

        _swap(entenKey, _entenIsCurrency0(entenKey), 1_000 ether);
        uint256 accruedSellBurn = hook.accruedSellBurns();

        uint256 balanceBeforeBuy = enten.balanceOf(address(this));
        _swap(secondKey, !_entenIsCurrency0(secondKey), 1_000 ether);
        uint256 buyBurn = supplyBefore - enten.totalSupply();
        uint256 buyReceived = enten.balanceOf(address(this)) - balanceBeforeBuy;

        assertGt(accruedSellBurn, 0);
        assertGt(buyBurn, 0);
        assertEq(buyBurn, _feeAmount(buyReceived + buyBurn));
        assertEq(hook.accruedSellBurns(), accruedSellBurn);

        hook.burnAccrued();

        assertEq(supplyBefore - enten.totalSupply(), accruedSellBurn + buyBurn);
        assertEq(hook.accruedSellBurns(), 0);
        assertEq(enten.balanceOf(address(hook)), 0);
    }

    function testHookDrivenSellBurnDecreasesLockedTeamTokens() public {
        _deployFixture(true);
        _setLocked(100 ether);
        uint256 amountIn = 1_000 ether;
        uint256 expectedBurn = _feeAmount(amountIn);

        _swap(_entenIsCurrency0(), amountIn);
        hook.burnAccrued();

        assertEq(_locked(), 100 ether - expectedBurn);
        assertEq(_effectiveSupply(), INITIAL_SUPPLY - 100 ether);
    }

    function testHookDrivenBuyBurnDecreasesLockedTeamTokens() public {
        _deployFixture(true);
        _setLocked(100 ether);
        uint256 lockedBefore = _locked();
        uint256 supplyBefore = enten.totalSupply();

        _swap(!_entenIsCurrency0(), 1_000 ether);

        uint256 burned = supplyBefore - enten.totalSupply();
        assertGt(burned, 0);
        assertEq(_locked(), lockedBefore - burned);
        assertEq(_effectiveSupply(), supplyBefore - lockedBefore);
    }

    function testHookDrivenBurnCapsLockedTeamTokenDecreaseAtRemainingLocked() public {
        _deployFixture(true);
        _setLocked(1 ether);
        uint256 amountIn = 1_000 ether;
        uint256 expectedBurn = _feeAmount(amountIn);
        assertGt(expectedBurn, _locked());

        _swap(_entenIsCurrency0(), amountIn);
        hook.burnAccrued();

        assertEq(_locked(), 0);
        assertEq(_effectiveSupply(), INITIAL_SUPPLY - expectedBurn);
    }

    function testHookDrivenBurnMatchesDirectPolicyBurnForSameAmount() public {
        _deployFixture(true);
        _setLocked(100 ether);
        uint256 burnAmount = 7 ether;
        uint256 amountIn = burnAmount * hook.BPS() / hook.BURN_BPS();
        assertEq(_feeAmount(amountIn), burnAmount);

        uint256 snapshot = vm.snapshotState();

        vm.prank(address(this));
        directBurnPolicy.burn(burnAmount);
        BurnSnapshot memory direct = _burnSnapshot();

        vm.revertToState(snapshot);

        _swap(_entenIsCurrency0(), amountIn);
        hook.burnAccrued();
        BurnSnapshot memory hookDriven = _burnSnapshot();

        assertEq(hookDriven.totalSupply, direct.totalSupply);
        assertEq(hookDriven.locked, direct.locked);
        assertEq(hookDriven.effectiveSupply, direct.effectiveSupply);
        assertEq(hookDriven.redeemBacking, direct.redeemBacking);
        assertEq(hook.accruedSellBurns(), 0);
        assertEq(enten.balanceOf(address(hook)), 0);
    }

    function testBurnAccruedReturnsZeroWhenNoSellBurnsAccrued() public {
        _deployFixture(true);

        uint256 supplyBefore = enten.totalSupply();
        assertEq(hook.burnAccrued(), 0);
        assertEq(enten.totalSupply(), supplyBefore);
        assertEq(hook.accruedSellBurns(), 0);
    }

    function testMultipleSellBurnsAccumulateBeforeBurnAccrued() public {
        _deployFixture(true);
        uint256 first = 1_000 ether;
        uint256 second = 2_000 ether;
        uint256 expectedBurn = _feeAmount(first) + _feeAmount(second);
        uint256 supplyBefore = enten.totalSupply();

        _swap(_entenIsCurrency0(), first);
        _swap(_entenIsCurrency0(), second);

        assertEq(hook.accruedSellBurns(), expectedBurn);
        assertEq(enten.totalSupply(), supplyBefore);

        hook.burnAccrued();

        assertEq(supplyBefore - enten.totalSupply(), expectedBurn);
        assertEq(hook.accruedSellBurns(), 0);
    }

    function testDustSellWithZeroFeeDoesNotAccrue() public {
        _deployFixture(true);
        uint256 dust = hook.BPS() / hook.BURN_BPS() - 1;
        uint256 supplyBefore = enten.totalSupply();

        _swap(_entenIsCurrency0(), dust);

        assertEq(hook.accruedSellBurns(), 0);
        assertEq(enten.totalSupply(), supplyBefore);
    }

    function testNonRoundSellFeeRoundsDown() public {
        _deployFixture(true);
        uint256 amountIn = 12_345_678_901;
        uint256 expectedBurn = _feeAmount(amountIn);

        _swap(_entenIsCurrency0(), amountIn);

        assertEq(hook.accruedSellBurns(), expectedBurn);
    }

    function testFuzzSellBurnAccountingMatchesDirectBurnSemantics(
        uint256 rawAmountIn,
        uint256 rawLocked,
        bool entenAsCurrency0
    ) public {
        _deployFixture(entenAsCurrency0);
        uint256 amountIn = bound(rawAmountIn, 1, 10_000 ether);
        uint256 lockedBefore = bound(rawLocked, 0, INITIAL_SUPPLY / 2);
        _setLocked(lockedBefore);
        uint256 supplyBefore = enten.totalSupply();
        uint256 effectiveBefore = _effectiveSupply();
        uint256 expectedBurn = _feeAmount(amountIn);
        uint256 expectedUnlocked = expectedBurn < lockedBefore ? expectedBurn : lockedBefore;

        _swap(_entenIsCurrency0(), amountIn);

        assertEq(hook.accruedSellBurns(), expectedBurn);
        assertEq(enten.totalSupply(), supplyBefore);

        hook.burnAccrued();

        assertEq(supplyBefore - enten.totalSupply(), expectedBurn);
        assertEq(_locked(), lockedBefore - expectedUnlocked);
        assertEq(_effectiveSupply(), effectiveBefore - (expectedBurn - expectedUnlocked));
        assertEq(hook.accruedSellBurns(), 0);
        assertEq(enten.balanceOf(address(hook)), 0);
    }

    function testFuzzBuyBurnAccountingMatchesOutputFeeAndDirectBurnSemantics(
        uint256 rawAmountIn,
        uint256 rawLocked,
        bool entenAsCurrency0
    ) public {
        _deployFixture(entenAsCurrency0);
        uint256 amountIn = bound(rawAmountIn, 1, 10_000 ether);
        uint256 lockedBefore = bound(rawLocked, 0, INITIAL_SUPPLY / 2);
        _setLocked(lockedBefore);
        uint256 supplyBefore = enten.totalSupply();
        uint256 effectiveBefore = _effectiveSupply();
        uint256 balanceBefore = enten.balanceOf(address(this));

        _swap(!_entenIsCurrency0(), amountIn);

        uint256 burned = supplyBefore - enten.totalSupply();
        uint256 received = enten.balanceOf(address(this)) - balanceBefore;
        uint256 expectedUnlocked = burned < lockedBefore ? burned : lockedBefore;

        assertEq(burned, _feeAmount(received + burned));
        assertEq(_locked(), lockedBefore - expectedUnlocked);
        assertEq(_effectiveSupply(), effectiveBefore - (burned - expectedUnlocked));
        assertEq(hook.accruedSellBurns(), 0);
        assertEq(enten.balanceOf(address(hook)), 0);
    }

    function testFuzzMixedHookBurnSequencePreservesAccounting(
        uint256 rawSellOne,
        uint256 rawBuy,
        uint256 rawSellTwo,
        uint256 rawLocked
    ) public {
        _deployFixture(true);
        uint256 sellOne = bound(rawSellOne, 1, 5_000 ether);
        uint256 buyAmountIn = bound(rawBuy, 1, 5_000 ether);
        uint256 sellTwo = bound(rawSellTwo, 1, 5_000 ether);
        uint256 lockedBefore = bound(rawLocked, 0, INITIAL_SUPPLY / 2);
        _setLocked(lockedBefore);
        uint256 supplyBefore = enten.totalSupply();
        uint256 effectiveBefore = _effectiveSupply();
        uint256 expectedSellBurns = _feeAmount(sellOne) + _feeAmount(sellTwo);

        _swap(_entenIsCurrency0(), sellOne);
        _swap(!_entenIsCurrency0(), buyAmountIn);
        uint256 buyBurn = supplyBefore - enten.totalSupply();
        _swap(_entenIsCurrency0(), sellTwo);

        assertEq(hook.accruedSellBurns(), expectedSellBurns);
        assertEq(enten.balanceOf(address(hook)), 0);

        hook.burnAccrued();

        uint256 totalBurned = expectedSellBurns + buyBurn;
        uint256 expectedUnlocked = totalBurned < lockedBefore ? totalBurned : lockedBefore;
        assertEq(supplyBefore - enten.totalSupply(), totalBurned);
        assertEq(_locked(), lockedBefore - expectedUnlocked);
        assertEq(_effectiveSupply(), effectiveBefore - (totalBurned - expectedUnlocked));
        assertEq(hook.accruedSellBurns(), 0);
        assertEq(enten.balanceOf(address(hook)), 0);
    }

    function testBeforeInitializeRejectsPoolWithoutEnten() public {
        _deployFixture(true);
        ERC20Mock other0 = new ERC20Mock();
        ERC20Mock other1 = new ERC20Mock();
        (Currency currency0, Currency currency1) = _sort(address(other0), address(other1));
        PoolKey memory nonEntenKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });

        vm.expectRevert(EntenDeflationHook.Hook__PoolMustIncludeEnten.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), nonEntenKey, SQRT_PRICE_1_1);
    }

    function testBeforeInitializeAcceptsPoolWithEnten() public {
        _deployFixture(true);

        vm.prank(address(manager));
        bytes4 selector = hook.beforeInitialize(address(this), entenKey, SQRT_PRICE_1_1);

        assertEq(selector, IHooks.beforeInitialize.selector);
    }

    function testBeforeSwapAndAfterSwapRejectPoolWithoutEnten() public {
        _deployFixture(true);
        ERC20Mock other0 = new ERC20Mock();
        ERC20Mock other1 = new ERC20Mock();
        (Currency currency0, Currency currency1) = _sort(address(other0), address(other1));
        PoolKey memory nonEntenKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });

        vm.expectRevert(EntenDeflationHook.Hook__PoolMustIncludeEnten.selector);
        vm.prank(address(manager));
        hook.beforeSwap(
            address(this),
            nonEntenKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ZERO_BYTES
        );

        vm.expectRevert(EntenDeflationHook.Hook__PoolMustIncludeEnten.selector);
        vm.prank(address(manager));
        hook.afterSwap(
            address(this),
            nonEntenKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            toBalanceDelta(0, 0),
            ZERO_BYTES
        );
    }

    function testOnlyPoolManagerCanCallPoolCallbacks() public {
        _deployFixture(true);

        vm.expectRevert(abi.encodeWithSelector(EntenDeflationHook.Hook__OnlyPoolManager.selector, address(this)));
        hook.beforeInitialize(address(this), entenKey, SQRT_PRICE_1_1);

        vm.expectRevert(abi.encodeWithSelector(EntenDeflationHook.Hook__OnlyPoolManager.selector, address(this)));
        hook.beforeSwap(
            address(this),
            entenKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ZERO_BYTES
        );

        vm.expectRevert(abi.encodeWithSelector(EntenDeflationHook.Hook__OnlyPoolManager.selector, address(this)));
        hook.afterSwap(
            address(this),
            entenKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            toBalanceDelta(0, 0),
            ZERO_BYTES
        );

        vm.expectRevert(abi.encodeWithSelector(EntenDeflationHook.Hook__OnlyPoolManager.selector, address(this)));
        hook.unlockCallback(abi.encode(uint256(1)));
    }

    function testBurnNoOpsWhenDeflationBurnerNotConfigured() public {
        _deployFixtureWithoutActivatingHook(true);
        uint256 supplyBefore = enten.totalSupply();
        _swap(_entenIsCurrency0(), 1_000 ether);

        assertEq(hook.burnAccrued(), 0);
        assertEq(enten.totalSupply(), supplyBefore);
        assertEq(hook.accruedSellBurns(), 0);
    }

    function testBurnAccruedNoOpsWhenBurnerModuleDisabledAndKeepsAccrual() public {
        _deployFixture(true);
        _swap(_entenIsCurrency0(), 1_000 ether);
        uint256 accrued = hook.accruedSellBurns();

        vm.prank(admin);
        controller.setModuleDisabled(toKeycode("BRNER"), true);

        assertEq(hook.burnAccrued(), 0);

        assertEq(hook.accruedSellBurns(), accrued);
    }

    function testBeforeSwapRevertsWhenBurnAmountExceedsInt128() public {
        _deployFixture(true);
        uint256 tooLargeInput = ((uint256(1) << 127) * hook.BPS() + hook.BURN_BPS() - 1) / hook.BURN_BPS();

        vm.expectRevert(EntenDeflationHook.Hook__AmountTooLarge.selector);
        vm.prank(address(manager));
        hook.beforeSwap(
            address(this),
            entenKey,
            SwapParams({
                zeroForOne: _entenIsCurrency0(),
                amountSpecified: -tooLargeInput.toInt256(),
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            ZERO_BYTES
        );
    }

    function testAfterSwapRevertsWhenDeltaIsInt128Min() public {
        _deployFixture(true);
        bool zeroForOne = !_entenIsCurrency0();
        BalanceDelta delta =
            _entenIsCurrency0() ? toBalanceDelta(type(int128).min, 0) : toBalanceDelta(0, type(int128).min);

        vm.expectRevert(EntenDeflationHook.Hook__AmountTooLarge.selector);
        vm.prank(address(manager));
        hook.afterSwap(
            address(this),
            entenKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            delta,
            ZERO_BYTES
        );
    }

    function testUnsupportedHookMethodsRevert() public {
        _deployFixture(true);
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});

        vm.expectRevert(EntenDeflationHook.Hook__Unsupported.selector);
        hook.afterInitialize(address(this), entenKey, SQRT_PRICE_1_1, 0);

        vm.expectRevert(EntenDeflationHook.Hook__Unsupported.selector);
        hook.beforeAddLiquidity(address(this), entenKey, liquidityParams, ZERO_BYTES);

        vm.expectRevert(EntenDeflationHook.Hook__Unsupported.selector);
        hook.afterAddLiquidity(
            address(this), entenKey, liquidityParams, toBalanceDelta(0, 0), toBalanceDelta(0, 0), ZERO_BYTES
        );

        vm.expectRevert(EntenDeflationHook.Hook__Unsupported.selector);
        hook.beforeRemoveLiquidity(address(this), entenKey, liquidityParams, ZERO_BYTES);

        vm.expectRevert(EntenDeflationHook.Hook__Unsupported.selector);
        hook.afterRemoveLiquidity(
            address(this), entenKey, liquidityParams, toBalanceDelta(0, 0), toBalanceDelta(0, 0), ZERO_BYTES
        );

        vm.expectRevert(EntenDeflationHook.Hook__Unsupported.selector);
        hook.beforeDonate(address(this), entenKey, 1, 1, ZERO_BYTES);

        vm.expectRevert(EntenDeflationHook.Hook__Unsupported.selector);
        hook.afterDonate(address(this), entenKey, 1, 1, ZERO_BYTES);
    }

    function _assertSellAccruesAndBurnsInputEntenThroughModule() internal {
        bool zeroForOne = _entenIsCurrency0();
        uint256 amountIn = 1_000 ether;
        uint256 expectedBurn = _feeAmount(amountIn);
        uint256 supplyBefore = enten.totalSupply();

        _swap(zeroForOne, amountIn);

        assertEq(enten.totalSupply(), supplyBefore);
        assertEq(hook.accruedSellBurns(), expectedBurn);

        hook.burnAccrued();

        assertEq(supplyBefore - enten.totalSupply(), expectedBurn);
        assertEq(enten.balanceOf(address(hook)), 0);
        assertEq(hook.accruedSellBurns(), 0);
    }

    function _assertBuyBurnsOutputEntenImmediatelyThroughModule() internal {
        bool zeroForOne = !_entenIsCurrency0();
        uint256 entenBefore = enten.balanceOf(address(this));
        uint256 supplyBefore = enten.totalSupply();

        _swap(zeroForOne, 1_000 ether);

        uint256 burned = supplyBefore - enten.totalSupply();
        uint256 received = enten.balanceOf(address(this)) - entenBefore;
        uint256 rawEntenOutput = received + burned;

        assertGt(burned, 0);
        assertEq(burned, _feeAmount(rawEntenOutput));
        assertEq(enten.balanceOf(address(hook)), 0);
        assertEq(hook.accruedSellBurns(), 0);
    }

    function _assertExactOutputSellBurnsInputEnten() internal {
        uint256 amountOut = 100 ether;
        uint256 entenBefore = enten.balanceOf(address(this));
        uint256 supplyBefore = enten.totalSupply();

        _swapExactOutput(entenKey, _entenIsCurrency0(), amountOut);

        uint256 grossEntenIn = entenBefore - enten.balanceOf(address(this));
        uint256 burned = supplyBefore - enten.totalSupply();

        assertGt(burned, 0);
        assertEq(burned, _feeAmount(grossEntenIn));
        assertEq(hook.accruedSellBurns(), 0);
        assertEq(enten.balanceOf(address(hook)), 0);
    }

    function _assertExactOutputBuyBurnsOutputEnten() internal {
        uint256 amountOut = 100 ether;
        uint256 entenBefore = enten.balanceOf(address(this));
        uint256 supplyBefore = enten.totalSupply();

        _swapExactOutput(entenKey, !_entenIsCurrency0(), amountOut);

        uint256 received = enten.balanceOf(address(this)) - entenBefore;
        uint256 burned = supplyBefore - enten.totalSupply();

        assertEq(received, amountOut);
        assertGt(burned, 0);
        assertEq(burned, _feeAmount(received + burned));
        assertEq(hook.accruedSellBurns(), 0);
        assertEq(enten.balanceOf(address(hook)), 0);
    }

    function _deployFixture(bool entenAsCurrency0) internal {
        _deployFixture({entenAsCurrency0: entenAsCurrency0, activateHook: true});
    }

    function _deployFixtureWithoutActivatingHook(bool entenAsCurrency0) internal {
        _deployFixture({entenAsCurrency0: entenAsCurrency0, activateHook: false});
    }

    function _deployFixture(bool entenAsCurrency0, bool activateHook) internal {
        IV4PoolManagerDeployer deployer =
            IV4PoolManagerDeployer(deployCode("V4PoolManagerDeployer.sol:V4PoolManagerDeployer"));
        manager = IPoolManager(deployer.deploy(address(this)));
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        _deployEntenCore();
        quote = _deployQuoteForOrientation(entenAsCurrency0);
        quote.mint(address(this), INITIAL_SUPPLY);

        burner = new BurnerModule(address(controller), address(kernel), address(0), 0);
        directBurnPolicy = new BurnerPolicy(address(controller));

        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        deployCodeTo(
            "EntenDeflationHook.sol:EntenDeflationHook",
            abi.encode(address(controller), manager, address(enten)),
            hookAddress
        );
        hook = EntenDeflationHook(hookAddress);

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(burner));
        controller.executeAction(Actions.ActivatePolicy, address(directBurnPolicy));
        if (activateHook) controller.executeAction(Actions.ActivatePolicy, address(hook));
        vm.stopPrank();

        enten.approve(address(modifyLiquidityRouter), type(uint256).max);
        enten.approve(address(swapRouter), type(uint256).max);
        quote.approve(address(modifyLiquidityRouter), type(uint256).max);
        quote.approve(address(swapRouter), type(uint256).max);

        (Currency currency0, Currency currency1) = _sort(address(enten), address(quote));
        entenKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        assertEq(_entenIsCurrency0(), entenAsCurrency0);

        manager.initialize(entenKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            entenKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e22, salt: 0}),
            ZERO_BYTES
        );
    }

    function _deployQuoteForOrientation(bool entenAsCurrency0) internal returns (ERC20Mock quote_) {
        uint160 entenAddress = uint160(address(enten));
        address quoteAddress = entenAsCurrency0 ? address(entenAddress + 1) : address(entenAddress - 1);
        deployCodeTo("ERC20Mock.sol:ERC20Mock", quoteAddress);
        quote_ = ERC20Mock(quoteAddress);
    }

    function _deployEntenCore() internal {
        uint256 nonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedToken = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedController = vm.computeCreateAddress(address(this), nonce + 3);

        kernel = new Kernel(predictedController, predictedVault);
        vault = new Vault(predictedController, predictedKernel);
        enten = new Token("Enten", "ENTEN", predictedController, address(this), INITIAL_SUPPLY, type(uint256).max);
        controller = new Controller(admin, protocolCollector, predictedKernel, predictedVault, predictedToken);
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        return _swap(entenKey, zeroForOne, amountIn);
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _swapExactOutput(PoolKey memory key, bool zeroForOne, uint256 amountOut) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountOut.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _deployAdditionalEntenPool(uint160 quoteOffset) internal returns (PoolKey memory key) {
        ERC20Mock secondQuote = ERC20Mock(address(uint160(address(enten)) + quoteOffset));
        deployCodeTo("ERC20Mock.sol:ERC20Mock", address(secondQuote));
        secondQuote.mint(address(this), INITIAL_SUPPLY);
        secondQuote.approve(address(modifyLiquidityRouter), type(uint256).max);
        secondQuote.approve(address(swapRouter), type(uint256).max);

        (Currency currency0, Currency currency1) = _sort(address(enten), address(secondQuote));
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e22, salt: 0}),
            ZERO_BYTES
        );
    }

    function _setLocked(uint256 amount) internal {
        vm.prank(address(controller));
        kernel.updateState(Slots.TEAM_LOCKED_TOKENS_SLOT, bytes32(amount));
    }

    function _burnSnapshot() internal view returns (BurnSnapshot memory snapshot) {
        snapshot = BurnSnapshot({
            totalSupply: enten.totalSupply(),
            locked: _locked(),
            effectiveSupply: _effectiveSupply(),
            redeemBacking: _redeemBacking(address(quote))
        });
    }

    function _redeemBacking(address token_) internal view returns (uint256) {
        return uint256(kernel.viewData(Slots.slots(Slots.BACKING_AMOUNT_SLOT, token_)));
    }

    function _locked() internal view returns (uint256) {
        return uint256(kernel.viewData(Slots.TEAM_LOCKED_TOKENS_SLOT));
    }

    function _effectiveSupply() internal view returns (uint256) {
        return enten.totalSupply() - _locked();
    }

    function _feeAmount(uint256 amount) internal view returns (uint256) {
        return amount * hook.BURN_BPS() / hook.BPS();
    }

    function _entenIsCurrency0() internal view returns (bool) {
        return _entenIsCurrency0(entenKey);
    }

    function _entenIsCurrency0(PoolKey memory key) internal view returns (bool) {
        return Currency.unwrap(key.currency0) == address(enten);
    }

    function _sort(address a, address b) internal pure returns (Currency currency0, Currency currency1) {
        (currency0, currency1) = a < b ? (Currency.wrap(a), Currency.wrap(b)) : (Currency.wrap(b), Currency.wrap(a));
    }
}
