///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IController} from "enten-v1/interfaces/IController.sol";
import {IToken} from "enten-v1/interfaces/IToken.sol";
import {IKernel} from "enten-v1/interfaces/IKernel.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Keycode, Permissions} from "enten-v1/Utils.sol";
import {BRWRv1} from "../modules/BRWR/BRWR.v1.sol";
import {IBorrower} from "../interfaces/IBorrower.sol";
import {Policy} from "enten-v1/Policy.sol";
import {decodeAddresses, validateAssets, backingPerToken} from "../Utils.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";

contract BorrowPolicy is Policy {
    Keycode internal constant BRWR_KEYCODE = Keycode.wrap("BRRWR");

    address public immutable TOKEN;
    IKernel public immutable KERNEL;
    BRWRv1 public borrowerModule;

    uint256 private constant WAD = 1e18;

    error Borrower__InvalidAssetsLength();
    error Borrower__NoAssetsAvailable();

    constructor(address controller) Policy(controller) {
        TOKEN = address(IController(controller).TOKEN());
        KERNEL = IController(controller).KERNEL();
    }

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap("BRPOL");
    }

    function configureDependencies() external override onlyController returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](1);
        dependencies[0] = BRWR_KEYCODE;

        borrowerModule = BRWRv1(getModuleAddress(BRWR_KEYCODE));
    }

    function requestPermissions() external pure override returns (Permissions[] memory permissions) {
        permissions = new Permissions[](1);
        permissions[0] = Permissions({keycode: BRWR_KEYCODE, funcSelector: BRWRv1.executeBorrowAction.selector});
    }

    function deposit(uint256 amount) external {
        address user = msg.sender;
        IBorrower.ActionData memory data =
            IBorrower.ActionData({collateralAmount: amount, receipts: new IController.Receipt[](0)});
        bytes memory encodedData = abi.encode(data);
        borrowerModule.executeBorrowAction(IBorrower.Action.Deposit, user, encodedData);
    }

    function withdraw(uint256 amount) external {
        address user = msg.sender;
        IBorrower.ActionData memory data =
            IBorrower.ActionData({collateralAmount: amount, receipts: new IController.Receipt[](0)});
        bytes memory encodedData = abi.encode(data);
        borrowerModule.executeBorrowAction(IBorrower.Action.Withdraw, user, encodedData);
    }

    function depositAndBorrow(uint256 amount, IController.Receipt[] calldata assets) external {
        validateAssets(assets, _assets());
        IBorrower.ActionData memory data = IBorrower.ActionData({collateralAmount: amount, receipts: assets});
        borrowerModule.executeBorrowAction(IBorrower.Action.DepositAndBorrow, msg.sender, abi.encode(data));
    }

    function repayAndWithdraw(IController.Receipt[] calldata assets, uint256 amount) external {
        validateAssets(assets, _assets());
        IBorrower.ActionData memory data = IBorrower.ActionData({collateralAmount: amount, receipts: assets});
        borrowerModule.executeBorrowAction(IBorrower.Action.RepayAndWithdraw, msg.sender, abi.encode(data));
    }

    function borrow(IController.Receipt[] calldata receipts) external {
        address[] memory assets = _assets();
        if (assets.length == 0) revert Borrower__NoAssetsAvailable();
        validateAssets(receipts, assets);
        IBorrower.ActionData memory data = IBorrower.ActionData({collateralAmount: 0, receipts: receipts});
        bytes memory encodedData = abi.encode(data);
        borrowerModule.executeBorrowAction(IBorrower.Action.Borrow, msg.sender, encodedData);
    }

    function repay(IController.Receipt[] calldata receipts) external {
        validateAssets(receipts, _assets());
        IBorrower.ActionData memory data = IBorrower.ActionData({collateralAmount: 0, receipts: receipts});
        borrowerModule.executeBorrowAction(IBorrower.Action.Repay, msg.sender, abi.encode(data));
    }

    function repayAll() external {
        IBorrower.UserPosition memory position = userPosition(msg.sender);
        IController.Receipt[] memory receipts = new IController.Receipt[](position.debt.length);
        uint256 receiptIdx;
        for (uint256 i = 0; i < position.debt.length;) {
            if (position.debt[i].amount > 0) {
                receipts[receiptIdx] =
                    IController.Receipt({asset: position.debt[i].asset, amount: position.debt[i].amount});
                unchecked {
                    receiptIdx++;
                }
            }
            unchecked {
                i++;
            }
        }
        assembly ("memory-safe") {
            mstore(receipts, receiptIdx)
        }

        IBorrower.ActionData memory data = IBorrower.ActionData({collateralAmount: 0, receipts: receipts});
        borrowerModule.executeBorrowAction(IBorrower.Action.Repay, msg.sender, abi.encode(data));
    }

    function borrowMax() external {
        address user = msg.sender;
        IController.Receipt[] memory receipts = _borrowableReceipts(user);

        IBorrower.ActionData memory data = IBorrower.ActionData({collateralAmount: 0, receipts: receipts});
        borrowerModule.executeBorrowAction(IBorrower.Action.Borrow, user, abi.encode(data));
    }

    function borrowable(address user) external view returns (IController.Receipt[] memory receipts) {
        return _borrowableReceipts(user);
    }

    function currentDebtForAsset(address user, address asset) external view returns (uint256 debt) {
        debt = _debtForAsset(userPosition(user), asset);
    }

    function totalCollateral() external view returns (uint256 collateral) {
        // TODO: Correct this in main repo as it is not spelled correctly.
        collateral = uint256(KERNEL.viewData(Slots.TOTAL_COLLATERL_SLOT));
    }

    function borrowableForAsset(address user, address asset) external view returns (uint256) {
        IBorrower.UserPosition memory position = userPosition(user);
        IController.Backing[] memory backings = backingPerToken(KERNEL, IToken(TOKEN));

        for (uint256 i; i < backings.length;) {
            if (backings[i].asset == asset) {
                uint256 borrowLimit = Math.mulDiv(position.collateral, backings[i].backingPerToken, WAD);
                uint256 currentDebt = _debtForAsset(position, asset);

                return borrowLimit > currentDebt ? borrowLimit - currentDebt : 0;
            }

            unchecked {
                ++i;
            }
        }

        return 0;
    }

    function maxBorrowForAsset(address user, address asset) external view returns (uint256) {
        IBorrower.UserPosition memory position = userPosition(user);
        IController.Backing[] memory backings = backingPerToken(KERNEL, IToken(TOKEN));

        for (uint256 i; i < backings.length;) {
            if (backings[i].asset == asset) {
                return Math.mulDiv(position.collateral, backings[i].backingPerToken, WAD);
            }

            unchecked {
                ++i;
            }
        }

        return 0;
    }

    function totalBorrowedPerAsset(address asset) external view returns (uint256 borrowed) {
        bytes32 slot = Slots.slots(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, asset);
        borrowed = uint256(KERNEL.viewData(slot));
    }

    function borrowableAssets() external view returns (address[] memory assets) {
        return _assets();
    }

    ///@notice user position storage layout described in Borrower _getPosition.
    function userPosition(address user) public view returns (IBorrower.UserPosition memory position) {
        bytes32 slot = Slots.USER_POSITION_BASE_SLOT;
        uint256 userSlot;

        assembly ("memory-safe") {
            mstore(0x00, slot)
            mstore(0x20, and(user, 0xffffffffffffffffffffffffffffffffffffffff))
            userSlot := keccak256(0x00, 0x40)
        }

        // Read collateral and debt.length together.
        bytes memory header = KERNEL.viewData(bytes32(userSlot), 2);

        uint256 collateral;
        uint256 debtLen;

        assembly ("memory-safe") {
            collateral := mload(add(header, 0x20))
            debtLen := mload(add(header, 0x40))
        }

        IBorrower.DebtPosition[] memory debt = new IBorrower.DebtPosition[](debtLen);

        if (debtLen != 0) {
            // Custom contiguous layout starts debt data immediately after the header.
            bytes memory rawDebtData = KERNEL.viewData(bytes32(userSlot + 2), debtLen * 2);

            for (uint256 i; i < debtLen;) {
                bytes32 assetWord;
                uint256 amount;
                uint256 offset = i * 64;

                assembly ("memory-safe") {
                    assetWord := mload(add(add(rawDebtData, 0x20), offset))
                    amount := mload(add(add(rawDebtData, 0x40), offset))
                }

                debt[i] = IBorrower.DebtPosition({asset: address(uint160(uint256(assetWord))), amount: amount});

                unchecked {
                    ++i;
                }
            }
        }

        position = IBorrower.UserPosition({collateral: collateral, debt: debt});
    }

    function _assets() internal view returns (address[] memory assets) {
        uint256 assetsLength = uint256(KERNEL.viewData(Slots.ASSETS_LENGTH_SLOT));
        assets = new address[](assetsLength);
        bytes memory rawAssetsData = KERNEL.viewData(Slots.ASSETS_BASE_SLOT, assetsLength);
        address[] memory addr = decodeAddresses(rawAssetsData);
        if (addr.length != assetsLength) revert Borrower__InvalidAssetsLength();
        assets = addr;
    }

    function _debtForAsset(IBorrower.UserPosition memory position, address asset) internal pure returns (uint256 debt) {
        for (uint256 i; i < position.debt.length;) {
            if (position.debt[i].asset == asset) {
                debt += position.debt[i].amount;
            }

            unchecked {
                ++i;
            }
        }
    }

    function _borrowableReceipts(address user) internal view returns (IController.Receipt[] memory receipts) {
        IBorrower.UserPosition memory position = userPosition(user);
        IController.Backing[] memory backings = backingPerToken(KERNEL, IToken(TOKEN));

        receipts = new IController.Receipt[](backings.length);
        uint256 receiptIdx;

        for (uint256 i; i < backings.length;) {
            address asset = backings[i].asset;
            uint256 borrowLimit = Math.mulDiv(position.collateral, backings[i].backingPerToken, WAD);
            uint256 currentDebt = _debtForAsset(position, asset);

            if (borrowLimit > currentDebt) {
                receipts[receiptIdx] = IController.Receipt({asset: asset, amount: borrowLimit - currentDebt});

                unchecked {
                    ++receiptIdx;
                }
            }

            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(receipts, receiptIdx)
        }
    }
}
