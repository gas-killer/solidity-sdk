// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

/// @notice Builds nested-settlement trees exactly as the off-chain signer does: leaves are
///         never sorted, adjacent nodes pair with OpenZeppelin's sorted-pair keccak, and an odd
///         last node moves up a level unchanged.
library MerkleBuilder {
    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length != 0, "empty tree");
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            level = _up(level);
        }
        return level[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory out) {
        require(index < leaves.length, "index out of range");
        bytes32[] memory scratch = new bytes32[](256);
        uint256 depth;
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            uint256 sibling = index ^ 1;
            if (sibling < level.length) scratch[depth++] = level[sibling];
            level = _up(level);
            index /= 2;
        }
        out = new bytes32[](depth);
        for (uint256 i = 0; i < depth; ++i) {
            out[i] = scratch[i];
        }
    }

    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _up(bytes32[] memory level) private pure returns (bytes32[] memory next) {
        next = new bytes32[]((level.length + 1) / 2);
        for (uint256 i = 0; i < level.length; i += 2) {
            next[i / 2] = i + 1 < level.length ? hashPair(level[i], level[i + 1]) : level[i];
        }
    }
}
