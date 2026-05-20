///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/*
    @title Team Locker
    @notice Minimal Vesting contract for Enten Token Team tokens that uses a burn-to-vest
    mechanism. Reading from the unified Kernel Storage space to see how many tokens are locked
    and claiming what is available.
    @author 0xChihiro
*/

import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IKernel} from "enten-v1/interfaces/IKernel.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";

contract TeamLocker is AccessControl {
    using SafeERC20 for IERC20;
    bytes32 public constant CLAIMER_ROLE = keccak256("CLAIMER_ROLE");

    uint256 public immutable STARTING_LOCKED;
    address public immutable TOKEN;
    IKernel public immutable KERNEL;

    uint256 public claimed;

    error TeamLocker__NotEnoughTokensUnlocked();
    error TeamLocked__NoTokensToClaim();

    event TeamLocker__Claim(address indexed caller, address indexed receiver, uint256 amount);

    constructor(uint256 lockedTokens, address admin, address token, address kernel) {
        STARTING_LOCKED = lockedTokens;
        TOKEN = token;
        KERNEL = IKernel(kernel);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CLAIMER_ROLE, admin);
    }

    function claim(uint256 amount, address receiver) external onlyRole(CLAIMER_ROLE) {
        uint256 stillLocked = uint256(KERNEL.viewData(Slots.TEAM_LOCKED_TOKENS_SLOT));
        uint256 availableForClaim = STARTING_LOCKED - claimed - stillLocked;
        if (amount > availableForClaim) revert TeamLocker__NotEnoughTokensUnlocked();
        claimed += amount;
        IERC20(TOKEN).safeTransfer(receiver, amount);
        emit TeamLocker__Claim(msg.sender, receiver, amount);
    }

    function claimAll(address receiver) external onlyRole(CLAIMER_ROLE) {
        uint256 stillLocked = uint256(KERNEL.viewData(Slots.TEAM_LOCKED_TOKENS_SLOT));
        uint256 availableForClaim = STARTING_LOCKED - claimed - stillLocked;
        if (availableForClaim > 0) {
            claimed += availableForClaim;
            IERC20(TOKEN).safeTransfer(receiver, availableForClaim);
            emit TeamLocker__Claim(msg.sender, receiver, availableForClaim);
        } else {
            revert TeamLocked__NoTokensToClaim();
        }
    }
}
