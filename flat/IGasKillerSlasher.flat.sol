// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

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
