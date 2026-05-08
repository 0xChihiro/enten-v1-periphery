///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IController} from "enten-v1/interfaces/IController.sol";
import {IEntenToken} from "enten-v1/interfaces/IEntenToken.sol";
import {IKernel} from "enten-v1/interfaces/IKernel.sol";
import {IBurner} from "../../interfaces/IBurner.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";
import {Keycode, toKeycode} from "enten-v1/Utils.sol";
import {BRNER} from "./BRNER.sol";

interface IControllerTokenView {
    function TOKEN() external view returns (address);
}

contract BurnerModule is BRNER {
    uint256 internal constant WAD = 1e18;
    IKernel public immutable KERNEL;
    IEntenToken public immutable TOKEN;

    constructor(address controller, address kernel) BRNER(controller) {
        KERNEL = IKernel(kernel);
        address token = IControllerTokenView(controller).TOKEN();
        TOKEN = IEntenToken(token);
    }

    function executeDeflationaryAction(Action action, address user, uint256 amount)
        external
        override(BRNER)
        permissioned
    {
        if (action == Action.Burn) {
            IController.Settlement[] memory settlements = new IController.Settlement[](1);
            settlements[0] = IController.Settlement({
                payer: user,
                amount: amount,
                transition: IController.StateTransitions.Burn,
                receipts: new IController.Receipt[](0),
                singleStateUpdates: new IController.StateUpdate[](0),
                multiStateUpdates: new IController.StateUpdates[](0)
            });
            CONTROLLER.settle(settlements);
        } else if (action == Action.Redeem) {
            IController.Settlement[] memory settlements = new IController.Settlement[](1);
            settlements[0] = IController.Settlement({
                payer: user,
                amount: amount,
                transition: IController.StateTransitions.Redeem,
                receipts: _getReceipts(amount),
                singleStateUpdates: new IController.StateUpdate[](0),
                multiStateUpdates: new IController.StateUpdates[](0)
            });
            CONTROLLER.settle(settlements);
        } else {
            revert Burner__ActionImpossible();
        }
    }

    function _getReceipts(uint256 redeemAmount) internal view returns (IController.Receipt[] memory receipts) {
        uint256 totalSupply = TOKEN.totalSupply();
        IController.Backing[] memory backing = _backingPerToken(totalSupply);
        receipts = new IController.Receipt[](backing.length);
        for (uint256 i = 0; i < backing.length;) {
            uint256 assetAmount = Math.mulDiv(redeemAmount, backing[i].backingPerToken, totalSupply);
            receipts[i] = IController.Receipt({asset: backing[i].asset, amount: assetAmount});
            unchecked {
                i++;
            }
        }
    }

    function _backingPerToken(uint256 totalSupply) internal view returns (IController.Backing[] memory backing) {
        if (totalSupply == 0) return new IController.Backing[](0);

        uint256 assetsLength = uint256(KERNEL.viewData(Slots.ASSETS_LENGTH_SLOT));
        backing = new IController.Backing[](assetsLength);
        if (assetsLength == 0) return backing;

        bytes memory rawAssets = KERNEL.viewData(Slots.ASSETS_BASE_SLOT, assetsLength);
        bytes32[] memory slots = new bytes32[](assetsLength * 2);

        for (uint256 i; i < assetsLength;) {
            address asset;

            assembly ("memory-safe") {
                asset := and(mload(add(add(rawAssets, 0x20), shl(5, i))), 0xffffffffffffffffffffffffffffffffffffffff)
            }

            backing[i].asset = asset;
            uint256 offset = i * 2;
            slots[offset] = _slot(Slots.BACKING_AMOUNT_SLOT, asset);
            slots[offset + 1] = _slot(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, asset);

            unchecked {
                ++i;
            }
        }

        bytes32[] memory responses = KERNEL.viewData(slots);

        for (uint256 i; i < assetsLength;) {
            uint256 offset = i * 2;
            uint256 totalBacking = uint256(responses[offset]) + uint256(responses[offset + 1]);
            backing[i].backingPerToken = Math.mulDiv(totalBacking, WAD, totalSupply);

            unchecked {
                ++i;
            }
        }
    }

    function _slot(bytes32 namespace, address asset) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0x00, namespace)
            mstore(0x20, and(asset, 0xffffffffffffffffffffffffffffffffffffffff))
            slot := keccak256(0x00, 0x40)
        }
    }
}
