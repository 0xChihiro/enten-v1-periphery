///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IBorrower} from "../src/interfaces/IBorrower.sol";
import {Borrower} from "../src/modules/BRWR/Borrower.sol";
import {Controller} from "enten-v1/Controller.sol";
import {EntenToken} from "enten-v1/EntenToken.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Policy} from "enten-v1/Policy.sol";
import {Vault} from "enten-v1/Vault.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IVault} from "enten-v1/interfaces/IVault.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Actions, Keycode, Permissions} from "enten-v1/Utils.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

contract BorrowerInvariantPolicy is Policy {
    Keycode internal constant BRWR_KEYCODE = Keycode.wrap("BRRWR");

    constructor(address controller) Policy(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap("BRINV");
    }

    function configureDependencies() external pure override returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](1);
        dependencies[0] = BRWR_KEYCODE;
    }

    function requestPermissions() external pure override returns (Permissions[] memory requests) {
        requests = new Permissions[](1);
        requests[0] = Permissions({keycode: BRWR_KEYCODE, funcSelector: Borrower.executeBorrowAction.selector});
    }

    function executeBorrowAction(IBorrower.Action action, address user, IBorrower.ActionData memory actionData)
        external
    {
        Borrower(getModuleAddress(BRWR_KEYCODE)).executeBorrowAction(action, user, abi.encode(actionData));
    }
}

contract BorrowerInvariantHandler is Test {
    Borrower public immutable borrower;
    BorrowerInvariantPolicy public immutable policy;
    EntenToken public immutable token;
    Vault public immutable vault;

    address[] public users;
    ERC20Mock[] public assets;

    constructor(
        Borrower borrower_,
        BorrowerInvariantPolicy policy_,
        EntenToken token_,
        Vault vault_,
        address[] memory users_,
        ERC20Mock[] memory assets_
    ) {
        borrower = borrower_;
        policy = policy_;
        token = token_;
        vault = vault_;
        users = users_;
        assets = assets_;
    }

    function deposit(uint256 userSeed, uint256 amountSeed) external {
        address user = _user(userSeed);
        uint256 amount = _boundAmount(amountSeed, token.balanceOf(user));
        if (amount == 0) return;

        vm.prank(user);
        token.approve(address(vault), amount);
        _execute(IBorrower.Action.Deposit, user, amount, new IController.Receipt[](0));
    }

    function withdraw(uint256 userSeed, uint256 amountSeed) external {
        address user = _user(userSeed);
        IBorrower.UserPosition memory position = borrower.positions(user);
        uint256 maxWithdraw = _maxWithdraw(position);
        uint256 amount = _boundAmount(amountSeed, maxWithdraw);
        if (amount == 0) return;

        _execute(IBorrower.Action.Withdraw, user, amount, new IController.Receipt[](0));
    }

    function borrow(uint256 userSeed, uint256 assetSeed, uint256 amountSeed) external {
        address user = _user(userSeed);
        ERC20Mock asset = _asset(assetSeed);
        IBorrower.UserPosition memory position = borrower.positions(user);
        uint256 maxBorrow = _maxBorrow(position, address(asset));
        uint256 amount = _boundAmount(amountSeed, maxBorrow);
        if (amount == 0) return;

        _execute(IBorrower.Action.Borrow, user, 0, _oneReceipt(address(asset), amount));
    }

    function repay(uint256 userSeed, uint256 assetSeed, uint256 amountSeed) external {
        address user = _user(userSeed);
        ERC20Mock asset = _asset(assetSeed);
        IBorrower.UserPosition memory position = borrower.positions(user);
        uint256 debt = _debtFor(position, address(asset));
        uint256 amount = _boundAmount(amountSeed, debt);
        if (amount == 0) return;

        vm.prank(user);
        asset.approve(address(vault), amount);
        _execute(IBorrower.Action.Repay, user, 0, _oneReceipt(address(asset), amount));
    }

    function depositAndBorrow(uint256 userSeed, uint256 assetSeed, uint256 collateralSeed, uint256 borrowSeed)
        external
    {
        address user = _user(userSeed);
        ERC20Mock asset = _asset(assetSeed);
        uint256 collateralAmount = _boundAmount(collateralSeed, token.balanceOf(user));
        if (collateralAmount == 0) return;

        IBorrower.UserPosition memory position = borrower.positions(user);
        uint256 maxBorrow = _maxBorrowAfterCollateral(position, address(asset), collateralAmount);
        uint256 borrowAmount = _boundAmount(borrowSeed, maxBorrow);

        vm.prank(user);
        token.approve(address(vault), collateralAmount);
        _execute(IBorrower.Action.DepositAndBorrow, user, collateralAmount, _oneReceipt(address(asset), borrowAmount));
    }

    function repayAndWithdraw(uint256 userSeed, uint256 assetSeed, uint256 repaySeed, uint256 withdrawSeed) external {
        address user = _user(userSeed);
        ERC20Mock asset = _asset(assetSeed);
        IBorrower.UserPosition memory position = borrower.positions(user);
        uint256 debt = _debtFor(position, address(asset));
        uint256 repayAmount = _boundAmount(repaySeed, debt);
        uint256 maxWithdraw = _maxWithdrawAfterRepay(position, address(asset), repayAmount);
        uint256 withdrawAmount = _boundAmount(withdrawSeed, maxWithdraw);
        if (repayAmount == 0 && withdrawAmount == 0) return;

        if (repayAmount != 0) {
            vm.prank(user);
            asset.approve(address(vault), repayAmount);
        }

        _execute(IBorrower.Action.RepayAndWithdraw, user, withdrawAmount, _oneReceipt(address(asset), repayAmount));
    }

    function invalidBorrowOverLimit(uint256 userSeed, uint256 assetSeed) external {
        address user = _user(userSeed);
        ERC20Mock asset = _asset(assetSeed);
        IBorrower.UserPosition memory position = borrower.positions(user);
        uint256 amount = _maxBorrow(position, address(asset)) + 1;

        try policy.executeBorrowAction(
            IBorrower.Action.Borrow,
            user,
            IBorrower.ActionData({collateralAmount: 0, receipts: _oneReceipt(address(asset), amount)})
        ) {
            fail();
        } catch {}
    }

    function invalidRepayTooMuch(uint256 userSeed, uint256 assetSeed) external {
        address user = _user(userSeed);
        ERC20Mock asset = _asset(assetSeed);
        IBorrower.UserPosition memory position = borrower.positions(user);
        uint256 amount = _debtFor(position, address(asset)) + 1;

        try policy.executeBorrowAction(
            IBorrower.Action.Repay,
            user,
            IBorrower.ActionData({collateralAmount: 0, receipts: _oneReceipt(address(asset), amount)})
        ) {
            fail();
        } catch {}
    }

    function invalidWithdrawOverLimit(uint256 userSeed) external {
        address user = _user(userSeed);
        IBorrower.UserPosition memory position = borrower.positions(user);
        uint256 amount = _maxWithdraw(position) + 1;

        try policy.executeBorrowAction(
            IBorrower.Action.Withdraw,
            user,
            IBorrower.ActionData({collateralAmount: amount, receipts: new IController.Receipt[](0)})
        ) {
            fail();
        } catch {}
    }

    function _execute(
        IBorrower.Action action,
        address user,
        uint256 collateralAmount,
        IController.Receipt[] memory receipts
    ) internal {
        policy.executeBorrowAction(
            action, user, IBorrower.ActionData({collateralAmount: collateralAmount, receipts: receipts})
        );
    }

    function _oneReceipt(address asset, uint256 amount) internal pure returns (IController.Receipt[] memory receipts) {
        receipts = new IController.Receipt[](1);
        receipts[0] = IController.Receipt({asset: asset, amount: amount});
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }

    function _asset(uint256 seed) internal view returns (ERC20Mock) {
        return assets[seed % assets.length];
    }

    function _boundAmount(uint256 seed, uint256 maxAmount) internal pure returns (uint256) {
        if (maxAmount == 0) return 0;
        return bound(seed, 1, maxAmount);
    }

    function _maxBorrow(IBorrower.UserPosition memory position, address asset) internal pure returns (uint256) {
        uint256 currentDebt = _debtFor(position, asset);
        if (position.collateral <= currentDebt) return 0;
        return position.collateral - currentDebt;
    }

    function _maxBorrowAfterCollateral(IBorrower.UserPosition memory position, address asset, uint256 collateralAmount)
        internal
        pure
        returns (uint256)
    {
        uint256 currentDebt = _debtFor(position, asset);
        uint256 collateral = position.collateral + collateralAmount;
        if (collateral <= currentDebt) return 0;
        return collateral - currentDebt;
    }

    function _maxWithdraw(IBorrower.UserPosition memory position) internal pure returns (uint256) {
        uint256 maxDebt = _maxDebt(position);
        if (position.collateral <= maxDebt) return 0;
        return position.collateral - maxDebt;
    }

    function _maxWithdrawAfterRepay(IBorrower.UserPosition memory position, address asset, uint256 repayAmount)
        internal
        pure
        returns (uint256)
    {
        uint256 maxDebt;
        for (uint256 i; i < position.debt.length;) {
            uint256 amount = position.debt[i].amount;
            if (position.debt[i].asset == asset) amount -= repayAmount;
            if (amount > maxDebt) maxDebt = amount;
            unchecked {
                ++i;
            }
        }

        if (position.collateral <= maxDebt) return 0;
        return position.collateral - maxDebt;
    }

    function _maxDebt(IBorrower.UserPosition memory position) internal pure returns (uint256 maxDebt) {
        for (uint256 i; i < position.debt.length;) {
            if (position.debt[i].amount > maxDebt) maxDebt = position.debt[i].amount;
            unchecked {
                ++i;
            }
        }
    }

    function _debtFor(IBorrower.UserPosition memory position, address asset) internal pure returns (uint256 debt) {
        for (uint256 i; i < position.debt.length;) {
            if (position.debt[i].asset == asset) debt += position.debt[i].amount;
            unchecked {
                ++i;
            }
        }
    }
}

contract BorrowerInvariantTest is StdInvariant, Test {
    uint256 internal constant USER_COUNT = 200;
    uint256 internal constant ASSET_COUNT = 5;
    uint256 internal constant USER_TOKEN_BALANCE = 100_000 ether;
    uint256 internal constant TOTAL_TOKEN_SUPPLY = USER_COUNT * USER_TOKEN_BALANCE;
    uint256 internal constant INITIAL_ASSET_BACKING = TOTAL_TOKEN_SUPPLY;

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    EntenToken internal token;
    Borrower internal borrower;
    BorrowerInvariantPolicy internal policy;
    BorrowerInvariantHandler internal handler;

    address internal admin = makeAddr("Admin");
    address internal protocolCollector = makeAddr("Protocol Collector");
    address[] internal users;
    ERC20Mock[] internal assets;

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedToken = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedController = vm.computeCreateAddress(address(this), nonce + 3);

        kernel = new Kernel(predictedController, predictedVault);
        vault = new Vault(predictedController, predictedKernel);
        token =
            new EntenToken("Enten", "ENTEN", predictedController, address(this), TOTAL_TOKEN_SUPPLY, type(uint256).max);
        controller = new Controller(admin, protocolCollector, predictedKernel, predictedVault, predictedToken);

        borrower = new Borrower(address(controller), address(kernel));
        policy = new BorrowerInvariantPolicy(address(controller));

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(borrower));
        controller.executeAction(Actions.ActivatePolicy, address(policy));
        vm.stopPrank();

        _createUsers();
        _createAssets();
        _setAssets();
        _seedBacking();
        _distributeTokens();

        handler = new BorrowerInvariantHandler(borrower, policy, token, vault, users, assets);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = BorrowerInvariantHandler.deposit.selector;
        selectors[1] = BorrowerInvariantHandler.withdraw.selector;
        selectors[2] = BorrowerInvariantHandler.borrow.selector;
        selectors[3] = BorrowerInvariantHandler.repay.selector;
        selectors[4] = BorrowerInvariantHandler.depositAndBorrow.selector;
        selectors[5] = BorrowerInvariantHandler.repayAndWithdraw.selector;
        selectors[6] = BorrowerInvariantHandler.invalidBorrowOverLimit.selector;
        selectors[7] = BorrowerInvariantHandler.invalidRepayTooMuch.selector;
        selectors[8] = BorrowerInvariantHandler.invalidWithdrawOverLimit.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_collateralBucketMatchesUserPositions() public view {
        assertEq(_sumCollateralPositions(), _bucketValue(IVault.Bucket.Collateral, address(token)));
    }

    function invariant_borrowBucketsMatchUserDebtPositions() public view {
        for (uint256 i; i < assets.length;) {
            assertEq(_sumDebtPositions(address(assets[i])), _bucketValue(IVault.Bucket.Borrow, address(assets[i])));
            unchecked {
                ++i;
            }
        }
    }

    function invariant_borrowAndRedeemBucketsConserveInitialBacking() public view {
        for (uint256 i; i < assets.length;) {
            uint256 borrowBucket = _bucketValue(IVault.Bucket.Borrow, address(assets[i]));
            uint256 redeemBucket = _bucketValue(IVault.Bucket.Redeem, address(assets[i]));
            assertEq(borrowBucket + redeemBucket, INITIAL_ASSET_BACKING);
            unchecked {
                ++i;
            }
        }
    }

    function invariant_tokenBalancesMatchCollateralAccounting() public view {
        uint256 userBalances;
        for (uint256 i; i < users.length;) {
            userBalances += token.balanceOf(users[i]);
            unchecked {
                ++i;
            }
        }

        uint256 collateralBucket = _bucketValue(IVault.Bucket.Collateral, address(token));
        assertEq(token.balanceOf(address(vault)), collateralBucket);
        assertEq(userBalances + token.balanceOf(address(vault)), TOTAL_TOKEN_SUPPLY);
    }

    function invariant_assetBalancesMatchBorrowAccounting() public view {
        for (uint256 i; i < assets.length;) {
            uint256 userBalances;
            for (uint256 j; j < users.length;) {
                userBalances += assets[i].balanceOf(users[j]);
                unchecked {
                    ++j;
                }
            }

            uint256 borrowBucket = _bucketValue(IVault.Bucket.Borrow, address(assets[i]));
            uint256 redeemBucket = _bucketValue(IVault.Bucket.Redeem, address(assets[i]));
            assertEq(userBalances, borrowBucket);
            assertEq(assets[i].balanceOf(address(vault)), redeemBucket);
            assertEq(userBalances + assets[i].balanceOf(address(vault)), INITIAL_ASSET_BACKING);

            unchecked {
                ++i;
            }
        }
    }

    function invariant_successfulActionsLeavePositionsCollateralized() public view {
        for (uint256 i; i < users.length;) {
            IBorrower.UserPosition memory position = borrower.positions(users[i]);
            for (uint256 j; j < assets.length;) {
                assertLe(_debtFor(position, address(assets[j])), position.collateral);
                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    function _sumCollateralPositions() internal view returns (uint256 collateral) {
        for (uint256 i; i < users.length;) {
            collateral += borrower.positions(users[i]).collateral;
            unchecked {
                ++i;
            }
        }
    }

    function _sumDebtPositions(address asset_) internal view returns (uint256 debt) {
        for (uint256 i; i < users.length;) {
            debt += _debtFor(borrower.positions(users[i]), asset_);
            unchecked {
                ++i;
            }
        }
    }

    function _debtFor(IBorrower.UserPosition memory position, address asset_) internal pure returns (uint256 debt) {
        for (uint256 i; i < position.debt.length;) {
            if (position.debt[i].asset == asset_) debt += position.debt[i].amount;
            unchecked {
                ++i;
            }
        }
    }

    function _createUsers() internal {
        for (uint256 i; i < USER_COUNT;) {
            users.push(address(uint160(uint256(keccak256(abi.encode("Borrower", i))))));
            unchecked {
                ++i;
            }
        }
    }

    function _createAssets() internal {
        for (uint256 i; i < ASSET_COUNT;) {
            assets.push(new ERC20Mock());
            unchecked {
                ++i;
            }
        }
    }

    function _distributeTokens() internal {
        for (uint256 i; i < users.length;) {
            assertTrue(token.transfer(users[i], USER_TOKEN_BALANCE));
            unchecked {
                ++i;
            }
        }
    }

    function _seedBacking() internal {
        for (uint256 i; i < assets.length;) {
            assets[i].mint(address(vault), INITIAL_ASSET_BACKING);
            _setBucket(IVault.Bucket.Redeem, address(assets[i]), INITIAL_ASSET_BACKING);
            unchecked {
                ++i;
            }
        }
    }

    function _setAssets() internal {
        bytes memory data = new bytes(assets.length * 32);
        for (uint256 i; i < assets.length;) {
            bytes32 assetWord = bytes32(uint256(uint160(address(assets[i]))));
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
        if (bucket == IVault.Bucket.Collateral) return _slot(Slots.TOTAL_COLLATERL_SLOT, token_);
        revert("invalid bucket");
    }

    function _slot(bytes32 namespace, address token_) internal pure returns (bytes32) {
        return keccak256(abi.encode(namespace, token_));
    }
}
