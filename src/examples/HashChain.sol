// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/// @title HashChain
/// @notice The deliberate per-call workload the nested examples use to make a frame worth
///         nesting: the analyzer nests a callee only when its computation outweighs the
///         per-frame overhead.
library HashChain {
    /// @dev Hashes in scratch space so memory stays constant: a struct-log trace records memory
    ///      at every step, so a loop that allocates per round makes the trace grow quadratically
    ///      and can exhaust the node serving it.
    function extend(bytes32 seed, uint256 rounds) internal pure returns (bytes32 h) {
        h = seed;
        assembly ("memory-safe") {
            for { let i := 0 } lt(i, rounds) { i := add(i, 1) } {
                mstore(0x00, h)
                mstore(0x20, i)
                h := keccak256(0x00, 0x40)
            }
        }
    }
}
