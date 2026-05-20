///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Gateway} from "../policies/Gateway.sol";

/// @notice Minimal single-purpose timelock for delayed Gateway.updateSystem calls.
/// @dev Intended to hold Gateway's UPGRADE_ROLE after initial launch/setup is complete.
contract SystemUpgradeTimelock {
    uint256 public constant DELAY = 3 days;
    uint256 public constant GRACE_PERIOD = 14 days;

    address public immutable gateway;
    address public admin;

    mapping(bytes32 operationId => uint256 timestamp) public executableAt;
    mapping(bytes32 operationId => bool status) public executed;
    mapping(bytes32 operationId => bool status) public cancelled;

    error SystemUpgradeTimelock__NotAdmin();
    error SystemUpgradeTimelock__ZeroAddress();
    error SystemUpgradeTimelock__InvalidSelector();
    error SystemUpgradeTimelock__AlreadyQueued();
    error SystemUpgradeTimelock__NotQueued();
    error SystemUpgradeTimelock__AlreadyExecuted();
    error SystemUpgradeTimelock__Cancelled();
    error SystemUpgradeTimelock__DelayNotElapsed();
    error SystemUpgradeTimelock__OperationExpired();
    error SystemUpgradeTimelock__ExecutionFailed();

    event SystemUpgradeTimelock__OperationQueued(
        bytes32 indexed operationId, address indexed caller, bytes data, uint256 executableAt
    );
    event SystemUpgradeTimelock__OperationCancelled(bytes32 indexed operationId, address indexed caller);
    event SystemUpgradeTimelock__OperationExecuted(bytes32 indexed operationId, address indexed caller);
    event SystemUpgradeTimelock__AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert SystemUpgradeTimelock__NotAdmin();
        _;
    }

    constructor(address gateway_, address admin_) {
        if (gateway_ == address(0) || admin_ == address(0)) revert SystemUpgradeTimelock__ZeroAddress();

        gateway = gateway_;
        admin = admin_;
    }

    function queue(bytes calldata data) external onlyAdmin returns (bytes32 operationId) {
        _validateSelector(data);

        operationId = _hashOperation(data);
        uint256 currentExecutableAt = executableAt[operationId];
        uint256 currentTimestamp = block.timestamp;
        if (executed[operationId]) revert SystemUpgradeTimelock__AlreadyExecuted();
        if (
            currentExecutableAt != 0 && !cancelled[operationId]
                && currentTimestamp <= currentExecutableAt + GRACE_PERIOD
        ) {
            revert SystemUpgradeTimelock__AlreadyQueued();
        }

        uint256 timestamp = currentTimestamp + DELAY;
        executableAt[operationId] = timestamp;
        cancelled[operationId] = false;

        emit SystemUpgradeTimelock__OperationQueued(operationId, msg.sender, data, timestamp);
    }

    function cancel(bytes32 operationId) external onlyAdmin {
        if (executableAt[operationId] == 0) revert SystemUpgradeTimelock__NotQueued();
        if (executed[operationId]) revert SystemUpgradeTimelock__AlreadyExecuted();
        if (cancelled[operationId]) revert SystemUpgradeTimelock__Cancelled();

        cancelled[operationId] = true;

        emit SystemUpgradeTimelock__OperationCancelled(operationId, msg.sender);
    }

    function execute(bytes calldata data) external returns (bytes32 operationId) {
        _validateSelector(data);

        operationId = _hashOperation(data);
        uint256 timestamp = executableAt[operationId];
        if (timestamp == 0) revert SystemUpgradeTimelock__NotQueued();
        if (executed[operationId]) revert SystemUpgradeTimelock__AlreadyExecuted();
        if (cancelled[operationId]) revert SystemUpgradeTimelock__Cancelled();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < timestamp) revert SystemUpgradeTimelock__DelayNotElapsed();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > timestamp + GRACE_PERIOD) revert SystemUpgradeTimelock__OperationExpired();

        executed[operationId] = true;

        (bool success,) = gateway.call(data);
        if (!success) revert SystemUpgradeTimelock__ExecutionFailed();

        emit SystemUpgradeTimelock__OperationExecuted(operationId, msg.sender);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert SystemUpgradeTimelock__ZeroAddress();

        address oldAdmin = admin;
        admin = newAdmin;

        emit SystemUpgradeTimelock__AdminTransferred(oldAdmin, newAdmin);
    }

    function hashOperation(bytes calldata data) external view returns (bytes32) {
        return _hashOperation(data);
    }

    function _hashOperation(bytes calldata data) internal view returns (bytes32) {
        return keccak256(abi.encode(address(this), block.chainid, gateway, data));
    }

    function _validateSelector(bytes calldata data) internal pure {
        if (data.length < 4) revert SystemUpgradeTimelock__InvalidSelector();

        bytes4 selector;
        assembly ("memory-safe") {
            selector := calldataload(data.offset)
        }

        if (selector != Gateway.updateSystem.selector) revert SystemUpgradeTimelock__InvalidSelector();
    }
}
