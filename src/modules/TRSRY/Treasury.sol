///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {TRSRY} from "./TRSRY.v1.sol";
import {IController} from "enten-v1/interfaces/IController.sol";

contract Treasury is TRSRY {
    constructor(address controller) TRSRY(controller) {}

    function execute(TreasuryAction action, address dst, Asset[] calldata assets) external override permissioned {
        IController.Receipt[] memory receipts = new IController.Receipt[](assets.length);
        for (uint256 i = 0; i < assets.length;) {
            receipts[i] = IController.Receipt({asset: assets[i].asset, amount: assets[i].amount});
            unchecked {
                i++;
            }
        }
        if (action == TreasuryAction.Deploy) {
            IController.Settlement[] memory settlements = new IController.Settlement[](1);
            settlements[0] = IController.Settlement({
                payer: dst,
                amount: 0,
                transition: IController.StateTransitions.Deploy,
                receipts: receipts,
                singleStateUpdates: new IController.StateUpdate[](0),
                multiStateUpdates: new IController.StateUpdates[](0),
                externalCalls: new IController.ExternalCall[](0)
            });
            CONTROLLER.settle(settlements);
        } else if (action == TreasuryAction.Recall) {
            IController.Settlement[] memory settlements = new IController.Settlement[](1);
            settlements[0] = IController.Settlement({
                payer: dst,
                amount: 0,
                transition: IController.StateTransitions.Recall,
                receipts: receipts,
                singleStateUpdates: new IController.StateUpdate[](0),
                multiStateUpdates: new IController.StateUpdates[](0),
                externalCalls: new IController.ExternalCall[](0)
            });
            CONTROLLER.settle(settlements);
        } else {
            revert Treasury__ActionNotSupported();
        }
    }
}
