// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

// src/interface/ISP1Verifier.sol

/**
 * @title ISP1Verifier
 * @notice Interface for SP1 proof verification
 * @dev The verification surface of Succinct's SP1 verifier, redeclared here so the SDK does not
 *      take a source dependency on `sp1-contracts` for one function signature. Proof-system
 *      agnostic on purpose: `verifyProof` is identical across Succinct's Groth16 and PLONK
 *      verifiers and their gateway, so a slasher can be pointed at whichever one a chain has
 *      deployed. `GasKillerSlasherBase` holds only this interface; the concrete verifier is
 *      supplied by address at construction.
 */
interface ISP1Verifier {
    /**
     * @notice Verify an SP1 proof, reverting if it does not hold
     * @param programVKey The verification key for the SP1 program
     * @param publicValues The public values from the proof
     * @param proofBytes The proof bytes, prefixed with the target verifier's 4-byte selector
     */
    function verifyProof(bytes32 programVKey, bytes calldata publicValues, bytes calldata proofBytes) external view;
}
