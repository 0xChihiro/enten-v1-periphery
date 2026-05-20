///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IController} from "enten-v1/interfaces/IController.sol";
import {IKernel} from "enten-v1/interfaces/IKernel.sol";
import {IToken} from "enten-v1/interfaces/IToken.sol";
import {Slots} from "enten-v1/libraries/Slots.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";

uint256 constant WAD = 1e18;

error InvalidAddressSliceLength();
error AssetNotBorrowable(address);

function assets(IKernel kernel) view returns (address[] memory assetsAddr) {
    uint256 assetsLen = uint256(kernel.viewData(Slots.ASSETS_LENGTH_SLOT));
    bytes memory rawAssets = kernel.viewData(Slots.ASSETS_BASE_SLOT, assetsLen);
    return decodeAddresses(rawAssets);
}

function decodeAddresses(bytes memory data) pure returns (address[] memory addresses) {
    if (data.length % 32 != 0) revert InvalidAddressSliceLength();

    uint256 length = data.length / 32;
    addresses = new address[](length);

    for (uint256 i; i < length;) {
        bytes32 word;

        assembly ("memory-safe") {
            word := mload(add(add(data, 0x20), mul(i, 0x20)))
        }

        addresses[i] = address(uint160(uint256(word)));

        unchecked {
            ++i;
        }
    }
}

function validateAssets(IController.Receipt[] memory requestedAssets, address[] memory borrowableAssets) pure {
    for (uint256 i; i < requestedAssets.length;) {
        bool found;

        for (uint256 j; j < borrowableAssets.length;) {
            if (requestedAssets[i].asset == borrowableAssets[j]) {
                found = true;
                break;
            }

            unchecked {
                ++j;
            }
        }

        if (!found) revert AssetNotBorrowable(requestedAssets[i].asset);

        unchecked {
            ++i;
        }
    }
}

function backingPerToken(IKernel kernel, IToken token) view returns (IController.Backing[] memory backings) {
    return backingPerToken(kernel, effectiveSupply(kernel, token));
}

function effectiveSupply(IKernel kernel, IToken token) view returns (uint256) {
    return token.totalSupply() - uint256(kernel.viewData(Slots.TEAM_LOCKED_TOKENS_SLOT));
}

function backingPerToken(IKernel kernel, uint256 totalSupply) view returns (IController.Backing[] memory backings) {
    if (totalSupply == 0) return new IController.Backing[](0);

    uint256 assetsLength = uint256(kernel.viewData(Slots.ASSETS_LENGTH_SLOT));
    backings = new IController.Backing[](assetsLength);
    if (assetsLength == 0) return backings;

    bytes memory rawAssetData = kernel.viewData(Slots.ASSETS_BASE_SLOT, assetsLength);
    address[] memory assetList = decodeAddresses(rawAssetData);

    bytes32[] memory slotsToRead = new bytes32[](assetsLength * 2);

    for (uint256 i; i < assetsLength;) {
        address asset = assetList[i];
        backings[i].asset = asset;

        uint256 offset = i * 2;
        slotsToRead[offset] = deriveAssetSlot(Slots.BACKING_AMOUNT_SLOT, asset);
        slotsToRead[offset + 1] = deriveAssetSlot(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, asset);

        unchecked {
            ++i;
        }
    }

    bytes32[] memory responses = kernel.viewData(slotsToRead);

    for (uint256 i; i < assetsLength;) {
        uint256 offset = i * 2;
        uint256 totalBacking = uint256(responses[offset]) + uint256(responses[offset + 1]);
        backings[i].backingPerToken = Math.mulDiv(totalBacking, WAD, totalSupply);

        unchecked {
            ++i;
        }
    }
}

function deriveAssetSlot(bytes32 namespace, address asset) pure returns (bytes32 slot) {
    assembly ("memory-safe") {
        mstore(0x00, namespace)
        mstore(0x20, and(asset, 0xffffffffffffffffffffffffffffffffffffffff))
        slot := keccak256(0x00, 0x40)
    }
}
