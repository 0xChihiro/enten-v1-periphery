///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IController} from "enten-v1/interfaces/IController.sol";

interface IBorrower {
    enum Action {
        Deposit,
        Withdraw,
        Repay,
        Borrow,
        DepositAndBorrow,
        RepayAndWithdraw
    }

    struct DebtPosition {
        address asset;
        uint256 amount;
    }

    struct UserPosition {
        uint256 collateral;
        DebtPosition[] debt;
    }

    struct ActionData {
        uint256 collateralAmount;
        IController.Receipt[] receipts;
    }

    error Borrower__ActionNotPossible();
    error Borrower__DebtAssetChanged();
    error Borrower__DebtAssetNotFound();
    error Borrower__DebtAssetNotBacked();
    error Borrower__DebtAssetZeroAddress();
    error Borrower__InsufficientCollateral();
    error Borrower__PositionNotCollateralized();
    error Borrower__RepayTooMuch();
    error Borrower__TokenZeroAddress();
    error Borrower__ZeroTokenSupply();
    error Borrower__UseDepositAndBorrow();
}
