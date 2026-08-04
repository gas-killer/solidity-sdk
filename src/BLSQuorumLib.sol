// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {
    IBLSSignatureChecker,
    IBLSSignatureCheckerTypes
} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";

/// @title BLSQuorumLib
/// @notice The BLS quorum admission rule: which aggregate signatures the Gas Killer network
///         treats as authorizing a state transition.
/// @dev Shared by `GasKillerSDK.verifyAndUpdate` (which applies a transition) and
///      `GasKillerBLSSlasher.slash` (which attributes a fraudulent one). These two must agree
///      exactly. If the slasher accepted a weaker quorum than the SDK, it would slash operators
///      for a commitment that could never have settled; if it accepted a stronger one, a
///      commitment that did settle would be unslashable. Keeping the rule — the `checkSignatures`
///      call, the threshold, and the comparison — in one place makes that agreement structural
///      rather than a convention two contracts are each expected to honour.
library BLSQuorumLib {
    /// @notice Denominator used when evaluating stake percentage thresholds (representing 100%)
    uint8 internal constant THRESHOLD_DENOMINATOR = 100;

    /// @notice Minimum percentage of quorum stake that must have signed
    ///         (QUORUM_THRESHOLD/THRESHOLD_DENOMINATOR)
    uint8 internal constant QUORUM_THRESHOLD = 66;

    /// @notice Thrown when signatories hold less than `QUORUM_THRESHOLD`% of stake for any quorum
    error InsufficientQuorumThreshold();

    /// @notice Verify an aggregate BLS signature and require the quorum stake threshold on every
    ///         quorum it covers
    /// @dev Reverts via `checkSignatures` if the aggregate signature itself is invalid, then
    ///      requires each quorum's signed stake to meet the threshold.
    /// @param checker The BLS signature checker to verify against
    /// @param msgHash The signed message hash
    /// @param quorumNumbers The quorum numbers the message was signed for
    /// @param referenceBlockNumber The block number at which the operator set is evaluated
    /// @param nonSignerStakesAndSignature The non-signer stakes and signature data computed off-chain
    function verifyQuorum(
        IBLSSignatureChecker checker,
        bytes32 msgHash,
        bytes calldata quorumNumbers,
        uint32 referenceBlockNumber,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature calldata nonSignerStakesAndSignature
    ) internal view {
        (IBLSSignatureCheckerTypes.QuorumStakeTotals memory stakeTotals,) =
            checker.checkSignatures(msgHash, quorumNumbers, referenceBlockNumber, nonSignerStakesAndSignature);

        uint256 quorumCount = quorumNumbers.length;
        for (uint256 i = 0; i < quorumCount; ++i) {
            require(
                stakeTotals.signedStakeForQuorum[i] * THRESHOLD_DENOMINATOR
                    >= stakeTotals.totalStakeForQuorum[i] * QUORUM_THRESHOLD,
                InsufficientQuorumThreshold()
            );
        }
    }
}
