// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IGasKillerSlasher} from "./interface/IGasKillerSlasher.sol";
import {ISP1Verifier} from "./interface/ISP1Verifier.sol";
import {IHeliosLightClient} from "./interface/IHeliosLightClient.sol";
import {
    IBLSSignatureChecker,
    IBLSSignatureCheckerTypes
} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";
import {IIndexRegistry} from "@eigenlayer-middleware/interfaces/IIndexRegistry.sol";
import {ISlashingRegistryCoordinator} from "@eigenlayer-middleware/interfaces/ISlashingRegistryCoordinator.sol";
import {IInstantSlasher} from "@eigenlayer-middleware/interfaces/IInstantSlasher.sol";
import {BN254} from "@eigenlayer-middleware/libraries/BN254.sol";
import {
    IAllocationManager,
    IAllocationManagerTypes
} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {OperatorSet} from "eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";

/// @title GasKillerSlasher
/// @notice Detects fraudulent Gas Killer commitments and slashes the operators who signed them
/// @dev A commitment is fraudulent when the aggregate network signed storage updates that differ
///      from the ones produced by actually executing the committed call. A challenger proves the
///      correct execution with the Gas Killer challenger SP1 program (see the sp1-contract-call
///      `examples/gas-killer` guest), which re-executes `contractCalldata` from `callerAddress`
///      against `contractAddress` at the state anchored by `anchorHash` and commits the resulting
///      canonical storage updates.
///
///      Slashing flow:
///      1. Challenger calls `slash()` with the signed commitment, the aggregate BLS signature
///         material, and the SP1 fraud proof
///      2. The contract checks the aggregate network actually signed the commitment (same
///         `checkSignatures` + quorum threshold as `GasKillerSDK.verifyAndUpdate`)
///      3. The SP1 proof and the anchor block hash are verified
///      4. Proven storage updates are compared with the signed ones; a mismatch is fraud
///      5. Every operator that signed is slashed through `InstantSlasher.fulfillSlashingRequest`
///
///      Note: this contract must be set as the authorized `slasher` in the InstantSlasher contract.
contract GasKillerSlasher is IGasKillerSlasher {
    using BN254 for BN254.G1Point;

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

    /// @notice The BLS signature checker of the Gas Killer AVS
    IBLSSignatureChecker public immutable BLS_SIGNATURE_CHECKER;

    /// @notice The registry coordinator of the Gas Killer AVS
    ISlashingRegistryCoordinator public immutable REGISTRY_COORDINATOR;

    /// @notice The index registry of the Gas Killer AVS
    IIndexRegistry public immutable INDEX_REGISTRY;

    /// @notice The EigenLayer InstantSlasher contract
    IInstantSlasher public immutable INSTANT_SLASHER;

    /// @notice The EigenLayer AllocationManager contract
    IAllocationManager public immutable ALLOCATION_MANAGER;

    /// @notice The AVS address (Gas Killer service manager)
    address public immutable AVS;

    /// @notice The SP1 verification key of the Gas Killer challenger program
    bytes32 public immutable PROGRAM_V_KEY;

    /// @notice The chain config hash (chain id + active hardfork) proofs must be generated against
    /// @dev Prevents a challenger from "proving" a divergent execution by running the guest with
    ///      a wrong chain configuration against the same state
    bytes32 public immutable CHAIN_CONFIG_HASH;

    /// @notice The challenge window duration in seconds
    uint256 public immutable CHALLENGE_WINDOW;

    /// @notice The operator set ID for Gas Killer
    uint32 public immutable OPERATOR_SET_ID;

    // ============ Storage ============

    /// @notice Mapping of commitment hash to slashed status
    mapping(bytes32 => bool) private _slashed;

    /// @notice Mapping of (target contract, commitment hash) to application timestamp
    /// @dev Keyed by the recording contract so third parties cannot start the challenge
    ///      window for commitments they did not apply
    mapping(address => mapping(bytes32 => uint256)) private _commitmentTimestamp;

    // ============ Constructor ============

    /// @notice Initialize the slasher contract
    /// @param _sp1Verifier The SP1 verifier contract address
    /// @param _helios The Helios light client contract address (0 to rely on recording only)
    /// @param _blsSignatureChecker The BLS signature checker of the Gas Killer AVS
    /// @param _registryCoordinator The registry coordinator of the Gas Killer AVS
    /// @param _indexRegistry The index registry of the Gas Killer AVS
    /// @param _instantSlasher The EigenLayer InstantSlasher contract address
    /// @param _allocationManager The EigenLayer AllocationManager contract address
    /// @param _avs The AVS (Gas Killer service manager) address
    /// @param _programVKey The SP1 verification key of the challenger program
    /// @param _chainConfigHash The expected chain config hash of challenger proofs
    /// @param _challengeWindow The challenge window duration in seconds
    /// @param _operatorSetId The operator set ID for Gas Killer
    constructor(
        address _sp1Verifier,
        address _helios,
        address _blsSignatureChecker,
        address _registryCoordinator,
        address _indexRegistry,
        address _instantSlasher,
        address _allocationManager,
        address _avs,
        bytes32 _programVKey,
        bytes32 _chainConfigHash,
        uint256 _challengeWindow,
        uint32 _operatorSetId
    ) {
        SP1_VERIFIER = ISP1Verifier(_sp1Verifier);
        HELIOS = IHeliosLightClient(_helios);
        BLS_SIGNATURE_CHECKER = IBLSSignatureChecker(_blsSignatureChecker);
        REGISTRY_COORDINATOR = ISlashingRegistryCoordinator(_registryCoordinator);
        INDEX_REGISTRY = IIndexRegistry(_indexRegistry);
        INSTANT_SLASHER = IInstantSlasher(_instantSlasher);
        ALLOCATION_MANAGER = IAllocationManager(_allocationManager);
        AVS = _avs;
        PROGRAM_V_KEY = _programVKey;
        CHAIN_CONFIG_HASH = _chainConfigHash;
        CHALLENGE_WINDOW = _challengeWindow;
        OPERATOR_SET_ID = _operatorSetId;
    }

    // ============ External Functions ============

    /// @inheritdoc IGasKillerSlasher
    function slash(
        SignedCommitment calldata commitment,
        bytes calldata quorumNumbers,
        uint32 referenceBlockNumber,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature calldata nonSignerStakesAndSignature,
        bytes calldata sp1Proof,
        bytes calldata sp1PublicValues
    ) external {
        bytes32 commitmentHash = computeCommitmentHash(commitment);

        require(!_slashed[commitmentHash], AlreadySlashed());

        // Enforce the challenge window when the commitment application was recorded.
        // Unrecorded commitments remain challengeable indefinitely: signing a fraudulent
        // commitment is an offense even if it was never applied on-chain.
        uint256 timestamp = _commitmentTimestamp[commitment.contractAddress][commitmentHash];
        require(timestamp == 0 || block.timestamp <= timestamp + CHALLENGE_WINDOW, ChallengeExpired());

        // Verify the aggregate network actually signed this commitment, with the same quorum
        // threshold `verifyAndUpdate` enforces. `checkSignatures` reverts on an invalid
        // aggregate signature.
        (IBLSSignatureCheckerTypes.QuorumStakeTotals memory stakeTotals,) = BLS_SIGNATURE_CHECKER.checkSignatures(
            commitmentHash, quorumNumbers, referenceBlockNumber, nonSignerStakesAndSignature
        );
        for (uint256 i = 0; i < quorumNumbers.length; i++) {
            require(
                stakeTotals.signedStakeForQuorum[i] * THRESHOLD_DENOMINATOR
                    >= stakeTotals.totalStakeForQuorum[i] * QUORUM_THRESHOLD,
                InsufficientQuorumThreshold()
            );
        }

        // Verify the SP1 proof of the correct execution.
        _verifyProof(sp1Proof, sp1PublicValues);

        // Compare the proven execution with the signed commitment.
        GasKillerPublicValues memory proven = abi.decode(sp1PublicValues, (GasKillerPublicValues));
        _checkInputs(commitment, proven);

        // Verify the anchor block hash is a real block on this chain.
        _verifyAnchorHash(proven.anchorHash);

        // Fraud iff the proven storage updates differ from the signed ones.
        require(
            keccak256(proven.storageUpdates) != keccak256(commitment.storageUpdates), NoFraudDetected()
        );

        _slashed[commitmentHash] = true;

        // Slash every operator that signed the commitment: all operators registered for the
        // signed quorums at the reference block, minus the declared non-signers.
        address[] memory signers = _getSigners(quorumNumbers, referenceBlockNumber, nonSignerStakesAndSignature);
        _executeSlashing(signers, commitmentHash);

        emit SlashingExecuted(commitmentHash, msg.sender, signers, FULL_SLASH_WAD);
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
    function getCommitmentTimestamp(address targetContract, bytes32 commitmentHash)
        external
        view
        returns (uint256)
    {
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
        require(proven.chainConfigHash == CHAIN_CONFIG_HASH, InvalidChainConfig());
        require(proven.anchorType == ANCHOR_TYPE_BLOCK_HASH, InputMismatch());
        require(proven.anchorHash == commitment.anchorHash, InputMismatch());
        require(proven.callerAddress == commitment.callerAddress, InputMismatch());
        require(proven.contractAddress == commitment.contractAddress, InputMismatch());
        require(
            keccak256(proven.contractCalldata) == keccak256(commitment.contractCalldata), InputMismatch()
        );
    }

    /// @notice Verify an anchor block hash using the Helios light client
    /// @param anchorHash The block hash to verify
    function _verifyAnchorHash(bytes32 anchorHash) internal view {
        if (address(HELIOS) != address(0) && HELIOS.isBlockHashValid(anchorHash)) {
            return;
        }

        revert UnverifiedBlock();
    }

    /// @notice Derive the set of operators that signed: all operators registered for the given
    ///         quorums at the reference block, minus the declared non-signers
    /// @dev The aggregate signature was already verified against exactly this set by
    ///      `checkSignatures`, so the derived list is the true signer set
    /// @param quorumNumbers The quorum numbers the commitment was signed for
    /// @param referenceBlockNumber The reference block used for the operator set
    /// @param nonSignerStakesAndSignature The non-signer data submitted with the signature
    /// @return signers The signer addresses (deduplicated across quorums)
    function _getSigners(
        bytes calldata quorumNumbers,
        uint32 referenceBlockNumber,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature calldata nonSignerStakesAndSignature
    ) internal view returns (address[] memory signers) {
        uint256 nonSignerCount = nonSignerStakesAndSignature.nonSignerPubkeys.length;
        bytes32[] memory nonSignerIds = new bytes32[](nonSignerCount);
        for (uint256 i = 0; i < nonSignerCount; i++) {
            nonSignerIds[i] = nonSignerStakesAndSignature.nonSignerPubkeys[i].hashG1Point();
        }

        // Collect operator ids over all quorums, skipping non-signers and duplicates.
        uint256 totalOperators = 0;
        for (uint256 q = 0; q < quorumNumbers.length; q++) {
            totalOperators +=
                INDEX_REGISTRY.getOperatorListAtBlockNumber(uint8(quorumNumbers[q]), referenceBlockNumber).length;
        }

        bytes32[] memory signerIds = new bytes32[](totalOperators);
        uint256 signerCount = 0;
        for (uint256 q = 0; q < quorumNumbers.length; q++) {
            bytes32[] memory operatorIds =
                INDEX_REGISTRY.getOperatorListAtBlockNumber(uint8(quorumNumbers[q]), referenceBlockNumber);
            for (uint256 i = 0; i < operatorIds.length; i++) {
                if (_contains(nonSignerIds, operatorIds[i], nonSignerCount)) {
                    continue;
                }
                if (_contains(signerIds, operatorIds[i], signerCount)) {
                    continue;
                }
                signerIds[signerCount++] = operatorIds[i];
            }
        }

        signers = new address[](signerCount);
        for (uint256 i = 0; i < signerCount; i++) {
            signers[i] = REGISTRY_COORDINATOR.getOperatorFromId(signerIds[i]);
        }
    }

    /// @notice Check whether `value` appears in the first `length` elements of `array`
    function _contains(bytes32[] memory array, bytes32 value, uint256 length) private pure returns (bool) {
        for (uint256 i = 0; i < length; i++) {
            if (array[i] == value) {
                return true;
            }
        }
        return false;
    }

    /// @notice Execute slashing for the given operators via EigenLayer InstantSlasher
    /// @param signers Operator addresses to slash
    /// @param commitmentHash The commitment hash, referenced in the slashing description
    function _executeSlashing(address[] memory signers, bytes32 commitmentHash) internal {
        OperatorSet memory operatorSet = OperatorSet({avs: AVS, id: OPERATOR_SET_ID});
        IStrategy[] memory strategies = ALLOCATION_MANAGER.getStrategiesInOperatorSet(operatorSet);

        uint256[] memory wadsToSlash = new uint256[](strategies.length);
        for (uint256 i = 0; i < strategies.length; i++) {
            wadsToSlash[i] = FULL_SLASH_WAD;
        }

        string memory description =
            string(abi.encodePacked("Gas Killer fraud detected for commitment: ", _bytes32ToHexString(commitmentHash)));

        for (uint256 i = 0; i < signers.length; i++) {
            if (ALLOCATION_MANAGER.isOperatorSlashable(signers[i], operatorSet)) {
                IAllocationManagerTypes.SlashingParams memory slashingParams = IAllocationManagerTypes.SlashingParams({
                    operator: signers[i],
                    operatorSetId: OPERATOR_SET_ID,
                    strategies: strategies,
                    wadsToSlash: wadsToSlash,
                    description: description
                });

                INSTANT_SLASHER.fulfillSlashingRequest(slashingParams);
            }
        }
    }

    /// @notice Convert bytes32 to a 0x-prefixed hex string
    function _bytes32ToHexString(bytes32 value) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(66);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i] & 0x0f)];
        }
        return string(str);
    }
}
