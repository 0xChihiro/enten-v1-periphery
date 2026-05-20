///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ADMINv1} from "./ADMIN.v1.sol";
import {IController} from "enten-v1/interfaces/IController.sol";

contract Admin is ADMINv1 {
    constructor(address controller) ADMINv1(controller) {}

    function upgradeSystem(SystemUpgrade[] calldata upgrades) external override permissioned {
        for (uint256 i = 0; i < upgrades.length;) {
            CONTROLLER.executeAction(upgrades[i].action, upgrades[i].target);
            unchecked {
                i++;
            }
        }
    }

    function updateAdminState(IController.StateUpdate[] calldata updates) external override permissioned {
        IController.Settlement[] memory settlements = new IController.Settlement[](1);
        settlements[0] = IController.Settlement({
            payer: msg.sender,
            amount: 0,
            transition: IController.StateTransitions.StateUpdate,
            receipts: new IController.Receipt[](0),
            singleStateUpdates: updates,
            multiStateUpdates: new IController.StateUpdates[](0)
        });

        CONTROLLER.settle(settlements);
    }
}
