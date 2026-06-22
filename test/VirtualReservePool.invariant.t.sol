// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {VirtualReservePool} from "../src/policies/VirtualReservePool.sol";
import {Minter} from "../src/modules/MINTR/Minter.sol";
import {BurnerModule} from "../src/modules/DFLT/Burner.sol";
import {IBurner} from "../src/interfaces/IBurner.sol";
import {Controller} from "enten-v1/Controller.sol";
import {Kernel} from "enten-v1/Kernel.sol";
import {Token} from "enten-v1/Token.sol";
import {Vault} from "enten-v1/Vault.sol";
import {IController} from "enten-v1/interfaces/IController.sol";
import {IVault} from "enten-v1/interfaces/IVault.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Actions, Keycode} from "enten-v1/Utils.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Drives buys and time advances against a two-asset VirtualReservePool. Records high-water marks
///         the invariants assert against.
contract VirtualReservePoolInvariantHandler is Test {
    VirtualReservePool public pool;
    Kernel public kernel;
    address public controller;
    Token public token;
    Vault public vault;
    ERC20Mock public assetA;
    ERC20Mock public assetB;

    address public buyer;
    uint256 public successfulBuys;
    uint256 public totalMintedByBuys;
    uint256 public successfulDonations;
    uint256 public successfulSells;
    uint256 public successfulDeepens;
    uint256 public totalRedeemedBySells;

    constructor(
        VirtualReservePool pool_,
        Token token_,
        Vault vault_,
        ERC20Mock assetA_,
        ERC20Mock assetB_,
        address buyer_
    ) {
        pool = pool_;
        // Resolve these via external calls ONCE here, never inside a pranked function: an external
        // staticcall (e.g. pool.KERNEL()) under vm.prank would consume the prank before updateState.
        kernel = Kernel(address(pool_.KERNEL()));
        controller = address(pool_.CONTROLLER());
        token = token_;
        vault = vault_;
        assetA = assetA_;
        assetB = assetB_;
        buyer = buyer_;
    }

    /// @notice Buy a bounded amount, paying both assets at the quoted prices.
    function buy(uint96 amountSeed) external {
        uint256 cap = _minReserve();
        if (cap <= 1) return;
        uint256 amount = bound(uint256(amountSeed), 1, cap - 1);

        (IController.Receipt[] memory q,,) = pool.quote(amount);

        assetA.mint(buyer, q[0].amount);
        assetB.mint(buyer, q[1].amount);
        vm.startPrank(buyer);
        assetA.approve(address(vault), q[0].amount);
        assetB.approve(address(vault), q[1].amount);
        try pool.buy(amount, q, block.timestamp) {
            ++successfulBuys;
            totalMintedByBuys += amount;
        } catch {}
        vm.stopPrank();
    }

    /// @notice Advance time so the premium decay path is exercised between buys.
    function warp(uint32 dt) external {
        vm.warp(block.timestamp + (uint256(dt) % (30 days) + 1));
    }

    /// @notice Simulate external backing growth (e.g. yield) flowing into the redeem bucket.
    function simulateBackingGrowth(uint8 assetSeed, uint96 amountSeed) external {
        ERC20Mock a = assetSeed % 2 == 0 ? assetA : assetB;
        uint256 amount = bound(uint256(amountSeed), 0, 10_000 ether);
        if (amount == 0) return;
        a.mint(address(vault), amount);
        bytes32 slot = keccak256(abi.encode(Slots.BACKING_AMOUNT_SLOT, address(a)));
        uint256 current = uint256(kernel.viewData(slot));
        vm.prank(controller);
        kernel.updateState(slot, bytes32(current + amount));
        ++successfulDonations;
    }

    /// @notice Sell (redeem) part of the buyer's accumulated token balance back for pure backing.
    function sell(uint96 amountSeed) external {
        uint256 balance = token.balanceOf(buyer);
        if (balance == 0) return;
        // BRNER forbids redeeming the entire effective supply, so stay below balance and supply.
        uint256 maxRedeem = balance < 100 ether ? balance : 100 ether;
        uint256 amount = bound(uint256(amountSeed), 1, maxRedeem);

        IController.Receipt[] memory minOut = new IController.Receipt[](2);
        minOut[0] = IController.Receipt({asset: address(assetA), amount: 0});
        minOut[1] = IController.Receipt({asset: address(assetB), amount: 0});

        vm.prank(buyer);
        try pool.sell(amount, minOut, block.timestamp) {
            ++successfulSells;
            totalRedeemedBySells += amount;
        } catch {}
    }

    /// @notice Deepen one asset's virtual reserve. The handler is granted RESERVE_ROLE in setUp.
    function deepen(uint8 assetSeed, uint96 increaseSeed) external {
        ERC20Mock a = assetSeed % 2 == 0 ? assetA : assetB;
        (uint256 oldVtr,,,,,, bool configured) = pool.reserves(address(a));
        if (!configured) return;

        uint256 increase = bound(uint256(increaseSeed), 1, 1_000 ether);
        pool.deepenReserve(address(a), oldVtr + increase);
        ++successfulDeepens;
    }

    function _minReserve() internal view returns (uint256) {
        uint256 ra = pool.reserveOf(address(assetA));
        uint256 rb = pool.reserveOf(address(assetB));
        return ra < rb ? ra : rb;
    }
}

contract VirtualReservePoolInvariantTest is StdInvariant, Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;
    uint256 internal constant BACKING_A = 1_000 ether;
    uint256 internal constant BACKING_B = 2_000 ether;
    uint256 internal constant RESERVE_A = 1_000 ether;
    uint256 internal constant RESERVE_B = 200 ether;
    uint256 internal constant START_PREMIUM = 0.5 ether;
    uint256 internal constant HALF_LIFE = 10 hours;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RESET_THRESHOLD_BPS = 8_000;
    uint256 internal constant RESET_TARGET_BPS = 2_000;
    uint256 internal constant MIN_PREMIUM_BPS = 500;

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    Token internal token;
    Minter internal minter;
    BurnerModule internal burner;
    VirtualReservePool internal pool;
    ERC20Mock internal assetA;
    ERC20Mock internal assetB;
    VirtualReservePoolInvariantHandler internal handler;

    address internal admin = makeAddr("Admin");
    address internal holder = makeAddr("Holder");
    address internal buyer = makeAddr("Buyer");
    address internal protocolCollector = makeAddr("Protocol Collector");

    // Snapshot floors at deploy so invariants can assert monotonic non-decrease.
    uint256 internal lastBptA;
    uint256 internal lastBptB;

    function setUp() public {
        vm.warp(1_000);

        uint256 nonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedToken = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedController = vm.computeCreateAddress(address(this), nonce + 3);

        kernel = new Kernel(predictedController, predictedVault);
        vault = new Vault(predictedController, predictedKernel);
        token = new Token("Enten", "ENTEN", predictedController, holder, INITIAL_SUPPLY, type(uint256).max);
        controller = new Controller(admin, protocolCollector, predictedKernel, predictedVault, predictedToken, 0);

        assetA = new ERC20Mock();
        assetB = new ERC20Mock();
        minter = new Minter(address(controller));
        burner = new BurnerModule(address(controller), address(kernel), address(assetA), 2);
        pool = new VirtualReservePool(address(controller), admin, HALF_LIFE, RESET_THRESHOLD_BPS, RESET_TARGET_BPS, MIN_PREMIUM_BPS);

        _setAssets(address(assetA), address(assetB));
        _seedBacking(assetA, BACKING_A);
        _seedBacking(assetB, BACKING_B);

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(minter));
        controller.executeAction(Actions.InstallModule, address(burner));
        controller.setMintPermission(Keycode.wrap("MINTR"), true);
        controller.executeAction(Actions.ActivatePolicy, address(pool));
        pool.setReserve(address(assetA), RESERVE_A, START_PREMIUM);
        pool.setReserve(address(assetB), RESERVE_B, START_PREMIUM);
        pool.open();
        vm.stopPrank();

        handler = new VirtualReservePoolInvariantHandler(pool, token, vault, assetA, assetB, buyer);
        bytes32 reserveRole = pool.RESERVE_ROLE();
        vm.prank(admin);
        pool.grantRole(reserveRole, address(handler));

        lastBptA = _backingPerToken(address(assetA));
        lastBptB = _backingPerToken(address(assetB));

        targetContract(address(handler));
    }

    /// @notice Supply accounting holds across mints (buys) and burns (sells): the live supply equals genesis
    ///         plus everything bought minus everything redeemed. {totalMinted} tracks ONLY curve mints (it is
    ///         not decremented by redemption, so the virtual reserve is never refilled by a sell).
    function invariant_totalMintedMatchesSupplyGrowth() public view {
        assertEq(pool.totalMinted(), handler.totalMintedByBuys(), "totalMinted != buys");
        assertEq(
            token.totalSupply(),
            INITIAL_SUPPLY + handler.totalMintedByBuys() - handler.totalRedeemedBySells(),
            "supply != genesis + bought - redeemed"
        );
    }

    /// @notice Backing-per-token is non-decreasing for every asset across any interleaving of buys, time
    ///         advances, and external backing donations — the core invariant this pool must never break.
    function invariant_backingPerTokenNeverDecreases() public {
        uint256 curA = _backingPerToken(address(assetA));
        uint256 curB = _backingPerToken(address(assetB));
        assertGe(curA, lastBptA, "asset A backing-per-token decreased");
        assertGe(curB, lastBptB, "asset B backing-per-token decreased");
        lastBptA = curA;
        lastBptB = curB;
    }

    /// @notice Spot price is always >= the fee-grossed backing floor for every asset: the premium decays
    ///         toward the floor but the curve never trades below it.
    function invariant_spotPriceNeverBelowFloor() public view {
        assertGe(pool.price(address(assetA)), pool.minimumPrice(address(assetA)), "asset A price below floor");
        assertGe(pool.price(address(assetB)), pool.minimumPrice(address(assetB)), "asset B price below floor");
    }

    /// @notice Live reserves remain internally consistent after buys and admin deepening: reserveOf(asset)
    ///         exactly equals virtualTokenReserve - (totalMinted - mintedAtConfig).
    function invariant_liveReserveConsistentAndPositive() public view {
        _assertReserve(address(assetA));
        _assertReserve(address(assetB));
    }

    /// @notice Backing accounting can never claim more than the vault actually holds: the redeem bucket for
    ///         each asset must stay covered by the vault's real token balance. Buys add equal amounts to
    ///         both (minus the protocol fee, which leaves the vault), and simulated backing growth adds to
    ///         both, so the bucket can never outrun the balance.
    function invariant_redeemBucketCoveredByVaultBalance() public view {
        assertLe(
            _bucketValue(IVault.Bucket.Redeem, address(assetA)),
            assetA.balanceOf(address(vault)),
            "asset A redeem bucket exceeds vault balance"
        );
        assertLe(
            _bucketValue(IVault.Bucket.Redeem, address(assetB)),
            assetB.balanceOf(address(vault)),
            "asset B redeem bucket exceeds vault balance"
        );
    }

    function testHandlerExecutesAtLeastOneBuy() public {
        handler.buy(uint96(10 ether));
        assertGt(handler.successfulBuys(), 0);
    }

    function _assertReserve(address asset_) internal view {
        (uint256 virtualTokenReserve,,,, uint256 mintedAtConfig,,) = pool.reserves(asset_);
        uint256 live = pool.reserveOf(asset_);
        assertEq(live, virtualTokenReserve - (pool.totalMinted() - mintedAtConfig), "live reserve mismatch");
        assertGt(live, 0, "reserve fully drained");
    }

    function _backingPerToken(address asset_) internal view returns (uint256) {
        uint256 backing = _bucketValue(IVault.Bucket.Redeem, asset_);
        uint256 supply = token.totalSupply();
        return supply == 0 ? 0 : backing * WAD / supply;
    }

    function _seedBacking(ERC20Mock token_, uint256 amount) internal {
        token_.mint(address(vault), amount);
        _setBucket(IVault.Bucket.Redeem, address(token_), amount);
    }

    function _setAssets(address first, address second) internal {
        address[] memory a = new address[](2);
        a[0] = first;
        a[1] = second;
        bytes memory data = new bytes(a.length * 32);
        for (uint256 i; i < a.length;) {
            bytes32 assetWord = bytes32(uint256(uint160(a[i])));
            assembly ("memory-safe") {
                mstore(add(add(data, 0x20), shl(5, i)), assetWord)
            }
            unchecked {
                ++i;
            }
        }
        vm.startPrank(address(controller));
        kernel.updateState(Slots.ASSETS_LENGTH_SLOT, bytes32(a.length));
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
        if (bucket == IVault.Bucket.Redeem) return _slot(Slots.BACKING_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Treasury) return _slot(Slots.TREASURY_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Team) return _slot(Slots.TEAM_AMOUNT_SLOT, token_);
        revert("invalid bucket");
    }

    function _slot(bytes32 namespace, address token_) internal pure returns (bytes32) {
        return keccak256(abi.encode(namespace, token_));
    }
}
