// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0 ^0.8.27;

// lib/openzeppelin-contracts/contracts/utils/Context.sol

// OpenZeppelin Contracts v4.4.1 (utils/Context.sol)

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
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

// src/interface/IHeliosLightClient.sol

/**
 * @title IHeliosLightClient
 * @notice Interface for Helios Ethereum light client
 * @dev Used for trustless block hash verification
 */
interface IHeliosLightClient {
    /**
     * @notice Check if a block hash is valid and verified by the light client
     * @param blockHash The block hash to verify
     * @return True if the block hash is valid
     */
    function isBlockHashValid(bytes32 blockHash) external view returns (bool);

    /**
     * @notice Get the block hash for a given block number
     * @param blockNumber The block number to query
     * @return The block hash for the given block number
     */
    function getBlockHash(uint256 blockNumber) external view returns (bytes32);
}

// src/interface/ISP1Verifier.sol

/**
 * @title ISP1Verifier
 * @notice Interface for SP1 PLONK proof verification
 * @dev This interface wraps the SP1 verifier contract from Succinct
 */
interface ISP1Verifier {
    /**
     * @notice Verify an SP1 PLONK proof
     * @param programVKey The verification key for the SP1 program
     * @param publicValues The public values from the proof
     * @param proofBytes The PLONK proof bytes
     */
    function verifyProof(bytes32 programVKey, bytes calldata publicValues, bytes calldata proofBytes) external view;
}

// lib/openzeppelin-contracts/contracts/access/Ownable.sol

// OpenZeppelin Contracts (last updated v4.9.0) (access/Ownable.sol)

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        _transferOwnership(_msgSender());
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby disabling any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

// src/GasKillerSlasherBase.sol

/// @title GasKillerSlasherBase
/// @notice Scheme-agnostic core of the Gas Killer fraud-proof slashers
/// @dev A commitment is fraudulent when the aggregate network signed storage updates that differ
///      from the ones produced by actually executing the committed call. A challenger proves the
///      correct execution with the Gas Killer challenger SP1 program (see the sp1-contract-call
///      `examples/gas-killer` guest), which re-executes `contractCalldata` from `callerAddress`
///      against `contractAddress` at the state anchored by `anchorHash` and commits the resulting
///      canonical storage updates.
///
///      This base owns everything that does not depend on the signature scheme: the challenge
///      window, the chain-config allowlist, SP1 proof verification, the anchor-hash check, the
///      fraud comparison, and the slashed/recorded bookkeeping. A concrete slasher wires in the
///      two scheme-specific steps around it:
///      1. re-checking that the aggregate network actually signed the commitment (before calling
///         `_completeSlash`), and
///      2. deriving and slashing the operators who signed (`_executeSlashing`).
///
///      Concrete flow (see `GasKillerBLSSlasher`):
///      1. `_beginSlash` computes the commitment hash and enforces not-already-slashed + window
///      2. the concrete verifies the aggregate signature and derives the signer set
///      3. `_completeSlash` verifies the SP1 proof + anchor hash, confirms fraud, marks the
///         commitment slashed, invokes `_executeSlashing`, and emits `SlashingExecuted`
///
///      A Schnorr concrete is intentionally not provided yet — the Schnorr staking system has no
///      economic stake to seize and no on-chain signer enumeration. Tracked in
///      https://github.com/gas-killer/solidity-sdk/issues/65.
abstract contract GasKillerSlasherBase is IGasKillerSlasher, Ownable {
    // ============ Constants ============

    /// @notice Denominator used when evaluating stake percentage thresholds (representing 100%)
    uint8 public constant THRESHOLD_DENOMINATOR = 100;

    /// @notice Minimum percentage of quorum stake that must have signed the commitment
    /// @dev Matches `GasKillerSDK.QUORUM_THRESHOLD`: a commitment below this threshold could
    ///      never have been applied on-chain
    uint8 public constant QUORUM_THRESHOLD = 66;

    /// @notice `AnchorType.BlockHash` as committed by the challenger program
    uint8 public constant ANCHOR_TYPE_BLOCK_HASH = 0;

    /// @notice Wad amount for full slash (100%)
    uint256 public constant FULL_SLASH_WAD = 1e18;

    // ============ Immutables ============

    /// @notice The SP1 verifier contract (Groth16 or PLONK gateway)
    ISP1Verifier public immutable SP1_VERIFIER;

    /// @notice The Helios light client contract used to verify anchor block hashes
    IHeliosLightClient public immutable HELIOS;

    /// @notice The SP1 verification key of the Gas Killer challenger program
    bytes32 public immutable PROGRAM_V_KEY;

    /// @notice The challenge window duration in seconds
    uint256 public immutable CHALLENGE_WINDOW;

    // ============ Storage ============

    /// @notice Mapping of commitment hash to slashed status
    mapping(bytes32 => bool) private _slashed;

    /// @notice Mapping of (target contract, commitment hash) to application timestamp
    /// @dev Keyed by the recording contract so third parties cannot start the challenge
    ///      window for commitments they did not apply
    mapping(address => mapping(bytes32 => uint256)) private _commitmentTimestamp;

    /// @notice Chain config hashes (chain id + active hardfork) accepted for proofs
    /// @dev The challenger program commits `keccak256(chainId ++ activeForkName)` where
    ///      `activeForkName` is the hardfork active at the anchor block; that value changes
    ///      the moment a network hardfork activates. The owner must accept the new fork's
    ///      hash so commitments anchored to post-fork blocks stay challengeable. Requiring an
    ///      explicit allowlist still blocks proofs generated against a wrong chain/fork.
    mapping(bytes32 => bool) public acceptedChainConfigHash;

    // ============ Constructor ============

    /// @notice Initialize the scheme-agnostic slasher state
    /// @param _sp1Verifier The SP1 verifier contract address
    /// @param _helios The Helios light client contract address (0 to rely on recording only)
    /// @param _programVKey The SP1 verification key of the challenger program
    /// @param _chainConfigHash The initial accepted chain config hash of challenger proofs
    ///        (the owner accepts additional hashes as the network hardforks)
    /// @param _challengeWindow The challenge window duration in seconds
    constructor(
        address _sp1Verifier,
        address _helios,
        bytes32 _programVKey,
        bytes32 _chainConfigHash,
        uint256 _challengeWindow
    ) {
        SP1_VERIFIER = ISP1Verifier(_sp1Verifier);
        HELIOS = IHeliosLightClient(_helios);
        PROGRAM_V_KEY = _programVKey;
        acceptedChainConfigHash[_chainConfigHash] = true;
        CHALLENGE_WINDOW = _challengeWindow;
        emit ChainConfigHashSet(_chainConfigHash, true);
    }

    // ============ External Functions ============

    /// @inheritdoc IGasKillerSlasher
    function setChainConfigHashAccepted(bytes32 chainConfigHash, bool accepted) external onlyOwner {
        acceptedChainConfigHash[chainConfigHash] = accepted;
        emit ChainConfigHashSet(chainConfigHash, accepted);
    }

    /// @inheritdoc IGasKillerSlasher
    function recordCommitment(bytes32 commitmentHash) external {
        if (_commitmentTimestamp[msg.sender][commitmentHash] == 0) {
            _commitmentTimestamp[msg.sender][commitmentHash] = block.timestamp;
            emit CommitmentRecorded(msg.sender, commitmentHash);
        }
    }

    /// @inheritdoc IGasKillerSlasher
    function isSlashed(bytes32 commitmentHash) external view returns (bool) {
        return _slashed[commitmentHash];
    }

    /// @inheritdoc IGasKillerSlasher
    function getCommitmentTimestamp(address targetContract, bytes32 commitmentHash) external view returns (uint256) {
        return _commitmentTimestamp[targetContract][commitmentHash];
    }

    /// @inheritdoc IGasKillerSlasher
    function challengeWindow() external view returns (uint256) {
        return CHALLENGE_WINDOW;
    }

    /// @inheritdoc IGasKillerSlasher
    function programVKey() external view returns (bytes32) {
        return PROGRAM_V_KEY;
    }

    /// @inheritdoc IGasKillerSlasher
    function computeCommitmentHash(SignedCommitment calldata commitment) public pure returns (bytes32) {
        return sha256(
            abi.encode(
                commitment.transitionIndex,
                commitment.contractAddress,
                commitment.anchorHash,
                commitment.callerAddress,
                commitment.contractCalldata,
                commitment.storageUpdates
            )
        );
    }

    // ============ Internal Functions ============

    /// @notice Begin a slashing challenge: compute the commitment hash and enforce the
    ///         not-already-slashed and challenge-window preconditions
    /// @dev Unrecorded commitments remain challengeable indefinitely: signing a fraudulent
    ///      commitment is an offense even if it was never applied on-chain.
    /// @param commitment The signed commitment being challenged
    /// @return commitmentHash The computed commitment hash
    function _beginSlash(SignedCommitment calldata commitment) internal view returns (bytes32 commitmentHash) {
        commitmentHash = computeCommitmentHash(commitment);

        require(!_slashed[commitmentHash], AlreadySlashed());

        uint256 timestamp = _commitmentTimestamp[commitment.contractAddress][commitmentHash];
        require(timestamp == 0 || block.timestamp <= timestamp + CHALLENGE_WINDOW, ChallengeExpired());
    }

    /// @notice Verify the fraud proof and, on confirmed fraud, mark the commitment slashed and
    ///         slash the given signers
    /// @dev The caller (a concrete slasher) must have already verified the aggregate signature
    ///      over `commitmentHash` and derived `signers` from exactly that signed set.
    /// @param commitment The signed commitment being challenged
    /// @param commitmentHash The commitment hash returned by `_beginSlash`
    /// @param sp1Proof The SP1 proof bytes
    /// @param sp1PublicValues The ABI-encoded `GasKillerPublicValues`
    /// @param signers The operators that signed the commitment, to be slashed on confirmed fraud
    function _completeSlash(
        SignedCommitment calldata commitment,
        bytes32 commitmentHash,
        bytes calldata sp1Proof,
        bytes calldata sp1PublicValues,
        address[] memory signers
    ) internal {
        // Verify the SP1 proof of the correct execution.
        _verifyProof(sp1Proof, sp1PublicValues);

        // Compare the proven execution with the signed commitment.
        GasKillerPublicValues memory proven = abi.decode(sp1PublicValues, (GasKillerPublicValues));
        _checkInputs(commitment, proven);

        // Verify the anchor block hash is a real block on this chain.
        _verifyAnchorHash(proven.anchorHash);

        // Fraud iff the proven storage updates differ from the signed ones.
        require(keccak256(proven.storageUpdates) != keccak256(commitment.storageUpdates), NoFraudDetected());

        _slashed[commitmentHash] = true;

        _executeSlashing(signers, commitmentHash);

        emit SlashingExecuted(commitmentHash, msg.sender, signers, FULL_SLASH_WAD);
    }

    /// @notice Slash the operators who signed a commitment proven fraudulent
    /// @dev Implemented per scheme: the BLS concrete slashes through EigenLayer's InstantSlasher.
    /// @param signers Operator addresses to slash
    /// @param commitmentHash The commitment hash, referenced in the slashing description
    function _executeSlashing(address[] memory signers, bytes32 commitmentHash) internal virtual;

    /// @notice Verify the SP1 proof
    /// @param proofBytes The SP1 proof bytes
    /// @param publicValues The ABI-encoded public values
    function _verifyProof(bytes calldata proofBytes, bytes calldata publicValues) internal view {
        try SP1_VERIFIER.verifyProof(PROGRAM_V_KEY, publicValues, proofBytes) {}
        catch {
            revert InvalidProof();
        }
    }

    /// @notice Require the proven execution inputs to match the signed commitment
    /// @param commitment The signed commitment
    /// @param proven The proof's public values
    function _checkInputs(SignedCommitment calldata commitment, GasKillerPublicValues memory proven) internal view {
        require(acceptedChainConfigHash[proven.chainConfigHash], InvalidChainConfig());
        require(proven.anchorType == ANCHOR_TYPE_BLOCK_HASH, InputMismatch());
        require(proven.anchorHash == commitment.anchorHash, InputMismatch());
        require(proven.callerAddress == commitment.callerAddress, InputMismatch());
        require(proven.contractAddress == commitment.contractAddress, InputMismatch());
        require(keccak256(proven.contractCalldata) == keccak256(commitment.contractCalldata), InputMismatch());
    }

    /// @notice Verify an anchor block hash using the Helios light client
    /// @param anchorHash The block hash to verify
    function _verifyAnchorHash(bytes32 anchorHash) internal view {
        if (address(HELIOS) != address(0) && HELIOS.isBlockHashValid(anchorHash)) {
            return;
        }

        revert UnverifiedBlock();
    }
}
