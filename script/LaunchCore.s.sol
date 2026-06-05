///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {IControllerFactory} from "enten-v1/interfaces/IControllerFactory.sol";
import {ControllerFactory} from "enten-v1/factories/ControllerFactory.sol";
import {ProtocolCollector} from "enten-v1/ProtocolCollector.sol";
import {CreationCodeStore} from "enten-v1/factories/CreationCodeStore.sol";
import {Token} from "enten-v1/Token.sol";
import {Vault} from "enten-v1/Vault.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Controller} from "enten-v1/Controller.sol";
import {TeamLocker} from "../src/TeamLocker.sol";

contract LaunchCoreScript is Script {
    /// This is the testnet controller for megaEth testnet
    ControllerFactory factory = ControllerFactory(0x88534de930c666d22BE2FCe031c883CA40493670);

    function run() public {
        address admin = vm.envAddress("ADMIN_ADDRESS");
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        vm.startBroadcast(deployerPk);

        /// update to your own salt here
        bytes32 salt = keccak256("enten.controller.launch.testnet");

        IControllerFactory.Deployment memory expectedDeployments = factory.predictDeployment(deployer, salt);

        /// Change The necessary constructor inputs to what you need them to be.
        IControllerFactory.LaunchConfig memory config = IControllerFactory.LaunchConfig({
            tokenName: "Enten",
            tokenSymbol: "ENTEN",
            preMineAddress: admin,
            preMineAmount: 3_500_000e18,
            maxSupply: 10_000_000e18
        });

        IControllerFactory.Deployment memory deployments = factory.launchController(admin, salt, config);

        vm.stopBroadcast();
    }
}
