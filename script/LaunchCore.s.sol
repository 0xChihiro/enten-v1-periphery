///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {IControllerFactory} from "enten-v1/interfaces/IControllerFactory.sol";
import {ControllerFactory} from "enten-v1/factories/ControllerFactory.sol";

contract LaunchCoreScript is Script {
    /// This is the testnet controller for megaEth testnet
    ControllerFactory factory = ControllerFactory(0x88534de930c666d22BE2FCe031c883CA40493670);

    function run() public {
        address admin = vm.envAddress("ADMIN_ADDRESS");
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPk);

        /// update to your own salt here
        bytes32 salt = keccak256("enten.controller.launch.testnet");

        /// Change The necessary constructor inputs to what you need them to be.
        IControllerFactory.LaunchConfig memory config = IControllerFactory.LaunchConfig({
            tokenName: "Enten",
            tokenSymbol: "ENTEN",
            preMineAddress: admin,
            preMineAmount: 3_500_000e18,
            teamTokenAmount: 0,
            maxSupply: 10_000_000e18
        });

        factory.launchController(admin, salt, config);

        vm.stopBroadcast();
    }
}
