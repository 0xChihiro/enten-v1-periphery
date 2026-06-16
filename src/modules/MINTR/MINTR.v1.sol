///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Module} from "enten-v1/Module.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {Keycode, toKeycode} from "enten-v1/Utils.sol";

abstract contract MINTR is Module {
    constructor(address controller) Module(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return toKeycode("MINTR");
    }

    function mint(address user, uint256 mintAmount, IController.Receipt[] calldata receipts) external virtual;
}
