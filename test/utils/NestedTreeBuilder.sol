// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {StateUpdateType} from "../../src/StateChangeHandlerLib.sol";
import {NestedFrames} from "../../src/libraries/NestedFrames.sol";
import {MerkleBuilder} from "./MerkleBuilder.sol";

/// @notice Builds a signed-ready nested tree from frame specs, the way the off-chain signer
///         does: leaves bottom-up, the tree, then witnesses bottom-up.
/// @dev Frames are given in execution order (depth-first pre-order) with frame 0 the root, so
///      every child has a larger id than its parent. A `NESTED` op's arg is written as
///      `abi.encode(target, value, childFrameId)` and replaced with the child's leaf here.
library NestedTreeBuilder {
    struct Frame {
        address target;
        address caller;
        uint256 index;
        uint256 value;
        bytes32 calldataHash;
        bytes4 targetFunction;
        StateUpdateType[] types;
        bytes[] args;
    }

    struct Tree {
        bytes32 root;
        bytes32[] leaves;
        bytes32[] frameLeaves;
        bytes[] programs;
        bytes[] witnesses;
        bytes[] rootChildren;
        bytes32[] rootProof;
        bytes32[] expiryProof;
    }

    function build(Frame[] memory frames, uint256 expiryBlock) internal view returns (Tree memory tree) {
        uint256 n = frames.length;
        tree.frameLeaves = new bytes32[](n);
        tree.programs = new bytes[](n);
        uint256[][] memory kids = new uint256[][](n);

        for (uint256 i = n; i > 0; --i) {
            Frame memory f = frames[i - 1];
            kids[i - 1] = _resolveNested(f, tree.frameLeaves);
            tree.programs[i - 1] = abi.encode(f.types, f.args);
            tree.frameLeaves[i - 1] = i == 1
                ? NestedFrames.rootLeaf(f.index, f.target, f.targetFunction, tree.programs[0])
                : NestedFrames.nestedLeaf(f.target, f.index, f.caller, f.value, f.calldataHash, tree.programs[i - 1]);
        }

        tree.leaves = new bytes32[](n + 1);
        tree.leaves[0] = NestedFrames.expiryLeaf(frames[0].target, expiryBlock);
        for (uint256 i = 0; i < n; ++i) {
            tree.leaves[i + 1] = tree.frameLeaves[i];
        }
        tree.root = MerkleBuilder.root(tree.leaves);
        tree.expiryProof = MerkleBuilder.proof(tree.leaves, 0);
        tree.rootProof = MerkleBuilder.proof(tree.leaves, 1);

        tree.witnesses = new bytes[](n);
        for (uint256 i = n; i > 1; --i) {
            tree.witnesses[i - 1] = abi.encode(
                NestedFrames.Witness(
                    frames[i - 1].calldataHash,
                    tree.programs[i - 1],
                    MerkleBuilder.proof(tree.leaves, i),
                    _witnessesOf(kids[i - 1], tree.witnesses)
                )
            );
        }
        tree.rootChildren = _witnessesOf(kids[0], tree.witnesses);
    }

    function _resolveNested(Frame memory f, bytes32[] memory frameLeaves) private pure returns (uint256[] memory kids) {
        uint256 count;
        for (uint256 j = 0; j < f.types.length; ++j) {
            if (f.types[j] == StateUpdateType.NESTED) ++count;
        }
        kids = new uint256[](count);
        uint256 k;
        for (uint256 j = 0; j < f.types.length; ++j) {
            if (f.types[j] != StateUpdateType.NESTED) continue;
            (address target, uint256 value, uint256 child) = abi.decode(f.args[j], (address, uint256, uint256));
            f.args[j] = abi.encode(target, value, frameLeaves[child]);
            kids[k++] = child;
        }
    }

    function _witnessesOf(uint256[] memory ids, bytes[] memory witnesses) private pure returns (bytes[] memory out) {
        out = new bytes[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            out[i] = witnesses[ids[i]];
        }
    }
}
