///SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Gateway} from "../src/policies/Gateway.sol";
import {console} from "forge-std/Test.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IVault} from "enten-v1/interfaces/IVault.sol";
import {toKeycode} from "enten-v1/Utils.sol";

contract GatewayScript is Script {
    // Enten Testnet Gateway address, update with your own address
    Gateway gateway = Gateway(0x1f97534Bc0bA1b43A6Aab24adDbDe98b4Afb6c41);
    // Enten Testnet Controller
    IController controller = IController(0x7c10c80402c170449AbA11f5a16Bca2d01BDAa21);
    // Testnet Mega
    address mega = 0xc903c68C1d389CEd76fEe0349067a4295828e6c2;
    // Enten Testnet Vault
    address vault = 0x34d500707F2f9Dd825c71bbeEEFBd209B3511A45;

    uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address admin = vm.envAddress("ADMIN_ADDRESS");

    function run() public {
        vm.startBroadcast(deployerPk);
        // gateway.addAsset(mega);
        // gateway.setFees(9_000, 0, 750);

        // // Seed testnet vault with a few tokens of added asset in order for testing. Assets
        // // must have some backing value in the vault before auctions can happen.
        // IERC20(mega).transfer(vault, 490e18);
        // controller.grantRole(controller.CREDITOR_ROLE(), admin);
        controller.setMintPermission(toKeycode("MINTR"), true);
        // controller.sync(mega, IVault.Bucket.Redeem);

        vm.stopBroadcast();
    }
}
