// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

/// @title IGasKillerForwardee
/// @notice Interface for GasKiller contracts that accept storage updates forwarded by a
///         trusted peer as part of a multi-call bundle
/// @dev In multi-call mode, a forwarder embeds the callee's sub-payload as an ordinary
///      CALL update inside its own quorum-signed `storageUpdates` blob. The bundle root's
///      ECDSA quorum signature therefore transitively commits to every forwarded byte,
///      including the callee's expected transition index. The callee authorizes the
///      delivery via a per-contract trusted-forwarder allowlist.
///
///      This is intentionally a separate interface from `IGasKillerSDK` so that
///      multi-call-capable contracts remain distinguishable on-chain from older
///      deployments via ERC-165.
interface IGasKillerForwardee {
    /// @notice Thrown when `applyForwardedUpdates` is called by an address that is not an
    ///         allowlisted forwarder
    /// @param caller The unauthorized caller
    error UntrustedForwarder(address caller);

    /// @notice Thrown when a forwarded STORE operation targets a reserved slot
    ///         (the state-transition counter or the SDK configuration slots)
    /// @param index The zero-based position of the offending operation in the batch
    /// @param slot The reserved storage slot that was targeted
    error ReservedSlot(uint256 index, bytes32 slot);

    /// @notice Emitted after a forwarded update batch has been applied
    /// @param forwarder The trusted forwarder that delivered the updates
    /// @param transitionIndex The transition index the batch was applied at
    event ForwardedUpdatesApplied(address indexed forwarder, uint256 indexed transitionIndex);

    /// @notice Apply storage updates forwarded by a trusted GasKiller peer
    /// @dev Payable so a forwarding CALL update can carry the ETH the original call
    ///      transferred. Reverts unless `msg.sender` is an allowlisted forwarder and
    ///      `expectedTransitionIndex` matches this contract's pre-call transition count.
    /// @param storageUpdates ABI-encoded `(StateUpdateType[], bytes[])` pair
    /// @param expectedTransitionIndex The transition count this contract must have had
    ///        immediately before this call
    function applyForwardedUpdates(bytes calldata storageUpdates, uint256 expectedTransitionIndex) external payable;

    /// @notice Query whether an address is an allowlisted forwarder
    /// @param forwarder The address to query
    /// @return `true` if `forwarder` may call `applyForwardedUpdates`
    function isTrustedForwarder(address forwarder) external view returns (bool);
}
