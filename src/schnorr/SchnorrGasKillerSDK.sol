// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IERC165} from "forge-std/interfaces/IERC165.sol";
import {ISchnorrGasKillerSDK} from "./interface/ISchnorrGasKillerSDK.sol";
import {ISchnorrGasKillerSDKBatch, SchnorrTaskSubmission} from "./interface/ISchnorrGasKillerSDKBatch.sol";
import {StateTracker} from "../StateTracker.sol";
import {TransitionGuard} from "../TransitionGuard.sol";
import {StateChangeHandlerLib, StateUpdateType} from "../StateChangeHandlerLib.sol";
import {ISchnorrStakeRegistry} from "./interface/ISchnorrStakeRegistry.sol";

/// @title SchnorrGasKillerSDK
/// @notice Aggregate-Schnorr variant of `GasKillerSDK`. Identical task-hash and
///         state-update semantics; the only change is `_verifyQuorum`, which authorises a
///         state transition with a **single** aggregate Schnorr signature verified against
///         a `SchnorrStakeRegistry` (constant gas, non-signer subtraction) instead of `N`
///         per-operator ECDSA signatures verified against `ECDSAStakeRegistry`.
///
/// @dev The signed message is unchanged — `sha256(abi.encode(transitionIndex,
///      address(this), targetFunction, storageUpdates))` — so the off-chain digest and the
///      slashing/fraud-proof machinery are scheme-agnostic. The calldata swaps
///      `(operators[], signatures[])` for `(s, Raddr, nonSigners[])`.
///
///      Both entrypoints are `guardTransition`-protected (see `TransitionGuard`): a `CALL`
///      state update runs arbitrary external code mid-transition, so re-entering
///      `verifyAndUpdate` with the *next* transition's valid signature would otherwise
///      interleave two signed transitions. The same transient flag is queryable as
///      `inTransition()` so external readers can reject mid-transition state.
///
///      Both entrypoints are also `payable`, so a caller can fund value-bearing state
///      updates out of `msg.value` — see the per-function docs for the funding rules, which
///      mirror the BLS `GasKillerSDK.verifyAndUpdate`.
abstract contract SchnorrGasKillerSDK is
    StateTracker,
    TransitionGuard,
    ISchnorrGasKillerSDK,
    ISchnorrGasKillerSDKBatch
{
    struct SchnorrSDKStorage {
        address avsAddress;
        ISchnorrStakeRegistry registry;
        uint96 blockStaleMeasure;
    }

    // keccak256(abi.encode(uint256(keccak256("gaskiller.SchnorrGasKillerSDK.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION = 0x1d6f9f139320a34a32f3b29eb8638270178e831962a74100c9e8b433f21e1200;

    uint256 private constant DEFAULT_BLOCK_STALE_MEASURE = 300;

    error FutureBlockNumber();
    error StaleBlockNumber();
    error InvalidTransitionIndex();
    error InvalidSignature();
    error InvalidQuorumSignature();
    error EmptyBatch();
    error BlockStaleMeasureOverflow();

    /// @notice Verify an aggregate Schnorr quorum signature and apply the state updates.
    /// @dev Payable so a caller can fund value-bearing `CALL`/`CREATE`/`CREATE2` state updates
    ///      out of `msg.value`. The value each update moves is fixed inside the quorum-signed
    ///      `storageUpdates`, so `msg.value` only tops up this contract's balance — it cannot
    ///      redirect value anywhere the quorum did not sign. Under-funding reverts the whole
    ///      transition (`RevertingContext` for a CALL, `DeploymentFailed` for a CREATE/CREATE2).
    ///      Over-funding is NOT refunded: whatever the updates do not consume simply stays in
    ///      this contract. Inheriting contracts whose callers may over-send must provide their
    ///      own recovery path (e.g. a withdrawal function, or a refund executed as a signed
    ///      CALL update in a later transition).
    /// @param msgHash             the task digest (recomputed and checked below).
    /// @param referenceBlockNumber block at which stake/keys are evaluated by the registry.
    /// @param storageUpdates      ABI-encoded `(StateUpdateType[], bytes[])`.
    /// @param transitionIndex     expected `stateTransitionCount() - 1`.
    /// @param targetFunction      selector bound into the digest.
    /// @param s                   aggregate Schnorr response scalar.
    /// @param Raddr               aggregate nonce address `address(R)`.
    /// @param nonSigners          operators that did not sign, strictly ascending.
    function verifyAndUpdate(
        bytes32 msgHash,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes4 targetFunction,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners
    ) external payable guardTransition {
        _verifyAndUpdateOne(
            msgHash, referenceBlockNumber, storageUpdates, transitionIndex, targetFunction, s, Raddr, nonSigners
        );
    }

    /// @notice Verify and apply a sequence of independently signed state transitions in
    ///         one transaction, amortizing the intrinsic and cold-access costs across the
    ///         batch (sub-transitions after the first verify at warm-access prices).
    /// @dev Each applied submission is checked exactly as a standalone `verifyAndUpdate`
    ///      would check it — same digest, same registry verification — so batching changes
    ///      nothing for the off-chain signing path. Transitions apply in order; the
    ///      `guardTransition` latch is held across the whole batch, and any failing
    ///      sub-transition reverts the entire batch.
    ///
    ///      A submission whose `transitionIndex` is already settled is SKIPPED (not
    ///      validated, not applied) rather than reverting the batch: settlement is
    ///      permissionless, so a third party who lifts one submission from the mempool
    ///      and settles it standalone could otherwise nullify the whole batch with one
    ///      cheap front-run. An index can only ever be consumed by a quorum-signed
    ///      transition for this contract, so a skipped item's transition has already
    ///      happened. Reverts (`InvalidTransitionIndex`) only on a genuine gap — an index
    ///      above the next expected one.
    ///
    ///      Batch assemblers: a `CALL` state update forwards all remaining gas to its target
    ///      with no cap (see `StateChangeHandlerLib`). A greedy/griefing target in an early
    ///      sub-transition can therefore starve every later one in the same batch, reverting
    ///      the whole (atomic) batch — no partial-state hazard, but it does nullify the
    ///      amortization this function exists for.
    ///
    ///      Payable on the same terms as `verifyAndUpdate`, with one batch-specific wrinkle:
    ///      `msg.value` tops up this contract's balance **once for the whole batch** and is
    ///      pooled across every applied sub-transition rather than partitioned per submission.
    ///      Assemblers must send the *sum* of what the applied submissions spend; since the
    ///      batch is atomic, a shortfall anywhere reverts all of it. A skipped (already-settled)
    ///      submission spends nothing, so a front-run leaves its share unspent — and, as with
    ///      the standalone entrypoint, unspent value is not refunded.
    /// @param submissions The transitions to apply, in order of ascending transition index.
    function verifyAndUpdateBatch(SchnorrTaskSubmission[] calldata submissions) external payable guardTransition {
        uint256 len = submissions.length;
        require(len != 0, EmptyBatch());
        for (uint256 i = 0; i < len; ++i) {
            SchnorrTaskSubmission calldata sub = submissions[i];
            // Already settled (e.g. front-run or redelivered) → skip, don't poison the batch.
            if (sub.transitionIndex + 1 <= stateTransitionCount()) continue;
            _verifyAndUpdateOne(
                sub.msgHash,
                sub.referenceBlockNumber,
                sub.storageUpdates,
                sub.transitionIndex,
                sub.targetFunction,
                sub.s,
                sub.Raddr,
                sub.nonSigners
            );
        }
    }

    /// @dev The single-transition settlement path shared by both entrypoints. Callers must
    ///      hold the `guardTransition` latch.
    function _verifyAndUpdateOne(
        bytes32 msgHash,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes4 targetFunction,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners
    ) private trackState {
        require(referenceBlockNumber < block.number, FutureBlockNumber());
        require((uint256(referenceBlockNumber) + _getBlockStaleMeasure()) >= block.number, StaleBlockNumber());

        require(transitionIndex + 1 == stateTransitionCount(), InvalidTransitionIndex());
        bytes32 expectedHash = sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates));
        require(expectedHash == msgHash, InvalidSignature());

        _verifyQuorum(msgHash, s, Raddr, nonSigners, referenceBlockNumber);

        _stateChangeHandler(storageUpdates);
    }

    function _verifyQuorum(
        bytes32 msgHash,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners,
        uint32 referenceBlockNumber
    ) private view {
        bool ok = _sto().registry.isValidSignature(msgHash, s, Raddr, nonSigners, referenceBlockNumber);
        require(ok, InvalidQuorumSignature());
    }

    function _stateChangeHandler(bytes calldata storageUpdates) internal {
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        StateChangeHandlerLib._runStateUpdates(types, args);
    }

    /// @notice Query if a contract implements an interface
    /// @dev Supports ERC-165, ISchnorrGasKillerSDK detection (the router's preflight
    ///      probes the schnorr `verifyAndUpdate` selector before submitting), and the
    ///      ISchnorrGasKillerSDKBatch batching/latch extension
    /// @param interfaceId The interface identifier, as specified in ERC-165
    /// @return `true` if the contract implements `interfaceId` and `false` otherwise
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(ISchnorrGasKillerSDK).interfaceId
            || interfaceId == type(ISchnorrGasKillerSDKBatch).interfaceId;
    }

    /// @notice Compute the expected message hash for a given transition, function, and storage updates
    /// @dev Exact mirror of the ECDSA `GasKillerSDK.getMessageHash` — the digest is
    ///      scheme-agnostic, so off-chain parity checks work unchanged.
    /// @param transitionIndex The transition index
    /// @param targetFunction The target function selector
    /// @param storageUpdates The ABI-encoded storage updates
    /// @return The expected SHA-256 hash
    function getMessageHash(uint256 transitionIndex, bytes4 targetFunction, bytes calldata storageUpdates)
        external
        view
        returns (bytes32)
    {
        return sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates));
    }

    /// @inheritdoc TransitionGuard
    function inTransition() public view override(TransitionGuard, ISchnorrGasKillerSDKBatch) returns (bool locked) {
        return TransitionGuard.inTransition();
    }

    function schnorrRegistry() external view returns (address) {
        return address(_sto().registry);
    }

    function avsAddress() external view returns (address) {
        return _sto().avsAddress;
    }

    function blockStaleMeasure() external view returns (uint256) {
        return _getBlockStaleMeasure();
    }

    function _setAvsAddress(address _avsAddress) internal {
        _sto().avsAddress = _avsAddress;
    }

    function _setSchnorrRegistry(address _registry) internal {
        _sto().registry = ISchnorrStakeRegistry(_registry);
    }

    function _setBlockStaleMeasure(uint256 _blockStaleMeasure) internal {
        require(_blockStaleMeasure <= type(uint96).max, BlockStaleMeasureOverflow());
        _sto().blockStaleMeasure = uint96(_blockStaleMeasure);
    }

    function _getBlockStaleMeasure() internal view returns (uint256) {
        uint256 v = _sto().blockStaleMeasure;
        return v == 0 ? DEFAULT_BLOCK_STALE_MEASURE : v;
    }

    function _sto() private pure returns (SchnorrSDKStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}
