///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BorrowPolicy} from "../src/policies/BorrowPolicy.sol";
import {Borrower} from "../src/modules/BRWR/Borrower.sol";
import {IBorrower} from "../src/interfaces/IBorrower.sol";
import {BurnerModule} from "../src/modules/DFLT/Burner.sol";
import {BurnerPolicy} from "../src/policies/BurnerPolicy.sol";
import {IBurner} from "../src/interfaces/IBurner.sol";
import {Controller} from "enten-v1/Controller.sol";
import {Token} from "enten-v1/Token.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Vault} from "enten-v1/Vault.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IVault} from "enten-v1/interfaces/IVault.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Actions} from "enten-v1/Utils.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Documents the one residual lever behind M-4: team-token unlocks. The only path that lowers the
///         team-locked counter is a {BurnerModule} burn, which reduces totalSupply by at least as much as it
///         unlocks. So effectiveSupply (= totalSupply - teamLocked) can only fall, backing-per-token can only
///         rise, and an open borrow position can never be pushed under-collateralised by an unlock.
contract BorrowerTeamUnlockTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    Token internal token;
    Borrower internal borrower;
    BorrowPolicy internal policy;
    BurnerModule internal burner;
    BurnerPolicy internal burnerPolicy;
    ERC20Mock internal asset;
    ERC20Mock internal secondAsset;

    address internal admin = makeAddr("Admin");
    address internal user = makeAddr("User");
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
        controller = new Controller(admin, protocolCollector, predictedKernel, predictedVault, predictedToken, 0);

        borrower = new Borrower(address(controller));
        policy = new BorrowPolicy(address(controller));
        burner = new BurnerModule(address(controller), address(kernel), address(0), 0);
        burnerPolicy = new BurnerPolicy(address(controller));
        asset = new ERC20Mock();
        secondAsset = new ERC20Mock();

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(borrower));
        controller.executeAction(Actions.InstallModule, address(burner));
        controller.executeAction(Actions.ActivatePolicy, address(policy));
        controller.executeAction(Actions.ActivatePolicy, address(burnerPolicy));
        vm.stopPrank();

        _setAssets(address(asset), address(secondAsset));
    }

    function testTeamUnlockViaBurnNeverReducesBorrowCapacity() public {
        // effectiveSupply starts at 800 (1000 supply - 200 locked); seed backing so bpt = 1.
        _setLocked(200 ether);
        _seedBacking(asset, 800 ether);
        _depositCollateral(100 ether);
        _borrow(_oneReceipt(address(asset), 40 ether));

        assertEq(_effectiveSupply(), 800 ether);
        uint256 maxBefore = policy.maxBorrowForAsset(user, address(asset));
        assertEq(maxBefore, 100 ether);

        // Burn 300: unlocked = min(300, 200) = 200, so totalSupply falls 300 while locked falls 200.
        // effectiveSupply drops 800 -> 700, so backing-per-token (and the borrow limit) strictly rises.
        vm.prank(user);
        burnerPolicy.burn(300 ether);

        assertEq(_effectiveSupply(), 700 ether);
        assertEq(_locked(), 0);

        uint256 maxAfter = policy.maxBorrowForAsset(user, address(asset));
        assertGe(maxAfter, maxBefore, "team unlock reduced borrow capacity");
        assertGt(maxAfter, maxBefore, "expected capacity to strictly increase here");
        // Existing debt remains within the (now larger) limit.
        assertLe(policy.currentDebtForAsset(user, address(asset)), maxAfter);
    }

    // --------------------------------------------------------------------- helpers

    function _depositCollateral(uint256 amount) internal {
        vm.prank(user);
        token.approve(address(vault), amount);
        vm.prank(user);
        policy.deposit(amount);
    }

    function _borrow(IController.Receipt[] memory receipts) internal {
        vm.prank(user);
        policy.borrow(receipts);
    }

    function _oneReceipt(address receiptAsset, uint256 amount)
        internal
        pure
        returns (IController.Receipt[] memory receipts)
    {
        receipts = new IController.Receipt[](1);
        receipts[0] = IController.Receipt({asset: receiptAsset, amount: amount});
    }

    function _seedBacking(ERC20Mock token_, uint256 amount) internal {
        token_.mint(address(vault), amount);
        _setBucket(IVault.Bucket.Redeem, address(token_), amount);
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

    function _setAssets(address first, address second) internal {
        address[] memory assets = new address[](2);
        assets[0] = first;
        assets[1] = second;

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

    function _bucketSlot(IVault.Bucket bucket, address token_) internal pure returns (bytes32) {
        if (bucket == IVault.Bucket.Redeem) return _slot(Slots.BACKING_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Borrow) return _slot(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, token_);
        if (bucket == IVault.Bucket.Collateral) return _slot(Slots.TOTAL_COLLATERAL_SLOT, token_);
        revert("invalid bucket");
    }

    function _slot(bytes32 namespace, address token_) internal pure returns (bytes32) {
        return keccak256(abi.encode(namespace, token_));
    }
}
