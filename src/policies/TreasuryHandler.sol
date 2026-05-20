///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Policy} from "enten-v1/Policy.sol";
import {Strategy} from "../Strategy.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {Keycode, toKeycode, Permissions, ensureContract} from "enten-v1/Utils.sol";
import {TRSRY} from "../modules/TRSRY/TRSRY.v1.sol";
import {ITreasury} from "../interfaces/ITreasury.sol";
import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";

contract TreasuryHandler is Policy, AccessControl {
    bytes32 public constant STRATEGY_MANAGER_ROLE = keccak256("STRATEGY_MANAGER_ROLE");
    bytes32 public constant FUNDS_MANAGER_ROLE = keccak256("FUNDS_MANAGER_ROLE");

    error TreasuryHandler__AdminIsAddressZero();
    error TreasuryHandler__InvalidDeploymentConfiguration();
    error TreasuryHandler__StrategyHasNoAssets();
    error TreasuryHandler__StrategyAlreadyActive();
    error TreasuryHandler__StrategyNotActive();

    event TreasuryHandler__AddStrategy();
    event TreasuryHandler__RemoveStrategy();
    event TreasuryHandler__DeployFunds();
    event TreasuryHandler__RecallFunds();

    TRSRY public treasuryModule;
    uint256 public strategyCounter;
    address[] public strategies;
    mapping(address => uint256) public strategyIndex;
    mapping(Strategy => bool) public strategyIsActive;
    mapping(address => address[]) public strategyAssets;
    /// @dev mapping for which strategies have access to which assets
    mapping(address => mapping(address => bool)) public assetAccess;

    constructor(address controller, address admin) Policy(controller) {
        if (admin == address(0)) revert TreasuryHandler__AdminIsAddressZero();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(STRATEGY_MANAGER_ROLE, admin);
        _grantRole(FUNDS_MANAGER_ROLE, admin);
    }

    function configureDependencies() external override onlyController returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](1);
        dependencies[0] = toKeycode("TRSRY");
        treasuryModule = TRSRY(CONTROLLER.getModuleForKeycode(dependencies[0]));
    }

    function requestPermissions() external pure override returns (Permissions[] memory permissions) {
        permissions = new Permissions[](1);
        permissions[0] = Permissions({keycode: toKeycode("TRSRY"), funcSelector: TRSRY.execute.selector});
    }

    function addStrategy(address strategy) external onlyRole(STRATEGY_MANAGER_ROLE) {
        ensureContract(strategy);
        if (strategyIsActive[Strategy(strategy)]) revert TreasuryHandler__StrategyAlreadyActive();
        address[] memory allocatedAssets = Strategy(strategy).ASSETS();
        if (allocatedAssets.length == 0) revert TreasuryHandler__StrategyHasNoAssets();
        strategyIsActive[Strategy(strategy)] = true;
        delete strategyAssets[strategy];
        for (uint256 i = 0; i < allocatedAssets.length;) {
            assetAccess[strategy][allocatedAssets[i]] = true;
            strategyAssets[strategy].push(allocatedAssets[i]);
            unchecked {
                i++;
            }
        }
        strategies.push(strategy);
        strategyIndex[strategy] = strategyCounter;
        unchecked {
            strategyCounter++;
        }
        emit TreasuryHandler__AddStrategy();
    }

    function removeStrategy(address strategy) external onlyRole(STRATEGY_MANAGER_ROLE) {
        if (strategyCounter == 0 || !strategyIsActive[Strategy(strategy)]) revert TreasuryHandler__StrategyNotActive();
        address[] storage assets = strategyAssets[strategy];
        strategyIsActive[Strategy(strategy)] = false;
        for (uint256 i = 0; i < assets.length;) {
            assetAccess[strategy][assets[i]] = false;
            unchecked {
                i++;
            }
        }
        delete strategyAssets[strategy];

        address lastStrategy = strategies[strategyCounter - 1];
        uint256 oldIndex = strategyIndex[strategy];
        if (strategy != lastStrategy) {
            strategies[oldIndex] = lastStrategy;
            strategyIndex[lastStrategy] = oldIndex;
        }
        strategies.pop();
        unchecked {
            strategyCounter--;
        }
        delete strategyIndex[strategy];
        emit TreasuryHandler__RemoveStrategy();
    }

    function deployToStrategy(address strategy, ITreasury.Asset[] calldata assets)
        external
        onlyRole(FUNDS_MANAGER_ROLE)
    {
        if (!strategyIsActive[Strategy(strategy)]) {
            revert TreasuryHandler__InvalidDeploymentConfiguration();
        }
        for (uint256 i = 0; i < assets.length;) {
            validateAssets(strategy, assets[i].asset);
            unchecked {
                i++;
            }
        }

        treasuryModule.execute(ITreasury.TreasuryAction.Deploy, strategy, assets);
    }

    function recallFromStrategy(address strategy, ITreasury.Asset[] calldata assets)
        external
        onlyRole(FUNDS_MANAGER_ROLE)
    {
        for (uint256 i = 0; i < assets.length;) {
            validateAssets(strategy, assets[i].asset);
            unchecked {
                i++;
            }
        }

        treasuryModule.execute(ITreasury.TreasuryAction.Recall, strategy, assets);
    }

    function validateAssets(address strategy, address asset) internal view {
        if (!assetAccess[strategy][asset]) {
            revert TreasuryHandler__InvalidDeploymentConfiguration();
        }
    }
}
