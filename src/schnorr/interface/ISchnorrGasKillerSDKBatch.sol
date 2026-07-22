// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

/// @notice One independently quorum-signed state transition, as submitted to
///         `verifyAndUpdateBatch`. Field-for-field identical to the arguments of
///         `ISchnorrGasKillerSDK.verifyAndUpdate` — the signed digest is unchanged, so
///         batching is purely a submission-side optimization and the off-chain signing
///         path does not know or care whether a transition settles alone or in a batch.
struct SchnorrTaskSubmission {
    bytes32 msgHash;
    uint32 referenceBlockNumber;
    bytes storageUpdates;
    uint256 transitionIndex;
    bytes4 targetFunction;
    uint256 s;
    address Raddr;
    address[] nonSigners;
}

/// @title ISchnorrGasKillerSDKBatch
/// @notice Optional batching + in-transition-latch extension of `ISchnorrGasKillerSDK`.
/// @dev Kept separate from `ISchnorrGasKillerSDK` on purpose: that interface is
///      deliberately single-function so `type(ISchnorrGasKillerSDK).interfaceId` equals
///      the `verifyAndUpdate` selector, which the router's ERC-165 preflight probes.
///      Contracts supporting this extension report **both** interface IDs.
///
///      Batching amortizes the per-transaction fixed costs across N transitions: the
///      21,000 intrinsic, the cold-access warm-up of the registry account + its aggregate
///      key/weight/watermark slots, and the SDK's own config slots — everything after the
///      first sub-transition runs at warm-access prices (measured: the registry verify
///      alone drops from ~17.0k cold to ~6.5k warm at full participation).
///
///      Batch assemblers (the off-chain router composing `submissions`) should be aware
///      that `StateChangeHandlerLib`'s `CALL` update forwards *all* remaining gas to its
///      target with no cap. A greedy or griefing CALL target in an early sub-transition can
///      consume enough gas to starve every later sub-transition, reverting the whole
///      (atomic) batch — no partial-state hazard, since it's all-or-nothing, but it does
///      nullify the amortization this extension exists for. Ordering submissions with
///      untrusted CALL targets last, or excluding them from batches entirely, avoids this.
interface ISchnorrGasKillerSDKBatch {
    /// @notice Verify and apply a sequence of independently signed state transitions.
    /// @dev Transitions apply in calldata order with consecutive `transitionIndex`es.
    ///      Submissions whose index is already settled are skipped (front-run/redelivery
    ///      tolerance — settlement is permissionless, so without the skip one lifted
    ///      submission settled standalone would revert the whole batch); an index gap or
    ///      any failing applied sub-transition reverts the whole batch. The in-transition
    ///      latch is held across the entire batch.
    /// @param submissions The transitions to apply, in order.
    function verifyAndUpdateBatch(SchnorrTaskSubmission[] calldata submissions) external;

    /// @notice True while a state transition (or batch) is being applied — external
    ///         readers should treat mid-transition state as unsigned and fail closed.
    function inTransition() external view returns (bool);
}
