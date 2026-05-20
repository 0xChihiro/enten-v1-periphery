///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {TreasuryHandler} from "../src/policies/TreasuryHandler.sol";
import {Treasury} from "../src/modules/TRSRY/Treasury.sol";
import {TRSRY} from "../src/modules/TRSRY/TRSRY.v1.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";
import {Strategy} from "../src/Strategy.sol";
import {Controller} from "enten-v1/Controller.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Token} from "enten-v1/Token.sol";
import {Vault} from "enten-v1/Vault.sol";
import {Actions, Keycode, Permissions, TargetNotAContract} from "enten-v1/Utils.sol";
import {IVault} from "enten-v1/interfaces/IVault.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {IAccessControl} from "openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Test} from "forge-std/Test.sol";

contract MockStrategy is Strategy {
    address[] internal supportedAssets;

    constructor(address treasury, address[] memory assets_) Strategy(treasury) {
        _setAssets(assets_);
    }

    function ASSETS() external view override returns (address[] memory assets) {
        assets = supportedAssets;
    }

    function _setAssets(address[] memory assets_) internal {
        for (uint256 i; i < assets_.length;) {
            supportedAssets.push(assets_[i]);
            unchecked {
                ++i;
            }
        }
    }
}

contract MutableMockStrategy is MockStrategy {
    constructor(address treasury, address[] memory assets_) MockStrategy(treasury, assets_) {}

    function setAssets(address[] memory assets_) external {
        delete supportedAssets;
        _setAssets(assets_);
    }
}

contract TreasuryHandlerTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    Token internal token;
    Treasury internal treasuryModule;
    TreasuryHandler internal handler;
    ERC20Mock internal asset;
    ERC20Mock internal secondAsset;
    MockStrategy internal strategy;
    MockStrategy internal secondStrategy;
    MockStrategy internal thirdStrategy;

    address internal controllerAdmin = makeAddr("Controller Admin");
    address internal protocolCollector = makeAddr("Protocol Collector");
    address internal treasuryAdmin = makeAddr("Treasury Admin");
    address internal strategyManager = makeAddr("Strategy Manager");
    address internal fundsManager = makeAddr("Funds Manager");
    address internal user = makeAddr("User");
    address internal tokenRecipient = makeAddr("Token Recipient");

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedToken = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedController = vm.computeCreateAddress(address(this), nonce + 3);

        kernel = new Kernel(predictedController, predictedVault);
        vault = new Vault(predictedController, predictedKernel);
        token = new Token("Enten", "ENTEN", predictedController, tokenRecipient, INITIAL_SUPPLY, type(uint256).max);
        controller = new Controller(controllerAdmin, protocolCollector, predictedKernel, predictedVault, predictedToken);

        treasuryModule = new Treasury(address(controller));
        handler = new TreasuryHandler(address(controller), treasuryAdmin);
        asset = new ERC20Mock();
        secondAsset = new ERC20Mock();

        address[] memory oneAsset = new address[](1);
        oneAsset[0] = address(asset);
        strategy = new MockStrategy(address(handler), oneAsset);

        address[] memory secondStrategyAssets = new address[](1);
        secondStrategyAssets[0] = address(secondAsset);
        secondStrategy = new MockStrategy(address(handler), secondStrategyAssets);

        address[] memory thirdStrategyAssets = new address[](2);
        thirdStrategyAssets[0] = address(asset);
        thirdStrategyAssets[1] = address(secondAsset);
        thirdStrategy = new MockStrategy(address(handler), thirdStrategyAssets);

        vm.startPrank(treasuryAdmin);
        handler.grantRole(handler.STRATEGY_MANAGER_ROLE(), strategyManager);
        handler.grantRole(handler.FUNDS_MANAGER_ROLE(), fundsManager);
        vm.stopPrank();

        vm.startPrank(controllerAdmin);
        controller.executeAction(Actions.InstallModule, address(treasuryModule));
        controller.executeAction(Actions.ActivatePolicy, address(handler));
        controller.grantRole(controller.EXECUTOR_ROLE(), address(treasuryModule));
        vm.stopPrank();
    }

    function testConstructorRejectsZeroAdmin() public {
        vm.expectRevert(TreasuryHandler.TreasuryHandler__AdminIsAddressZero.selector);
        new TreasuryHandler(address(controller), address(0));
    }

    function testConstructorGrantsInitialAdminRoles() public view {
        assertTrue(handler.hasRole(handler.DEFAULT_ADMIN_ROLE(), treasuryAdmin));
        assertTrue(handler.hasRole(handler.STRATEGY_MANAGER_ROLE(), treasuryAdmin));
        assertTrue(handler.hasRole(handler.FUNDS_MANAGER_ROLE(), treasuryAdmin));
    }

    function testTreasuryHandlerConfiguresTreasuryDependencyAndPermission() public view {
        assertEq(address(handler.treasuryModule()), address(treasuryModule));

        Permissions[] memory permissions = handler.requestPermissions();
        assertEq(permissions.length, 1);
        assertTrue(Keycode.unwrap(permissions[0].keycode) == 0x5452535259);
        assertEq(permissions[0].funcSelector, TRSRY.execute.selector);
    }

    function testAddStrategyRegistersStrategyAssetsIndexAndCounter() public {
        vm.prank(strategyManager);
        handler.addStrategy(address(strategy));

        assertTrue(handler.strategyIsActive(strategy));
        assertTrue(handler.assetAccess(address(strategy), address(asset)));
        assertFalse(handler.assetAccess(address(strategy), address(secondAsset)));
        assertEq(handler.strategyCounter(), 1);
        assertEq(handler.strategyIndex(address(strategy)), 0);
        assertEq(handler.strategies(0), address(strategy));
    }

    function testAddStrategyRegistersAllStrategyAssets() public {
        vm.prank(strategyManager);
        handler.addStrategy(address(thirdStrategy));

        assertTrue(handler.assetAccess(address(thirdStrategy), address(asset)));
        assertTrue(handler.assetAccess(address(thirdStrategy), address(secondAsset)));
    }

    function testAddStrategyRequiresStrategyManagerRole() public {
        bytes32 role = handler.STRATEGY_MANAGER_ROLE();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        handler.addStrategy(address(strategy));
    }

    function testAddStrategyRejectsNonContractEmptyAssetsAndDuplicate() public {
        vm.prank(strategyManager);
        vm.expectRevert(abi.encodeWithSelector(TargetNotAContract.selector, user));
        handler.addStrategy(user);

        address[] memory emptyAssets = new address[](0);
        MockStrategy emptyStrategy = new MockStrategy(address(handler), emptyAssets);

        vm.prank(strategyManager);
        vm.expectRevert(TreasuryHandler.TreasuryHandler__StrategyHasNoAssets.selector);
        handler.addStrategy(address(emptyStrategy));

        vm.startPrank(strategyManager);
        handler.addStrategy(address(strategy));
        vm.expectRevert(TreasuryHandler.TreasuryHandler__StrategyAlreadyActive.selector);
        handler.addStrategy(address(strategy));
        vm.stopPrank();
    }

    function testRemoveStrategyClearsActiveFlagAssetAccessIndexAndCounter() public {
        vm.startPrank(strategyManager);
        handler.addStrategy(address(strategy));
        handler.removeStrategy(address(strategy));
        vm.stopPrank();

        assertFalse(handler.strategyIsActive(strategy));
        assertFalse(handler.assetAccess(address(strategy), address(asset)));
        assertEq(handler.strategyCounter(), 0);
        assertEq(handler.strategyIndex(address(strategy)), 0);

        vm.prank(strategyManager);
        vm.expectRevert(TreasuryHandler.TreasuryHandler__StrategyNotActive.selector);
        handler.removeStrategy(address(strategy));
    }

    function testRemoveStrategyClearsOriginallyGrantedAssetsEvenIfStrategyAssetViewChanges() public {
        address[] memory originalAssets = new address[](1);
        originalAssets[0] = address(asset);
        MutableMockStrategy mutableStrategy = new MutableMockStrategy(address(handler), originalAssets);

        vm.prank(strategyManager);
        handler.addStrategy(address(mutableStrategy));

        address[] memory changedAssets = new address[](1);
        changedAssets[0] = address(secondAsset);
        mutableStrategy.setAssets(changedAssets);

        vm.prank(strategyManager);
        handler.removeStrategy(address(mutableStrategy));

        assertFalse(handler.assetAccess(address(mutableStrategy), address(asset)));
        assertFalse(handler.assetAccess(address(mutableStrategy), address(secondAsset)));
    }

    function testRemoveMiddleStrategySwapsLastStrategyIntoRemovedSlot() public {
        vm.startPrank(strategyManager);
        handler.addStrategy(address(strategy));
        handler.addStrategy(address(secondStrategy));
        handler.addStrategy(address(thirdStrategy));
        handler.removeStrategy(address(secondStrategy));
        vm.stopPrank();

        assertFalse(handler.strategyIsActive(secondStrategy));
        assertFalse(handler.assetAccess(address(secondStrategy), address(secondAsset)));
        assertTrue(handler.strategyIsActive(strategy));
        assertTrue(handler.strategyIsActive(thirdStrategy));
        assertEq(handler.strategyCounter(), 2);
        assertEq(handler.strategies(0), address(strategy));
        assertEq(handler.strategies(1), address(thirdStrategy));
        assertEq(handler.strategyIndex(address(strategy)), 0);
        assertEq(handler.strategyIndex(address(thirdStrategy)), 1);
        assertEq(handler.strategyIndex(address(secondStrategy)), 0);
    }

    function testRemoveLastStrategyPreservesEarlierStrategyIndex() public {
        vm.startPrank(strategyManager);
        handler.addStrategy(address(strategy));
        handler.addStrategy(address(secondStrategy));
        handler.removeStrategy(address(secondStrategy));
        vm.stopPrank();

        assertTrue(handler.strategyIsActive(strategy));
        assertFalse(handler.strategyIsActive(secondStrategy));
        assertEq(handler.strategyCounter(), 1);
        assertEq(handler.strategies(0), address(strategy));
        assertEq(handler.strategyIndex(address(strategy)), 0);
    }

    function testRemoveStrategyRequiresStrategyManagerRoleAndActiveStrategy() public {
        bytes32 role = handler.STRATEGY_MANAGER_ROLE();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        handler.removeStrategy(address(strategy));

        vm.prank(strategyManager);
        vm.expectRevert(TreasuryHandler.TreasuryHandler__StrategyNotActive.selector);
        handler.removeStrategy(address(strategy));
    }

    function testDeployToStrategyMovesRealTreasuryAssetsToStrategyAndUpdatesVaultAccounting() public {
        _setAssets(address(asset));
        _seedBacking(address(asset), INITIAL_SUPPLY);
        _seedTreasury(address(asset), 70 ether);

        vm.prank(strategyManager);
        handler.addStrategy(address(strategy));

        ITreasury.Asset[] memory assets = _oneAsset(address(asset), 25 ether);

        vm.prank(fundsManager);
        handler.deployToStrategy(address(strategy), assets);

        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY + 45 ether);
        assertEq(asset.balanceOf(address(strategy)), 25 ether);
        assertEq(asset.balanceOf(fundsManager), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 45 ether);
    }

    function testRecallFromStrategyPullsRealAssetsBackToVaultAndUpdatesTreasuryAccounting() public {
        _setAssets(address(asset));
        _seedBacking(address(asset), INITIAL_SUPPLY);
        asset.mint(address(strategy), 40 ether);

        vm.prank(address(strategy));
        asset.approve(address(vault), 40 ether);

        vm.prank(strategyManager);
        handler.addStrategy(address(strategy));

        ITreasury.Asset[] memory assets = _oneAsset(address(asset), 40 ether);

        vm.prank(fundsManager);
        handler.recallFromStrategy(address(strategy), assets);

        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY + 40 ether);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 40 ether);
    }

    function testDeployToStrategySupportsMultipleAssetsWithIndependentAccounting() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(address(asset), INITIAL_SUPPLY);
        _seedBacking(address(secondAsset), 2_000 ether);
        _seedTreasury(address(asset), 70 ether);
        _seedTreasury(address(secondAsset), 90 ether);

        vm.prank(strategyManager);
        handler.addStrategy(address(thirdStrategy));

        ITreasury.Asset[] memory assets = new ITreasury.Asset[](2);
        assets[0] = ITreasury.Asset({asset: address(asset), amount: 25 ether});
        assets[1] = ITreasury.Asset({asset: address(secondAsset), amount: 35 ether});

        vm.prank(fundsManager);
        handler.deployToStrategy(address(thirdStrategy), assets);

        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY + 45 ether);
        assertEq(secondAsset.balanceOf(address(vault)), 2_000 ether + 55 ether);
        assertEq(asset.balanceOf(address(thirdStrategy)), 25 ether);
        assertEq(secondAsset.balanceOf(address(thirdStrategy)), 35 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(secondAsset)), 2_000 ether);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 45 ether);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(secondAsset)), 55 ether);
    }

    function testRecallFromStrategySupportsMultipleAssetsWithIndependentAccounting() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(address(asset), INITIAL_SUPPLY);
        _seedBacking(address(secondAsset), 2_000 ether);
        asset.mint(address(thirdStrategy), 25 ether);
        secondAsset.mint(address(thirdStrategy), 35 ether);

        vm.startPrank(address(thirdStrategy));
        asset.approve(address(vault), 25 ether);
        secondAsset.approve(address(vault), 35 ether);
        vm.stopPrank();

        vm.prank(strategyManager);
        handler.addStrategy(address(thirdStrategy));

        ITreasury.Asset[] memory assets = new ITreasury.Asset[](2);
        assets[0] = ITreasury.Asset({asset: address(asset), amount: 25 ether});
        assets[1] = ITreasury.Asset({asset: address(secondAsset), amount: 35 ether});

        vm.prank(fundsManager);
        handler.recallFromStrategy(address(thirdStrategy), assets);

        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY + 25 ether);
        assertEq(secondAsset.balanceOf(address(vault)), 2_000 ether + 35 ether);
        assertEq(asset.balanceOf(address(thirdStrategy)), 0);
        assertEq(secondAsset.balanceOf(address(thirdStrategy)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(secondAsset)), 2_000 ether);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 25 ether);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(secondAsset)), 35 ether);
    }

    function testDeployAndRecallRequireFundsManagerRole() public {
        ITreasury.Asset[] memory assets = _oneAsset(address(asset), 1 ether);
        bytes32 role = handler.FUNDS_MANAGER_ROLE();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        handler.deployToStrategy(address(strategy), assets);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        handler.recallFromStrategy(address(strategy), assets);
    }

    function testDeployAndRecallRejectInactiveOrUnsupportedStrategyAssetsBeforeVaultTransfers() public {
        _setAssets(address(asset));
        _seedBacking(address(asset), INITIAL_SUPPLY);
        _seedTreasury(address(asset), 10 ether);
        ITreasury.Asset[] memory assets = _oneAsset(address(asset), 1 ether);

        vm.prank(fundsManager);
        vm.expectRevert(TreasuryHandler.TreasuryHandler__InvalidDeploymentConfiguration.selector);
        handler.deployToStrategy(address(strategy), assets);

        vm.prank(fundsManager);
        vm.expectRevert(TreasuryHandler.TreasuryHandler__InvalidDeploymentConfiguration.selector);
        handler.recallFromStrategy(address(strategy), assets);

        vm.prank(strategyManager);
        handler.addStrategy(address(strategy));

        ITreasury.Asset[] memory unsupportedAssets = _oneAsset(address(secondAsset), 1 ether);

        vm.prank(fundsManager);
        vm.expectRevert(TreasuryHandler.TreasuryHandler__InvalidDeploymentConfiguration.selector);
        handler.deployToStrategy(address(strategy), unsupportedAssets);

        vm.prank(fundsManager);
        vm.expectRevert(TreasuryHandler.TreasuryHandler__InvalidDeploymentConfiguration.selector);
        handler.recallFromStrategy(address(strategy), unsupportedAssets);

        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY + 10 ether);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 10 ether);
    }

    function _oneAsset(address asset_, uint256 amount) internal pure returns (ITreasury.Asset[] memory assets) {
        assets = new ITreasury.Asset[](1);
        assets[0] = ITreasury.Asset({asset: asset_, amount: amount});
    }

    function _seedBacking(address asset_, uint256 amount) internal {
        ERC20Mock(asset_).mint(address(vault), amount);
        _setBucket(IVault.Bucket.Redeem, asset_, amount);
    }

    function _seedTreasury(address asset_, uint256 amount) internal {
        ERC20Mock(asset_).mint(address(vault), amount);
        _setBucket(IVault.Bucket.Treasury, asset_, amount);
    }

    function _setAssets(address first) internal {
        address[] memory assets = new address[](1);
        assets[0] = first;
        _setAssets(assets);
    }

    function _setAssets(address first, address second) internal {
        address[] memory assets = new address[](2);
        assets[0] = first;
        assets[1] = second;
        _setAssets(assets);
    }

    function _setAssets(address[] memory assets) internal {
        bytes memory data = new bytes(assets.length * 32);
        for (uint256 i; i < assets.length;) {
            bytes32 assetWord = bytes32(uint256(uint160(assets[i])));
            assembly ("memory-safe") {
                mstore(add(add(data, 0x20), shl(5, i)), assetWord)
            }
            unchecked {
                ++i;
            }
        }

        vm.startPrank(address(controller));
        kernel.updateState(Slots.ASSETS_LENGTH_SLOT, bytes32(assets.length));
        kernel.updateState(Slots.ASSETS_BASE_SLOT, data);
        vm.stopPrank();
    }

    function _setBucket(IVault.Bucket bucket, address asset_, uint256 amount) internal {
        vm.prank(address(controller));
        kernel.updateState(_bucketSlot(bucket, asset_), bytes32(amount));
    }

    function _bucketValue(IVault.Bucket bucket, address asset_) internal view returns (uint256) {
        return uint256(kernel.viewData(_bucketSlot(bucket, asset_)));
    }

    function _bucketSlot(IVault.Bucket bucket, address asset_) internal pure returns (bytes32) {
        if (bucket == IVault.Bucket.Borrow) return _slot(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, asset_);
        if (bucket == IVault.Bucket.Redeem) return _slot(Slots.BACKING_AMOUNT_SLOT, asset_);
        if (bucket == IVault.Bucket.Treasury) return _slot(Slots.TREASURY_AMOUNT_SLOT, asset_);
        if (bucket == IVault.Bucket.Team) return _slot(Slots.TEAM_AMOUNT_SLOT, asset_);
        if (bucket == IVault.Bucket.Collateral) return _slot(Slots.TOTAL_COLLATERL_SLOT, asset_);
        revert("invalid bucket");
    }

    function _slot(bytes32 namespace, address asset_) internal pure returns (bytes32) {
        return keccak256(abi.encode(namespace, asset_));
    }
}
