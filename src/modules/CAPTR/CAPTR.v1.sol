///SPDX-License-Identifer: MIT
pragma solidity 0.8.34;

import {Module} from "enten-v1/Module.sol";
import {Keycode, toKeycode} from "enten-v1/Utils.sol";
import {IController} from "enten-v1/interfaces/IController.sol";

abstract contract CAPTRv1 is Module {
    constructor(address controller) Module(controller) {}

    function capture(uint256 amount, IController.ExternalCall[] calldata calls) external virtual;

    function KEYCODE() public pure override returns (Keycode keycode) {
        return toKeycode("CAPTR");
    }

    function VERSION() external pure override returns (uint8 major, uint8 minor) {
        return (1, 0);
    }
}
