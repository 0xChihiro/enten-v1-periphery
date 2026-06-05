///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IBurner} from "../interfaces/IBurner.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {IToken} from "enten-v1/interfaces/IToken.sol";
import {Policy} from "enten-v1/Policy.sol";
import {Keycode, Permissions, toKeycode} from "enten-v1/Utils.sol";

contract EntenDeflationHook is IHooks, IUnlockCallback, Policy {
    using SafeCast for int128;
    using SafeCast for uint256;

    uint256 public constant BPS = 10_000;
    uint256 public constant BURN_BPS = 70;

    IPoolManager public immutable POOL_MANAGER;
    Currency public immutable ENTEN;

    address public deflationBurner;
    uint256 public accruedSellBurns;

    error Hook__OnlyPoolManager(address caller);
    error Hook__ZeroAddress();
    error Hook__TokenControllerMismatch();
    error Hook__PoolMustIncludeEnten();
    error Hook__AmountTooLarge();
    error Hook__DeflationBurnerNotConfigured();
    error Hook__Unsupported();

    event EntenBurnAccrued(uint256 amount);
    event EntenBurned(uint256 amount);

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert Hook__OnlyPoolManager(msg.sender);
        _;
    }

    constructor(address controller, IPoolManager poolManager, address entenToken) Policy(controller) {
        if (address(poolManager) == address(0) || entenToken == address(0)) revert Hook__ZeroAddress();
        if (IToken(entenToken).CONTROLLER() != controller) revert Hook__TokenControllerMismatch();

        POOL_MANAGER = poolManager;
        ENTEN = Currency.wrap(entenToken);

        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function KEYCODE() public pure override returns (Keycode) {
        return toKeycode("VHOKP");
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function configureDependencies() external override onlyController returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](1);
        dependencies[0] = toKeycode("BRNER");

        deflationBurner = getModuleAddress(dependencies[0]);
    }

    function requestPermissions() external pure override returns (Permissions[] memory requests) {
        requests = new Permissions[](1);
        requests[0] =
            Permissions({keycode: Keycode.wrap("BRNER"), funcSelector: IBurner.executeDeflationaryAction.selector});
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        _validateEntenPool(key);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validateEntenPool(key);
        if (!_burningEnabled()) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        Currency output = params.zeroForOne ? key.currency1 : key.currency0;
        if (params.amountSpecified > 0) {
            if (!_isEnten(output)) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

            uint256 exactOutputBurnAmount = _grossUpFeeAmount(uint256(params.amountSpecified));
            if (exactOutputBurnAmount == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_toInt128(exactOutputBurnAmount), 0), 0);
        }

        if (!_isEnten(input)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 burnAmount = _feeAmount(uint256(-params.amountSpecified));
        if (burnAmount == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        int128 burnDelta = _toInt128(burnAmount);
        accruedSellBurns += burnAmount;
        POOL_MANAGER.mint(address(this), _entenId(), burnAmount);

        emit EntenBurnAccrued(burnAmount);

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(burnDelta, 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        _validateEntenPool(key);
        if (!_burningEnabled()) return (IHooks.afterSwap.selector, 0);

        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        Currency output = params.zeroForOne ? key.currency1 : key.currency0;
        uint256 burnAmount;

        if (params.amountSpecified > 0) {
            if (_isEnten(output)) {
                burnAmount = _grossUpFeeAmount(uint256(params.amountSpecified));
                if (burnAmount == 0) return (IHooks.afterSwap.selector, 0);

                _takeAndBurnEnten(burnAmount);
                return (IHooks.afterSwap.selector, 0);
            }

            if (!_isEnten(input)) return (IHooks.afterSwap.selector, 0);
            burnAmount = _grossUpFeeAmount(_absInt128(params.zeroForOne ? delta.amount0() : delta.amount1()));
        } else {
            if (!_isEnten(output)) return (IHooks.afterSwap.selector, 0);
            burnAmount = _feeAmount(_absInt128(params.zeroForOne ? delta.amount1() : delta.amount0()));
        }
        if (burnAmount == 0) return (IHooks.afterSwap.selector, 0);

        int128 burnDelta = _toInt128(burnAmount);
        _takeAndBurnEnten(burnAmount);

        return (IHooks.afterSwap.selector, burnDelta);
    }

    function burnAccrued() external returns (uint256 amount) {
        amount = accruedSellBurns;
        if (amount == 0) return 0;
        if (!_burningEnabled()) return 0;

        accruedSellBurns = 0;
        POOL_MANAGER.unlock(abi.encode(amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert Hook__OnlyPoolManager(msg.sender);

        uint256 amount = abi.decode(data, (uint256));
        POOL_MANAGER.burn(address(this), _entenId(), amount);
        POOL_MANAGER.take(ENTEN, address(this), amount);
        _burnEnten(amount);

        return "";
    }

    function _validateEntenPool(PoolKey calldata key) internal view {
        if (!_isEnten(key.currency0) && !_isEnten(key.currency1)) revert Hook__PoolMustIncludeEnten();
    }

    function _isEnten(Currency currency) internal view returns (bool) {
        return Currency.unwrap(currency) == Currency.unwrap(ENTEN);
    }

    function _feeAmount(uint256 amount) internal pure returns (uint256) {
        return amount * BURN_BPS / BPS;
    }

    function _grossUpFeeAmount(uint256 netAmount) internal pure returns (uint256) {
        if (netAmount == 0) return 0;

        uint256 grossAmount = (netAmount * BPS + (BPS - BURN_BPS) - 1) / (BPS - BURN_BPS);
        if (_feeAmount(grossAmount) == 0) return 0;

        while (grossAmount > netAmount) {
            uint256 previousGross = grossAmount - 1;
            uint256 previousFee = _feeAmount(previousGross);
            if (previousFee == 0 || previousGross - previousFee < netAmount) break;
            grossAmount = previousGross;
        }

        return grossAmount - netAmount;
    }

    function _entenId() internal view returns (uint256) {
        return uint160(Currency.unwrap(ENTEN));
    }

    function _toInt128(uint256 amount) internal pure returns (int128) {
        if (amount >= 1 << 127) revert Hook__AmountTooLarge();
        return amount.toInt128();
    }

    function _absInt128(int128 amount) internal pure returns (uint256) {
        if (amount == type(int128).min) revert Hook__AmountTooLarge();
        if (amount < 0) amount = -amount;
        return uint256(amount.toUint128());
    }

    function _burningEnabled() internal view returns (bool) {
        Keycode burnerKeycode = toKeycode("BRNER");
        return deflationBurner != address(0) && CONTROLLER.isPolicyActive(address(this))
            && CONTROLLER.modulePermissions(burnerKeycode, address(this), IBurner.executeDeflationaryAction.selector)
            && !CONTROLLER.moduleDisabled(burnerKeycode) && !CONTROLLER.settlementsPaused();
    }

    function _takeAndBurnEnten(uint256 amount) internal {
        POOL_MANAGER.take(ENTEN, address(this), amount);
        _burnEnten(amount);
    }

    function _burnEnten(uint256 amount) internal {
        address burner = deflationBurner;
        if (burner == address(0)) revert Hook__DeflationBurnerNotConfigured();

        IBurner(burner).executeDeflationaryAction(IBurner.Action.Burn, address(this), amount);
        emit EntenBurned(amount);
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert Hook__Unsupported();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert Hook__Unsupported();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert Hook__Unsupported();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert Hook__Unsupported();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert Hook__Unsupported();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert Hook__Unsupported();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert Hook__Unsupported();
    }
}
