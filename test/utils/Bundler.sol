// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

/// @notice Runs several calls inside one external call, so a transient approval and whatever
///         reads it share a transaction the way they must on chain. Foundry may treat each
///         top-level call from a test as its own transaction and clear transient storage between
///         them, so without bundling a test can only observe an approval that is already gone.
contract Bundler {
    struct Call {
        address target;
        bytes data;
    }

    /// Reverts with the first failing call's own revert data.
    function run(Call[] calldata calls) external returns (bytes[] memory results, uint256[] memory gasUsed) {
        results = new bytes[](calls.length);
        gasUsed = new uint256[](calls.length);
        for (uint256 i = 0; i < calls.length; ++i) {
            uint256 before = gasleft();
            (bool ok, bytes memory result) = calls[i].target.call(calls[i].data);
            gasUsed[i] = before - gasleft();
            if (!ok) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
            results[i] = result;
        }
    }
}
