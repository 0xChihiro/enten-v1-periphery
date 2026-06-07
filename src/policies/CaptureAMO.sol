///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Keycode, Permissions, toKeycode} from "enten-v1/Utils.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {Policy} from "enten-v1/Policy.sol";
import {CAPTRv1} from "../modules/CAPTR/CAPTR.v1.sol";
import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";

contract CaptureAMO is AccessControl, Policy {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    uint256 public constant DAY = 86_400;

    uint256 public immutable DAILY_LIMIT;
    uint256 public immutable TRANSACTION_LIMIT;

    CAPTRv1 public captureModule;
    uint256 public dailyStart;
    uint256 public spent;

    error Capture__InvalidConfiguration();
    error CaptureAMO__InvalidExecutionParameters();
    error CaptureAMO__Limits();

    event CaptureAMO__ExecuteCapture(address indexed caller, uint256 mintAmount, IController.ExternalCall[] calls);

    constructor(address controller, address admin, uint256 dailyLimit, uint256 transactionLimit) Policy(controller) {
        if (dailyLimit < transactionLimit || transactionLimit == 0 || admin == address(0)) {
            revert Capture__InvalidConfiguration();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);

        DAILY_LIMIT = dailyLimit;
        TRANSACTION_LIMIT = transactionLimit;

        dailyStart = block.timestamp;
    }

    function configureDependencies() external override onlyController returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](1);
        dependencies[0] = toKeycode("CAPTR");

        captureModule = CAPTRv1(getModuleAddress(dependencies[0]));
    }

    function requestPermissions() external pure override returns (Permissions[] memory permissions) {
        permissions = new Permissions[](1);
        permissions[0] = Permissions({keycode: toKeycode("CAPTR"), funcSelector: CAPTRv1.capture.selector});
    }

    function executeCapture(uint256 mintAmount, IController.ExternalCall[] calldata calls)
        external
        onlyRole(EXECUTOR_ROLE)
    {
        if (mintAmount == 0 || calls.length == 0) revert CaptureAMO__InvalidExecutionParameters();
        if (dailyStart + DAY < block.timestamp) {
            spent = 0;
        } else {}
        if (spent + mintAmount > DAILY_LIMIT || mintAmount > TRANSACTION_LIMIT) revert CaptureAMO__Limits();
        spent += mintAmount;
        captureModule.capture(mintAmount, calls);
        emit CaptureAMO__ExecuteCapture(msg.sender, mintAmount, calls);
    }
}
