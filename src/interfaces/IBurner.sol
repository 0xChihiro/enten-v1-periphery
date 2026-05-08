///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IBurner {
    enum Action {
        Burn,
        Redeem
    }

    function executeDeflationaryAction(Action, address, uint256) external;

    error Burner__ActionImpossible();
}
