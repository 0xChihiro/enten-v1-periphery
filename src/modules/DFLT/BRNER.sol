///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Module} from "enten-v1/Module.sol";
import {Keycode, toKeycode} from "enten-v1/Utils.sol";
import {IBurner} from "../../interfaces/IBurner.sol";

abstract contract BRNER is Module, IBurner {
    constructor(address controller) Module(controller) {}

    function executeDeflationaryAction(Action action, address user, uint256 amount) external virtual;

    function KEYCODE() public pure override returns (Keycode) {
        return toKeycode("BRNER");
    }

    function VERSION() external pure override returns (uint8 major, uint8 minor) {
        return (1, 0);
    }
}
