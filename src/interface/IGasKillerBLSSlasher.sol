// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IGasKillerSlasher} from "./IGasKillerSlasher.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";

/// @title IGasKillerBLSSlasher
/// @notice Slashing interface for the BLS-based Gas Killer AVS
/// @dev Extends the scheme-agnostic `IGasKillerSlasher` with a `slash` entrypoint that carries the
///      aggregate BLS signature material (`quorumNumbers`, `referenceBlockNumber`,
///      `NonSignerStakesAndSignature`) verified against the EigenLayer `BLSSignatureChecker`.
interface IGasKillerBLSSlasher is IGasKillerSlasher {
    /// @notice Submit a fraud proof for a signed commitment and slash the operators who signed it
    /// @dev Verifies (1) the aggregate network actually signed the commitment, (2) the SP1 proof
    ///      of the correct execution, (3) the anchor block hash, and (4) that the proven storage
    ///      updates differ from the signed ones. On success, every operator that signed the
    ///      commitment is slashed through EigenLayer.
    /// @param commitment The signed commitment being challenged
    /// @param quorumNumbers The quorum numbers the commitment was signed for
    /// @param referenceBlockNumber The reference block used for the operator set
    /// @param nonSignerStakesAndSignature The aggregate BLS signature and non-signer data,
    ///        exactly as submitted to `verifyAndUpdate`
    /// @param sp1Proof The SP1 proof bytes (Groth16 or PLONK)
    /// @param sp1PublicValues The ABI-encoded `GasKillerPublicValues`
    function slash(
        SignedCommitment calldata commitment,
        bytes calldata quorumNumbers,
        uint32 referenceBlockNumber,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature calldata nonSignerStakesAndSignature,
        bytes calldata sp1Proof,
        bytes calldata sp1PublicValues
    ) external;
}
