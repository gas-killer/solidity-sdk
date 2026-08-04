// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {CommitmentDigestLib} from "./CommitmentDigestLib.sol";
import {IGasKillerSlasher} from "./interface/IGasKillerSlasher.sol";
import {ISP1Verifier} from "./interface/ISP1Verifier.sol";
import {IHeliosLightClient} from "./interface/IHeliosLightClient.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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
    /// @dev Internal: `programVKey()` is the external accessor, so the interface stays the single
    ///      documented surface rather than shipping two getters for one value.
    bytes32 internal immutable PROGRAM_V_KEY;

    /// @notice The challenge window duration in seconds
    /// @dev Internal for the same reason as [`PROGRAM_V_KEY`]; read it via `challengeWindow()`.
    uint256 internal immutable CHALLENGE_WINDOW;

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
    /// @param _helios The Helios light client contract address. Zero deploys a
    ///        **recording-only** slasher: `recordCommitment` still starts challenge windows, but
    ///        every `slash` reverts `UnverifiedBlock`, because an anchor hash can only be
    ///        confirmed against a light client. This is immutable — a slasher deployed with zero
    ///        can never slash, and enabling slashing later means deploying a new one and
    ///        re-pointing the SDKs at it.
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
        return CommitmentDigestLib.commitmentHash(
            commitment.contractAddress,
            commitment.transitionIndex,
            commitment.anchorHash,
            commitment.callerAddress,
            commitment.contractCalldata,
            commitment.storageUpdates
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
    /// @dev Fails closed on an unset light client: without one there is no way to establish that
    ///      the anchor is a real block on this chain, and accepting an unverifiable anchor would
    ///      let a challenger slash against a fabricated execution context.
    /// @param anchorHash The block hash to verify
    function _verifyAnchorHash(bytes32 anchorHash) internal view {
        if (address(HELIOS) != address(0) && HELIOS.isBlockHashValid(anchorHash)) {
            return;
        }

        revert UnverifiedBlock();
    }
}
