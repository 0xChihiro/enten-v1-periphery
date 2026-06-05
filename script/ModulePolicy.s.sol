/// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";

contract ModulePolicyScript is Script {
    function run() public {
        vm.startBroadcast();
        vm.stopBroadcast();
    }
}
