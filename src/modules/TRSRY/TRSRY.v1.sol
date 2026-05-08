///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Module} from "enten-v1/Module.sol";
import {Keycode, toKeycode} from "enten-v1/Utils.sol";
import {ITreasury} from "../../interfaces/ITreasury.sol";

abstract contract TRSRY is ITreasury, Module {
    constructor(address controller) Module(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap("TRSRY");
    }

    function VERSION() public pure override returns (uint8 major, uint8 minor) {
        major = 1;
        minor = 0;
    }

    function execute(TreasuryAction action, address dst, Asset[] calldata assets) external virtual;
}
