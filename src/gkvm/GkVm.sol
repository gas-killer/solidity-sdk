// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.4;

import {GkVmUnavailable} from "./GkVmErrors.sol";

/// @dev The gkvm precompile address: address(uint160(uint256(keccak256("gaskiller.gkvm.addr.v1")))).
///      Exists only in the operators' simulation env; on every real chain it is an empty account.
address constant GKVM_ADDRESS = 0x35597421749DeEad8ba95049eDEe0B94E66F3c59;

/// @dev Mandatory first byte of every successful gkvm output: distinguishes a real answer from the
///      empty returndata of a STATICCALL to an empty account.
bytes1 constant GKVM_OK_TAG = 0x01;

/// @title GkVm
/// @notice Consumer-side binding for the gkvm precompile (UNBOUNDED_V3 native guest execution)
/// @dev Wire format (raw bytes, precompile convention — no function selector):
///        input  = programHash (32) || artifactRoot (32, zero = no artifact) || abi.encode(args...)
///        output = GKVM_OK_TAG || abi.encode(rets...)   on success
///      See src/examples/onchain-llm/UNBOUNDED_V3_NATIVE.md (§ The precompile).
library GkVm {
    /// @notice Runs a guest program through the gkvm precompile
    /// @dev Always a STATICCALL: the precompile reverts `GkVmStaticOnly` otherwise. Typed guest errors
    ///      (see GkVmErrors.sol) bubble up unchanged. Reverts `GkVmUnavailable` when nothing answers
    ///      at `gkvm` — which is every real chain, so executing a V3 tracked function on-chain
    ///      deterministically reverts.
    /// @param gkvm Precompile address; production deployments pass `GKVM_ADDRESS`
    /// @param programHash keccak256 of the guest ELF bytes
    /// @param artifactRoot Paged Merkle root of the artifact bundle, zero for no artifact
    /// @param payload ABI-encoded guest arguments
    /// @return out ABI-encoded guest return values, OK-tag stripped
    function exec(address gkvm, bytes32 programHash, bytes32 artifactRoot, bytes memory payload)
        internal
        view
        returns (bytes memory out)
    {
        (bool ok, bytes memory ret) = gkvm.staticcall(abi.encodePacked(programHash, artifactRoot, payload));
        if (!ok) _bubble(ret);
        if (ret.length == 0 || ret[0] != GKVM_OK_TAG) revert GkVmUnavailable();
        return _stripTag(ret);
    }

    /// @notice Re-raises a failed call's returndata as this frame's revert data
    function _bubble(bytes memory ret) private pure {
        assembly {
            revert(add(ret, 0x20), mload(ret))
        }
    }

    /// @notice Drops the leading OK-tag byte in place
    /// @dev Re-seats the length word one byte forward, over the tag; `ret` must not be used afterwards
    function _stripTag(bytes memory ret) private pure returns (bytes memory out) {
        assembly {
            out := add(ret, 1)
            mstore(out, sub(mload(ret), 1))
        }
    }
}
