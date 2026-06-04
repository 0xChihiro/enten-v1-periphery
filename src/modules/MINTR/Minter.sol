/// SPDX-License-Idnetifier: MIT
pragma solidity 0.8.34;

import {MINTR} from "./MINTR.v1.sol";
import {IMinter} from "../../interfaces/IMinter.sol";
import {IController} from "enten-v1/interfaces/IController.sol";

contract Minter is MINTR, IMinter {
    constructor(address controller) MINTR(controller) {}

    function mint(
        address user,
        uint256 mintAmount,
        IController.Receipt[] calldata receipts,
        IController.StateUpdate[] calldata updates
    ) external override permissioned {
        IController.Settlement[] memory settlements = new IController.Settlement[](1);
        settlements[0] = IController.Settlement({
            payer: user,
            amount: mintAmount,
            transition: IController.StateTransitions.Payment,
            receipts: receipts,
            singleStateUpdates: updates,
            multiStateUpdates: new IController.StateUpdates[](0),
            externalCalls: new IController.ExternalCall[](0)
        });
        CONTROLLER.settle(settlements);
    }
}
