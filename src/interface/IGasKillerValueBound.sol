// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

/// @title IGasKillerValueBound
/// @notice Reported by consumers whose settlement digest binds `msg.value`.
/// @dev `type(IGasKillerSDK).interfaceId` didn't move when the digest started binding the value,
///      so this ID is what tells such a consumer apart from one built on an older SDK, which
///      accepts a value-bearing signature with any `msg.value`. Single-function, so the ID is the
///      `getMessageHashWithValue` selector. The `IGasKillerSDK` ID did move later, when
///      `verifyAndUpdate` stopped taking the digest, and every consumer that reports the new ID
///      binds the value and reports this one too.
interface IGasKillerValueBound {
    /// @notice The digest the quorum signs for a transition settled with `value` wei.
    function getMessageHashWithValue(
        uint256 transitionIndex,
        bytes4 targetFunction,
        bytes calldata storageUpdates,
        uint256 value
    ) external view returns (bytes32);
}
