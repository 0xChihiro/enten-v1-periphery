///SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";

contract V4PoolManagerDeployer {
    function deploy(address initialOwner) external returns (address) {
        return address(new PoolManager(initialOwner));
    }
}
