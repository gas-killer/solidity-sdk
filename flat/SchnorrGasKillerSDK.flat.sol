// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.6.2 ^0.8.0 ^0.8.27;

// src/CommitmentDigestLib.sol

/// @title CommitmentDigestLib
/// @notice The Gas Killer commitment digest: the exact bytes operators sign to authorize a state
///         transition.
/// @dev One definition, four consumers that must agree byte-for-byte:
///      - `GasKillerSDK` and `SchnorrGasKillerSDK` reconstruct it to admit a settlement,
///      - `GasKillerSlasherBase` reconstructs it to identify the commitment being challenged,
///      - the off-chain operator signer in `gas-killer/service` builds the same preimage in Rust.
///
///      Disagreement is silent and total in either direction: a settlement whose digest the
///      slasher cannot reproduce is unslashable, and operators signing a digest the SDK does not
///      reconstruct can never reach quorum. The Rust side is pinned by a golden vector and by the
///      e2e parity check against `getMessageHash`; the three on-chain sites are pinned here, by
///      construction, and cross-checked in `GasKillerSlashingParity.t.sol`.
///
///      `target` is passed explicitly rather than read as `address(this)` because the slasher
///      computes digests on behalf of the contract that settled them, not itself.
library CommitmentDigestLib {
    /// @notice Compute the commitment digest for one state transition
    /// @param target The Gas Killer contract the transition applies to
    /// @param transitionIndex The transition index
    /// @param anchorHash The hash of the block the off-chain execution was anchored to
    /// @param callerAddress The msg.sender of the original call
    /// @param contractCalldata The full calldata of the original call
    /// @param storageUpdates The ABI-encoded storage updates
    /// @return The SHA-256 digest operators sign
    function commitmentHash(
        address target,
        uint256 transitionIndex,
        bytes32 anchorHash,
        address callerAddress,
        bytes calldata contractCalldata,
        bytes calldata storageUpdates
    ) internal pure returns (bytes32) {
        return sha256(abi.encode(transitionIndex, target, anchorHash, callerAddress, contractCalldata, storageUpdates));
    }
}

// lib/forge-std/src/interfaces/IERC165.sol

interface IERC165 {
    /// @notice Query if a contract implements an interface
    /// @param interfaceID The interface identifier, as specified in ERC-165
    /// @dev Interface identification is specified in ERC-165. This function
    /// uses less than 30,000 gas.
    /// @return `true` if the contract implements `interfaceID` and
    /// `interfaceID` is not 0xffffffff, `false` otherwise
    function supportsInterface(bytes4 interfaceID) external view returns (bool);
}

// src/interface/IGasKillerSlasher.sol

/// @title IGasKillerSlasher
/// @notice Scheme-agnostic interface for the Gas Killer slashing contracts
/// @dev Enables fraud detection and slashing of malicious operators via SP1 zkVM proofs. The
///      commitment structs, events, errors and challenge-window/chain-config surface are shared
///      across signature schemes; the scheme-specific `slash` entrypoint (which carries the
///      aggregate signature material) lives in a per-scheme interface such as `IGasKillerBLSSlasher`.
interface IGasKillerSlasher {
    // ============ Structs ============

    /// @notice A commitment signed by the aggregate network
    /// @dev `sha256(abi.encode(transitionIndex, contractAddress, anchorHash, callerAddress,
    ///      contractCalldata, storageUpdates))` is the message hash operators sign and the
    ///      hash `GasKillerSDK.verifyAndUpdate` verifies
    /// @param transitionIndex Sequential counter for state transitions
    /// @param contractAddress The target contract address
    /// @param anchorHash Hash of the block the execution is anchored to
    /// @param callerAddress The caller address (msg.sender for the original call)
    /// @param contractCalldata Full calldata with arguments
    /// @param storageUpdates Claimed storage changes, encoded as `abi.encode(StateUpdateType[], bytes[])`
    struct SignedCommitment {
        uint256 transitionIndex;
        address contractAddress;
        bytes32 anchorHash;
        address callerAddress;
        bytes contractCalldata;
        bytes storageUpdates;
    }

    /// @notice Public values committed by the Gas Killer challenger SP1 program
    /// @param id Anchor id (block number for BlockHash anchors)
    /// @param anchorHash Hash of the block the execution was anchored to
    /// @param anchorType Type of anchor (0 = BlockHash, 1 = Timestamp, 2 = Slot)
    /// @param chainConfigHash Hash of the chain configuration (chain id + active hardfork)
    /// @param callerAddress The caller address used in the proven execution
    /// @param contractAddress The contract address used in the proven execution
    /// @param contractCalldata The calldata used in the proven execution
    /// @param contractOutput The return data of the proven execution
    /// @param storageUpdates The storage updates produced by the proven execution, encoded
    ///        exactly as an honest operator would sign them
    /// @param opcodeHash keccak256 of the state-modifying opcodes executed
    struct GasKillerPublicValues {
        uint256 id;
        bytes32 anchorHash;
        uint8 anchorType;
        bytes32 chainConfigHash;
        address callerAddress;
        address contractAddress;
        bytes contractCalldata;
        bytes contractOutput;
        bytes storageUpdates;
        bytes32 opcodeHash;
    }

    // ============ Events ============

    /// @notice Emitted when slashing is executed
    /// @param commitmentHash Hash of the slashed commitment
    /// @param challenger Address of the challenger who submitted the proof
    /// @param slashedOperators Operators who were slashed
    /// @param slashAmount Slash proportion per strategy, in WAD (1e18 = 100%)
    event SlashingExecuted(
        bytes32 indexed commitmentHash, address indexed challenger, address[] slashedOperators, uint256 slashAmount
    );

    /// @notice Emitted when a commitment is recorded for challenge-window tracking
    /// @param targetContract The Gas Killer contract the commitment was applied to
    /// @param commitmentHash Hash of the commitment
    event CommitmentRecorded(address indexed targetContract, bytes32 indexed commitmentHash);

    /// @notice Emitted when a chain config hash is accepted or revoked
    /// @param chainConfigHash The chain config hash (chain id + active hardfork)
    /// @param accepted Whether proofs carrying this hash are accepted
    event ChainConfigHashSet(bytes32 indexed chainConfigHash, bool accepted);

    // ============ Errors ============

    /// @notice Thrown when the SP1 proof is invalid
    error InvalidProof();

    /// @notice Thrown when the anchor block hash cannot be verified
    error UnverifiedBlock();

    /// @notice Thrown when the proof's public values do not match the commitment inputs
    error InputMismatch();

    /// @notice Thrown when the proven execution used an unexpected chain configuration
    error InvalidChainConfig();

    /// @notice Thrown when the proven storage updates equal the signed ones (no fraud)
    error NoFraudDetected();

    /// @notice Thrown when the challenge window has expired
    error ChallengeExpired();

    /// @notice Thrown when the commitment has already been slashed
    error AlreadySlashed();

    /// @notice Thrown when the aggregate signature does not meet the quorum threshold
    error InsufficientQuorumThreshold();

    // ============ External Functions ============

    /// @notice Accept or revoke a chain config hash for challenger proofs
    /// @dev Owner-only. The challenger program commits `keccak256(chainId ++ activeForkName)`,
    ///      which changes at every network hardfork; the owner accepts the new fork's hash so
    ///      post-fork commitments stay challengeable.
    /// @param chainConfigHash The chain config hash to accept or revoke
    /// @param accepted Whether proofs carrying this hash should be accepted
    function setChainConfigHashAccepted(bytes32 chainConfigHash, bool accepted) external;

    /// @notice Whether proofs carrying `chainConfigHash` are accepted
    /// @param chainConfigHash The chain config hash (chain id + active hardfork)
    /// @return True if accepted
    function acceptedChainConfigHash(bytes32 chainConfigHash) external view returns (bool);

    /// @notice Record a commitment application for challenge-window tracking
    /// @dev Called by the Gas Killer contract itself during `verifyAndUpdate`; records are
    ///      keyed by `msg.sender` so third parties cannot start (or exhaust) the window
    ///      for a contract they do not control
    /// @param commitmentHash The commitment hash (the verified message hash)
    function recordCommitment(bytes32 commitmentHash) external;

    /// @notice Check if a commitment has been slashed
    /// @param commitmentHash The hash of the commitment
    /// @return True if the commitment has been slashed
    function isSlashed(bytes32 commitmentHash) external view returns (bool);

    /// @notice Get the timestamp a commitment was recorded at (0 if never recorded)
    /// @param targetContract The Gas Killer contract the commitment was applied to
    /// @param commitmentHash The commitment hash
    /// @return The recording timestamp
    function getCommitmentTimestamp(address targetContract, bytes32 commitmentHash) external view returns (uint256);

    /// @notice Get the challenge window duration
    /// @return The challenge window in seconds
    function challengeWindow() external view returns (uint256);

    /// @notice Get the SP1 program verification key of the challenger program
    /// @return The verification key
    function programVKey() external view returns (bytes32);

    /// @notice Compute the commitment hash operators sign
    /// @param commitment The signed commitment
    /// @return The sha256 hash of the commitment
    function computeCommitmentHash(SignedCommitment calldata commitment) external pure returns (bytes32);
}

// src/schnorr/interface/ISchnorrGasKillerSDKBatch.sol

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
    bytes32 anchorHash;
    address callerAddress;
    bytes contractCalldata;
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
    ///
    ///      Payable, on the same terms as `ISchnorrGasKillerSDK.verifyAndUpdate`, with one
    ///      batch-specific wrinkle: `msg.value` tops up the contract's balance **once for the
    ///      whole batch** and is pooled across every applied sub-transition rather than
    ///      partitioned per submission. Batch assemblers must therefore send the *sum* of
    ///      what the applied submissions spend; the batch is atomic, so a shortfall anywhere
    ///      reverts all of it. A skipped (already-settled) submission spends nothing, so a
    ///      front-run leaves its share unspent — and unspent value is not refunded.
    /// @param submissions The transitions to apply, in order.
    function verifyAndUpdateBatch(SchnorrTaskSubmission[] calldata submissions) external payable;

    /// @notice True while a state transition (or batch) is being applied — external
    ///         readers should treat mid-transition state as unsigned and fail closed.
    function inTransition() external view returns (bool);
}

// src/schnorr/interface/ISchnorrStakeRegistry.sol

/// @title ISchnorrStakeRegistry
/// @notice Verification surface the `SchnorrGasKillerSDK` depends on. Kept minimal (and
///         separate from the concrete registry) so the SDK can be unit-tested against a
///         mock, mirroring how `GasKillerSDK` depends on ERC-1271 `isValidSignature`.
interface ISchnorrStakeRegistry {
    /// @notice Verify an aggregate Schnorr quorum signature over `message`.
    /// @param message     the signed 32-byte task digest.
    /// @param s           aggregate response scalar.
    /// @param Raddr       aggregate nonce address `address(R)`.
    /// @param nonSigners  operator identities that did not sign, strictly ascending.
    /// @param refBlock    reference block; must be `>= effectiveBlock` and `< block.number`.
    function isValidSignature(
        bytes32 message,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners,
        uint256 refBlock
    ) external view returns (bool);
}

// src/StateChangeHandlerLib.sol

/// @notice Discriminator enum for the type of state update operation to execute
/// @dev Each variant maps to a different EVM operation: storage writes, external calls, log emissions, or contract deployment
enum StateUpdateType {
    /// @notice Write a 32-byte value directly to a storage slot
    STORE,
    /// @notice Execute an external call with optional ETH value transfer
    CALL,
    /// @notice Emit a log with no indexed topics
    LOG0,
    /// @notice Emit a log with one indexed topic
    LOG1,
    /// @notice Emit a log with two indexed topics
    LOG2,
    /// @notice Emit a log with three indexed topics
    LOG3,
    /// @notice Emit a log with four indexed topics
    LOG4,
    /// @notice Deploy a contract using CREATE (nonce-derived address)
    CREATE,
    /// @notice Deploy a contract using CREATE2 (salt-derived deterministic address)
    CREATE2
}

/// @title StateChangeHandlerLib
/// @notice Library for decoding and executing batched state update operations
/// @dev Processes ABI-encoded arrays of typed state updates; supports STORE, CALL, LOG0-LOG4, CREATE, and CREATE2
library StateChangeHandlerLib {
    /// @notice Decodes and executes a series of state updates
    /// @dev This function processes an array of state updates, executing them in sequence. Each update can be one of:
    ///      - STORE: Direct storage writes using assembly
    ///      - CALL: External contract calls with value transfer
    ///      - LOG0-LOG4: Event emission with 0-4 indexed topics
    ///      - CREATE: Contract deployment via CREATE opcode
    ///      - CREATE2: Deterministic contract deployment via CREATE2 opcode
    /// @param types Array of StateUpdateType enums indicating the type of each state update operation
    /// @param args Array of ABI-encoded arguments corresponding to each operation type
    /// @dev types and args arrays must be equal length, with args[i] containing the encoded parameters for types[i]
    function _runStateUpdates(StateUpdateType[] memory types, bytes[] memory args) internal {
        uint256 length = types.length;
        require(length == args.length, InvalidArguments());
        for (uint256 i = 0; i < length; ++i) {
            StateUpdateType stateUpdateType = types[i];
            bytes memory arg = args[i];

            if (stateUpdateType == StateUpdateType.STORE) {
                (bytes32 slot, bytes32 value) = abi.decode(arg, (bytes32, bytes32));
                assembly {
                    sstore(slot, value)
                }
            } else if (stateUpdateType == StateUpdateType.CALL) {
                // Forwards all remaining gas (no stipend cap). In a batched settlement
                // (e.g. SchnorrGasKillerSDK.verifyAndUpdateBatch) this is amplified: a
                // greedy or griefing target in an earlier sub-transition's CALL can consume
                // enough gas to starve every later sub-transition in the same batch,
                // reverting the whole (atomic) batch. No partial-state hazard — it's all or
                // nothing — but it does nullify the batch's cost amortization. See
                // ISchnorrGasKillerSDKBatch for the batch-assembly-side note.
                (address target, uint256 value, bytes memory callargs) = abi.decode(arg, (address, uint256, bytes));
                bool success;
                assembly {
                    success := call(gas(), target, value, add(callargs, 0x20), mload(callargs), 0, 0)
                }
                // TODO: this section needs heavy testing
                if (!success) {
                    uint256 _returndatasize;
                    assembly {
                        _returndatasize := returndatasize()
                    }
                    bytes memory revertData = new bytes(_returndatasize);
                    assembly {
                        returndatacopy(add(revertData, 0x20), 0, _returndatasize)
                    }
                    revert RevertingContext(i, target, revertData, callargs);
                }
            } else if (stateUpdateType == StateUpdateType.LOG0) {
                // `_validateLogArg` checks that `arg` is a canonical, in-bounds encoding before this reads
                // directly out of its buffer. The `data` length word sits at `base + canonicalOffset`, and
                // any topics sit inline in the head at `base + 0x20*k`.
                _validateLogArg(arg, 0x20);
                assembly {
                    let dataPtr := add(add(arg, 0x20), 0x20)
                    log0(add(dataPtr, 0x20), mload(dataPtr))
                }
            } else if (stateUpdateType == StateUpdateType.LOG1) {
                _validateLogArg(arg, 0x40);
                assembly {
                    let base := add(arg, 0x20)
                    let dataPtr := add(base, 0x40)
                    log1(add(dataPtr, 0x20), mload(dataPtr), mload(add(base, 0x20)))
                }
            } else if (stateUpdateType == StateUpdateType.LOG2) {
                _validateLogArg(arg, 0x60);
                assembly {
                    let base := add(arg, 0x20)
                    let dataPtr := add(base, 0x60)
                    log2(add(dataPtr, 0x20), mload(dataPtr), mload(add(base, 0x20)), mload(add(base, 0x40)))
                }
            } else if (stateUpdateType == StateUpdateType.LOG3) {
                _validateLogArg(arg, 0x80);
                assembly {
                    let base := add(arg, 0x20)
                    let dataPtr := add(base, 0x80)
                    log3(
                        add(dataPtr, 0x20),
                        mload(dataPtr),
                        mload(add(base, 0x20)),
                        mload(add(base, 0x40)),
                        mload(add(base, 0x60))
                    )
                }
            } else if (stateUpdateType == StateUpdateType.LOG4) {
                _validateLogArg(arg, 0xa0);
                assembly {
                    let base := add(arg, 0x20)
                    let dataPtr := add(base, 0xa0)
                    log4(
                        add(dataPtr, 0x20),
                        mload(dataPtr),
                        mload(add(base, 0x20)),
                        mload(add(base, 0x40)),
                        mload(add(base, 0x60)),
                        mload(add(base, 0x80))
                    )
                }
            } else if (stateUpdateType == StateUpdateType.CREATE) {
                (uint256 value, bytes memory initcode) = abi.decode(arg, (uint256, bytes));
                address deployed;
                assembly {
                    deployed := create(value, add(initcode, 0x20), mload(initcode))
                }
                require(deployed != address(0), DeploymentFailed());
            } else if (stateUpdateType == StateUpdateType.CREATE2) {
                (bytes32 salt, uint256 value, bytes memory initcode) = abi.decode(arg, (bytes32, uint256, bytes));
                address deployed;
                assembly {
                    deployed := create2(value, add(initcode, 0x20), mload(initcode), salt)
                }
                require(deployed != address(0), DeploymentFailed());
            }
        }
    }

    /// @notice Validate that `arg` is a canonical, in-bounds ABI encoding of a LOG payload
    /// @dev Reverts with `MalformedLogPayload` on a truncated head, a non-canonical `data` offset, or a
    ///      `data` length that runs past the end of `arg`. `canonicalOffset` is the encoding's head size
    ///      `0x20 * (numTopics + 1)` (0x20 for LOG0, 0x40 for LOG1, ... 0xa0 for LOG4); it is also where the
    ///      `data` length word lives, and every fixed `bytes32` topic sits within the head before it.
    /// @param arg The ABI-encoded LOG payload to validate
    /// @param canonicalOffset The expected offset of the `data` field (equals the encoding's head size)
    function _validateLogArg(bytes memory arg, uint256 canonicalOffset) private pure {
        uint256 len = arg.length;
        // The head (offset word + topics) and the `data` length word must both be readable.
        if (len < canonicalOffset + 0x20) revert MalformedLogPayload();
        uint256 off;
        uint256 dataLen;
        assembly {
            let base := add(arg, 0x20)
            off := mload(base)
            dataLen := mload(add(base, canonicalOffset))
        }
        // Offset must match what abi.encode produces, and the data bytes must fit inside `arg`.
        // `len >= canonicalOffset + 0x20` above makes the subtraction below safe.
        if (off != canonicalOffset) revert MalformedLogPayload();
        if (dataLen > len - canonicalOffset - 0x20) revert MalformedLogPayload();
    }

    /// @notice Thrown when `types` and `args` arrays have different lengths
    error InvalidArguments();

    /// @notice Thrown when a LOG operation's payload is not a canonical, in-bounds ABI encoding
    error MalformedLogPayload();

    /// @notice Thrown when a CALL operation's external call reverts
    /// @param index The zero-based position of the failing operation in the batch
    /// @param target The contract address that was called
    /// @param revertData The raw revert data returned by the failed call
    /// @param callargs The calldata that was passed to the failed call
    error RevertingContext(uint256 index, address target, bytes revertData, bytes callargs);

    /// @notice Thrown when a CREATE or CREATE2 operation returns address(0)
    error DeploymentFailed();
}

// src/StateTracker.sol

/// @title StateTracker
/// @notice Tracks the number of state transitions that have occurred in a contract
/// @dev Uses a precomputed ERC-7201-style storage slot to store the transition counter.
///      The slot is computed as: `keccak256("gasKiller.stateTracker") - 1`
///
///      Inherit this contract to enable Gas Killer state-transition tracking.
contract StateTracker {
    /// @notice Precomputed storage slot for the state transition counter
    /// @dev Computed as `keccak256("gasKiller.stateTracker") - 1`
    bytes32 internal constant STATE_TRACKER_STORAGE_LOCATION =
        0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;

    /// @notice Increment the state transition counter before executing the modified function
    /// @dev Apply this modifier to any function that constitutes a tracked state transition.
    ///      Steps: load current count → increment by 1 → store → execute function body.
    modifier trackState() {
        assembly {
            let count := sload(STATE_TRACKER_STORAGE_LOCATION)
            sstore(STATE_TRACKER_STORAGE_LOCATION, add(0x01, count))
        }
        _;
    }

    /// @notice Return the current number of state transitions that have occurred
    /// @return count The total number of tracked state transitions
    function stateTransitionCount() public view returns (uint256 count) {
        assembly {
            count := sload(STATE_TRACKER_STORAGE_LOCATION)
        }
    }
}

// src/TransitionGuard.sol

/// @title TransitionGuard
/// @notice EIP-1153 transient-storage reentrancy guard that doubles as an
///         "in transition" latch external contracts can query.
/// @dev Two holes in the unguarded settlement path, one mechanism:
///
///      1. **Reentrancy.** `StateChangeHandlerLib`'s `CALL` update forwards all remaining
///         gas to an arbitrary target *mid-transition* — after `trackState` has already
///         bumped the counter and before the transition's later updates have executed. A
///         re-entrant `verifyAndUpdate` carrying transition N+1's valid quorum signature
///         would pass the transition-index check and interleave N+1's updates inside N.
///         `guardTransition` makes the re-entrant call revert instead.
///
///      2. **Midway state.** During a `CALL` update the called contract observes storage
///         that never existed per the signed semantics: the transition counter already
///         shows N+1 while only a prefix of transition N's updates have landed. The quorum
///         signed the *final* post-transition state, not this intermediate one. The same
///         transient flag is exposed as `inTransition()`, so integrators reading a Gas
///         Killer contract can fail closed (revert or fall back) while a transition is
///         being applied, for one warm TLOAD (~100 gas) paid by the reader.
///
///      Transient storage clears automatically at the end of the transaction, so the
///      guard costs ~3 transient ops (~300 gas) per guarded call and never leaves a
///      dirty storage slot behind. Requires an EVM with EIP-1153 (Cancun or later).
abstract contract TransitionGuard {
    /// @notice Precomputed transient-storage slot for the guard flag
    /// @dev Computed as `keccak256("gasKiller.transitionGuard") - 1`, mirroring
    ///      `StateTracker`'s slot-derivation convention.
    bytes32 internal constant TRANSITION_GUARD_SLOT =
        0x577f51c71236185614d2425ce0aefc41d4e67f3a91a20821f72674b76f8d3ec0;

    /// @notice Thrown when a guarded function is re-entered while a transition is applying
    error ReentrantTransition();

    /// @notice Reverts on re-entry and holds the in-transition latch for the duration of
    ///         the function body (a batch entrypoint holds it across the whole batch).
    modifier guardTransition() {
        _enterTransition();
        _;
        _exitTransition();
    }

    /// @notice True while a state transition (or batch of transitions) is being applied
    /// @dev External contracts that read Gas Killer state and can be called mid-transition
    ///      (directly or transitively via a `CALL` update) should check this and fail
    ///      closed — mid-transition storage is not a quorum-signed state.
    function inTransition() public view virtual returns (bool locked) {
        assembly {
            locked := tload(TRANSITION_GUARD_SLOT)
        }
    }

    function _enterTransition() private {
        bool locked;
        assembly {
            locked := tload(TRANSITION_GUARD_SLOT)
        }
        if (locked) revert ReentrantTransition();
        assembly {
            tstore(TRANSITION_GUARD_SLOT, 1)
        }
    }

    function _exitTransition() private {
        assembly {
            tstore(TRANSITION_GUARD_SLOT, 0)
        }
    }
}

// src/schnorr/interface/ISchnorrGasKillerSDK.sol

/// @title ISchnorrGasKillerSDK
/// @notice Interface for SchnorrGasKillerSDK contracts
/// @dev Defines the core functionality that SchnorrGasKillerSDK implementations must
///      provide. State updates are approved by an operator quorum expressed as a
///      **single** aggregate Schnorr signature verified by a `SchnorrStakeRegistry`
///      (constant gas, non-signer subtraction) instead of `N` per-operator ECDSA
///      signatures. Deliberately single-function so
///      `type(ISchnorrGasKillerSDK).interfaceId` equals the `verifyAndUpdate`
///      selector — the router's ERC-165 preflight probes exactly this ID.
interface ISchnorrGasKillerSDK is IERC165 {
    /// @notice Verify the operators' aggregate Schnorr quorum signature and apply the
    ///         encoded state updates
    /// @dev Payable so a caller can fund value-bearing `CALL`/`CREATE`/`CREATE2` state updates
    ///      out of `msg.value`. The value each update moves is fixed inside the quorum-signed
    ///      `storageUpdates`, so `msg.value` only tops up the contract's balance — it cannot
    ///      redirect value anywhere the quorum did not sign. Under-funding reverts the whole
    ///      transition. Over-funding is NOT refunded: whatever the updates do not consume stays
    ///      in the contract, and recovering it is the responsibility of the inheriting contract
    ///      (e.g. a withdrawal function, or a refund executed as a signed CALL update in a
    ///      later transition).
    ///
    ///      `payable` does not change the function selector, so
    ///      `type(ISchnorrGasKillerSDK).interfaceId` — which the router's ERC-165 preflight
    ///      probes — is unaffected.
    /// @param msgHash The hash of the message to verify (sha256 of the encoded task)
    /// @param referenceBlockNumber The block number at which operator keys and stake
    ///        weights are evaluated by the stake registry
    /// @param storageUpdates The storage updates to verify and apply
    /// @param transitionIndex The transition index
    /// @param anchorHash The hash of the block the off-chain execution was anchored to
    /// @param callerAddress The msg.sender of the original call
    /// @param contractCalldata The full calldata of the original call
    /// @param s Aggregate Schnorr response scalar
    /// @param Raddr Aggregate nonce address `address(R)`
    /// @param nonSigners Operators that did not sign, in strictly ascending order
    function verifyAndUpdate(
        bytes32 msgHash,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes32 anchorHash,
        address callerAddress,
        bytes calldata contractCalldata,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners
    ) external payable;
}

// src/schnorr/SchnorrGasKillerSDK.sol

/// @title SchnorrGasKillerSDK
/// @notice Aggregate-Schnorr variant of `GasKillerSDK`. Identical task-hash and
///         state-update semantics; the only change is `_verifyQuorum`, which authorises a
///         state transition with a **single** aggregate Schnorr signature verified against
///         a `SchnorrStakeRegistry` (constant gas, non-signer subtraction) instead of `N`
///         per-operator ECDSA signatures verified against `ECDSAStakeRegistry`.
///
/// @dev The signed message mirrors the ECDSA `GasKillerSDK` digest —
///      `sha256(abi.encode(transitionIndex, address(this), anchorHash, callerAddress,
///      contractCalldata, storageUpdates))` — so the off-chain digest and the
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
        /// @notice Optional Gas Killer slasher; when set, applied commitments are recorded for challenge-window tracking
        IGasKillerSlasher slasher;
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
    /// @param anchorHash          hash of the block the off-chain execution was anchored to.
    /// @param callerAddress       the msg.sender of the original call.
    /// @param contractCalldata    the full calldata of the original call.
    /// @param s                   aggregate Schnorr response scalar.
    /// @param Raddr               aggregate nonce address `address(R)`.
    /// @param nonSigners          operators that did not sign, strictly ascending.
    function verifyAndUpdate(
        bytes32 msgHash,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes32 anchorHash,
        address callerAddress,
        bytes calldata contractCalldata,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners
    ) external payable guardTransition {
        _verifyAndUpdateOne(
            msgHash,
            referenceBlockNumber,
            storageUpdates,
            transitionIndex,
            anchorHash,
            callerAddress,
            contractCalldata,
            s,
            Raddr,
            nonSigners
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
                sub.anchorHash,
                sub.callerAddress,
                sub.contractCalldata,
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
        bytes32 anchorHash,
        address callerAddress,
        bytes calldata contractCalldata,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners
    ) private trackState {
        require(referenceBlockNumber < block.number, FutureBlockNumber());
        require((uint256(referenceBlockNumber) + _getBlockStaleMeasure()) >= block.number, StaleBlockNumber());

        require(transitionIndex + 1 == stateTransitionCount(), InvalidTransitionIndex());
        require(
            _computeMessageHash(transitionIndex, anchorHash, callerAddress, contractCalldata, storageUpdates)
                == msgHash,
            InvalidSignature()
        );

        _verifyQuorum(msgHash, s, Raddr, nonSigners, referenceBlockNumber);

        // Record the commitment for challenge-window tracking when a slasher is configured
        _recordCommitment(msgHash);

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

    /// @notice Record an applied commitment with the configured slasher, if any
    /// @param commitmentHash The verified message hash
    function _recordCommitment(bytes32 commitmentHash) internal {
        IGasKillerSlasher gasKillerSlasher = _sto().slasher;
        if (address(gasKillerSlasher) != address(0)) {
            gasKillerSlasher.recordCommitment(commitmentHash);
        }
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

    /// @notice Compute the expected message hash for a given transition and execution context
    /// @dev Exact mirror of the BLS `GasKillerSDK.getMessageHash` — the digest is
    ///      scheme-agnostic, so off-chain parity checks work unchanged.
    /// @param transitionIndex The transition index
    /// @param anchorHash The hash of the block the off-chain execution was anchored to
    /// @param callerAddress The msg.sender of the original call
    /// @param contractCalldata The full calldata of the original call
    /// @param storageUpdates The ABI-encoded storage updates
    /// @return The expected SHA-256 hash
    function getMessageHash(
        uint256 transitionIndex,
        bytes32 anchorHash,
        address callerAddress,
        bytes calldata contractCalldata,
        bytes calldata storageUpdates
    ) external view returns (bytes32) {
        return _computeMessageHash(transitionIndex, anchorHash, callerAddress, contractCalldata, storageUpdates);
    }

    /// @notice The task digest operators sign, binding the execution context to this contract
    /// @dev Single definition shared by settlement and `getMessageHash`, so the hash a
    ///      submission is checked against is by construction the one integrators can precompute.
    ///      Byte-identical to `GasKillerSDK._computeMessageHash`; `GasKillerSlashingParity.t.sol`
    ///      pins both against the slasher's `computeCommitmentHash`.
    /// @param transitionIndex The transition index
    /// @param anchorHash The hash of the block the off-chain execution was anchored to
    /// @param callerAddress The msg.sender of the original call
    /// @param contractCalldata The full calldata of the original call
    /// @param storageUpdates The ABI-encoded storage updates
    /// @return The expected SHA-256 hash
    function _computeMessageHash(
        uint256 transitionIndex,
        bytes32 anchorHash,
        address callerAddress,
        bytes calldata contractCalldata,
        bytes calldata storageUpdates
    ) internal view returns (bytes32) {
        return CommitmentDigestLib.commitmentHash(
            address(this), transitionIndex, anchorHash, callerAddress, contractCalldata, storageUpdates
        );
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

    /// @notice Return the configured Gas Killer slasher address (zero when unset)
    function slasher() external view returns (address) {
        return address(_sto().slasher);
    }

    /// @notice Set the Gas Killer slasher used for challenge-window recording (zero to disable)
    /// @param _slasher The new slasher address
    function _setSlasher(address _slasher) internal {
        _sto().slasher = IGasKillerSlasher(_slasher);
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
