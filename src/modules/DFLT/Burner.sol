///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IController} from "enten-v1/interfaces/IController.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {IToken} from "enten-v1/interfaces/IToken.sol";
import {IKernel} from "enten-v1/interfaces/IKernel.sol";
import {IBurner} from "../../interfaces/IBurner.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";
import {Keycode, toKeycode} from "enten-v1/Utils.sol";
import {BRNER} from "./BRNER.sol";
import {effectiveSupply} from "../../Utils.sol";

interface IControllerTokenView {
    function TOKEN() external view returns (address);
}

contract BurnerModule is BRNER {
    uint256 internal constant WAD = 1e18;

    IKernel public immutable KERNEL;
    IToken public immutable TOKEN;

    constructor(address controller, address kernel, address, uint8) BRNER(controller) {
        KERNEL = IKernel(kernel);
        address token = IControllerTokenView(controller).TOKEN();
        TOKEN = IToken(token);
    }

    function executeDeflationaryAction(Action action, address user, uint256 amount)
        external
        override(BRNER)
        permissioned
    {
        if (action == Action.Burn) {
            IController.Settlement[] memory settlements = new IController.Settlement[](1);
            uint256 remainingLocked = uint256(KERNEL.viewData(Slots.TEAM_LOCKED_TOKENS_SLOT));
            uint256 unlocked = amount < remainingLocked ? amount : remainingLocked;
            settlements[0] = IController.Settlement({
                payer: user,
                amount: amount,
                transition: IController.StateTransitions.Burn,
                receipts: new IController.Receipt[](0),
                singleStateUpdates: _burnStateUpdates(amount, unlocked),
                multiStateUpdates: new IController.StateUpdates[](0),
                externalCalls: new IController.ExternalCall[](0)
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
                multiStateUpdates: new IController.StateUpdates[](0),
                externalCalls: new IController.ExternalCall[](0)
            });
            CONTROLLER.settle(settlements);
        } else {
            revert Burner__ActionImpossible();
        }
    }

    function _burnStateUpdates(uint256, uint256 unlocked)
        internal
        pure
        returns (IController.StateUpdate[] memory updates)
    {
        if (unlocked == 0) return new IController.StateUpdate[](0);

        updates = new IController.StateUpdate[](1);
        updates[0] = IController.StateUpdate({
            op: IController.Op.Sub, slot: Slots.TEAM_LOCKED_TOKENS_SLOT, data: bytes32(unlocked)
        });
    }

    function _getReceipts(uint256 redeemAmount) internal view returns (IController.Receipt[] memory receipts) {
        uint256 totalSupply = effectiveSupply(KERNEL, TOKEN);
        if (totalSupply == 0) revert Burner__ZeroEffectiveSupply();
        if (redeemAmount >= totalSupply) revert Burner__RedeemWouldZeroEffectiveSupply();

        IController.Backing[] memory backing = _backingPerToken(totalSupply);
        if (backing.length == 0) revert Burner__NoRegisteredAssets();

        receipts = new IController.Receipt[](backing.length);
        for (uint256 i = 0; i < backing.length;) {
            uint256 assetAmount = Math.mulDiv(redeemAmount, backing[i].backingPerToken, WAD);
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
            slots[offset] = Slots.slots(Slots.BACKING_AMOUNT_SLOT, asset);
            slots[offset + 1] = Slots.slots(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, asset);

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
}
