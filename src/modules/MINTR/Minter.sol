/// SPDX-License-Idnetifier: MIT
pragma solidity 0.8.34;

import {MINTR} from "./MINTR.v1.sol";
import {IMinter} from "../../interfaces/IMinter.sol";
import {IController} from "enten-v1/interfaces/IController.sol";

contract Minter is MINTR, IMinter {
    constructor(address controller) MINTR(controller) {}

    function mint(address user, uint256 mintAmount, IController.Receipt[] calldata receipts)
        external
        override
        permissioned
    {
        // mint performs only the Payment settlement. State updates are intentionally not accepted: forwarding
        // caller-supplied updates would let any policy holding MINTR.mint write arbitrary kernel slots (fees,
        // asset registry, team-locked supply). Keeping the surface to "mint for payment" enforces least privilege.
        IController.Settlement[] memory settlements = new IController.Settlement[](1);
        settlements[0] = IController.Settlement({
            payer: user,
            amount: mintAmount,
            transition: IController.StateTransitions.Payment,
            receipts: receipts,
            singleStateUpdates: new IController.StateUpdate[](0),
            multiStateUpdates: new IController.StateUpdates[](0),
            externalCalls: new IController.ExternalCall[](0)
        });
        CONTROLLER.settle(settlements);
    }
}
