///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BorrowPolicy} from "../src/policies/BorrowPolicy.sol";
import {Borrower} from "../src/modules/BRWR/Borrower.sol";
import {IBorrower} from "../src/interfaces/IBorrower.sol";
import {backingPerToken} from "../src/Utils.sol";
import {IToken} from "enten-v1/interfaces/IToken.sol";
import {Controller} from "enten-v1/Controller.sol";
import {Token} from "enten-v1/Token.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Vault} from "enten-v1/Vault.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IVault} from "enten-v1/interfaces/IVault.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Actions} from "enten-v1/Utils.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

contract BorrowerInvariantHandler is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;

    BorrowPolicy public policy;
    Borrower public borrower;
    Token public token;
    ERC20Mock public asset;
    ERC20Mock public secondAsset;

    address[] public users;
    uint256 public successfulCalls;

    uint256 internal constant WAD = 1e18;

    /// @notice Highest debt-array length ever observed per user. The debt array is append-only in the
    ///         module (full repay zeroes an entry but never removes it), so the live length must always
    ///         equal this high-water mark; a shrink would indicate accounting corruption.
    mapping(address => uint256) public debtLenHighWater;

    constructor(
        BorrowPolicy policy_,
        Borrower borrower_,
        Token token_,
        ERC20Mock asset_,
        ERC20Mock secondAsset_,
        address alice,
        address bob
    ) {
        policy = policy_;
        borrower = borrower_;
        token = token_;
        asset = asset_;
        secondAsset = secondAsset_;
        users.push(alice);
        users.push(bob);
    }

    function deposit(uint8 userSeed, uint96 amountSeed) external {
        address user = _user(userSeed);
        uint256 balance = token.balanceOf(user);
        uint256 amount = bound(uint256(amountSeed), 0, balance);
        if (amount == 0) return;

        vm.startPrank(user);
        token.approve(address(policy.CONTROLLER().VAULT()), amount);
        try policy.deposit(amount) {
            ++successfulCalls;
        } catch {}
        vm.stopPrank();
    }

    function withdraw(uint8 userSeed, uint96 amountSeed) external {
        address user = _user(userSeed);
        IBorrower.UserPosition memory position = borrower.positions(user);
        uint256 amount = bound(uint256(amountSeed), 0, position.collateral);
        if (amount == 0) return;

        vm.prank(user);
        try policy.withdraw(amount) {
            ++successfulCalls;
        } catch {}
    }

    function borrow(uint8 userSeed, uint8 assetSeed, uint96 amountSeed) external {
        address user = _user(userSeed);
        address borrowAsset = _asset(assetSeed);
        uint256 maxBorrow = policy.borrowableForAsset(user, borrowAsset);
        uint256 amount = bound(uint256(amountSeed), 0, maxBorrow == 0 ? 1 : maxBorrow + 1);
        if (amount == 0) return;

        vm.prank(user);
        try policy.borrow(_oneReceipt(borrowAsset, amount)) {
            ++successfulCalls;
        } catch {}
        _trackDebtLen(user);
    }

    function borrowMax(uint8 userSeed) external {
        address user = _user(userSeed);

        vm.prank(user);
        try policy.borrowMax() {
            ++successfulCalls;
        } catch {}
        _trackDebtLen(user);
    }

    function repay(uint8 userSeed, uint8 assetSeed, uint96 amountSeed) external {
        address user = _user(userSeed);
        ERC20Mock repayAsset = _erc20Asset(assetSeed);
        uint256 debt = policy.currentDebtForAsset(user, address(repayAsset));
        uint256 balance = repayAsset.balanceOf(user);
        uint256 upper = debt < balance ? debt : balance;
        uint256 amount = bound(uint256(amountSeed), 0, upper);
        if (amount == 0) return;

        vm.startPrank(user);
        repayAsset.approve(address(policy.CONTROLLER().VAULT()), amount);
        try policy.repay(_oneReceipt(address(repayAsset), amount)) {
            ++successfulCalls;
        } catch {}
        vm.stopPrank();
    }

    function repayAll(uint8 userSeed) external {
        address user = _user(userSeed);
        IBorrower.UserPosition memory position = borrower.positions(user);

        vm.startPrank(user);
        for (uint256 i; i < position.debt.length;) {
            if (position.debt[i].amount != 0) {
                ERC20Mock(position.debt[i].asset).approve(address(policy.CONTROLLER().VAULT()), position.debt[i].amount);
            }
            unchecked {
                ++i;
            }
        }
        try policy.repayAll() {
            ++successfulCalls;
        } catch {}
        vm.stopPrank();
    }

    function depositAndBorrow(uint8 userSeed, uint8 assetSeed, uint96 collateralSeed, uint96 borrowSeed) external {
        address user = _user(userSeed);
        address borrowAsset = _asset(assetSeed);
        uint256 collateralAmount = bound(uint256(collateralSeed), 0, token.balanceOf(user));
        if (collateralAmount == 0) return;

        // Bound the borrow to the capacity the position will have *after* the collateral lands, plus one
        // wei, so the combined action exercises both the success path (borrowing against just-deposited
        // collateral) and the revert path (one wei over the limit).
        uint256 capacity = _capacityAfterDeposit(user, borrowAsset, collateralAmount);
        uint256 amount = bound(uint256(borrowSeed), 0, capacity + 1);

        vm.startPrank(user);
        token.approve(address(policy.CONTROLLER().VAULT()), collateralAmount);
        try policy.depositAndBorrow(collateralAmount, _oneReceipt(borrowAsset, amount)) {
            ++successfulCalls;
        } catch {}
        vm.stopPrank();
        _trackDebtLen(user);
    }

    function repayAndWithdraw(uint8 userSeed, uint8 assetSeed, uint96 repaySeed, uint96 withdrawSeed) external {
        address user = _user(userSeed);
        ERC20Mock repayAsset = _erc20Asset(assetSeed);

        uint256 debt = policy.currentDebtForAsset(user, address(repayAsset));
        uint256 balance = repayAsset.balanceOf(user);
        uint256 repayUpper = debt < balance ? debt : balance;
        uint256 repayAmount = bound(uint256(repaySeed), 0, repayUpper);

        uint256 collateral = borrower.positions(user).collateral;
        uint256 withdrawAmount = bound(uint256(withdrawSeed), 0, collateral);
        if (repayAmount == 0 && withdrawAmount == 0) return;

        vm.startPrank(user);
        if (repayAmount != 0) repayAsset.approve(address(policy.CONTROLLER().VAULT()), repayAmount);
        try policy.repayAndWithdraw(_oneReceipt(address(repayAsset), repayAmount), withdrawAmount) {
            ++successfulCalls;
        } catch {}
        vm.stopPrank();
    }

    function trackedUsers() external view returns (address[] memory) {
        return users;
    }

    function trackedAssets() external view returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = address(asset);
        assets[1] = address(secondAsset);
    }

    function _user(uint8 userSeed) internal view returns (address) {
        return users[userSeed % users.length];
    }

    function _asset(uint8 assetSeed) internal view returns (address) {
        return assetSeed % 2 == 0 ? address(asset) : address(secondAsset);
    }

    function _erc20Asset(uint8 assetSeed) internal view returns (ERC20Mock) {
        return assetSeed % 2 == 0 ? asset : secondAsset;
    }

    function _trackDebtLen(address user) internal {
        uint256 len = borrower.positions(user).debt.length;
        if (len > debtLenHighWater[user]) debtLenHighWater[user] = len;
    }

    /// @dev Spare borrowing capacity for `borrowAsset` assuming `addedCollateral` is deposited first.
    function _capacityAfterDeposit(address user, address borrowAsset, uint256 addedCollateral)
        internal
        view
        returns (uint256)
    {
        uint256 collateral = borrower.positions(user).collateral + addedCollateral;
        IController.Backing[] memory backings = backingPerToken(policy.KERNEL(), IToken(address(token)));

        for (uint256 i; i < backings.length;) {
            if (backings[i].asset == borrowAsset) {
                uint256 limit = Math.mulDiv(collateral, backings[i].backingPerToken, WAD);
                uint256 currentDebt = policy.currentDebtForAsset(user, borrowAsset);
                return limit > currentDebt ? limit - currentDebt : 0;
            }
            unchecked {
                ++i;
            }
        }

        return 0;
    }

    function _oneReceipt(address receiptAsset, uint256 amount)
        internal
        pure
        returns (IController.Receipt[] memory receipts)
    {
        receipts = new IController.Receipt[](1);
        receipts[0] = IController.Receipt({asset: receiptAsset, amount: amount});
    }
}

contract BorrowerInvariantTest is StdInvariant, Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;
    uint256 internal constant WAD = 1e18;

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    Token internal token;
    Borrower internal borrower;
    BorrowPolicy internal policy;
    ERC20Mock internal asset;
    ERC20Mock internal secondAsset;
    BorrowerInvariantHandler internal handler;

    address internal admin = makeAddr("Admin");
    address internal user = makeAddr("User");
    address internal alice = makeAddr("Alice");
    address internal bob = makeAddr("Bob");
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
        asset = new ERC20Mock();
        secondAsset = new ERC20Mock();

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(borrower));
        controller.executeAction(Actions.ActivatePolicy, address(policy));
        vm.stopPrank();

        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, 500 ether);
        _seedBacking(secondAsset, 200 ether);

        vm.startPrank(user);
        assertTrue(token.transfer(alice, 400 ether));
        assertTrue(token.transfer(bob, 400 ether));
        vm.stopPrank();

        handler = new BorrowerInvariantHandler(policy, borrower, token, asset, secondAsset, alice, bob);
        targetContract(address(handler));
    }

    function invariant_successfulUsersRemainCollateralized() public view {
        address[] memory users = handler.trackedUsers();
        address[] memory assets = handler.trackedAssets();

        for (uint256 i; i < users.length;) {
            IBorrower.UserPosition memory position = borrower.positions(users[i]);
            for (uint256 j; j < assets.length;) {
                uint256 debt = _debtForAsset(position, assets[j]);
                uint256 maxDebt = policy.maxBorrowForAsset(users[i], assets[j]);
                assertLe(debt, maxDebt, "user debt exceeds collateral-backed limit");
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function invariant_globalBorrowBucketMatchesTrackedUserDebt() public view {
        address[] memory users = handler.trackedUsers();
        address[] memory assets = handler.trackedAssets();

        for (uint256 i; i < assets.length;) {
            uint256 totalDebt;
            for (uint256 j; j < users.length;) {
                totalDebt += policy.currentDebtForAsset(users[j], assets[i]);
                unchecked {
                    ++j;
                }
            }

            assertEq(_bucketValue(IVault.Bucket.Borrow, assets[i]), totalDebt, "borrow bucket mismatch");
            unchecked {
                ++i;
            }
        }
    }

    function invariant_borrowPlusRedeemBackingIsConserved() public view {
        assertEq(
            _bucketValue(IVault.Bucket.Borrow, address(asset)) + _bucketValue(IVault.Bucket.Redeem, address(asset)),
            500 ether,
            "asset backing not conserved"
        );
        assertEq(
            _bucketValue(IVault.Bucket.Borrow, address(secondAsset))
                + _bucketValue(IVault.Bucket.Redeem, address(secondAsset)),
            200 ether,
            "second asset backing not conserved"
        );
    }

    function invariant_borrowableViewsDoNotExceedRemainingCapacity() public view {
        address[] memory users = handler.trackedUsers();
        address[] memory assets = handler.trackedAssets();

        for (uint256 i; i < users.length;) {
            IController.Receipt[] memory receipts = policy.borrowable(users[i]);
            for (uint256 j; j < receipts.length;) {
                bool knownAsset;
                for (uint256 k; k < assets.length;) {
                    if (receipts[j].asset == assets[k]) {
                        knownAsset = true;
                        assertEq(receipts[j].amount, policy.borrowableForAsset(users[i], assets[k]));
                    }
                    unchecked {
                        ++k;
                    }
                }
                assertTrue(knownAsset, "borrowable returned unknown asset");
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Locked collateral makes borrowed liquidity neutral to everyone else's redemptions.
    /// @dev    Borrowing moves backing from the Redeem bucket to the Borrow bucket, but it also locks
    ///         collateral TOKEN that can no longer be redeemed (redemption burns from the caller's own
    ///         balance) while still counting in effectiveSupply. As a result the Redeem bucket can always
    ///         cover the *free* (non-collateral) holders. This is the on-chain form of the algebraic
    ///         identity: the module's per-user borrow check `debt <= collateral*bpt` is exactly equivalent
    ///         to `BACKING * effectiveSupply >= freeSupply * (BACKING + BORROWED)`.
    function invariant_freeHoldersAlwaysRedeemable() public view {
        uint256 effectiveSupply = token.totalSupply() - uint256(kernel.viewData(Slots.TEAM_LOCKED_TOKENS_SLOT));
        uint256 totalCollateral = _bucketValue(IVault.Bucket.Collateral, address(token));
        uint256 freeSupply = effectiveSupply > totalCollateral ? effectiveSupply - totalCollateral : 0;

        address[] memory assets = handler.trackedAssets();
        for (uint256 i; i < assets.length;) {
            uint256 backing = _bucketValue(IVault.Bucket.Redeem, assets[i]);
            uint256 borrowed = _bucketValue(IVault.Bucket.Borrow, assets[i]);
            assertGe(
                backing * effectiveSupply, freeSupply * (backing + borrowed), "redeem bucket cannot cover free holders"
            );
            unchecked {
                ++i;
            }
        }
    }

    /// @notice The global collateral bucket equals the summed per-user collateral and the vault's token
    ///         balance. The collateral-side analog of invariant_globalBorrowBucketMatchesTrackedUserDebt.
    function invariant_collateralBucketMatchesTrackedUserCollateral() public view {
        address[] memory users = handler.trackedUsers();
        uint256 summed;
        for (uint256 i; i < users.length;) {
            summed += borrower.positions(users[i]).collateral;
            unchecked {
                ++i;
            }
        }

        uint256 bucket = _bucketValue(IVault.Bucket.Collateral, address(token));
        assertEq(bucket, summed, "collateral bucket != summed user collateral");
        // TOKEN only ever enters the vault as collateral here, so the raw balance must match the bucket.
        assertEq(token.balanceOf(address(vault)), bucket, "vault token balance != collateral bucket");
    }

    /// @notice Debt arrays stay structurally sound: the module consolidates per asset (no duplicates) and
    ///         never removes an entry, so the live length must equal the per-user high-water mark.
    function invariant_debtArrayStructuralIntegrity() public view {
        address[] memory users = handler.trackedUsers();
        for (uint256 i; i < users.length;) {
            IBorrower.UserPosition memory position = borrower.positions(users[i]);

            assertEq(position.debt.length, handler.debtLenHighWater(users[i]), "debt array length shrank");

            for (uint256 j; j < position.debt.length;) {
                for (uint256 k = j + 1; k < position.debt.length;) {
                    assertTrue(position.debt[j].asset != position.debt[k].asset, "duplicate debt asset entry");
                    unchecked {
                        ++k;
                    }
                }
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function testHandlerExecutesAtLeastOneSuccessfulAction() public {
        handler.deposit(0, 100 ether);
        assertGt(handler.successfulCalls(), 0);
    }

    function _debtForAsset(IBorrower.UserPosition memory position, address asset_)
        internal
        pure
        returns (uint256 debt)
    {
        for (uint256 i; i < position.debt.length;) {
            if (position.debt[i].asset == asset_) debt += position.debt[i].amount;
            unchecked {
                ++i;
            }
        }
    }

    function _seedBacking(ERC20Mock token_, uint256 amount) internal {
        token_.mint(address(vault), amount);
        _setBucket(IVault.Bucket.Redeem, address(token_), amount);
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

    function _bucketValue(IVault.Bucket bucket, address token_) internal view returns (uint256) {
        return uint256(kernel.viewData(_bucketSlot(bucket, token_)));
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
}
