///SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {VirtualReservePool} from "../src/policies/VirtualReservePool.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Test.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {Actions} from "enten-v1/Utils.sol";

contract VirtualReserveScript is Script {
    function run() public {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        IController controller = IController(vm.envAddress("CONTROLLER_ADDRESS"));

        vm.startBroadcast(deployerPk);

        uint256 halfLife = 43_200; // 12 Hours
        uint256 threshold = 8_000; // reset once 80% of the curve's tokens have been minted/bought
        uint256 target = 2_000; // reset rewinds the curve position to 20% consumed
        uint256 minPremium = 250; // Premium is minimum 2.5% over grossFees(backing)

        VirtualReservePool vr =
            new VirtualReservePool(address(controller), admin, halfLife, threshold, target, minPremium);
        address mega = 0x28B7E77f82B25B95953825F1E3eA0E36c1c29861; // Token used for the reserve must already be used as a backing asset and registered in the system

        // If the deployer is not the admin these function will revert
        vr.setReserve(mega, 750_000e18, 1e18); // 750k ENTEN curve depth, 1.0 (WAD) opening premium

        // for this new policy to be installed both the minter and burner / redemption modules must already be installed
        controller.executeAction(Actions.ActivatePolicy, address(vr));

        vm.stopBroadcast();

        console2.log("Virtual Reserve Pool:", address(vr));
    }
}
