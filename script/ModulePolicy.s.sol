/// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/Test.sol";
import {Auction} from "../src/policies/Auction.sol";
import {Minter} from "../src/modules/MINTR/Minter.sol";
import {Admin} from "../src/modules/ADMIN/Admin.sol";
import {Gateway} from "../src/policies/Gateway.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {Actions} from "enten-v1/Utils.sol";

contract ModulePolicyScript is Script {
    // Enten Testnet controller. Should be replaced with your own controller.
    address controller = 0x7c10c80402c170449AbA11f5a16Bca2d01BDAa21;
    // Whichever wallet is responsible for adding modules and policies
    uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address adminAddr = vm.envAddress("ADMIN_ADDRESS");

    function run() public {
        vm.startBroadcast(deployerPk);
        address minter = address(new Minter(controller));
        address auction = address(new Auction(controller, 1_000e18, 3600, 3e18));
        address admin = address(new Admin(controller));
        address gateway = address(new Gateway(controller, adminAddr));

        IController(controller).executeAction(Actions.InstallModule, minter);
        IController(controller).executeAction(Actions.InstallModule, admin);
        IController(controller).executeAction(Actions.ActivatePolicy, auction);
        IController(controller).executeAction(Actions.ActivatePolicy, gateway);

        vm.stopBroadcast();

        console.log("Auction Address:", auction);
        console.log("Gateway Address:", gateway);
    }
}
