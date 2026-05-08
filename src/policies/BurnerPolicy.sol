///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Policy} from "enten-v1/Policy.sol";
import {BRNER} from "../modules/DFLT/BRNER.sol";
import {IBurner} from "../interfaces/IBurner.sol";
import {Keycode, Permissions, toKeycode} from "enten-v1/Utils.sol";

contract BurnerPolicy is Policy {
    BRNER public BURNER;

    constructor(address controller) Policy(controller) {}

    function configureDependencies() external override returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](1);
        dependencies[0] = toKeycode("BRNER");

        BURNER = BRNER(getModuleAddress(dependencies[0]));
    }

    function requestPermissions() external pure override returns (Permissions[] memory permissions) {
        Keycode burner = toKeycode("BRNER");
        permissions = new Permissions[](1);
        permissions[0] = Permissions(burner, BRNER.executeDeflationaryAction.selector);
    }

    function burn(uint256 amount) external {
        BURNER.executeDeflationaryAction(IBurner.Action.Burn, msg.sender, amount);
    }

    function redeem(uint256 amount) external {
        BURNER.executeDeflationaryAction(IBurner.Action.Redeem, msg.sender, amount);
    }
}
