///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface ITreasury {
    enum TreasuryAction {
        Deploy,
        Recall
    }

    struct Asset {
        address asset;
        uint256 amount;
    }

    error Treasury__ActionNotSupported();
}
