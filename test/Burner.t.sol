///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IBurner} from "../src/interfaces/IBurner.sol";
import {BurnerModule} from "../src/modules/DFLT/Burner.sol";
import {BRNER} from "../src/modules/DFLT/BRNER.sol";
import {BurnerPolicy} from "../src/policies/BurnerPolicy.sol";

import {Controller} from "enten-v1/Controller.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Module} from "enten-v1/Module.sol";
import {Policy} from "enten-v1/Policy.sol";
import {Token} from "enten-v1/Token.sol";
import {Vault} from "enten-v1/Vault.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IVault} from "enten-v1/interfaces/IVault.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Actions, Keycode, Permissions, toKeycode} from "enten-v1/Utils.sol";

import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Test} from "forge-std/Test.sol";

contract BurnerTestPolicy is Policy {
    BRNER public BURNER;

    constructor(address controller) Policy(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap("BRTST");
    }

    function configureDependencies() external override onlyController returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](1);
        dependencies[0] = toKeycode("BRNER");
        BURNER = BRNER(getModuleAddress(dependencies[0]));
    }

    function requestPermissions() external pure override returns (Permissions[] memory permissions) {
        permissions = new Permissions[](1);
        permissions[0] = Permissions(toKeycode("BRNER"), BRNER.executeDeflationaryAction.selector);
    }

    function execute(IBurner.Action action, address account, uint256 amount) external {
        BURNER.executeDeflationaryAction(action, account, amount);
    }

    function executeRaw(uint8 action, address account, uint256 amount) external {
        (bool success, bytes memory data) = address(BURNER)
            .call(abi.encodeWithSelector(BRNER.executeDeflationaryAction.selector, action, account, amount));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }
    }
}

contract BurnerModuleAndPolicyTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    Token internal token;
    BurnerModule internal burner;
    BurnerPolicy internal policy;
    BurnerTestPolicy internal harnessPolicy;
    ERC20Mock internal asset;
    ERC20Mock internal secondAsset;

    address internal admin = makeAddr("Admin");
    address internal user = makeAddr("User");
    address internal otherUser = makeAddr("Other User");
    address internal protocolCollector = makeAddr("Protocol Collector");

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedToken = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedController = vm.computeCreateAddress(address(this), nonce + 3);

        kernel = new Kernel(predictedController, predictedVault);
        vault = new Vault(predictedController, predictedKernel);
        token = new Token("Enten", "ENTEN", predictedController, user, INITIAL_SUPPLY, type(uint256).max);
        controller = new Controller(admin, protocolCollector, predictedKernel, predictedVault, predictedToken);

        asset = new ERC20Mock();
        secondAsset = new ERC20Mock();
        burner = new BurnerModule(address(controller), address(kernel), address(asset), 2);
        policy = new BurnerPolicy(address(controller));
        harnessPolicy = new BurnerTestPolicy(address(controller));

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(burner));
        controller.executeAction(Actions.ActivatePolicy, address(policy));
        controller.executeAction(Actions.ActivatePolicy, address(harnessPolicy));
        vm.stopPrank();

        _setAssets(address(asset));
    }

    function testPolicyConfiguresBurnerDependencyAndPermission() public view {
        assertEq(address(policy.BURNER()), address(burner));
        assertTrue(controller.isPolicyActive(address(policy)));
        assertTrue(
            controller.modulePermissions(toKeycode("BRNER"), address(policy), BRNER.executeDeflationaryAction.selector)
        );

        Permissions[] memory permissions = policy.requestPermissions();
        assertEq(permissions.length, 1);
        assertEq(Keycode.unwrap(permissions[0].keycode), Keycode.unwrap(toKeycode("BRNER")));
        assertEq(permissions[0].funcSelector, BRNER.executeDeflationaryAction.selector);
    }

    function testPolicyBurnRoutesMsgSenderAndUnlocksMatchingLockedTeamTokens() public {
        _seedBacking(asset, 900 ether);
        _setLocked(100 ether);
        _transferToken(user, otherUser, 50 ether);

        vm.prank(user);
        policy.burn(40 ether);

        assertEq(token.totalSupply(), INITIAL_SUPPLY - 40 ether);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 50 ether - 40 ether);
        assertEq(token.balanceOf(otherUser), 50 ether);
        assertEq(_locked(), 60 ether);
        assertEq(_effectiveSupply(), 900 ether);
        assertEq(asset.balanceOf(address(vault)), 900 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 900 ether);
    }

    function testModuleBurnCapsUnlockAtRemainingLockedAndOnlyExcessReducesEffectiveSupply() public {
        _seedBacking(asset, 900 ether);
        _setLocked(25 ether);

        vm.prank(address(harnessPolicy));
        harnessPolicy.execute(IBurner.Action.Burn, user, 40 ether);

        assertEq(token.totalSupply(), INITIAL_SUPPLY - 40 ether);
        assertEq(_locked(), 0);
        assertEq(_effectiveSupply(), 960 ether);
        assertEq(asset.balanceOf(address(vault)), 900 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 900 ether);
    }

    function testBurnWithNoLockedTeamTokensDoesNotWriteLockedSlot() public {
        _seedBacking(asset, INITIAL_SUPPLY);
        assertEq(_locked(), 0);

        vm.prank(user);
        policy.burn(10 ether);

        assertEq(token.totalSupply(), INITIAL_SUPPLY - 10 ether);
        assertEq(_locked(), 0);
        assertEq(_effectiveSupply(), INITIAL_SUPPLY - 10 ether);
        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY);
    }

    function testBurnZeroLeavesSupplyLockedAndBackingUnchanged() public {
        _seedBacking(asset, 900 ether);
        _setLocked(100 ether);

        vm.prank(user);
        policy.burn(0);

        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY);
        assertEq(_locked(), 100 ether);
        assertEq(asset.balanceOf(address(vault)), 900 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 900 ether);
    }

    function testPolicyRedeemBurnsTokensTransfersBackingAndDoesNotUnlockTeamTokens() public {
        _seedBacking(asset, 900 ether);
        _setLocked(100 ether);

        vm.prank(user);
        policy.redeem(90 ether);

        assertEq(token.totalSupply(), INITIAL_SUPPLY - 90 ether);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 90 ether);
        assertEq(asset.balanceOf(user), 90 ether);
        assertEq(asset.balanceOf(address(vault)), 810 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 810 ether);
        assertEq(_locked(), 100 ether);
        assertEq(_effectiveSupply(), 810 ether);
    }

    function testRedeemUsesEffectiveSupplyForFractionalBackingReceipts() public {
        _seedBacking(asset, 450 ether);
        _setLocked(100 ether);

        vm.prank(user);
        policy.redeem(100 ether);

        assertEq(asset.balanceOf(user), 50 ether);
        assertEq(asset.balanceOf(address(vault)), 400 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 400 ether);
        assertEq(token.totalSupply(), 900 ether);
        assertEq(_locked(), 100 ether);
        assertEq(_effectiveSupply(), 800 ether);
    }

    function testRedeemReceiptsIncludeBorrowedBackingInBackingPerTokenMath() public {
        _seedBacking(asset, 400 ether);
        _setBucket(IVault.Bucket.Borrow, address(asset), 500 ether);
        _setLocked(100 ether);

        vm.prank(user);
        policy.redeem(90 ether);

        assertEq(asset.balanceOf(user), 90 ether);
        assertEq(asset.balanceOf(address(vault)), 310 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 310 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 500 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 90 ether);
        assertEq(_locked(), 100 ether);
    }

    function testRedeemTransfersProRataBackingForAllRegisteredAssets() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, 900 ether);
        _seedBacking(secondAsset, 450 ether);
        _setLocked(100 ether);

        vm.prank(user);
        policy.redeem(90 ether);

        assertEq(asset.balanceOf(user), 90 ether);
        assertEq(secondAsset.balanceOf(user), 45 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 810 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(secondAsset)), 405 ether);
        assertEq(_locked(), 100 ether);
    }

    function testDirectUnpermissionedModuleCallReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Module.Module__PolicyNotPermitted.selector, user));
        vm.prank(user);
        burner.executeDeflationaryAction(IBurner.Action.Burn, user, 1 ether);
    }

    function testBurnAfterPolicyDeactivatedRevertsAndLeavesStateUnchanged() public {
        _seedBacking(asset, 900 ether);
        _setLocked(100 ether);

        vm.prank(admin);
        controller.executeAction(Actions.DeactivatePolicy, address(policy));

        vm.expectRevert(abi.encodeWithSelector(Module.Module__PolicyNotPermitted.selector, address(policy)));
        vm.prank(user);
        policy.burn(10 ether);

        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY);
        assertEq(_locked(), 100 ether);
        assertEq(asset.balanceOf(address(vault)), 900 ether);
    }

    function testUnsupportedBurnerActionRevertsWithoutChangingState() public {
        _seedBacking(asset, 900 ether);
        _setLocked(100 ether);

        vm.expectRevert();
        harnessPolicy.executeRaw(2, user, 10 ether);

        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY);
        assertEq(_locked(), 100 ether);
        assertEq(asset.balanceOf(address(vault)), 900 ether);
    }

    function testBurnOverBalanceRevertsAtomically() public {
        _seedBacking(asset, 900 ether);
        _setLocked(100 ether);

        vm.expectRevert();
        vm.prank(user);
        policy.burn(INITIAL_SUPPLY + 1);

        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY);
        assertEq(_locked(), 100 ether);
        assertEq(asset.balanceOf(address(vault)), 900 ether);
    }

    function testRedeemOverBalanceRevertsAtomically() public {
        _seedBacking(asset, 900 ether);
        _setLocked(100 ether);

        vm.expectRevert();
        vm.prank(user);
        policy.redeem(INITIAL_SUPPLY + 1);

        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY);
        assertEq(asset.balanceOf(user), 0);
        assertEq(asset.balanceOf(address(vault)), 900 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 900 ether);
        assertEq(_locked(), 100 ether);
    }

    function testRedeemWithoutEnoughRedeemableBackingRevertsAtomically() public {
        _seedBacking(asset, 40 ether);
        _setBucket(IVault.Bucket.Borrow, address(asset), 860 ether);
        _setLocked(100 ether);

        vm.expectRevert();
        vm.prank(user);
        policy.redeem(90 ether);

        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY);
        assertEq(asset.balanceOf(user), 0);
        assertEq(asset.balanceOf(address(vault)), 40 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 40 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 860 ether);
        assertEq(_locked(), 100 ether);
    }

    function testRedeemWithZeroEffectiveSupplyRevertsAtomically() public {
        _seedBacking(asset, 0);
        _setLocked(INITIAL_SUPPLY);

        vm.expectRevert(IBurner.Burner__ZeroEffectiveSupply.selector);
        vm.prank(user);
        policy.redeem(1 ether);

        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY);
        assertEq(asset.balanceOf(user), 0);
        assertEq(_locked(), INITIAL_SUPPLY);
        assertEq(_effectiveSupply(), 0);
    }

    function testRedeemWithNoRegisteredAssetsRevertsAtomically() public {
        _setAssets(new address[](0));
        assertEq(uint256(kernel.viewData(Slots.ASSETS_LENGTH_SLOT)), 0);

        vm.expectRevert(IBurner.Burner__NoRegisteredAssets.selector);
        vm.prank(user);
        policy.redeem(1 ether);

        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY);
        assertEq(_locked(), 0);
    }

    function testBurnWithNoRegisteredAssetsStillWorks() public {
        _setAssets(new address[](0));
        _setLocked(100 ether);

        vm.prank(user);
        policy.burn(25 ether);

        assertEq(token.totalSupply(), INITIAL_SUPPLY - 25 ether);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 25 ether);
        assertEq(_locked(), 75 ether);
        assertEq(_effectiveSupply(), 900 ether);
    }

    function testRedeemRoundsReceiptDownByOneWeiBoundary() public {
        _seedBacking(asset, 2);

        vm.prank(user);
        policy.redeem(333333333333333333);

        assertEq(asset.balanceOf(user), 0);
        assertEq(asset.balanceOf(address(vault)), 2);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 2);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 333333333333333333);
    }

    function testRedeemOneWeiTransfersRoundedDownBacking() public {
        _seedBacking(asset, 500 ether);

        vm.prank(user);
        policy.redeem(1);

        assertEq(asset.balanceOf(user), 0);
        assertEq(asset.balanceOf(address(vault)), 500 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 500 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 1);
    }

    function testRedeemFullEffectiveSupplyRevertsAtomically() public {
        _seedBacking(asset, 900 ether);
        _setLocked(100 ether);

        vm.expectRevert(IBurner.Burner__RedeemWouldZeroEffectiveSupply.selector);
        vm.prank(user);
        policy.redeem(900 ether);

        assertEq(asset.balanceOf(user), 0);
        assertEq(asset.balanceOf(address(vault)), 900 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 900 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(_locked(), 100 ether);
        assertEq(_effectiveSupply(), 900 ether);
    }

    function testFuzzBurnLockedAccounting(uint256 rawLocked, uint256 rawAmount) public {
        uint256 lockedBefore = bound(rawLocked, 0, INITIAL_SUPPLY);
        uint256 amount = bound(rawAmount, 0, INITIAL_SUPPLY - 1);
        uint256 effectiveBefore = INITIAL_SUPPLY - lockedBefore;
        uint256 expectedUnlocked = amount < lockedBefore ? amount : lockedBefore;

        _seedBacking(asset, effectiveBefore);
        _setLocked(lockedBefore);

        vm.prank(user);
        policy.burn(amount);

        assertEq(token.totalSupply(), INITIAL_SUPPLY - amount);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - amount);
        assertEq(_locked(), lockedBefore - expectedUnlocked);
        assertEq(_effectiveSupply(), effectiveBefore - (amount - expectedUnlocked));
        assertEq(asset.balanceOf(address(vault)), effectiveBefore);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), effectiveBefore);
    }

    function testFuzzRedeemTransfersRoundedProRataBackingAndUpdatesBuckets(
        uint256 rawLocked,
        uint256 rawRedeemAmount,
        uint256 rawFirstBacking,
        uint256 rawSecondBacking
    ) public {
        _setAssets(address(asset), address(secondAsset));
        uint256 lockedBefore = bound(rawLocked, 0, INITIAL_SUPPLY - 2);
        uint256 effectiveBefore = INITIAL_SUPPLY - lockedBefore;
        uint256 redeemAmount = bound(rawRedeemAmount, 1, effectiveBefore - 1);
        uint256 firstBacking = bound(rawFirstBacking, 1, 2_000 ether);
        uint256 secondBacking = bound(rawSecondBacking, 1, 2_000 ether);
        _seedBacking(asset, firstBacking);
        _seedBacking(secondAsset, secondBacking);
        _setLocked(lockedBefore);

        uint256 expectedFirstReceipt = _expectedRedeemReceipt(firstBacking, effectiveBefore, redeemAmount);
        uint256 expectedSecondReceipt = _expectedRedeemReceipt(secondBacking, effectiveBefore, redeemAmount);

        vm.prank(user);
        policy.redeem(redeemAmount);

        assertEq(asset.balanceOf(user), expectedFirstReceipt);
        assertEq(secondAsset.balanceOf(user), expectedSecondReceipt);
        assertEq(asset.balanceOf(address(vault)), firstBacking - expectedFirstReceipt);
        assertEq(secondAsset.balanceOf(address(vault)), secondBacking - expectedSecondReceipt);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), firstBacking - expectedFirstReceipt);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(secondAsset)), secondBacking - expectedSecondReceipt);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - redeemAmount);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - redeemAmount);
        assertEq(_locked(), lockedBefore);
        assertEq(_effectiveSupply(), effectiveBefore - redeemAmount);
    }

    function testActivatingBurnerPolicyBeforeBurnerModuleInstalledReverts() public {
        (Controller freshController,,,, BurnerPolicy freshPolicy,) = _deployFreshCoreWithoutBurner();

        vm.expectRevert(abi.encodeWithSelector(Policy.Policy__ModuleDoesNotExist.selector, toKeycode("BRNER")));
        vm.prank(admin);
        freshController.executeAction(Actions.ActivatePolicy, address(freshPolicy));
    }

    function testDisabledBurnerModuleBlocksPolicyBurnAtomically() public {
        _seedBacking(asset, 900 ether);
        _setLocked(100 ether);

        vm.prank(admin);
        controller.setModuleDisabled(toKeycode("BRNER"), true);

        vm.expectRevert(abi.encodeWithSelector(IController.Controller__ModuleDisabled.selector, toKeycode("BRNER")));
        vm.prank(user);
        policy.burn(10 ether);

        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY);
        assertEq(_locked(), 100 ether);
        assertEq(asset.balanceOf(address(vault)), 900 ether);
    }

    function testDisabledBurnerModuleBlocksPolicyRedeemAtomically() public {
        _seedBacking(asset, 900 ether);
        _setLocked(100 ether);

        vm.prank(admin);
        controller.setModuleDisabled(toKeycode("BRNER"), true);

        vm.expectRevert(abi.encodeWithSelector(IController.Controller__ModuleDisabled.selector, toKeycode("BRNER")));
        vm.prank(user);
        policy.redeem(10 ether);

        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY);
        assertEq(asset.balanceOf(user), 0);
        assertEq(asset.balanceOf(address(vault)), 900 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 900 ether);
        assertEq(_locked(), 100 ether);
    }

    function testRedeemAfterPolicyDeactivatedRevertsAndLeavesStateUnchanged() public {
        _seedBacking(asset, 900 ether);
        _setLocked(100 ether);

        vm.prank(admin);
        controller.executeAction(Actions.DeactivatePolicy, address(policy));

        vm.expectRevert(abi.encodeWithSelector(Module.Module__PolicyNotPermitted.selector, address(policy)));
        vm.prank(user);
        policy.redeem(10 ether);

        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY);
        assertEq(asset.balanceOf(user), 0);
        assertEq(asset.balanceOf(address(vault)), 900 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 900 ether);
        assertEq(_locked(), 100 ether);
    }

    function testBurnerPolicyReconfiguresDependencyAfterModuleUpgrade() public {
        BurnerModule replacement = new BurnerModule(address(controller), address(kernel), address(asset), 2);

        vm.prank(admin);
        controller.executeAction(Actions.UpgradeModule, address(replacement));

        assertEq(address(policy.BURNER()), address(replacement));
        assertEq(controller.getModuleForKeycode(toKeycode("BRNER")), address(replacement));
        assertTrue(
            controller.modulePermissions(toKeycode("BRNER"), address(policy), BRNER.executeDeflationaryAction.selector)
        );

        _seedBacking(asset, 900 ether);
        _setLocked(100 ether);

        vm.prank(user);
        policy.burn(10 ether);

        assertEq(token.totalSupply(), INITIAL_SUPPLY - 10 ether);
        assertEq(_locked(), 90 ether);
    }

    function _transferToken(address from, address to, uint256 amount) internal {
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
    }

    function _seedBacking(ERC20Mock token_, uint256 amount) internal {
        token_.mint(address(vault), amount);
        _setBucket(IVault.Bucket.Redeem, address(token_), amount);
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

    function _setBucket(IVault.Bucket bucket, address token_, uint256 amount) internal {
        vm.prank(address(controller));
        kernel.updateState(_bucketSlot(bucket, token_), bytes32(amount));
    }

    function _setLocked(uint256 amount) internal {
        vm.prank(address(controller));
        kernel.updateState(Slots.TEAM_LOCKED_TOKENS_SLOT, bytes32(amount));
    }

    function _locked() internal view returns (uint256) {
        return uint256(kernel.viewData(Slots.TEAM_LOCKED_TOKENS_SLOT));
    }

    function _effectiveSupply() internal view returns (uint256) {
        return token.totalSupply() - _locked();
    }

    function _bucketValue(IVault.Bucket bucket, address token_) internal view returns (uint256) {
        return uint256(kernel.viewData(_bucketSlot(bucket, token_)));
    }

    function _expectedRedeemReceipt(uint256 backing, uint256 effectiveSupply_, uint256 redeemAmount)
        internal
        pure
        returns (uint256)
    {
        uint256 backingPerToken = backing * 1e18 / effectiveSupply_;
        return redeemAmount * backingPerToken / 1e18;
    }

    function _bucketSlot(IVault.Bucket bucket, address token_) internal pure returns (bytes32) {
        if (bucket == IVault.Bucket.Borrow) return _slot(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, token_);
        if (bucket == IVault.Bucket.Redeem) return _slot(Slots.BACKING_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Treasury) return _slot(Slots.TREASURY_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Team) return _slot(Slots.TEAM_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Collateral) return _slot(Slots.TOTAL_COLLATERAL_SLOT, token_);
        revert("invalid bucket");
    }

    function _slot(bytes32 namespace, address token_) internal pure returns (bytes32) {
        return keccak256(abi.encode(namespace, token_));
    }

    function _deployFreshCoreWithoutBurner()
        internal
        returns (
            Controller freshController,
            Kernel freshKernel,
            Vault freshVault,
            Token freshToken,
            BurnerPolicy freshPolicy,
            ERC20Mock freshAsset
        )
    {
        uint256 nonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedToken = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedController = vm.computeCreateAddress(address(this), nonce + 3);

        freshKernel = new Kernel(predictedController, predictedVault);
        freshVault = new Vault(predictedController, predictedKernel);
        freshToken = new Token("Enten", "ENTEN", predictedController, user, INITIAL_SUPPLY, type(uint256).max);
        freshController = new Controller(admin, protocolCollector, predictedKernel, predictedVault, predictedToken);
        freshPolicy = new BurnerPolicy(address(freshController));
        freshAsset = new ERC20Mock();
    }
}
