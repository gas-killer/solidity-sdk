// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {SchnorrVerify} from "./libraries/SchnorrVerify.sol";
import {ISchnorrOperatorRegistry} from "./interface/ISchnorrOperatorRegistry.sol";
import {ISchnorrNonceRegistry} from "./interface/ISchnorrNonceRegistry.sol";

/// @title SchnorrNonceRegistry
/// @notice On-chain commitment registry for **pre-committed MuSig2 nonce batches** — the
///         piece that makes aggregate-Schnorr signing non-interactive (the off-chain half
///         lives in the `gas-killer/service` repo, `docs/schnorr-nonce-registry.md`).
///         Operators commit a Merkle root per batch of nonce *points*; the full points
///         travel p2p and peers verify them against these roots. The chain never stores,
///         opens, or verifies a nonce point.
///
/// @dev Design invariants:
///      * **Append-only, contiguous coverage**: batch `k` covers
///        `[end(k-1), end(k-1) + count)` with batch 0 starting at slot 0. Registered
///        coverage is immutable, so reads at any block are stable and no
///        `effectiveBlock`-style watermark is needed (unlike the stake registry).
///      * **Cryptographic authentication, not `msg.sender`**: a registration carries a
///        single-key Schnorr signature by the operator key over [`batchMessage`], which
///        binds `(chainid, this registry, operator, batchIndex, startSlot, count, root)` —
///        anyone may relay the transaction; replay across deployments/chains or positions
///        is impossible.
///      * Only keys registered in the `SchnorrStakeRegistry` (which enforces a proof of
///        possession) may commit batches.
contract SchnorrNonceRegistry is ISchnorrNonceRegistry {
    /// Domain tag for the registration message — must equal the Rust `NONCE_BATCH_TAG`.
    bytes internal constant BATCH_TAG = "gas-killer/schnorr/nonce-batch/v1";

    /// Hard cap on slots per batch (mirrors the Rust `MAX_BATCH_SLOTS`); bounds the
    /// p2p gossip size a single registration can demand.
    uint64 public constant MAX_BATCH_SLOTS = 1 << 20;

    struct Batch {
        bytes32 root; // Merkle root over the batch's nonce leaves
        uint64 startSlot; // first absolute slot covered
        uint64 count; // number of slots covered
    }

    /// @notice The operator/PoP registry gating who may commit batches.
    ISchnorrOperatorRegistry public immutable stakeRegistry;

    /// operator identity (`pointAddress` of its Schnorr key) → append-only batch list.
    mapping(address => Batch[]) public batches;

    error NotRegisteredOperator(address operatorId);
    error KeyMismatch();
    error ZeroCount();
    error CountTooLarge();
    error CoverageOverflow();
    error InvalidRegistrationSignature();
    error NotCovered(address operatorId, uint64 slot);

    constructor(ISchnorrOperatorRegistry _stakeRegistry) {
        stakeRegistry = _stakeRegistry;
    }

    /// @notice The identity address of a public-key point — same formula as
    ///         `SchnorrStakeRegistry.pointAddress`.
    function pointAddress(uint256 x, uint256 y) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(x, y)))));
    }

    /// @notice The message a batch registration must sign. `uint64` fields are 8-byte
    ///         big-endian under `abi.encodePacked` — the Rust `batch_message` mirrors
    ///         this byte-for-byte.
    function batchMessage(address operatorId, uint64 batchIndex, uint64 startSlot, uint64 count, bytes32 root)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(BATCH_TAG, block.chainid, address(this), operatorId, batchIndex, startSlot, count, root)
        );
    }

    /// @notice Commits the next nonce batch for the operator whose Schnorr key is `(x, y)`.
    /// @param x     operator pubkey x-coordinate (must be registered in the stake registry).
    /// @param y     operator pubkey y-coordinate.
    /// @param root  Merkle root over the batch's `(operator, slot, R1, R2)` leaves.
    /// @param count slots covered; the batch is assigned `[coverage, coverage + count)`.
    /// @param sigS  registration signature scalar `s`.
    /// @param sigR  registration signature nonce address `address(R)`.
    function registerBatch(uint256 x, uint256 y, bytes32 root, uint64 count, uint256 sigS, address sigR) external {
        if (count == 0) revert ZeroCount();
        if (count > MAX_BATCH_SLOTS) revert CountTooLarge();

        address operatorId = pointAddress(x, y);
        {
            // An exit tombstone keeps `x`/`y` readable but clears `registered`, so an
            // exited operator can no longer extend its coverage — matching the stake
            // registry, where only `registered` governs membership.
            (uint256 rx, uint256 ry,, bool registered,) = stakeRegistry.operators(operatorId);
            if (!registered) revert NotRegisteredOperator(operatorId);
            // The identity address already binds (x, y); this guards against a stake
            // registry whose record diverges from the claimed key.
            if (rx != x || ry != y) revert KeyMismatch();
        }

        Batch[] storage list = batches[operatorId];
        uint64 batchIndex = uint64(list.length);
        uint64 startSlot = _coverage(list);
        if (startSlot > type(uint64).max - count) revert CoverageOverflow();

        if (!SchnorrVerify.verify(
                x, uint8(y & 1), batchMessage(operatorId, batchIndex, startSlot, count, root), sigS, sigR
            )) {
            revert InvalidRegistrationSignature();
        }

        list.push(Batch({root: root, startSlot: startSlot, count: count}));
        emit NonceBatchRegistered(operatorId, batchIndex, startSlot, count, root);
    }

    /// @inheritdoc ISchnorrNonceRegistry
    function coverage(address operatorId) external view returns (uint64) {
        return _coverage(batches[operatorId]);
    }

    /// @inheritdoc ISchnorrNonceRegistry
    function batchCount(address operatorId) external view returns (uint256) {
        return batches[operatorId].length;
    }

    /// @inheritdoc ISchnorrNonceRegistry
    function batchAt(address operatorId, uint64 slot)
        external
        view
        returns (uint64 batchIndex, bytes32 root, uint64 offset)
    {
        Batch[] storage list = batches[operatorId];
        uint256 n = list.length;
        if (n == 0 || slot >= _coverage(list)) revert NotCovered(operatorId, slot);

        // Binary search over contiguous, ascending [startSlot, startSlot + count) ranges.
        uint256 lo = 0;
        uint256 hi = n - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (slot >= list[mid].startSlot + list[mid].count) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        Batch storage batch = list[lo];
        return (uint64(lo), batch.root, slot - batch.startSlot);
    }

    /// @dev One past the last committed slot (0 for an empty list). Contiguity makes this
    ///      the last batch's end.
    function _coverage(Batch[] storage list) internal view returns (uint64) {
        uint256 n = list.length;
        if (n == 0) return 0;
        Batch storage last = list[n - 1];
        return last.startSlot + last.count;
    }
}
