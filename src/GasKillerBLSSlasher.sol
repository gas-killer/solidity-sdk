// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {BLSQuorumLib} from "./BLSQuorumLib.sol";
import {GasKillerSlasherBase} from "./GasKillerSlasherBase.sol";
import {IGasKillerBLSSlasher} from "./interface/IGasKillerBLSSlasher.sol";
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
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title GasKillerBLSSlasher
/// @notice Detects fraudulent Gas Killer commitments signed by the BLS AVS and slashes the signers
/// @dev Wires the BLS signature scheme into `GasKillerSlasherBase`. The two scheme-specific steps
///      are re-checking the aggregate BLS signature (same `checkSignatures` + quorum threshold as
///      `GasKillerSDK.verifyAndUpdate`) and deriving + slashing the signer set through EigenLayer.
///
///      Slashing flow:
///      1. Challenger calls `slash()` with the signed commitment, the aggregate BLS signature
///         material, and the SP1 fraud proof
///      2. The contract checks the aggregate network actually signed the commitment
///      3. The SP1 proof and the anchor block hash are verified (base)
///      4. Proven storage updates are compared with the signed ones; a mismatch is fraud (base)
///      5. Every operator that signed is slashed through `InstantSlasher.fulfillSlashingRequest`
///
///      Note: this contract must be set as the authorized `slasher` in the InstantSlasher contract.
contract GasKillerBLSSlasher is GasKillerSlasherBase, IGasKillerBLSSlasher {
    using BN254 for BN254.G1Point;

    // ============ Immutables ============

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

    /// @notice The operator set ID for Gas Killer
    uint32 public immutable OPERATOR_SET_ID;

    // ============ Constructor ============

    /// @notice Initialize the BLS slasher contract
    /// @param _sp1Verifier The SP1 verifier contract address
    /// @param _helios The Helios light client contract address (0 to rely on recording only)
    /// @param _blsSignatureChecker The BLS signature checker of the Gas Killer AVS
    /// @param _registryCoordinator The registry coordinator of the Gas Killer AVS
    /// @param _indexRegistry The index registry of the Gas Killer AVS
    /// @param _instantSlasher The EigenLayer InstantSlasher contract address
    /// @param _allocationManager The EigenLayer AllocationManager contract address
    /// @param _avs The AVS (Gas Killer service manager) address
    /// @param _programVKey The SP1 verification key of the challenger program
    /// @param _chainConfigHash The initial accepted chain config hash of challenger proofs
    ///        (the owner accepts additional hashes as the network hardforks)
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
    ) GasKillerSlasherBase(_sp1Verifier, _helios, _programVKey, _chainConfigHash, _challengeWindow) {
        BLS_SIGNATURE_CHECKER = IBLSSignatureChecker(_blsSignatureChecker);
        REGISTRY_COORDINATOR = ISlashingRegistryCoordinator(_registryCoordinator);
        INDEX_REGISTRY = IIndexRegistry(_indexRegistry);
        INSTANT_SLASHER = IInstantSlasher(_instantSlasher);
        ALLOCATION_MANAGER = IAllocationManager(_allocationManager);
        AVS = _avs;
        OPERATOR_SET_ID = _operatorSetId;
    }

    // ============ External Functions ============

    /// @inheritdoc IGasKillerBLSSlasher
    function slash(
        SignedCommitment calldata commitment,
        bytes calldata quorumNumbers,
        uint32 referenceBlockNumber,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature calldata nonSignerStakesAndSignature,
        bytes calldata sp1Proof,
        bytes calldata sp1PublicValues
    ) external {
        bytes32 commitmentHash = _beginSlash(commitment);

        // Verify the aggregate network actually signed this commitment. `BLSQuorumLib` is the
        // same admission rule `GasKillerSDK.verifyAndUpdate` applies, so a commitment that could
        // never have settled cannot be used to slash, and one that did settle is always
        // attributable.
        BLSQuorumLib.verifyQuorum(
            BLS_SIGNATURE_CHECKER, commitmentHash, quorumNumbers, referenceBlockNumber, nonSignerStakesAndSignature
        );

        // Derive every operator that signed the commitment: all operators registered for the
        // signed quorums at the reference block, minus the declared non-signers.
        address[] memory signers = _getSigners(quorumNumbers, referenceBlockNumber, nonSignerStakesAndSignature);

        // Verify the SP1 fraud proof and, on confirmed fraud, slash the signers.
        _completeSlash(commitment, commitmentHash, sp1Proof, sp1PublicValues, signers);
    }

    // ============ Internal Functions ============

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
            totalOperators += INDEX_REGISTRY.getOperatorListAtBlockNumber(uint8(quorumNumbers[q]), referenceBlockNumber)
            .length;
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
    function _executeSlashing(address[] memory signers, bytes32 commitmentHash) internal override {
        OperatorSet memory operatorSet = OperatorSet({avs: AVS, id: OPERATOR_SET_ID});
        IStrategy[] memory strategies = ALLOCATION_MANAGER.getStrategiesInOperatorSet(operatorSet);

        uint256[] memory wadsToSlash = new uint256[](strategies.length);
        for (uint256 i = 0; i < strategies.length; i++) {
            wadsToSlash[i] = FULL_SLASH_WAD;
        }

        string memory description = string.concat(
            "Gas Killer fraud detected for commitment: ", Strings.toHexString(uint256(commitmentHash), 32)
        );

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
}
