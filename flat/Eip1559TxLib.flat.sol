// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

// src/Eip1559TxLib.sol

/// @title Eip1559TxLib
/// @notice Reconstructs the signing hash of an EIP-1559 (type 0x02) Ethereum transaction from its
///         semantic fields and recovers the sender from the signature — entirely on-chain.
/// @dev This is what makes Gas Killer's `msg.sender` attribution trustless. The Gas Killer RPC
///      ingress accepts a user's ordinary signed transaction and turns it into an off-chain
///      compute task; operators attest to the resulting storage diff. Without this library the
///      chain would have to *trust the operators* about who the sender was. With it, the settlement
///      contract independently reconstructs the exact preimage the user's wallet signed and runs
///      `ecrecover`, so the sender is bound to the executed call cryptographically, not by
///      attestation.
///
///      Scope: EIP-1559 transactions with an **empty access list** only — the shape every wallet
///      produces when pointed at an RPC (MetaMask, viem, ethers, `cast`). A transaction that
///      carried an access list, or a legacy/2930/blob/set-code type, simply recovers a different
///      address here and fails the caller's signer check; it can never be silently mis-attributed.
///      Legacy and 2930 support can be added as sibling functions later.
///
///      The signing hash for a type-2 transaction is:
///
///          keccak256( 0x02 ‖ rlp([ chainId, nonce, maxPriorityFeePerGas, maxFeePerGas,
///                                  gasLimit, to, value, data, accessList ]) )
///
///      with `accessList` the empty list (RLP `0xc0`). `ecrecover` then uses `v = 27 + yParity`.
library Eip1559TxLib {
    /// @notice Recovers the signer of an EIP-1559 transaction with an empty access list.
    /// @param chainId The EIP-155 chain id the transaction was signed for
    /// @param nonce The sender's transaction nonce
    /// @param maxPriorityFeePerGas The type-2 priority fee
    /// @param maxFeePerGas The type-2 max fee
    /// @param gasLimit The gas limit
    /// @param to The transaction target (`address(this)` for a Gas Killer task)
    /// @param value The wei value
    /// @param data The transaction calldata
    /// @param yParity The signature's y-parity (0 or 1)
    /// @param r The signature `r`
    /// @param s The signature `s`
    /// @return signer The recovered address (`address(0)` if recovery fails)
    /// @return sigHash The reconstructed signing hash
    function recoverSigner(
        uint256 chainId,
        uint256 nonce,
        uint256 maxPriorityFeePerGas,
        uint256 maxFeePerGas,
        uint256 gasLimit,
        address to,
        uint256 value,
        bytes memory data,
        uint8 yParity,
        bytes32 r,
        bytes32 s
    ) internal pure returns (address signer, bytes32 sigHash) {
        sigHash = sigHashOf(chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data);
        // yParity is 0/1 for typed transactions; ecrecover wants 27/28.
        signer = ecrecover(sigHash, 27 + yParity, r, s);
    }

    /// @notice Computes the EIP-1559 (empty access list) signing hash for the given fields.
    function sigHashOf(
        uint256 chainId,
        uint256 nonce,
        uint256 maxPriorityFeePerGas,
        uint256 maxFeePerGas,
        uint256 gasLimit,
        address to,
        uint256 value,
        bytes memory data
    ) internal pure returns (bytes32) {
        // The RLP list payload: nine items, the last being the empty access list (0xc0).
        bytes memory payload = abi.encodePacked(
            _rlpUint(chainId),
            _rlpUint(nonce),
            _rlpUint(maxPriorityFeePerGas),
            _rlpUint(maxFeePerGas),
            _rlpUint(gasLimit),
            _rlpAddress(to),
            _rlpUint(value),
            _rlpBytes(data),
            bytes1(0xc0) // empty access list
        );
        // 0x02 transaction-type envelope prepended to the RLP-encoded list.
        return keccak256(abi.encodePacked(bytes1(0x02), _rlpList(payload)));
    }

    // -- minimal RLP encoders --------------------------------------------------------------------

    /// @notice RLP-encodes a scalar as a canonical big-endian byte string (no leading zeros).
    /// @dev `0` encodes as the empty string `0x80`; a single byte in `[0x00, 0x7f]` encodes as
    ///      itself; otherwise a `0x80 + length` prefix precedes the trimmed bytes. A uint256 is at
    ///      most 32 bytes, so the string-length branch (< 56 bytes) always applies.
    function _rlpUint(uint256 value) private pure returns (bytes memory) {
        if (value == 0) {
            return hex"80";
        }
        bytes memory trimmed = _trim(value);
        if (trimmed.length == 1 && uint8(trimmed[0]) < 0x80) {
            return trimmed;
        }
        return abi.encodePacked(bytes1(uint8(0x80 + trimmed.length)), trimmed);
    }

    /// @notice RLP-encodes a 20-byte address as a fixed-length string (`0x94 ‖ address`).
    /// @dev An address is a 20-byte string; the RLP prefix for a 20-byte (< 56) string is
    ///      `0x80 + 20 = 0x94`. Addresses are never zero-trimmed — the zero address is 20 zero
    ///      bytes, matching how transaction encoders treat the `to` field.
    function _rlpAddress(address value) private pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0x94), bytes20(value));
    }

    /// @notice RLP-encodes an arbitrary byte string (the transaction `data`).
    function _rlpBytes(bytes memory value) private pure returns (bytes memory) {
        uint256 len = value.length;
        if (len == 1 && uint8(value[0]) < 0x80) {
            return value;
        }
        return abi.encodePacked(_rlpLengthPrefix(0x80, 0xb7, len), value);
    }

    /// @notice Wraps an already-encoded RLP payload in a list header.
    function _rlpList(bytes memory payload) private pure returns (bytes memory) {
        return abi.encodePacked(_rlpLengthPrefix(0xc0, 0xf7, payload.length), payload);
    }

    /// @notice Builds an RLP length prefix for a string (`shortBase` 0x80 / `longBase` 0xb7) or a
    ///         list (`0xc0` / `0xf7`). Short form for lengths < 56, long form otherwise.
    function _rlpLengthPrefix(uint8 shortBase, uint8 longBase, uint256 len) private pure returns (bytes memory) {
        if (len < 56) {
            return abi.encodePacked(bytes1(uint8(shortBase + len)));
        }
        bytes memory lenBytes = _trim(len);
        return abi.encodePacked(bytes1(uint8(longBase + lenBytes.length)), lenBytes);
    }

    /// @notice Returns the minimal big-endian byte representation of `value` (no leading zeros).
    /// @dev `value` is assumed non-zero; callers handle zero separately.
    function _trim(uint256 value) private pure returns (bytes memory) {
        uint256 length = 0;
        uint256 temp = value;
        while (temp != 0) {
            length++;
            temp >>= 8;
        }
        bytes memory out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[length - 1 - i] = bytes1(uint8(value >> (8 * i)));
        }
        return out;
    }
}
