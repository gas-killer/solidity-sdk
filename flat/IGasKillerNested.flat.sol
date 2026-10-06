// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

// src/interface/ISchnorrStakeRegistry.sol

/// @title ISchnorrStakeRegistry
/// @notice Verification surface the `GasKillerSDK` depends on. Kept minimal (and
///         separate from the concrete registry) so the SDK can be unit-tested against a
///         mock, mirroring how `GasKillerSDK` depends on ERC-1271 `isValidSignature`.
interface ISchnorrStakeRegistry {
    /// @notice Verify an aggregate Schnorr quorum signature over `message`.
    /// @param message     the signed 32-byte task digest.
    /// @param s           aggregate response scalar.
    /// @param Raddr       aggregate nonce address `address(R)`.
    /// @param nonSigners  operator identities that did not sign, strictly ascending.
    /// @param refBlock    reference block; must be `>= effectiveBlock` and `< block.number`.
    function isValidSignature(
        bytes32 message,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners,
        uint256 refBlock
    ) external view returns (bool);
}

// src/interface/ISchnorrApprovalRegistry.sol

/// @notice An aggregate Schnorr quorum signature and the reference block it is checked at.
struct QuorumSignature {
    uint256 s;
    address Raddr;
    address[] nonSigners;
    uint256 refBlock;
}

/// @title ISchnorrApprovalRegistry
/// @notice Per-transaction root approvals for nested settlement. The root of a nested tree
///         is verified once, and every frame of the tree checks the cached approval in its own
///         registry instead of re-verifying the signature.
/// @dev Kept separate from `ISchnorrStakeRegistry` so consumers that never nest, and the
///      mocks they are tested against, see no new surface.
interface ISchnorrApprovalRegistry is ISchnorrStakeRegistry {
    error ApprovalExpired(uint256 expiryBlock);
    error InvalidExpiryProof();
    error InvalidApprovalSignature();

    /// @notice Verify a quorum signature over `root` and approve it for the rest of this
    ///         transaction.
    /// @dev Reverts unless the signature verifies exactly as `isValidSignature` would, the
    ///      expiry leaf for `(rootContract, expiryBlock)` is in the tree, and the expiry has not
    ///      passed. A repeat call re-runs every check but keeps the first approved `refBlock`.
    /// @param root         the signed Merkle root.
    /// @param rootContract the contract whose tree entrypoint settles the root.
    /// @param expiryBlock  the last block at which the tree may settle.
    /// @param expiryProof  Merkle proof of the expiry leaf.
    /// @param sig          the quorum signature over `root`.
    function verifyAndApprove(
        bytes32 root,
        address rootContract,
        uint256 expiryBlock,
        bytes32[] calldata expiryProof,
        QuorumSignature calldata sig
    ) external;

    /// @notice Whether `root` was approved earlier in this transaction, and at which reference
    ///         block.
    /// @dev Reports unapproved once an operator-set change has moved `effectiveBlock` past the
    ///      approved `refBlock`, so a mid-transaction mutation fails closed.
    function approvedRefBlock(bytes32 root) external view returns (bool approved, uint256 refBlock);
}

// src/interface/IGasKillerNested.sol

/// @notice Everything the root contract needs to settle a nested tree.
/// @param root            the signed Merkle root.
/// @param expiryBlock     the last block at which the tree may settle.
/// @param expiryProof     Merkle proof of the expiry leaf.
/// @param sig             the quorum signature over `root`.
/// @param transitionIndex expected `stateTransitionCount() - 1` of the root contract.
/// @param targetFunction  selector bound into the root leaf.
/// @param storageUpdates  the root frame's program.
/// @param proof           Merkle proof of the root leaf.
/// @param children        one `abi.encode(NestedFrames.Witness)` per `NESTED` op in the root
///                        frame's program, in program order.
struct TreeSubmission {
    bytes32 root;
    uint256 expiryBlock;
    bytes32[] expiryProof;
    QuorumSignature sig;
    uint256 transitionIndex;
    bytes4 targetFunction;
    bytes storageUpdates;
    bytes32[] proof;
    bytes[] children;
}

/// @title IGasKillerNested
/// @notice Nested settlement: one quorum signature over a Merkle root authorizes a tree of
///         frames across SDK-enabled contracts, each applied by the contract it belongs to.
/// @dev An ERC-165 extension separate from `IGasKillerSDK`, whose interface ID must stay equal
///      to the `verifyAndUpdate` selector the router probes.
interface IGasKillerNested {
    error NotApproved(bytes32 root);
    error LeafMismatch(bytes32 expected, bytes32 computed);
    error NotPendingChild(address parent, bytes32 leaf);
    error NotTreeMember(bytes32 leaf);

    /// @notice Settle a tree whose root frame belongs to this contract.
    function verifyAndUpdateTree(TreeSubmission calldata submission) external payable;

    /// @notice Apply this contract's frame of an approved tree. Called by the frame's signed
    ///         parent while it executes the `NESTED` op that names this frame.
    /// @param root         the approved root.
    /// @param expectedLeaf the leaf hash the parent's signed program names.
    /// @param witness      `abi.encode(NestedFrames.Witness)` for this frame.
    function applyNested(bytes32 root, bytes32 expectedLeaf, bytes calldata witness) external payable;

    /// @notice The leaf of the child this contract is calling right now, or zero.
    function pendingChild() external view returns (bytes32);
}
