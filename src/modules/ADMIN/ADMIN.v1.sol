///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Module} from "enten-v1/Module.sol";
import {Keycode, toKeycode, Actions} from "enten-v1/Utils.sol";
import {IController} from "enten-v1/interfaces/IController.sol";

abstract contract ADMINv1 is Module {
    struct SystemUpgrade {
        Actions action;
        address target;
    }
    constructor(address controller) Module(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return toKeycode("ADMIN");
    }

    function VERSION() public pure override returns (uint8, uint8) {
        return (1, 0);
    }

    function INIT() external override onlyController {}

    function upgradeSystem(SystemUpgrade[] calldata upgrades) external virtual;

    function updateAdminState(IController.StateUpdate[] calldata updates) external virtual;
}
