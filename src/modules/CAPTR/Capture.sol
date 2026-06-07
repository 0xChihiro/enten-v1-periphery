///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {CAPTRv1} from "./CAPTR.v1.sol";
import {IController} from "enten-v1/interfaces/IController.sol";

contract Capture is CAPTRv1 {
    constructor(address controller) CAPTRv1(controller) {}

    function capture(uint256 amount, IController.ExternalCall[] calldata calls) external override permissioned {
        IController.Settlement[] memory settlements = new IController.Settlement[](2);
        settlements[0] = IController.Settlement({
            payer: address(CONTROLLER),
            amount: amount,
            transition: IController.StateTransitions.Payment,
            receipts: new IController.Receipt[](0),
            singleStateUpdates: new IController.StateUpdate[](0),
            multiStateUpdates: new IController.StateUpdates[](0),
            externalCalls: new IController.ExternalCall[](0)
        });
        settlements[1] = IController.Settlement({
            payer: address(0),
            amount: 0,
            transition: IController.StateTransitions.ExternalCall,
            receipts: new IController.Receipt[](0),
            singleStateUpdates: new IController.StateUpdate[](0),
            multiStateUpdates: new IController.StateUpdates[](0),
            externalCalls: calls
        });
        CONTROLLER.settle(settlements);
    }
}
