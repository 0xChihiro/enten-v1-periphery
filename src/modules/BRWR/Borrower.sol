///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IBorrower} from "../../interfaces/IBorrower.sol";
import {IEntenToken} from "enten-v1/interfaces/IEntenToken.sol";
import {BRWRv1} from "./BRWR.v1.sol";
import {IKernel} from "enten-v1/interfaces/IKernel.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";

interface IControllerTokenView {
    function TOKEN() external view returns (address);
}

contract Borrower is IBorrower, BRWRv1 {
    uint256 internal constant WAD = 1e18;

    IKernel public immutable KERNEL;
    IEntenToken public immutable TOKEN;

    constructor(address controller, address kernel) BRWRv1(controller) {
        KERNEL = IKernel(kernel);
        address token = IControllerTokenView(controller).TOKEN();
        if (token == address(0)) revert Borrower__TokenZeroAddress();
        TOKEN = IEntenToken(token);
    }

    function executeBorrowAction(Action action, address user, bytes calldata data) external permissioned {
        (UserPosition memory position, uint256 userSlot) = _getPosition(user);
        ActionData memory actionData = abi.decode(data, (ActionData));
        UserPosition memory updatedPosition = _buildUpdatedPosition(action, position, actionData);
        _validatePosition(updatedPosition);
        IController.StateUpdate[] memory positionUpdates = _updatedSlots(position, updatedPosition, userSlot);
        if (action == Action.Borrow) {
            IController.Settlement memory settlement = IController.Settlement({
                payer: user,
                amount: 0,
                transition: IController.StateTransitions.Borrow,
                receipts: actionData.receipts,
                singleStateUpdates: positionUpdates,
                multiStateUpdates: new IController.StateUpdates[](0)
            });
            IController.Settlement[] memory datas = new IController.Settlement[](1);
            datas[0] = settlement;
            CONTROLLER.settle(datas);
        } else if (action == Action.Deposit) {
            if (actionData.receipts.length != 0) revert Borrower__UseDepositAndBorrow();
            IController.Settlement memory settlement = IController.Settlement({
                payer: user,
                amount: actionData.collateralAmount,
                transition: IController.StateTransitions.Deposit,
                receipts: actionData.receipts,
                singleStateUpdates: positionUpdates,
                multiStateUpdates: new IController.StateUpdates[](0)
            });
            IController.Settlement[] memory datas = new IController.Settlement[](1);
            datas[0] = settlement;
            CONTROLLER.settle(datas);
        } else if (action == Action.Withdraw) {
            IController.Settlement memory settlement = IController.Settlement({
                payer: user,
                amount: actionData.collateralAmount,
                transition: IController.StateTransitions.Withdraw,
                receipts: actionData.receipts,
                singleStateUpdates: positionUpdates,
                multiStateUpdates: new IController.StateUpdates[](0)
            });
            IController.Settlement[] memory datas = new IController.Settlement[](1);
            datas[0] = settlement;
            CONTROLLER.settle(datas);
        } else if (action == Action.Repay) {
            IController.Settlement memory settlement = IController.Settlement({
                payer: user,
                amount: 0,
                transition: IController.StateTransitions.Repay,
                receipts: actionData.receipts,
                singleStateUpdates: positionUpdates,
                multiStateUpdates: new IController.StateUpdates[](0)
            });
            IController.Settlement[] memory datas = new IController.Settlement[](1);
            datas[0] = settlement;
            CONTROLLER.settle(datas);
        } else if (action == Action.DepositAndBorrow) {
            IController.Settlement memory settlement = IController.Settlement({
                payer: user,
                amount: actionData.collateralAmount,
                transition: IController.StateTransitions.Deposit,
                receipts: actionData.receipts,
                singleStateUpdates: positionUpdates,
                multiStateUpdates: new IController.StateUpdates[](0)
            });
            IController.Settlement[] memory datas = new IController.Settlement[](1);
            datas[0] = settlement;
            CONTROLLER.settle(datas);
        } else if (action == Action.RepayAndWithdraw) {
            IController.Settlement memory settlement = IController.Settlement({
                payer: user,
                amount: actionData.collateralAmount,
                transition: IController.StateTransitions.Withdraw,
                receipts: actionData.receipts,
                singleStateUpdates: positionUpdates,
                multiStateUpdates: new IController.StateUpdates[](0)
            });
            IController.Settlement[] memory datas = new IController.Settlement[](1);
            datas[0] = settlement;
            CONTROLLER.settle(datas);
        } else {
            revert Borrower__ActionNotPossible();
        }
    }

    function positions(address user) external view returns (UserPosition memory position) {
        (position,) = _getPosition(user);
    }

    function _getPosition(address user) internal view returns (UserPosition memory position, uint256 userSlot) {
        bytes32 slot = Slots.USER_POSITION_BASE_SLOT;

        assembly ("memory-safe") {
            mstore(0x00, slot)
            mstore(0x20, and(user, 0xffffffffffffffffffffffffffffffffffffffff))
            userSlot := keccak256(0x00, 0x40)
        }

        // Read collateral and debt.length together.
        bytes memory header = KERNEL.viewData(bytes32(userSlot), 2);

        uint256 collateral;
        uint256 debtLen;

        assembly ("memory-safe") {
            collateral := mload(add(header, 0x20))
            debtLen := mload(add(header, 0x40))
        }

        DebtPosition[] memory debt = new DebtPosition[](debtLen);

        if (debtLen != 0) {
            // Custom contiguous layout starts debt data immediately after the header.
            bytes memory rawDebtData = KERNEL.viewData(bytes32(userSlot + 2), debtLen * 2);

            for (uint256 i; i < debtLen;) {
                bytes32 assetWord;
                uint256 amount;
                uint256 offset = i * 64;

                assembly ("memory-safe") {
                    assetWord := mload(add(add(rawDebtData, 0x20), offset))
                    amount := mload(add(add(rawDebtData, 0x40), offset))
                }

                debt[i] = DebtPosition({asset: address(uint160(uint256(assetWord))), amount: amount});

                unchecked {
                    ++i;
                }
            }
        }

        position = UserPosition({collateral: collateral, debt: debt});
    }

    function _buildUpdatedPosition(Action action, UserPosition memory oldPosition, ActionData memory actionData)
        internal
        pure
        returns (UserPosition memory updatedPosition)
    {
        uint256 collateral = oldPosition.collateral;
        DebtPosition[] memory debt = _copyDebt(oldPosition.debt);

        if (action == Action.Deposit) {
            collateral += actionData.collateralAmount;
        } else if (action == Action.Withdraw) {
            collateral = _decreaseCollateral(collateral, actionData.collateralAmount);
        } else if (action == Action.Borrow) {
            debt = _increaseDebt(debt, actionData.receipts);
        } else if (action == Action.Repay) {
            debt = _decreaseDebt(debt, actionData.receipts);
        } else if (action == Action.DepositAndBorrow) {
            collateral += actionData.collateralAmount;
            debt = _increaseDebt(debt, actionData.receipts);
        } else if (action == Action.RepayAndWithdraw) {
            debt = _decreaseDebt(debt, actionData.receipts);
            collateral = _decreaseCollateral(collateral, actionData.collateralAmount);
        } else {
            revert Borrower__ActionNotPossible();
        }

        updatedPosition = UserPosition({collateral: collateral, debt: debt});
    }

    function _copyPosition(UserPosition memory position) internal pure returns (UserPosition memory copied) {
        copied = UserPosition({collateral: position.collateral, debt: _copyDebt(position.debt)});
    }

    function _copyDebt(DebtPosition[] memory oldDebt) internal pure returns (DebtPosition[] memory debt) {
        uint256 debtLen = oldDebt.length;
        debt = new DebtPosition[](debtLen);

        for (uint256 i; i < debtLen;) {
            debt[i] = DebtPosition({asset: oldDebt[i].asset, amount: oldDebt[i].amount});

            unchecked {
                ++i;
            }
        }
    }

    function _decreaseCollateral(uint256 collateral, uint256 amount) internal pure returns (uint256) {
        if (amount > collateral) revert Borrower__InsufficientCollateral();

        unchecked {
            return collateral - amount;
        }
    }

    function _increaseDebt(DebtPosition[] memory debt, IController.Receipt[] memory receipts)
        internal
        pure
        returns (DebtPosition[] memory updatedDebt)
    {
        updatedDebt = debt;

        for (uint256 i; i < receipts.length;) {
            updatedDebt = _addDebt(updatedDebt, receipts[i].asset, receipts[i].amount);

            unchecked {
                ++i;
            }
        }
    }

    function _addDebt(DebtPosition[] memory oldDebt, address asset, uint256 amount)
        internal
        pure
        returns (DebtPosition[] memory debt)
    {
        if (amount == 0) return oldDebt;
        if (asset == address(0)) revert Borrower__DebtAssetZeroAddress();

        uint256 debtLen = oldDebt.length;

        for (uint256 i; i < debtLen;) {
            if (oldDebt[i].asset == asset) {
                debt = new DebtPosition[](debtLen);
                for (uint256 j; j < debtLen;) {
                    debt[j] = DebtPosition({asset: oldDebt[j].asset, amount: oldDebt[j].amount});

                    unchecked {
                        ++j;
                    }
                }

                debt[i].amount += amount;
                return debt;
            }

            unchecked {
                ++i;
            }
        }

        debt = new DebtPosition[](debtLen + 1);

        for (uint256 i; i < debtLen;) {
            debt[i] = DebtPosition({asset: oldDebt[i].asset, amount: oldDebt[i].amount});

            unchecked {
                ++i;
            }
        }

        debt[debtLen] = DebtPosition({asset: asset, amount: amount});
    }

    function _decreaseDebt(DebtPosition[] memory debt, IController.Receipt[] memory receipts)
        internal
        pure
        returns (DebtPosition[] memory updatedDebt)
    {
        updatedDebt = debt;

        for (uint256 i; i < receipts.length;) {
            updatedDebt = _subDebt(updatedDebt, receipts[i].asset, receipts[i].amount);

            unchecked {
                ++i;
            }
        }
    }

    function _subDebt(DebtPosition[] memory oldDebt, address asset, uint256 amount)
        internal
        pure
        returns (DebtPosition[] memory debt)
    {
        if (amount == 0) return oldDebt;
        if (asset == address(0)) revert Borrower__DebtAssetZeroAddress();

        uint256 debtLen = oldDebt.length;

        for (uint256 i; i < debtLen;) {
            if (oldDebt[i].asset == asset) {
                debt = new DebtPosition[](debtLen);
                for (uint256 j; j < debtLen;) {
                    debt[j] = DebtPosition({asset: oldDebt[j].asset, amount: oldDebt[j].amount});

                    unchecked {
                        ++j;
                    }
                }

                uint256 currentAmount = debt[i].amount;
                if (amount > currentAmount) revert Borrower__RepayTooMuch();

                unchecked {
                    debt[i].amount = currentAmount - amount;
                }

                return debt;
            }

            unchecked {
                ++i;
            }
        }

        revert Borrower__DebtAssetNotFound();
    }

    function _updatedSlots(UserPosition memory oldPosition, UserPosition memory newPosition, uint256 startingSlot)
        internal
        pure
        returns (IController.StateUpdate[] memory updates)
    {
        uint256 updateCount = _updatedSlotCount(oldPosition, newPosition);
        updates = new IController.StateUpdate[](updateCount);

        uint256 updateIndex;

        if (oldPosition.collateral != newPosition.collateral) {
            updates[updateIndex++] = _setUpdate(bytes32(startingSlot), bytes32(newPosition.collateral));
        }

        if (oldPosition.debt.length != newPosition.debt.length) {
            updates[updateIndex++] = _setUpdate(bytes32(startingSlot + 1), bytes32(newPosition.debt.length));
        }

        for (uint256 i; i < oldPosition.debt.length;) {
            if (oldPosition.debt[i].asset != newPosition.debt[i].asset) revert Borrower__DebtAssetChanged();

            if (oldPosition.debt[i].amount != newPosition.debt[i].amount) {
                updates[updateIndex++] =
                    _setUpdate(bytes32(startingSlot + 3 + (i * 2)), bytes32(newPosition.debt[i].amount));
            }

            unchecked {
                ++i;
            }
        }

        for (uint256 i = oldPosition.debt.length; i < newPosition.debt.length;) {
            uint256 assetSlot = startingSlot + 2 + (i * 2);

            updates[updateIndex++] =
                _setUpdate(bytes32(assetSlot), bytes32(uint256(uint160(newPosition.debt[i].asset))));
            updates[updateIndex++] = _setUpdate(bytes32(assetSlot + 1), bytes32(newPosition.debt[i].amount));

            unchecked {
                ++i;
            }
        }
    }

    function _updatedSlotCount(UserPosition memory oldPosition, UserPosition memory newPosition)
        internal
        pure
        returns (uint256 count)
    {
        if (newPosition.debt.length < oldPosition.debt.length) revert Borrower__DebtAssetChanged();
        if (oldPosition.collateral != newPosition.collateral) ++count;
        if (oldPosition.debt.length != newPosition.debt.length) ++count;

        for (uint256 i; i < oldPosition.debt.length;) {
            if (oldPosition.debt[i].asset != newPosition.debt[i].asset) revert Borrower__DebtAssetChanged();
            if (oldPosition.debt[i].amount != newPosition.debt[i].amount) ++count;

            unchecked {
                ++i;
            }
        }

        count += (newPosition.debt.length - oldPosition.debt.length) * 2;
    }

    function _setUpdate(bytes32 slot, bytes32 data) internal pure returns (IController.StateUpdate memory update) {
        update = IController.StateUpdate({op: IController.Op.Set, slot: slot, data: data});
    }

    function _validatePosition(UserPosition memory position) internal view {
        if (!_hasActiveDebt(position)) return;

        uint256 totalSupply = TOKEN.totalSupply();
        if (totalSupply == 0) revert Borrower__ZeroTokenSupply();

        IController.Backing[] memory backing = _backingPerToken(totalSupply);

        for (uint256 i; i < position.debt.length;) {
            DebtPosition memory debt = position.debt[i];

            if (debt.amount != 0 && _isFirstDebtAsset(position, debt.asset, i)) {
                uint256 totalDebt = _totalDebtForAsset(position, debt.asset, i);
                uint256 backingPerToken = _backingPerTokenForAsset(backing, debt.asset);
                uint256 borrowLimit = Math.mulDiv(position.collateral, backingPerToken, WAD);

                if (totalDebt > borrowLimit) revert Borrower__PositionNotCollateralized();
            }

            unchecked {
                ++i;
            }
        }
    }

    function _hasActiveDebt(UserPosition memory position) internal pure returns (bool) {
        for (uint256 i; i < position.debt.length;) {
            if (position.debt[i].amount != 0) return true;

            unchecked {
                ++i;
            }
        }

        return false;
    }

    function _isFirstDebtAsset(UserPosition memory position, address asset, uint256 index)
        internal
        pure
        returns (bool)
    {
        for (uint256 i; i < index;) {
            if (position.debt[i].asset == asset && position.debt[i].amount != 0) return false;

            unchecked {
                ++i;
            }
        }

        return true;
    }

    function _totalDebtForAsset(UserPosition memory position, address asset, uint256 startIndex)
        internal
        pure
        returns (uint256 totalDebt)
    {
        for (uint256 i = startIndex; i < position.debt.length;) {
            if (position.debt[i].asset == asset) {
                totalDebt += position.debt[i].amount;
            }

            unchecked {
                ++i;
            }
        }
    }

    function _backingPerToken() internal view returns (IController.Backing[] memory backing) {
        return _backingPerToken(TOKEN.totalSupply());
    }

    function _backingPerToken(uint256 totalSupply) internal view returns (IController.Backing[] memory backing) {
        if (totalSupply == 0) return new IController.Backing[](0);

        uint256 assetsLength = uint256(KERNEL.viewData(Slots.ASSETS_LENGTH_SLOT));
        backing = new IController.Backing[](assetsLength);
        if (assetsLength == 0) return backing;

        bytes memory rawAssets = KERNEL.viewData(Slots.ASSETS_BASE_SLOT, assetsLength);
        bytes32[] memory slots = new bytes32[](assetsLength * 2);

        for (uint256 i; i < assetsLength;) {
            address asset;

            assembly ("memory-safe") {
                asset := and(mload(add(add(rawAssets, 0x20), shl(5, i))), 0xffffffffffffffffffffffffffffffffffffffff)
            }

            backing[i].asset = asset;
            uint256 offset = i * 2;
            slots[offset] = _slot(Slots.BACKING_AMOUNT_SLOT, asset);
            slots[offset + 1] = _slot(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, asset);

            unchecked {
                ++i;
            }
        }

        bytes32[] memory responses = KERNEL.viewData(slots);

        for (uint256 i; i < assetsLength;) {
            uint256 offset = i * 2;
            uint256 totalBacking = uint256(responses[offset]) + uint256(responses[offset + 1]);
            backing[i].backingPerToken = Math.mulDiv(totalBacking, WAD, totalSupply);

            unchecked {
                ++i;
            }
        }
    }

    function _backingPerTokenForAsset(IController.Backing[] memory backing, address asset)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i; i < backing.length;) {
            if (backing[i].asset == asset) return backing[i].backingPerToken;

            unchecked {
                ++i;
            }
        }

        revert Borrower__DebtAssetNotBacked();
    }

    function _slot(bytes32 namespace, address asset) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0x00, namespace)
            mstore(0x20, and(asset, 0xffffffffffffffffffffffffffffffffffffffff))
            slot := keccak256(0x00, 0x40)
        }
    }
}
