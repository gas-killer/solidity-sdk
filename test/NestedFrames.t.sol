// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {NestedFrames} from "../src/libraries/NestedFrames.sol";
import {MerkleBuilder} from "./utils/MerkleBuilder.sol";

contract NestedFramesHarness {
    function decode(bytes calldata encoded) external pure returns (NestedFrames.Witness memory) {
        return NestedFrames.decodeWitness(encoded);
    }
}

contract NestedFramesTest is Test {
    NestedFramesHarness harness;

    address constant A = address(0xA11CE);
    address constant B = address(0xB0B);

    function setUp() public {
        harness = new NestedFramesHarness();
    }

    function test_tagsAreTheirDocumentedHashes() public pure {
        assertEq(NestedFrames.NESTED_LEAF_TAG, keccak256("gaskiller.nested.leaf.v1"));
        assertEq(NestedFrames.EXPIRY_LEAF_TAG, keccak256("gaskiller.nested.expiry.v1"));
        assertEq(NestedFrames.MODE, 0);
    }

    function test_rootLeafEqualsTodaysDigest() public pure {
        bytes memory updates = hex"c0ffee";
        bytes32 expected = sha256(abi.encode(uint256(7), A, bytes4(0x12345678), updates));
        assertEq(NestedFrames.rootLeaf(7, A, 0x12345678, updates), expected);
    }

    function test_leafTypesNeverCoincide() public view {
        bytes memory updates = hex"c0ffee";
        bytes32 root = NestedFrames.rootLeaf(1, A, 0x12345678, updates);
        bytes32 nested = NestedFrames.nestedLeaf(A, 1, B, 0, bytes32(0), updates);
        bytes32 expiry = NestedFrames.expiryLeaf(A, 1);
        assertTrue(root != nested && root != expiry && nested != expiry);
    }

    function test_leavesBindChainId() public {
        bytes32 nested = NestedFrames.nestedLeaf(A, 1, B, 2, bytes32(uint256(3)), hex"01");
        bytes32 expiry = NestedFrames.expiryLeaf(A, 100);
        vm.chainId(block.chainid + 1);
        assertTrue(NestedFrames.nestedLeaf(A, 1, B, 2, bytes32(uint256(3)), hex"01") != nested);
        assertTrue(NestedFrames.expiryLeaf(A, 100) != expiry);
    }

    function test_nestedLeafBindsEveryField() public view {
        bytes32 base = NestedFrames.nestedLeaf(A, 1, B, 2, bytes32(uint256(3)), hex"01");
        assertTrue(NestedFrames.nestedLeaf(B, 1, B, 2, bytes32(uint256(3)), hex"01") != base, "contract");
        assertTrue(NestedFrames.nestedLeaf(A, 2, B, 2, bytes32(uint256(3)), hex"01") != base, "index");
        assertTrue(NestedFrames.nestedLeaf(A, 1, A, 2, bytes32(uint256(3)), hex"01") != base, "caller");
        assertTrue(NestedFrames.nestedLeaf(A, 1, B, 3, bytes32(uint256(3)), hex"01") != base, "value");
        assertTrue(NestedFrames.nestedLeaf(A, 1, B, 2, bytes32(uint256(4)), hex"01") != base, "calldataHash");
        assertTrue(NestedFrames.nestedLeaf(A, 1, B, 2, bytes32(uint256(3)), hex"02") != base, "updates");
    }

    function test_singleLeafTreeRootIsTheLeaf() public pure {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = keccak256("only");
        assertEq(MerkleBuilder.root(leaves), leaves[0]);
        assertTrue(NestedFrames.isMember(new bytes32[](0), leaves[0], leaves[0]));
    }

    function test_everyLeafVerifiesInOddAndEvenTrees() public pure {
        for (uint256 n = 2; n <= 7; ++n) {
            bytes32[] memory leaves = _leaves(n, "tree");
            bytes32 root = MerkleBuilder.root(leaves);
            for (uint256 i = 0; i < n; ++i) {
                assertTrue(NestedFrames.isMember(MerkleBuilder.proof(leaves, i), root, leaves[i]), "member");
            }
        }
    }

    function test_leafFromAnotherTreeFails() public pure {
        bytes32[] memory leaves = _leaves(5, "tree");
        bytes32[] memory other = _leaves(5, "other");
        bytes32 root = MerkleBuilder.root(leaves);
        assertFalse(NestedFrames.isMember(MerkleBuilder.proof(other, 2), root, other[2]));
    }

    /// An internal node only passes as a leaf when the caller supplies the leaf hash; the SDK
    /// always hashes typed fields itself, so the shortened-proof form below is unreachable.
    function test_shortenedProofForAnInternalNodeIsTheOnlyWayIn() public pure {
        bytes32[] memory leaves = _leaves(4, "tree");
        bytes32 root = MerkleBuilder.root(leaves);
        bytes32 internalNode = MerkleBuilder.hashPair(leaves[0], leaves[1]);
        bytes32[] memory shortened = new bytes32[](1);
        shortened[0] = MerkleBuilder.hashPair(leaves[2], leaves[3]);
        assertTrue(NestedFrames.isMember(shortened, root, internalNode));
        assertFalse(NestedFrames.isMember(MerkleBuilder.proof(leaves, 0), root, internalNode));
    }

    function test_witnessRoundTrips() public view {
        bytes[] memory children = new bytes[](1);
        children[0] = hex"beef";
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = keccak256("p0");
        proof[1] = keccak256("p1");
        NestedFrames.Witness memory w =
            harness.decode(abi.encode(NestedFrames.Witness(keccak256("cd"), hex"c0ffee", proof, children)));
        assertEq(w.calldataHash, keccak256("cd"));
        assertEq(w.storageUpdates, hex"c0ffee");
        assertEq(w.proof.length, 2);
        assertEq(w.proof[1], keccak256("p1"));
        assertEq(w.children[0], hex"beef");
    }

    function test_malformedWitnessReverts() public {
        bytes memory good = abi.encode(NestedFrames.Witness(bytes32(0), hex"c0ffee", new bytes32[](0), new bytes[](0)));
        bytes memory truncated = new bytes(good.length - 40);
        for (uint256 i = 0; i < truncated.length; ++i) {
            truncated[i] = good[i];
        }
        vm.expectRevert();
        harness.decode(truncated);

        bytes memory badOffset = good;
        badOffset[31] = 0xff;
        vm.expectRevert();
        harness.decode(badOffset);
    }

    function _leaves(uint256 n, string memory salt) private pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            leaves[i] = keccak256(abi.encode(salt, i));
        }
    }
}
