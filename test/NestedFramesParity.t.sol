// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {NestedFrames} from "../src/libraries/NestedFrames.sol";
import {MerkleBuilder} from "./utils/MerkleBuilder.sol";

/// @notice Pins the nested-settlement encodings the off-chain signer must reproduce. The same
///         vectors are asserted by gas-analyzer's `nested` module; a change on either side breaks
///         both suites.
contract NestedFramesParityTest is Test {
    function setUp() public {
        vm.chainId(1);
    }

    function test_rootLeafVector() public view {
        assertEq(
            NestedFrames.rootLeaf(7, address(0xA11CE), 0x12345678, hex"c0ffee", 0),
            0x562537256ea398ca1c8f242715abcff06a6ea9d6f28669ff0ae5f61b2e19ba6c
        );
    }

    /// A root settled with ETH appends the value; zero-value roots keep the vector above.
    function test_valuedRootLeafVector() public view {
        assertEq(
            NestedFrames.rootLeaf(7, address(0xA11CE), 0x12345678, hex"c0ffee", 5),
            0x6156e09524b304a42cdb28f61833d32ae9cd019196bb907f05bf29d263fdc6fe
        );
    }

    function test_nestedLeafVector() public view {
        assertEq(
            NestedFrames.nestedLeaf(address(0xA11CE), 3, address(0xB0B), 5, keccak256("cd"), hex"c0ffee"),
            0x6178b9fced3f51c19e98e4b19474afc92e8e93f80bcccedbb8e4beffaf750c4a
        );
    }

    function test_expiryLeafVector() public view {
        assertEq(
            NestedFrames.expiryLeaf(address(0xA11CE), 1060),
            0x1ca6f6e91b62fff1e8c6ef2374f2b9288cc36775340d330769a2acf58854ebb2
        );
    }

    function test_treeVectors() public pure {
        bytes32[] memory leaves = new bytes32[](5);
        for (uint256 i = 0; i < 5; ++i) {
            leaves[i] = keccak256(abi.encode("tree", i));
        }
        assertEq(MerkleBuilder.root(leaves), 0x03f33a58ce39118744da6fa898233d2b505f3de76e7f62224053edafe87ab482);
        assertEq(
            keccak256(abi.encodePacked(MerkleBuilder.proof(leaves, 3))),
            0x569c3f0a5fe11b3463b7d547bd91b8d31c5dee3f1af947c028439fe893ba0dac
        );
    }

    function test_witnessEncodingVector() public pure {
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = keccak256("p0");
        proof[1] = keccak256("p1");
        bytes[] memory children = new bytes[](1);
        children[0] = hex"beef";
        assertEq(
            keccak256(abi.encode(NestedFrames.Witness(keccak256("cd"), hex"c0ffee", proof, children))),
            0x40ce15e5d0c20c9213984d208f78f17446a30c62c1184ac83a678320116d7f6e
        );
    }
}
