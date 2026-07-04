// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

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
    function verifyProof(
        bytes32 programVKey,
        bytes calldata publicValues,
        bytes calldata proofBytes
    ) external view;
}
