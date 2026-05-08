///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Module} from "v1-core/Module.sol";
import {Keycode} from "v1-core/interfaces/IController.sol";

abstract contract BRWRv1 is Module {
    constructor(address controller) Module(controller) {}

    function VERSION() external pure override returns (uint8 major, uint8 minor) {
        major = 1;
        minor = 0;
    }

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap("BRRWR");
    }
}
