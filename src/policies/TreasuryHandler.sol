///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ITreasury} from "../interfaces/ITreasury.sol";
import {Policy} from "enten-v1/Policy.sol";
import {TRSRY} from "../modules/TRSRY/TRSRY.v1.sol";
import {Keycode, Permissions} from "enten-v1/Utils.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Actions as V4Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "openzeppelin/contracts/utils/math/SafeCast.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

contract TreasuryHandler is Policy, AccessControl {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    Keycode internal constant TRSRY_KEYCODE = Keycode.wrap("TRSRY");
    Keycode internal constant TREASURY_HANDLER_KEYCODE = Keycode.wrap("TRHDL");
    uint48 internal constant MAX_APPROVAL_EXPIRATION = type(uint48).max;

    struct AddLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        uint256 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        bytes hookData;
        uint256 deadline;
    }

    TRSRY public TRSRYv1;
    IUniversalRouter public immutable UNIVERSAL_ROUTER;
    IPositionManager public immutable POSITION_MANAGER;
    IAllowanceTransfer public immutable PERMIT2;
    address public immutable TOKEN_ZERO;
    address public immutable TOKEN_ONE;
    PoolKey public liquidityPoolKey;
    uint256 public liquidityTokenId;
    int24 public liquidityTickLower;
    int24 public liquidityTickUpper;

    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant SWAP_ROLE = keccak256("SWAP_ROLE");
    bytes32 public constant ADD_LIQUIDITY_ROLE = keccak256("ADD_LIQUIDITY_ROLE");

    event TreasuryAssetsTaken(ITreasury.Asset[] assets);
    event TokensSwapped(
        address indexed router, address indexed fromToken, address indexed toToken, uint256 amountIn, uint256 amountOut
    );
    event LiquidityAdded(
        uint256 indexed tokenId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        int24 tickLower,
        int24 tickUpper
    );

    error TreasuryHandler__ZeroAddress();
    error TreasuryHandler__TreasuryNotConfigured();
    error TreasuryHandler__UnsupportedLiquidityToken(address token);
    error TreasuryHandler__InvalidSwap();
    error TreasuryHandler__ZeroAmount();
    error TreasuryHandler__Slippage(uint256 received, uint256 minAmountOut);
    error TreasuryHandler__RouterOverspent(uint256 spent, uint256 maxAmountIn);
    error TreasuryHandler__InsufficientBalance(address token, uint256 balance, uint256 required);
    error TreasuryHandler__Expired();
    error TreasuryHandler__InvalidTickRange();
    error TreasuryHandler__PositionRangeMismatch();

    constructor(
        address controller,
        address universalRouter,
        address positionManager,
        address permit2,
        PoolKey memory poolKey,
        address admin
    ) Policy(controller) {
        if (
            controller == address(0) || universalRouter == address(0) || positionManager == address(0)
                || permit2 == address(0) || admin == address(0)
        ) {
            revert TreasuryHandler__ZeroAddress();
        }

        address tokenZero = Currency.unwrap(poolKey.currency0);
        address tokenOne = Currency.unwrap(poolKey.currency1);
        if (tokenZero == address(0) || tokenOne == address(0) || tokenZero == tokenOne) {
            revert TreasuryHandler__ZeroAddress();
        }

        UNIVERSAL_ROUTER = IUniversalRouter(universalRouter);
        POSITION_MANAGER = IPositionManager(positionManager);
        PERMIT2 = IAllowanceTransfer(permit2);
        liquidityPoolKey = poolKey;
        TOKEN_ZERO = tokenZero;
        TOKEN_ONE = tokenOne;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TREASURY_ROLE, admin);
        _grantRole(SWAP_ROLE, admin);
        _grantRole(ADD_LIQUIDITY_ROLE, admin);
    }

    function KEYCODE() public pure override returns (Keycode) {
        return TREASURY_HANDLER_KEYCODE;
    }

    function configureDependencies() external override onlyController returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](1);
        dependencies[0] = TRSRY_KEYCODE;

        TRSRYv1 = TRSRY(getModuleAddress(dependencies[0]));
    }

    function requestPermissions() external pure override returns (Permissions[] memory permissions) {
        permissions = new Permissions[](1);
        permissions[0] = Permissions(TRSRY_KEYCODE, TRSRY.execute.selector);
    }

    function addLiquidity(AddLiquidityParams calldata params)
        external
        onlyRole(ADD_LIQUIDITY_ROLE)
        returns (uint256 tokenId)
    {
        if (block.timestamp > params.deadline) revert TreasuryHandler__Expired();
        if (params.liquidity == 0) revert TreasuryHandler__ZeroAmount();
        if (params.tickLower >= params.tickUpper) revert TreasuryHandler__InvalidTickRange();

        bool minting = liquidityTokenId == 0;
        if (minting) {
            tokenId = POSITION_MANAGER.nextTokenId();
        } else {
            if (params.tickLower != liquidityTickLower || params.tickUpper != liquidityTickUpper) {
                revert TreasuryHandler__PositionRangeMismatch();
            }
            tokenId = liquidityTokenId;
        }

        _approvePositionToken(TOKEN_ZERO, params.amount0Max);
        _approvePositionToken(TOKEN_ONE, params.amount1Max);

        POSITION_MANAGER.modifyLiquidities(_encodeAddLiquidity(params, tokenId, minting), params.deadline);

        _clearPositionTokenApproval(TOKEN_ZERO);
        _clearPositionTokenApproval(TOKEN_ONE);

        if (minting) {
            liquidityTokenId = tokenId;
            liquidityTickLower = params.tickLower;
            liquidityTickUpper = params.tickUpper;
        }

        emit LiquidityAdded(
            tokenId, params.liquidity, params.amount0Max, params.amount1Max, params.tickLower, params.tickUpper
        );
    }

    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external onlyRole(SWAP_ROLE) returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert TreasuryHandler__Expired();
        if (amountIn == 0) revert TreasuryHandler__ZeroAmount();
        if (fromToken == address(0) || toToken == address(0) || fromToken == toToken) {
            revert TreasuryHandler__InvalidSwap();
        }
        if (!_isLiquidityToken(toToken)) revert TreasuryHandler__UnsupportedLiquidityToken(toToken);
        uint256 fromBalance = IERC20(fromToken).balanceOf(address(this));
        if (fromBalance < amountIn) revert TreasuryHandler__InsufficientBalance(fromToken, fromBalance, amountIn);

        uint256 spent;
        (amountOut, spent) = _executeUniversalRouterSwap(fromToken, toToken, amountIn, commands, inputs, deadline);
        if (spent > amountIn) revert TreasuryHandler__RouterOverspent(spent, amountIn);
        if (amountOut < minAmountOut) revert TreasuryHandler__Slippage(amountOut, minAmountOut);

        emit TokensSwapped(address(UNIVERSAL_ROUTER), fromToken, toToken, amountIn, amountOut);
    }

    /// @notice bring assets into the treasury to be swapped and added to liquidity.
    function take(ITreasury.Asset[] calldata assets) external onlyRole(TREASURY_ROLE) {
        _treasury().execute(ITreasury.TreasuryAction.Deploy, address(this), assets);

        emit TreasuryAssetsTaken(assets);
    }

    function _approveSwapToken(address token, uint256 amount) internal {
        _approveTokenForPermit2(token, amount);
        PERMIT2.approve(token, address(UNIVERSAL_ROUTER), amount.toUint160(), MAX_APPROVAL_EXPIRATION);
        IERC20(token).forceApprove(address(UNIVERSAL_ROUTER), amount);
    }

    function _encodeAddLiquidity(AddLiquidityParams calldata addParams, uint256 tokenId, bool minting)
        internal
        view
        returns (bytes memory)
    {
        bytes memory actions = new bytes(3);
        bytes[] memory actionParams = new bytes[](3);
        PoolKey memory poolKey = liquidityPoolKey;

        if (minting) {
            actions[0] = bytes1(uint8(V4Actions.MINT_POSITION));
            actionParams[0] = abi.encode(
                poolKey,
                addParams.tickLower,
                addParams.tickUpper,
                addParams.liquidity,
                addParams.amount0Max,
                addParams.amount1Max,
                address(this),
                addParams.hookData
            );
        } else {
            actions[0] = bytes1(uint8(V4Actions.INCREASE_LIQUIDITY));
            actionParams[0] = abi.encode(
                tokenId, addParams.liquidity, addParams.amount0Max, addParams.amount1Max, addParams.hookData
            );
        }

        actions[1] = bytes1(uint8(V4Actions.CLOSE_CURRENCY));
        actionParams[1] = abi.encode(poolKey.currency0);
        actions[2] = bytes1(uint8(V4Actions.CLOSE_CURRENCY));
        actionParams[2] = abi.encode(poolKey.currency1);

        return abi.encode(actions, actionParams);
    }

    function _executeUniversalRouterSwap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) internal returns (uint256 amountOut, uint256 spent) {
        uint256 fromBalanceBefore = IERC20(fromToken).balanceOf(address(this));
        uint256 toBalanceBefore = IERC20(toToken).balanceOf(address(this));

        _approveSwapToken(fromToken, amountIn);
        UNIVERSAL_ROUTER.execute(commands, inputs, deadline);
        _clearSwapTokenApproval(fromToken);

        uint256 fromBalanceAfter = IERC20(fromToken).balanceOf(address(this));
        uint256 toBalanceAfter = IERC20(toToken).balanceOf(address(this));

        spent = fromBalanceBefore > fromBalanceAfter ? fromBalanceBefore - fromBalanceAfter : 0;
        amountOut = toBalanceAfter - toBalanceBefore;
    }

    function _clearSwapTokenApproval(address token) internal {
        PERMIT2.approve(token, address(UNIVERSAL_ROUTER), 0, 0);
        IERC20(token).forceApprove(address(UNIVERSAL_ROUTER), 0);
        IERC20(token).forceApprove(address(PERMIT2), 0);
    }

    function _approvePositionToken(address token, uint256 amount) internal {
        if (amount == 0) return;

        _approveTokenForPermit2(token, amount);
        PERMIT2.approve(token, address(POSITION_MANAGER), amount.toUint160(), MAX_APPROVAL_EXPIRATION);
    }

    function _clearPositionTokenApproval(address token) internal {
        PERMIT2.approve(token, address(POSITION_MANAGER), 0, 0);
        IERC20(token).forceApprove(address(PERMIT2), 0);
    }

    function _approveTokenForPermit2(address token, uint256 amount) internal {
        IERC20(token).forceApprove(address(PERMIT2), amount);
    }

    function _isLiquidityToken(address token) internal view returns (bool) {
        return token == TOKEN_ZERO || token == TOKEN_ONE;
    }

    function _treasury() internal view returns (TRSRY treasury) {
        treasury = TRSRYv1;
        if (address(treasury) == address(0)) revert TreasuryHandler__TreasuryNotConfigured();
    }
}
