///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

abstract contract Strategy {
    address public immutable TREASURY;

    error Strategy__NotTreasury();

    constructor(address treasury) {
        TREASURY = treasury;
    }

    modifier onlyTreasury() {
        if (msg.sender != TREASURY) revert Strategy__NotTreasury();
        _;
    }

    function ASSETS() external view virtual returns (address[] memory assets);

    function TVL() external view virtual returns (uint256[] memory tvl);
}
