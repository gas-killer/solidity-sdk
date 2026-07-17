// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

/// @title DataContractLib
/// @notice Minimal from-scratch "data contract" helpers: store immutable byte blobs as
///         contract runtime code (up to 24,575 payload bytes each under EIP-170) and read
///         them back with EXTCODECOPY.
/// @dev The deployed runtime is `0x00 || payload`. The leading STOP byte guarantees the
///      blob can never be executed as meaningful code. Reads skip that first byte.
///      Under Gas Killer's unbounded simulation mode, EXTCODECOPY reads never enter the
///      extracted state-update payload, so weights stored this way are free to consume
///      off-chain while remaining part of verifiable chain state.
library DataContractLib {
    /// @notice Maximum payload per data contract: EIP-170 (24,576) minus the STOP prefix
    uint256 internal constant MAX_PAYLOAD = 24_575;

    /// @notice Thrown when a payload exceeds MAX_PAYLOAD
    error PayloadTooLarge();

    /// @notice Thrown when CREATE fails (e.g. out of gas or nonce issues)
    error DeployFailed();

    /// @notice Deploy `payload` as the runtime code of a fresh data contract
    /// @param payload The bytes to persist (at most MAX_PAYLOAD)
    /// @return pointer The address of the deployed data contract
    function write(bytes memory payload) internal returns (address pointer) {
        if (payload.length > MAX_PAYLOAD) revert PayloadTooLarge();
        // Init code: PUSH2 len | DUP1 | PUSH1 0x0C | PUSH1 0x00 | CODECOPY | PUSH1 0x00 | RETURN
        // (12 bytes) followed by the runtime `0x00 || payload` at offset 0x0C.
        bytes memory initCode =
            abi.encodePacked(hex"61", uint16(payload.length + 1), hex"80600C6000396000F3", hex"00", payload);
        assembly ("memory-safe") {
            pointer := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (pointer == address(0)) revert DeployFailed();
    }

    /// @notice Payload length of a data contract (code size minus the STOP prefix)
    /// @param pointer The data contract address
    /// @return length The payload byte length
    function payloadLength(address pointer) internal view returns (uint256 length) {
        assembly ("memory-safe") {
            length := extcodesize(pointer)
        }
        if (length == 0) revert DeployFailed();
        unchecked {
            length -= 1;
        }
    }

    /// @notice Read the full payload of a data contract
    /// @param pointer The data contract address
    /// @return data The payload bytes
    function read(address pointer) internal view returns (bytes memory data) {
        uint256 length = payloadLength(pointer);
        data = new bytes(length);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(data, 0x20), 1, length)
        }
    }

    /// @notice Copy a data contract's payload into `dest` starting at byte `destOffset`
    /// @dev Reverts if the payload would overflow `dest`
    /// @param pointer The data contract address
    /// @param dest The destination buffer
    /// @param destOffset The byte offset within `dest` to copy to
    /// @return copied The number of payload bytes copied
    function readInto(address pointer, bytes memory dest, uint256 destOffset) internal view returns (uint256 copied) {
        copied = payloadLength(pointer);
        if (destOffset + copied > dest.length) revert PayloadTooLarge();
        assembly ("memory-safe") {
            extcodecopy(pointer, add(add(dest, 0x20), destOffset), 1, copied)
        }
    }
}
