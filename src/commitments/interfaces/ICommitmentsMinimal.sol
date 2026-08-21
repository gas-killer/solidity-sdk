// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Minimal vendored surfaces of the Commitments protocol (AInima-Collective/commitments,
// MIT). Signatures are copied verbatim from the upstream interfaces so the SDK does not
// take the whole repo as a build dependency; integration tests pin the real contracts.
// Upstream sources:
//   src/core/interfaces/ICommitmentManager.sol
//   src/extensions/services/interfaces/IOperatorRegistry.sol
//   src/shared/arbitration/interfaces/IArbiter.sol

/// @notice The forfeit surface of the Commitments `CommitmentManager` an arbiter drives.
///         Forfeiture is two-phase: `initiateForfeit` (arbiter-only) opens a proposal,
///         the commitment's challenge window (>= 1 day) elapses, then `executeForfeit`
///         is permissionless.
interface ICommitmentManagerMinimal {
    function initiateForfeit(uint256 commitmentId, uint16 penaltyBps) external;
    function cancelForfeit(uint256 commitmentId) external;
    function executeForfeit(uint256 commitmentId) external;
}

/// @notice The read surface of the Commitments `OperatorRegistry` the Gas Killer
///         adapter and arbiter consume. Operator identity is an address; stake is the
///         aggregate of live commitments (self-stake + delegations) naming the registry
///         as counterparty.
interface IOperatorRegistryMinimal {
    function isOperator(address operator) external view returns (bool);
    function getOperatorStake(address operator) external view returns (uint256);
    function minOperatorStake() external view returns (uint256);
    /// @notice The operator a tracked commitment supports (covers both an operator's
    ///         self-stake and delegations to it); `address(0)` for untracked ids.
    function operatorForCommitment(uint256 commitmentId) external view returns (address);
}

/// @notice Capability interface for contracts named as the `arbiter` on a commitment
///         (verbatim from upstream `IArbiter`; ERC-165 id is the xor of the three
///         selectors below). The manager authenticates arbiters purely by `msg.sender`
///         equality — this surface exists so counterparties can introspect an arbiter
///         before opting in.
interface IArbiter {
    function commitmentManager() external view returns (address);
    function arbiterCapabilities() external view returns (uint256);
    function arbiterMetadataURI() external view returns (string memory);
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @notice Named bits for `IArbiter.arbiterCapabilities()` (upstream
///         `ArbiterCapabilities`; bits are stable and append-only).
library ArbiterCapabilities {
    uint256 internal constant INITIATE_FORFEIT = 1 << 0;
    uint256 internal constant CANCEL_FORFEIT = 1 << 1;
    uint256 internal constant RELEASE_COMMITMENT = 1 << 2;
}

/// @notice Succinct SP1 verifier gateway surface (reverts on invalid proofs).
interface ISP1Verifier {
    function verifyProof(bytes32 programVKey, bytes calldata publicValues, bytes calldata proofBytes)
        external
        view;
}
