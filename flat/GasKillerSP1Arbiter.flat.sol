// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

// src/commitments/interfaces/ICommitmentsMinimal.sol

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

// src/schnorr/interface/ISchnorrStakeRegistry.sol

/// @title ISchnorrStakeRegistry
/// @notice Verification surface the `SchnorrGasKillerSDK` depends on. Kept minimal (and
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

// src/schnorr/libraries/SchnorrVerify.sol

/// @title SchnorrVerify
/// @notice Constant-gas verification of an aggregate secp256k1 Schnorr signature using the
///         audited Chronicle/MakerDAO "Scribe" `ecrecover` trick — the EVM performs **one**
///         `ecrecover` and no elliptic-curve scalar multiplication.
/// @dev The signing/verification convention is fixed and must match the Rust signer
///      (`common/src/schnorr`) byte-for-byte:
///
///        e = keccak256(Xx ‖ Xparity ‖ message ‖ Raddr) mod n      (Xparity a single 0/1 byte)
///        s = k − e·x (mod n)   ⇒   R = s·G + e·X
///        verify: ecrecover(−s·Xx mod n, 27+Xparity, Xx, e·Xx mod n) == Raddr
library SchnorrVerify {
    /// secp256k1 group order `n`.
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// @notice Verifies `sig = (s, Raddr)` over `message` against the aggregate key
    ///         `(Xx, Xparity)`.
    /// @param Xx        x-coordinate of the aggregate public key `X` (must be `< n`).
    /// @param Xparity   y-parity of `X`: `0` if even, `1` if odd.
    /// @param message   the 32-byte signed message (the task digest).
    /// @param s         the aggregate response scalar (`0 < s < n`).
    /// @param Raddr     `address(R)` — the nonce point's Ethereum address (non-zero).
    /// @return ok       true iff the signature is valid.
    function verify(uint256 Xx, uint8 Xparity, bytes32 message, uint256 s, address Raddr)
        internal
        pure
        returns (bool ok)
    {
        // Scribe validity domain: Xx a usable `r` (< n and non-zero), canonical s, real R,
        // and a defined parity bit.
        if (Xx == 0 || Xx >= N) return false;
        if (s == 0 || s >= N) return false;
        if (Raddr == address(0)) return false;
        if (Xparity > 1) return false;

        uint256 e = uint256(keccak256(abi.encodePacked(Xx, Xparity, message, Raddr))) % N;
        if (e == 0) return false;

        // h = −s·Xx (mod n) ; sp = e·Xx (mod n). Both non-zero because s,e,Xx ∈ (0,n), n prime.
        uint256 sXx = mulmod(s, Xx, N);
        if (sXx == 0) return false;
        bytes32 h = bytes32(N - sXx);
        bytes32 sp = bytes32(mulmod(e, Xx, N));

        address recovered = ecrecover(h, Xparity == 0 ? 27 : 28, bytes32(Xx), sp);
        return recovered != address(0) && recovered == Raddr;
    }
}

// src/schnorr/libraries/Secp256k1.sol

/// @title Secp256k1
/// @notice Minimal affine secp256k1 point arithmetic over the base field, used by
///         `SchnorrStakeRegistry` to maintain the aggregate operator public key and to
///         subtract non-signers from it. The identity (point at infinity) is represented
///         as `(0, 0)`.
/// @dev Signature *verification* does not use this library — that goes through the
///      `ecrecover` trick in `SchnorrVerify`. Point math is only needed for aggregation
///      (register/deregister) and per-non-signer subtraction at verify time (zero cost at
///      full participation). Modular inversion uses the `modexp` (0x05) precompile.
library Secp256k1 {
    /// secp256k1 base field prime `p`.
    uint256 internal constant P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    /// secp256k1 curve constant `b` (a = 0).
    uint256 internal constant B = 7;

    error NotOnCurve();

    /// @notice `y² == x³ + 7 (mod p)` with `0 < x,y < p`.
    function isOnCurve(uint256 x, uint256 y) internal pure returns (bool) {
        if (x == 0 || y == 0 || x >= P || y >= P) return false;
        uint256 lhs = mulmod(y, y, P);
        uint256 rhs = addmod(mulmod(mulmod(x, x, P), x, P), B, P);
        return lhs == rhs;
    }

    /// @notice The negation `-P = (x, p - y)` (identity maps to identity).
    function negate(uint256 x, uint256 y) internal pure returns (uint256, uint256) {
        if (x == 0 && y == 0) return (0, 0);
        return (x, P - y);
    }

    /// @notice Affine point addition `(x1,y1) + (x2,y2)`, handling identities, doubling and
    ///         the `P + (-P) = O` case.
    function add(uint256 x1, uint256 y1, uint256 x2, uint256 y2) internal view returns (uint256 x3, uint256 y3) {
        if (x1 == 0 && y1 == 0) return (x2, y2);
        if (x2 == 0 && y2 == 0) return (x1, y1);

        uint256 lambda;
        if (x1 == x2) {
            // Same x: either doubling (y1 == y2) or inverse (y1 == p - y2 → identity).
            if (addmod(y1, y2, P) == 0) return (0, 0);
            // lambda = 3·x1² / (2·y1)
            uint256 num = mulmod(3, mulmod(x1, x1, P), P);
            uint256 den = mulmod(2, y1, P);
            lambda = mulmod(num, _inv(den), P);
        } else {
            // lambda = (y2 - y1) / (x2 - x1)
            uint256 num = _sub(y2, y1);
            uint256 den = _sub(x2, x1);
            lambda = mulmod(num, _inv(den), P);
        }
        // x3 = lambda² - x1 - x2
        x3 = _sub(_sub(mulmod(lambda, lambda, P), x1), x2);
        // y3 = lambda·(x1 - x3) - y1
        y3 = _sub(mulmod(lambda, _sub(x1, x3), P), y1);
    }

    /// @notice Point subtraction `(x1,y1) - (x2,y2)`.
    function sub(uint256 x1, uint256 y1, uint256 x2, uint256 y2) internal view returns (uint256, uint256) {
        (uint256 nx, uint256 ny) = negate(x2, y2);
        return add(x1, y1, nx, ny);
    }

    /// @notice `(a - b) mod p` for `a, b < p`.
    function _sub(uint256 a, uint256 b) private pure returns (uint256) {
        return addmod(a, P - b, P);
    }

    /// @notice Modular inverse `a^(p-2) mod p` via the `modexp` precompile (0x05).
    function _inv(uint256 a) private view returns (uint256 result) {
        uint256 p = P;
        uint256 expo = P - 2;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x20) // len(base)
            mstore(add(ptr, 0x20), 0x20) // len(exp)
            mstore(add(ptr, 0x40), 0x20) // len(mod)
            mstore(add(ptr, 0x60), a)
            mstore(add(ptr, 0x80), expo)
            mstore(add(ptr, 0xa0), p)
            if iszero(staticcall(gas(), 0x05, ptr, 0xc0, ptr, 0x20)) { revert(0, 0) }
            result := mload(ptr)
        }
    }
}

// src/schnorr/SchnorrStakeRegistry.sol

/// @title SchnorrStakeRegistry
/// @notice Stake registry for the **aggregate Schnorr** quorum scheme — the Schnorr
///         equivalent of EigenLayer's `ECDSAStakeRegistry`. Instead of verifying `N`
///         individual signatures, it maintains a watermark-snapshotted **aggregate**
///         operator public key `X_all = Σ X_i` (a single current value, not a per-block
///         history) and verifies a single aggregate signature against
///         `X_agg = X_all − Σ non-signers` in constant gas.
///
/// @dev Mirrors the "aggressive snapshot" registry-cache design from the ECDSA gas-opt
///      work (service #311): a `_effectiveBlock` watermark records the last operator-set
///      mutation, and verification is **fail-closed** — it requires
///      `refBlock >= _effectiveBlock` so the cached aggregate/weights are guaranteed equal
///      to their historical values at `refBlock`. Plain (linear) key aggregation is safe
///      here only because registration requires a **proof of possession**, which defeats
///      rogue-key attacks (the same guarantee `BLSApkRegistry` enforces for BLS).
///
///      This is a self-contained implementation (no EigenLayer base classes) so the whole
///      verify + subtraction + threshold path is unit-testable; production would layer the
///      operator/AVS registration lifecycle on top, exactly as `ECDSAStakeRegistry` does.
///
///      **The operator set must be quiescent relative to a signing round.** Because only the
///      current aggregate is stored, every operator-set mutation invalidates any signature an
///      off-chain round has already assembled against the prior set — see `isValidSignature` for
///      the two ways that surfaces. Registration and deregistration are equally affected. The
///      cost is a retry, not a soundness risk: the failure mode is a rejected signature, never
///      acceptance of one that no current-set quorum endorsed.
///
///      `announceRegister` / `announceDeregister` exist to make that quiescence checkable rather
///      than assumed. A change announced now applies only after `noticeWindow` blocks, so
///      `nextPossibleMutationBlock()` tells an off-chain round how long the set it assembled
///      against will remain the set that verifies it. `registerOperator` and
///      `deregisterOperator` bypass the window for bootstrap and emergencies and emit
///      `ForcedMutation`; consumers should treat that event, and any
///      `OperatorRegistered` / `OperatorDeregistered` without a preceding announcement, as
///      "re-snapshot required".
///
///      A mutation also changes *what counts as* a quorum, because the threshold is measured
///      against the current `totalWeight`. Removing an operator can turn a signature holding
///      less than the threshold share of the old set into a valid quorum of the smaller one —
///      correctly, since the remaining signers do carry that share. What binds a signature to
///      one specific signer set is the aggregate match (`X_all − Σ non-signers` must equal the
///      key that signed), not the watermark: advancing `effectiveBlock` does not restrict which
///      quorums are acceptable, it guarantees the cached aggregate and weights are the ones in
///      force at `refBlock` so the registry never answers for a snapshot it no longer holds.
contract SchnorrStakeRegistry is ISchnorrStakeRegistry {
    /// Domain tag for the proof-of-possession message — must equal the Rust `POP_TAG`.
    bytes internal constant POP_TAG = "gas-killer/schnorr/pop/v1";

    struct Operator {
        uint256 x; // pubkey x
        uint256 y; // pubkey y
        // `weight`, `registered` and `exitBlock` share a slot (96 + 8 + 48 bits): the
        // verification loop reads a non-signer's whole record, so packing saves one cold SLOAD
        // per non-signer. uint96 matches EigenLayer's stake-weight width.
        uint96 weight; // stake weight
        bool registered; // in the active set — the only field the verification loop consults
        uint48 exitBlock; // block of the operator's most recent exit; 0 if it has never exited
    }

    /// @notice operator Ethereum address (= address of its pubkey point) → operator record.
    /// @dev An exited operator's record is retained as a tombstone rather than deleted: `x`, `y`,
    ///      `weight` and `exitBlock` stay readable so the identity remains attributable after it
    ///      leaves the set, which a fraud proof settled after the exit needs. Only `registered`
    ///      governs membership, so a tombstone is inert for verification — it is not in `X_all`,
    ///      not counted in `totalWeight`, and rejected as a non-signer. Re-registration
    ///      overwrites the record wholesale, clearing `exitBlock`.
    mapping(address => Operator) public operators;

    /// A scheduled operator-set change: announced now, applicable from `eligibleBlock`.
    struct PendingChange {
        ChangeKind kind;
        uint48 eligibleBlock;
        address operator; // identity (`pointAddress(x, y)`)
        uint256 x; // register only
        uint256 y; // register only
        uint96 weight; // register only
    }

    enum ChangeKind {
        Register,
        Deregister
    }

    /// Running aggregate public key `X_all = Σ X_i` (identity = `(0,0)`).
    uint256 public aggX;
    uint256 public aggY;
    /// Total registered stake weight.
    uint256 public totalWeight;
    /// Block of the last operator-set mutation (verification fail-closes below this).
    uint256 public effectiveBlock;

    // The verification hot path reads `operators`, `aggX`, `aggY`, `totalWeight` and
    // `effectiveBlock`; they are declared first so scheduling state cannot displace them.

    /// FIFO of announced-but-unapplied changes, `[pendingHead, pendingTail)`.
    ///
    /// `eligibleBlock` is non-decreasing in announcement order, so the head is the earliest block
    /// at which the operator set can next change. Cancelling out of the middle leaves a zeroed
    /// hole; `pendingHead` is always kept on a live entry (or equal to `pendingTail`) so reading
    /// the horizon stays a single storage load. A live entry's `operator` is never the zero
    /// address — it is either `pointAddress` of a key with a verified proof of possession, or an
    /// identity that had to be `registered` to be queued for removal — so zero marks a hole
    /// unambiguously.
    mapping(uint256 => PendingChange) public pendingChanges;
    uint256 public pendingHead;
    uint256 public pendingTail;
    /// Queue position of an identity's announced change, stored one-based so that zero means
    /// "nothing queued". Keeps both the duplicate-announcement check and cancelling a specific
    /// identity's change O(1), wherever it sits in the queue.
    mapping(address => uint256) public pendingChangeIndex;
    /// Live entries in the queue. Tracked rather than derived from `pendingTail - pendingHead`,
    /// which counts the holes a mid-queue cancellation leaves behind.
    uint256 internal pendingLive;

    /// Threshold as a fraction `num/den` of total weight required to sign (e.g. 2/3).
    uint256 public immutable thresholdNum;
    uint256 public immutable thresholdDen;

    /// @notice Blocks that must pass between announcing a change and applying it.
    /// @dev Must exceed the longest window a settlement can span — the signing round's duration
    ///      plus the consumer's `blockStaleMeasure` — or a round can still be assembled under one
    ///      operator set and settled under another. That bound lives on each consumer contract
    ///      and is adjustable there, while one registry may back several consumers, so the
    ///      registry cannot check the relationship; sizing this correctly is a deployment
    ///      responsibility.
    uint256 public immutable noticeWindow;

    /// @notice The registry owner, allowed to register operators (stands in for the
    ///         EigenLayer registration lifecycle).
    address public immutable owner;

    error NotOwner();
    error AlreadyRegistered();
    error NotOnCurve();
    error InvalidProofOfPossession();
    error NotRegistered(address operator);
    error NonSignersNotSorted();
    error FutureReferenceBlock();
    error StaleSnapshot();
    error ZeroWeight();
    error WeightOverflow();
    error ChangeAlreadyPending(address operator);
    error NoPendingChange();
    error NoticeWindowNotElapsed(uint256 eligibleBlock);
    error NoticeWindowTooLarge();

    event OperatorRegistered(address indexed operator, uint256 weight);
    event OperatorDeregistered(address indexed operator, uint256 weight);
    event OperatorWeightUpdated(address indexed operator, uint256 oldWeight, uint256 newWeight);
    event ChangeAnnounced(uint256 indexed index, ChangeKind kind, address indexed operator, uint256 eligibleBlock);
    event ChangeCancelled(uint256 indexed index, address indexed operator);
    /// Emitted when a change bypasses the notice window via the forced path.
    event ForcedMutation(address indexed operator);

    /// Upper bound on `noticeWindow`. Keeping both terms of `block.number + noticeWindow` under
    /// half of `uint48` means `eligibleBlock` cannot wrap when narrowed — a wrapped value would
    /// land in the past and make a change committable immediately, defeating the window. The
    /// bound is ~1.4e14 blocks, so it constrains nothing reachable.
    uint256 internal constant MAX_NOTICE_WINDOW = uint256(type(uint48).max) / 2;

    constructor(uint256 _thresholdNum, uint256 _thresholdDen, address _owner, uint256 _noticeWindow) {
        require(_thresholdDen != 0 && _thresholdNum <= _thresholdDen, "bad threshold");
        if (_noticeWindow > MAX_NOTICE_WINDOW) revert NoticeWindowTooLarge();
        thresholdNum = _thresholdNum;
        thresholdDen = _thresholdDen;
        owner = _owner;
        noticeWindow = _noticeWindow;
        effectiveBlock = block.number;
    }

    /// @dev The check is wrapped rather than inlined in the modifier body so the revert is emitted
    ///      once instead of at every call site.
    function _checkOwner() private view {
        if (msg.sender != owner) revert NotOwner();
    }

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /// @notice The Ethereum address of a public-key point (`keccak256(x‖y)[12:]`). This is
    ///         the operator identity used to look up non-signers.
    function pointAddress(uint256 x, uint256 y) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(x, y)))));
    }

    /// @notice The proof-of-possession message for an operator identity.
    function popMessage(address operator) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(POP_TAG, operator));
    }

    // ---------------------------------------------------------------------------------------
    // Scheduled operator-set changes
    //
    // Every mutation invalidates a signature already assembled against the prior set (see
    // `isValidSignature`). Announcing a change ahead of time gives an off-chain round a horizon
    // it can rely on: while `nextPossibleMutationBlock()` is beyond the block a settlement will
    // land in, the set it assembled against is still the set that will verify it. The horizon is
    // a guarantee for this path only — `forceRegisterOperator` / `forceDeregisterOperator` bypass
    // it — so the fail-closed watermark remains the backstop rather than the primary defence.
    // ---------------------------------------------------------------------------------------

    /// @notice Announce a registration, applicable once the notice window has elapsed.
    /// @dev The key is fully validated here — curve membership, weight bounds and proof of
    ///      possession — so an unusable announcement cannot sit in the queue and stall the
    ///      horizon. Nothing is added to `X_all` until the change is committed, so the announced
    ///      operator must not sign until then; its key would not be in the aggregate.
    /// @param x       pubkey x-coordinate.
    /// @param y       pubkey y-coordinate.
    /// @param weight  stake weight to credit on commit.
    /// @param popS    PoP signature scalar `s`.
    /// @param popR    PoP nonce address `address(R)`.
    /// @return index  queue position of the announced change.
    function announceRegister(uint256 x, uint256 y, uint256 weight, uint256 popS, address popR)
        external
        onlyOwner
        returns (uint256 index)
    {
        address id = _validateRegistration(x, y, weight, popS, popR);

        // casting to 'uint96' is safe: bounds-checked against type(uint96).max above
        // forge-lint: disable-next-line(unsafe-typecast)
        return _enqueue(ChangeKind.Register, id, x, y, uint96(weight));
    }

    /// @notice Announce a deregistration, applicable once the notice window has elapsed.
    /// @dev The operator stays in `X_all` and in `totalWeight` for the whole window and is
    ///      expected to keep signing. If it goes dark early the non-signer path absorbs its
    ///      absence, but its weight still counts toward the threshold denominator until the
    ///      change is committed — so announcing exits faster than the set can absorb them is a
    ///      liveness risk, not a safety one.
    /// @param operator  the operator identity (`pointAddress(x, y)`) to remove on commit.
    /// @return index    queue position of the announced change.
    function announceDeregister(address operator) external onlyOwner returns (uint256 index) {
        if (!operators[operator].registered) revert NotRegistered(operator);
        return _enqueue(ChangeKind.Deregister, operator, 0, 0, 0);
    }

    /// @notice Apply the oldest announced change once its notice window has elapsed.
    /// @dev Changes commit in announcement order. Because `eligibleBlock` is non-decreasing in
    ///      that order, the head of the queue is always the earliest possible mutation, which is
    ///      what makes `nextPossibleMutationBlock()` a single storage read rather than a scan.
    function commitNextChange() external onlyOwner {
        // Cancellation already leaves the head on a live entry, so this is a no-op in practice.
        // It runs before the head is read rather than after, so committing a cleared slot — which
        // would apply a zero-address, zero-weight change — cannot depend on that being true.
        _advancePastHoles();
        if (pendingHead == pendingTail) revert NoPendingChange();

        PendingChange memory change = pendingChanges[pendingHead];
        if (block.number < change.eligibleBlock) revert NoticeWindowNotElapsed(change.eligibleBlock);

        delete pendingChanges[pendingHead];
        delete pendingChangeIndex[change.operator];
        --pendingLive;
        ++pendingHead;
        _advancePastHoles();

        if (change.kind == ChangeKind.Register) {
            _applyRegister(change.operator, change.x, change.y, change.weight);
        } else {
            _applyDeregister(change.operator);
        }
    }

    /// @notice Drop the oldest announced change without applying it.
    /// @dev Only ever moves `nextPossibleMutationBlock()` later, never earlier, so it cannot
    ///      invalidate a round assembled against the horizon it published. Needed because an
    ///      abandoned announcement would otherwise pin the horizon and block every change behind
    ///      it in the queue.
    function cancelNextChange() external onlyOwner {
        if (pendingHead == pendingTail) revert NoPendingChange();
        _cancelAt(pendingHead);
    }

    /// @notice Drop a specific identity's announced change, wherever it sits in the queue.
    /// @dev Cancelling out of the middle leaves a hole rather than reordering, so the entries
    ///      around it keep both their positions and their `eligibleBlock`s — an unrelated
    ///      operator part-way through its notice window is not sent back to the start of it.
    ///
    ///      This is what keeps the forced paths usable: they refuse to act on an identity with a
    ///      queued change, and clearing that one entry no longer means cancelling everything
    ///      ahead of it. An emergency removal is `cancelChange(operator)` then
    ///      `deregisterOperator(operator)`, with no time gate between them.
    ///
    ///      Horizon-monotonic like `cancelNextChange`: removing a non-head entry leaves the
    ///      earliest `eligibleBlock` untouched, and removing the head can only move it later.
    /// @param operator  the identity whose announced change should be dropped.
    function cancelChange(address operator) external onlyOwner {
        uint256 oneBased = pendingChangeIndex[operator];
        if (oneBased == 0) revert NoPendingChange();
        _cancelAt(oneBased - 1);
    }

    /// @notice The earliest block at which the operator set can change, or `type(uint256).max`
    ///         when nothing is announced.
    /// @dev A settlement is safe from set-mutation invalidation while the block it lands in is
    ///      below this value. It is a bound on the *scheduled* path only; the forced path can
    ///      mutate at any block.
    function nextPossibleMutationBlock() external view returns (uint256) {
        if (pendingHead == pendingTail) return type(uint256).max;
        return pendingChanges[pendingHead].eligibleBlock;
    }

    /// @notice Number of announced changes not yet committed or cancelled.
    function pendingChangeCount() external view returns (uint256) {
        return pendingLive;
    }

    // ---------------------------------------------------------------------------------------
    // Forced operator-set changes
    // ---------------------------------------------------------------------------------------

    /// @notice Register an operator immediately, bypassing the notice window.
    /// @dev The path to use while bootstrapping a registry that does not yet back any consumer,
    ///      when there is no round to invalidate. Once the registry is live, prefer
    ///      `announceRegister`: this invalidates any signature already assembled against the
    ///      pre-registration aggregate — a newly registered key cannot contribute to a round
    ///      already under way, and its presence in `X_all` is enough to break one — and it does so
    ///      without the advance warning `announceRegister` gives, so consumers relying on
    ///      `nextPossibleMutationBlock()` will be caught out. `ForcedMutation` marks the bypass
    ///      for off-chain consumers.
    /// @param x       pubkey x-coordinate.
    /// @param y       pubkey y-coordinate.
    /// @param weight  stake weight to credit.
    /// @param popS    PoP signature scalar `s`.
    /// @param popR    PoP nonce address `address(R)`.
    function registerOperator(uint256 x, uint256 y, uint256 weight, uint256 popS, address popR) external onlyOwner {
        address id = _validateRegistration(x, y, weight, popS, popR);
        _requireNoScheduledChange(id);
        emit ForcedMutation(id);
        // casting to 'uint96' is safe: bounds-checked against type(uint96).max above
        // forge-lint: disable-next-line(unsafe-typecast)
        _applyRegister(id, x, y, uint96(weight));
    }

    /// @notice Deregister an operator immediately, bypassing the notice window.
    /// @dev The escape hatch for an operator that must leave the set at once — a compromised key
    ///      cannot wait out a notice window. Carries the same lack of advance warning as the
    ///      immediate registration path, so `announceDeregister` is the routine way to remove an
    ///      operator and this is the exception.
    /// @param operator  the operator identity (`pointAddress(x, y)`) to remove.
    function deregisterOperator(address operator) external onlyOwner {
        _requireNoScheduledChange(operator);
        emit ForcedMutation(operator);
        _applyDeregister(operator);
    }

    /// @notice Adjust a registered operator's stake weight in place, effective immediately.
    /// @dev Additive surface for stake-mirroring lifecycles (the Commitments adapter): a weight
    ///      change alters what counts as a quorum but leaves `X_all` intact, so an in-flight
    ///      round's signature stays *cryptographically* verifiable — the watermark still
    ///      advances, fail-closing settlements pinned to earlier reference blocks, because the
    ///      threshold denominator they were assembled against is no longer the one in force.
    ///      Bypasses the notice window like the forced paths and emits `ForcedMutation` so
    ///      consumers re-snapshot. A pending *deregistration* is compatible (its commit reads
    ///      the live weight); a pending registration is unreachable here since the identity is
    ///      not yet `registered`.
    /// @param operator   the operator identity (`pointAddress(x, y)`).
    /// @param newWeight  replacement stake weight; must be non-zero and fit `uint96` (use
    ///                   `deregisterOperator` to remove an operator, not a zero weight).
    function updateOperatorWeight(address operator, uint256 newWeight) external onlyOwner {
        if (newWeight == 0) revert ZeroWeight();
        if (newWeight > type(uint96).max) revert WeightOverflow();
        Operator storage op = operators[operator];
        if (!op.registered) revert NotRegistered(operator);

        uint256 oldWeight = op.weight;
        totalWeight = totalWeight - oldWeight + newWeight;
        // casting to 'uint96' is safe: bounds-checked against type(uint96).max above
        // forge-lint: disable-next-line(unsafe-typecast)
        op.weight = uint96(newWeight);
        effectiveBlock = block.number;

        emit ForcedMutation(operator);
        emit OperatorWeightUpdated(operator, oldWeight, newWeight);
    }

    // ---------------------------------------------------------------------------------------
    // Mutation internals
    // ---------------------------------------------------------------------------------------

    /// @dev Shared validation for both registration paths. Reverts unless the key is on the
    ///      curve, the weight fits `uint96` and is non-zero, the identity is not already in the
    ///      active set, and the proof of possession checks out.
    function _validateRegistration(uint256 x, uint256 y, uint256 weight, uint256 popS, address popR)
        private
        view
        returns (address id)
    {
        if (weight == 0) revert ZeroWeight();
        if (weight > type(uint96).max) revert WeightOverflow();
        if (!Secp256k1.isOnCurve(x, y)) revert NotOnCurve();

        id = pointAddress(x, y);
        if (operators[id].registered) revert AlreadyRegistered();

        // Proof of possession: a single-key Schnorr signature over popMessage(id), verified
        // against this very key. Without it, plain key aggregation would be rogue-key-forgeable.
        uint8 parity = uint8(y & 1);
        if (!SchnorrVerify.verify(x, parity, popMessage(id), popS, popR)) {
            revert InvalidProofOfPossession();
        }
    }

    /// @dev Clear one queue slot and keep `pendingHead` on a live entry.
    function _cancelAt(uint256 index) private {
        address operator = pendingChanges[index].operator;

        delete pendingChanges[index];
        delete pendingChangeIndex[operator];
        --pendingLive;

        emit ChangeCancelled(index, operator);

        _advancePastHoles();
    }

    /// @dev Restore the invariant that `pendingHead` addresses a live entry, so the horizon is a
    ///      single read and `commitNextChange` never lands on a cancelled slot. The loop only ever
    ///      walks holes the owner created, and each iteration permanently retires one queue slot.
    function _advancePastHoles() private {
        uint256 head = pendingHead;
        uint256 tail = pendingTail;
        while (head < tail && pendingChanges[head].operator == address(0)) {
            ++head;
        }
        pendingHead = head;
    }

    /// @dev The forced paths refuse to act on an identity that already has a queued change, so the
    ///      scheduled and forced paths can never both apply to it.
    ///
    ///      Without this rule an announced registration could be forced through first — an
    ///      announcement leaves `registered` false, so nothing in `_validateRegistration` would
    ///      object — and the still-queued entry would then apply the same key a second time on
    ///      commit, adding it to `X_all` and `totalWeight` twice. The mirror case, forcing a
    ///      deregistration that is already announced, would instead wedge the queue: the head
    ///      would revert `NotRegistered` on every commit and, because changes commit in order,
    ///      block everything behind it until cancelled.
    ///
    ///      An identity must therefore be committed or cancelled before it can be forced. That
    ///      also keeps the queue head valid by construction, since only `_applyRegister` and
    ///      `_applyDeregister` change membership and neither can now run behind the queue's back.
    function _requireNoScheduledChange(address operator) private view {
        if (pendingChangeIndex[operator] != 0) revert ChangeAlreadyPending(operator);
    }

    /// @dev Append a change to the FIFO and mark its identity as spoken for.
    function _enqueue(ChangeKind kind, address operator, uint256 x, uint256 y, uint96 weight)
        private
        returns (uint256 index)
    {
        if (pendingChangeIndex[operator] != 0) revert ChangeAlreadyPending(operator);

        // Cannot wrap: `noticeWindow` is bounded by MAX_NOTICE_WINDOW and a block number
        // approaching the other half of uint48 (~1.4e14) is unreachable.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 eligibleBlock = uint48(block.number + noticeWindow);

        index = pendingTail;
        pendingChangeIndex[operator] = index + 1;
        ++pendingLive;
        pendingChanges[index] =
            PendingChange({kind: kind, eligibleBlock: eligibleBlock, operator: operator, x: x, y: y, weight: weight});
        ++pendingTail;

        emit ChangeAnnounced(index, kind, operator, eligibleBlock);
    }

    /// @dev Add a validated key to the active set. Overwrites the record wholesale, which clears
    ///      any tombstone left by a previous exit.
    ///
    ///      The membership check is redundant against the callers — the forced path validates and
    ///      `_requireNoScheduledChange` keeps the queue head valid — but adding a key already in
    ///      `X_all` corrupts the aggregate irrecoverably, so the invariant is asserted where it is
    ///      relied on rather than only where it is currently established. `_applyDeregister`
    ///      carries the same check in the opposite direction.
    function _applyRegister(address id, uint256 x, uint256 y, uint96 weight) private {
        if (operators[id].registered) revert AlreadyRegistered();
        operators[id] = Operator({x: x, y: y, weight: weight, registered: true, exitBlock: 0});
        (aggX, aggY) = Secp256k1.add(aggX, aggY, x, y);
        totalWeight += weight;
        effectiveBlock = block.number;

        emit OperatorRegistered(id, weight);
    }

    /// @dev Remove an operator from the active set, leaving a tombstone behind. Subtracting the
    ///      key must read `op.x`/`op.y` before `registered` is cleared; the record is retained
    ///      rather than deleted so the identity stays attributable after the exit.
    function _applyDeregister(address operator) private {
        Operator storage op = operators[operator];
        if (!op.registered) revert NotRegistered(operator);

        uint256 weight = op.weight;
        (aggX, aggY) = Secp256k1.sub(aggX, aggY, op.x, op.y);
        totalWeight -= weight;
        effectiveBlock = block.number;

        op.registered = false;
        // A block number exceeding uint48 is unreachable (~2.8e14 blocks).
        // forge-lint: disable-next-line(unsafe-typecast)
        op.exitBlock = uint48(block.number);

        emit OperatorDeregistered(operator, weight);
    }

    /// @notice Verify an aggregate Schnorr signature for `message`, accounting for the
    ///         declared non-signers.
    /// @dev An operator-set mutation between the moment a round assembles its signature and the
    ///      moment the settlement is included makes that signature unusable. Which of two
    ///      failure modes a caller observes depends on when it pins `refBlock`:
    ///
    ///      - pinned **before** the mutation → `refBlock < effectiveBlock` and this reverts
    ///        `StaleSnapshot`.
    ///      - pinned **after** the mutation (the freshest-block strategy, `block.number - 1`) →
    ///        the watermark check passes, but the cached aggregate is no longer the one the
    ///        operators signed against, so verification fails and this returns `false`.
    ///
    ///      Both require the round to be re-assembled against the current set; neither can
    ///      admit a signature that was not valid for the set at `refBlock`.
    /// @param message     the signed 32-byte task digest.
    /// @param s           aggregate response scalar.
    /// @param Raddr       aggregate nonce address `address(R)`.
    /// @param nonSigners  operator identities that did NOT sign, strictly ascending.
    /// @param refBlock    reference block; must be `>= effectiveBlock` and `< block.number`.
    /// @return ok         true iff the quorum signed and the signature verifies.
    function isValidSignature(
        bytes32 message,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners,
        uint256 refBlock
    ) external view override returns (bool ok) {
        if (refBlock >= block.number) revert FutureReferenceBlock();
        // Fail-closed: the cached aggregate/weights only equal their value at refBlock when
        // no operator-set mutation happened after it.
        if (refBlock < effectiveBlock) revert StaleSnapshot();

        // Start from the full aggregate, subtract each non-signer's key and weight.
        uint256 xAgg = aggX;
        uint256 yAgg = aggY;
        uint256 signedWeight = totalWeight;

        address last = address(0);
        uint256 nonSignersLength = nonSigners.length;
        for (uint256 i = 0; i < nonSignersLength; ++i) {
            address ns = nonSigners[i];
            if (ns <= last) revert NonSignersNotSorted();
            last = ns;
            Operator storage op = operators[ns];
            if (!op.registered) revert NotRegistered(ns);
            (xAgg, yAgg) = Secp256k1.sub(xAgg, yAgg, op.x, op.y);
            signedWeight -= op.weight;
        }

        // Stake threshold: signedWeight/total >= num/den.
        if (signedWeight * thresholdDen < totalWeight * thresholdNum) return false;

        // If every operator is a non-signer the aggregate is the identity — reject.
        if (xAgg == 0 && yAgg == 0) return false;

        return SchnorrVerify.verify(xAgg, uint8(yAgg & 1), message, s, Raddr);
    }
}

// src/commitments/SchnorrCommitmentsAdapter.sol

/// @title SchnorrCommitmentsAdapter
/// @notice The operator-lifecycle authority for a `SchnorrStakeRegistry`, backed by the
///         Commitments protocol instead of EigenLayer. The registry's NatSpec anticipated
///         exactly this layer: "production would layer the operator/AVS registration
///         lifecycle on top, exactly as `ECDSAStakeRegistry` does" — this contract is that
///         layer, with Commitments `OperatorRegistry` stake as the source of truth.
///
///         The adapter is the registry's immutable `owner()`, so it must be deployed
///         BEFORE the registry (the registry's constructor takes the owner address) and
///         pointed at it with the one-shot `setRegistry`.
///
///         Responsibilities:
///           - `join` — a Commitments-registered operator publishes its Schnorr pubkey
///             (with proof of possession, validated by the registry), its BN254 p2p
///             identity, and its socket; the adapter mirrors it into the Schnorr registry
///             with a weight quantized from live Commitments stake.
///           - `syncWeight` — permissionless crank keeping registry weights equal to
///             quantized Commitments stake; drops operators whose stake fell below the
///             registry-side floor.
///           - `eject` — arbiter-only immediate removal (forced path, no notice window):
///             a proven-equivocating key leaves the signer set in the slash transaction,
///             so the >= 1-day forfeit challenge window delays money, not signing power.
///           - `leave` — operator-initiated exit, respecting the notice window when one
///             is configured.
///           - `getOperatorSet` — the single read the off-chain stack bootstraps from
///             (replaces the EigenLayer `EigenStakingClient` event scan).
///
/// @dev Weight quantization: `weight = stake / weightScale`, floored. Deployments that
///      want today's uniform-weight behavior set `weightScale = minOperatorStake` so every
///      minimum-staked operator maps to weight 1. Threshold math on the registry is
///      fractional (`signedWeight/totalWeight >= num/den`), so the scale cancels; only
///      sub-scale dust is uncounted.
///
///      Every registry mutation the adapter performs advances the registry's
///      `effectiveBlock`, transiently fail-closing settlements assembled against earlier
///      reference blocks. Cranks should therefore be driven off material stake changes
///      (delegation created/released/forfeited, `OperatorBelowMinStake`), not per block.
contract SchnorrCommitmentsAdapter {
    /// @notice The Commitments operator registry that is the stake source of truth.
    IOperatorRegistryMinimal public immutable operatorRegistry;

    /// @notice Divisor quantizing raw Commitments stake units into registry `uint96` weight.
    uint256 public immutable weightScale;

    /// @notice Bootstrap/emergency authority: wires the registry and arbiter, and can drive
    ///         the registry's owner surface directly if the mirror ever needs manual repair
    ///         (the registry's `owner` is immutable, so there is no ownership handoff to
    ///         fall back to).
    address public immutable admin;

    /// @notice The `SchnorrStakeRegistry` this adapter owns. One-shot.
    SchnorrStakeRegistry public registry;

    /// @notice The slashing arbiter allowed to call `eject`. One-shot.
    address public arbiter;

    /// @notice Off-chain node identity published at `join` time. The BN254 G2 key is the
    ///         commonware p2p identity; G1 accompanies it for engine-level verification;
    ///         `socket` is the dialable address. None of this is consulted on-chain — it is
    ///         the sidecar the off-chain bootstrap reads in one `eth_call`.
    struct NodeInfo {
        uint256 secpX;
        uint256 secpY;
        uint256[2] blsG1;
        uint256[4] blsG2;
        string socket;
    }

    struct OperatorView {
        address operator;
        uint256 weight; // live registry weight (0 when pending under a notice window)
        NodeInfo info;
    }

    mapping(address => NodeInfo) internal nodeInfo;
    /// Enumerable set of operators the adapter has joined (swap-and-pop on removal).
    address[] internal operatorList;
    /// One-based index into `operatorList`; zero means "not present".
    mapping(address => uint256) internal operatorIndex;

    error NotAdmin();
    error NotArbiter();
    error AlreadyWired();
    error NotWired();
    error ZeroAddress();
    error NotCommitmentsOperator(address operator);
    error KeyIsNotSender(address keyAddress, address sender);
    error StakeBelowScale(uint256 stake, uint256 scale);
    error NotJoined(address operator);

    event RegistryWired(address indexed registry);
    event ArbiterWired(address indexed arbiter);
    event OperatorJoined(address indexed operator, uint256 weight, bool announced);
    event OperatorLeft(address indexed operator, bool announced);
    event OperatorEjected(address indexed operator);
    event WeightSynced(address indexed operator, uint256 oldWeight, uint256 newWeight);
    event OperatorDropped(address indexed operator, uint256 stake);
    event NodeInfoUpdated(address indexed operator);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier whenWired() {
        if (address(registry) == address(0)) revert NotWired();
        _;
    }

    constructor(address _operatorRegistry, uint256 _weightScale, address _admin) {
        if (_operatorRegistry == address(0) || _admin == address(0)) revert ZeroAddress();
        require(_weightScale != 0, "zero scale");
        operatorRegistry = IOperatorRegistryMinimal(_operatorRegistry);
        weightScale = _weightScale;
        admin = _admin;
    }

    /// @notice Point the adapter at the registry it owns. One-shot: the registry is
    ///         constructed with this adapter as its immutable owner, so the deploy order is
    ///         adapter -> registry(owner = adapter) -> `setRegistry`.
    function setRegistry(address _registry) external onlyAdmin {
        if (address(registry) != address(0)) revert AlreadyWired();
        if (_registry == address(0)) revert ZeroAddress();
        registry = SchnorrStakeRegistry(_registry);
        emit RegistryWired(_registry);
    }

    /// @notice Wire the slashing arbiter allowed to `eject`. One-shot.
    function setArbiter(address _arbiter) external onlyAdmin {
        if (arbiter != address(0)) revert AlreadyWired();
        if (_arbiter == address(0)) revert ZeroAddress();
        arbiter = _arbiter;
        emit ArbiterWired(_arbiter);
    }

    // ---------------------------------------------------------------------------------------
    // Operator lifecycle
    // ---------------------------------------------------------------------------------------

    /// @notice Join the Schnorr signer set. Caller must be a registered Commitments operator
    ///         whose address IS the Ethereum address of the submitted Schnorr key (the same
    ///         identity invariant the off-chain node asserts at startup), with quantized
    ///         stake >= 1. Uses the immediate path when the registry has no notice window,
    ///         the announce queue otherwise (commit via `commitNext` once eligible).
    /// @param x       Schnorr (secp256k1) pubkey x-coordinate.
    /// @param y       Schnorr pubkey y-coordinate.
    /// @param popS    proof-of-possession scalar `s` over `registry.popMessage(operator)`.
    /// @param popR    proof-of-possession nonce address `address(R)`.
    /// @param blsG1   BN254 G1 public key (p2p/engine identity), affine coordinates.
    /// @param blsG2   BN254 G2 public key, affine coordinates (x.c1, x.c0, y.c1, y.c0 as
    ///                the commonware string-coordinate order expects).
    /// @param socket  dialable p2p socket, e.g. "node-1:3001".
    function join(
        uint256 x,
        uint256 y,
        uint256 popS,
        address popR,
        uint256[2] calldata blsG1,
        uint256[4] calldata blsG2,
        string calldata socket
    ) external whenWired {
        if (!operatorRegistry.isOperator(msg.sender)) revert NotCommitmentsOperator(msg.sender);
        address id = registry.pointAddress(x, y);
        if (id != msg.sender) revert KeyIsNotSender(id, msg.sender);

        uint256 weight = _quantizedStake(msg.sender);
        if (weight == 0) revert StakeBelowScale(operatorRegistry.getOperatorStake(msg.sender), weightScale);

        bool announced = registry.noticeWindow() != 0;
        if (announced) {
            registry.announceRegister(x, y, weight, popS, popR);
        } else {
            registry.registerOperator(x, y, weight, popS, popR);
        }

        nodeInfo[msg.sender] =
            NodeInfo({secpX: x, secpY: y, blsG1: blsG1, blsG2: blsG2, socket: socket});
        if (operatorIndex[msg.sender] == 0) {
            operatorList.push(msg.sender);
            operatorIndex[msg.sender] = operatorList.length;
        }

        emit OperatorJoined(msg.sender, weight, announced);
    }

    /// @notice Refresh the published p2p sidecar (socket move, key rotation happens via
    ///         leave + rejoin since the Schnorr key is the identity).
    function updateNodeInfo(uint256[2] calldata blsG1, uint256[4] calldata blsG2, string calldata socket)
        external
    {
        if (operatorIndex[msg.sender] == 0) revert NotJoined(msg.sender);
        NodeInfo storage info = nodeInfo[msg.sender];
        info.blsG1 = blsG1;
        info.blsG2 = blsG2;
        info.socket = socket;
        emit NodeInfoUpdated(msg.sender);
    }

    /// @notice Voluntary exit from the signer set. Respects the notice window when one is
    ///         configured (capital exit is separate: `requestUnbond` on the manager).
    function leave() external whenWired {
        if (operatorIndex[msg.sender] == 0) revert NotJoined(msg.sender);

        bool announced = registry.noticeWindow() != 0 && _isRegistered(msg.sender);
        if (announced) {
            registry.announceDeregister(msg.sender);
            // Sidecar is kept until the change commits; `syncWeight` cleans up after.
        } else {
            _forceRemove(msg.sender);
        }
        emit OperatorLeft(msg.sender, announced);
    }

    /// @notice Apply the oldest announced registry change once eligible. Permissionless
    ///         passthrough of `commitNextChange`; cleans the sidecar up when the committed
    ///         change was a deregistration.
    function commitNext() external whenWired {
        registry.commitNextChange();
        // A committed deregistration leaves a joined-but-unregistered operator; sweep it.
        uint256 n = operatorList.length;
        for (uint256 i = 0; i < n;) {
            address op = operatorList[i];
            if (!_isRegistered(op) && registry.pendingChangeIndex(op) == 0) {
                _removeFromList(op);
                n--;
                continue; // swapped element now occupies slot i
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Immediate forced removal of a proven-misbehaving operator — arbiter-only.
    ///         Clears any queued change first (targeted cancel), then force-deregisters,
    ///         with no time gate between them. Idempotent for already-removed operators so
    ///         a slash transaction can never fail on the ejection leg.
    function eject(address operator) external whenWired {
        if (msg.sender != arbiter && msg.sender != admin) revert NotArbiter();
        _forceRemove(operator);
        emit OperatorEjected(operator);
    }

    /// @notice Permissionless crank reconciling one operator's registry weight with its
    ///         live Commitments stake. Deregisters operators that stopped being
    ///         Commitments-registered or whose quantized stake hit zero.
    function syncWeight(address operator) external whenWired {
        if (!_isRegistered(operator)) {
            // Nothing mirrored (or pending under notice window) — only sweep the sidecar
            // if Commitments no longer recognizes the operator and nothing is queued.
            if (
                operatorIndex[operator] != 0 && !operatorRegistry.isOperator(operator)
                    && registry.pendingChangeIndex(operator) == 0
            ) {
                _removeFromList(operator);
                emit OperatorDropped(operator, 0);
            }
            return;
        }

        if (!operatorRegistry.isOperator(operator)) {
            _forceRemove(operator);
            emit OperatorDropped(operator, 0);
            return;
        }

        uint256 stake = operatorRegistry.getOperatorStake(operator);
        uint256 newWeight = stake / weightScale;
        if (newWeight == 0) {
            _forceRemove(operator);
            emit OperatorDropped(operator, stake);
            return;
        }

        (,, uint96 current,,) = registry.operators(operator);
        if (newWeight != current) {
            registry.updateOperatorWeight(operator, newWeight);
            emit WeightSynced(operator, current, newWeight);
        }
    }

    // ---------------------------------------------------------------------------------------
    // Admin escape hatch
    //
    // The registry's `owner` is immutable, so if the mirror logic is ever wrong the fix
    // cannot be "hand ownership back to an EOA". Instead the admin can drive the owner
    // surface directly. Bootstrap flows may also use these before Commitments state exists.
    // ---------------------------------------------------------------------------------------

    function adminRegister(uint256 x, uint256 y, uint256 weight, uint256 popS, address popR)
        external
        onlyAdmin
        whenWired
    {
        registry.registerOperator(x, y, weight, popS, popR);
    }

    function adminDeregister(address operator) external onlyAdmin whenWired {
        registry.deregisterOperator(operator);
        if (operatorIndex[operator] != 0) _removeFromList(operator);
    }

    function adminCancelChange(address operator) external onlyAdmin whenWired {
        registry.cancelChange(operator);
    }

    function adminUpdateWeight(address operator, uint256 weight) external onlyAdmin whenWired {
        registry.updateOperatorWeight(operator, weight);
    }

    // ---------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------

    /// @notice The full operator set with p2p sidecar and live registry weights — the one
    ///         read the off-chain bootstrap needs. Operators queued behind a notice window
    ///         report weight 0 until their registration commits.
    function getOperatorSet() external view returns (OperatorView[] memory set) {
        uint256 n = operatorList.length;
        set = new OperatorView[](n);
        for (uint256 i = 0; i < n; ++i) {
            address op = operatorList[i];
            uint256 weight = 0;
            if (address(registry) != address(0)) {
                (,, uint96 w, bool reg,) = registry.operators(op);
                weight = reg ? w : 0;
            }
            set[i] = OperatorView({operator: op, weight: weight, info: nodeInfo[op]});
        }
    }

    function getOperatorCount() external view returns (uint256) {
        return operatorList.length;
    }

    function getNodeInfo(address operator) external view returns (NodeInfo memory) {
        return nodeInfo[operator];
    }

    /// @notice Quantized live Commitments stake for `operator` (the weight `syncWeight`
    ///         would mirror).
    function quantizedStake(address operator) external view returns (uint256) {
        return _quantizedStake(operator);
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    function _quantizedStake(address operator) internal view returns (uint256) {
        return operatorRegistry.getOperatorStake(operator) / weightScale;
    }

    function _isRegistered(address operator) internal view returns (bool) {
        (,,, bool reg,) = registry.operators(operator);
        return reg;
    }

    /// @dev Forced removal: clear any queued change (the forced paths refuse to act on an
    ///      identity with one), deregister if currently in the set, and drop the sidecar.
    ///      Never reverts for an operator that is already gone.
    function _forceRemove(address operator) internal {
        if (registry.pendingChangeIndex(operator) != 0) {
            registry.cancelChange(operator);
        }
        if (_isRegistered(operator)) {
            registry.deregisterOperator(operator);
        }
        if (operatorIndex[operator] != 0) {
            _removeFromList(operator);
        }
    }

    function _removeFromList(address operator) internal {
        uint256 oneBased = operatorIndex[operator];
        uint256 last = operatorList.length;
        if (oneBased != last) {
            address moved = operatorList[last - 1];
            operatorList[oneBased - 1] = moved;
            operatorIndex[moved] = oneBased;
        }
        operatorList.pop();
        delete operatorIndex[operator];
        delete nodeInfo[operator];
    }
}

// src/commitments/GasKillerSP1Arbiter.sol

/// @title GasKillerSP1Arbiter
/// @notice The Commitments arbiter for Gas Killer slashing: an SP1 fraud proof (an operator
///         signed a task result that faithful re-execution contradicts) authorizes opening
///         two-phase forfeits against the operator's stake commitments, and ejects the
///         operator's key from the Schnorr signer set in the same transaction. The
///         >= 1-day forfeit challenge window therefore delays only the capital slash —
///         a proven-equivocating key stops counting toward quorums immediately.
///
///         The contract is a non-upgradeable shell per Commitments arbiter doctrine, with
///         one deliberate mutable slot: the SP1 program vkey, behind a guardian-proposed
///         timelock at least as long as the unbonding path, so every operator can observe
///         a hostile vkey proposal and fully exit before it could slash them. This is the
///         escape from `OperatorRegistry.requiredArbiter` being immutable while the SP1
///         guest program evolves.
///
/// @dev Deploy order (the registry bakes this address in immutably): deploy the arbiter
///      first with `operatorRegistry`/`adapter` unset, initialize the Commitments
///      `OperatorRegistry` with this address as `requiredArbiter`, then `wireService`.
contract GasKillerSP1Arbiter is IArbiter {
    /// @notice The CommitmentManager this arbiter dispatches forfeits to (IArbiter).
    address public immutable override commitmentManager;

    /// @notice Succinct SP1 verifier gateway.
    ISP1Verifier public immutable sp1Verifier;

    /// @notice Governance for vkey rotation, forfeit cancellation, and metadata.
    address public immutable guardian;

    /// @notice Seconds a proposed vkey must wait before activation. Size it >= the
    ///         operator exit path (unbonding period + Schnorr notice window) so no key can
    ///         be slashed by a program it never had the chance to exit ahead of.
    uint256 public immutable vkeyDelay;

    /// @notice Penalty applied per proven offense, in basis points of each commitment.
    uint16 public immutable slashPenaltyBps;

    /// @notice Active SP1 program vkey.
    bytes32 public vkey;

    /// @notice Pending vkey rotation (zero when none).
    bytes32 public pendingVkey;
    uint256 public pendingVkeyActiveAt;

    /// @notice Commitments operator registry (one-shot wire; see deploy order above).
    IOperatorRegistryMinimal public operatorRegistry;

    /// @notice Schnorr lifecycle adapter used for immediate ejection (one-shot wire).
    SchnorrCommitmentsAdapter public adapter;

    /// @notice Offense ledger: `offenseKey = keccak256(operator, faultDigest)` records that
    ///         a valid proof was consumed for that (operator, offense) pair. Follow-up
    ///         forfeits for commitments missed in the first submission (e.g. delegations
    ///         indexed late) go through `slashMore` without re-verifying the proof.
    struct Offense {
        address operator;
        uint64 recordedAt;
        bool recorded;
    }

    mapping(bytes32 => Offense) public offenses;

    string internal metadataURI;

    error NotGuardian();
    error AlreadyWired();
    error NotWired();
    error ZeroAddress();
    error OffenseAlreadyRecorded(bytes32 offenseKey);
    error OffenseNotRecorded(bytes32 offenseKey);
    error CommitmentNotOperators(uint256 commitmentId, address operator);
    error NoForfeitsInitiated();
    error NoPendingVkey();
    error VkeyTimelockActive(uint256 activeAt);

    event ServiceWired(address indexed operatorRegistry, address indexed adapter);
    event OffenseRecorded(bytes32 indexed offenseKey, address indexed operator, bytes32 faultDigest);
    event ForfeitOpened(bytes32 indexed offenseKey, uint256 indexed commitmentId, uint16 penaltyBps);
    event ForfeitAttemptFailed(bytes32 indexed offenseKey, uint256 indexed commitmentId, bytes reason);
    event ForfeitCancelled(uint256 indexed commitmentId);
    event ForfeitExecuted(uint256 indexed commitmentId);
    event ForfeitExecutionFailed(uint256 indexed commitmentId, bytes reason);
    event VkeyProposed(bytes32 indexed newVkey, uint256 activeAt);
    event VkeyActivated(bytes32 indexed newVkey);
    event VkeyProposalCancelled(bytes32 indexed cancelledVkey);
    event MetadataURIUpdated(string uri);

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    constructor(
        address _commitmentManager,
        address _sp1Verifier,
        bytes32 _vkey,
        address _guardian,
        uint256 _vkeyDelay,
        uint16 _slashPenaltyBps
    ) {
        if (_commitmentManager == address(0) || _sp1Verifier == address(0) || _guardian == address(0)) {
            revert ZeroAddress();
        }
        require(_slashPenaltyBps > 0 && _slashPenaltyBps <= 10_000, "bad penalty");
        commitmentManager = _commitmentManager;
        sp1Verifier = ISP1Verifier(_sp1Verifier);
        vkey = _vkey;
        guardian = _guardian;
        vkeyDelay = _vkeyDelay;
        slashPenaltyBps = _slashPenaltyBps;
    }

    /// @notice One-shot wiring of the Commitments registry and the Schnorr adapter,
    ///         breaking the deploy cycle around the registry's immutable `requiredArbiter`.
    function wireService(address _operatorRegistry, address _adapter) external onlyGuardian {
        if (address(operatorRegistry) != address(0)) revert AlreadyWired();
        if (_operatorRegistry == address(0) || _adapter == address(0)) revert ZeroAddress();
        operatorRegistry = IOperatorRegistryMinimal(_operatorRegistry);
        adapter = SchnorrCommitmentsAdapter(_adapter);
        emit ServiceWired(_operatorRegistry, _adapter);
    }

    // ---------------------------------------------------------------------------------------
    // Slashing
    // ---------------------------------------------------------------------------------------

    /// @notice Slash on a verified SP1 fraud proof. Permissionless: the proof is the
    ///         authority. Opens a forfeit on every supplied commitment bound to the accused
    ///         operator (self-stake and delegations — the caller enumerates ids off-chain
    ///         from registry events; `operatorForCommitment` makes the list trustless) and
    ///         ejects the operator's Schnorr key immediately.
    /// @dev Public-values layout (v1, must match the challenger guest):
    ///      `abi.encode(address operator, bytes32 faultDigest)` where `faultDigest`
    ///      uniquely identifies the offense (e.g. keccak of the equivocating task digest
    ///      and the faithful output hash). Kept in one decode site for guest evolution.
    /// @param publicValues   SP1 public values (see layout above).
    /// @param proofBytes     SP1 proof for the active `vkey`.
    /// @param commitmentIds  commitments to open forfeits on; each must be bound to the
    ///                       accused operator. Individual failures (e.g. an already-pending
    ///                       forfeit) are skipped and surfaced as events, but at least one
    ///                       forfeit must open.
    function slash(bytes calldata publicValues, bytes calldata proofBytes, uint256[] calldata commitmentIds)
        external
    {
        if (address(operatorRegistry) == address(0)) revert NotWired();
        sp1Verifier.verifyProof(vkey, publicValues, proofBytes);

        (address operator, bytes32 faultDigest) = abi.decode(publicValues, (address, bytes32));
        bytes32 offenseKey = keccak256(abi.encodePacked(operator, faultDigest));
        if (offenses[offenseKey].recorded) revert OffenseAlreadyRecorded(offenseKey);
        offenses[offenseKey] =
            Offense({operator: operator, recordedAt: uint64(block.timestamp), recorded: true});
        emit OffenseRecorded(offenseKey, operator, faultDigest);

        uint256 opened = _openForfeits(offenseKey, operator, commitmentIds);
        if (commitmentIds.length > 0 && opened == 0) revert NoForfeitsInitiated();

        // Ejection is idempotent and must not be blockable by forfeit-side failures.
        adapter.eject(operator);
    }

    /// @notice Open forfeits for additional commitments under an already-recorded offense
    ///         (delegations discovered after the original slash). Permissionless.
    function slashMore(bytes32 offenseKey, uint256[] calldata commitmentIds) external {
        Offense storage offense = offenses[offenseKey];
        if (!offense.recorded) revert OffenseNotRecorded(offenseKey);
        uint256 opened = _openForfeits(offenseKey, offense.operator, commitmentIds);
        if (opened == 0) revert NoForfeitsInitiated();
    }

    function _openForfeits(bytes32 offenseKey, address operator, uint256[] calldata commitmentIds)
        internal
        returns (uint256 opened)
    {
        uint256 idsLength = commitmentIds.length;
        for (uint256 i = 0; i < idsLength; ++i) {
            uint256 id = commitmentIds[i];
            if (operatorRegistry.operatorForCommitment(id) != operator) {
                revert CommitmentNotOperators(id, operator);
            }
            try ICommitmentManagerMinimal(commitmentManager).initiateForfeit(id, slashPenaltyBps) {
                ++opened;
                emit ForfeitOpened(offenseKey, id, slashPenaltyBps);
            } catch (bytes memory reason) {
                emit ForfeitAttemptFailed(offenseKey, id, reason);
            }
        }
    }

    /// @notice Crank `executeForfeit` for elapsed challenge windows. Permissionless
    ///         convenience over the manager's own permissionless entry point.
    function crankExecute(uint256[] calldata commitmentIds) external {
        uint256 idsLength = commitmentIds.length;
        for (uint256 i = 0; i < idsLength; ++i) {
            uint256 id = commitmentIds[i];
            try ICommitmentManagerMinimal(commitmentManager).executeForfeit(id) {
                emit ForfeitExecuted(id);
            } catch (bytes memory reason) {
                emit ForfeitExecutionFailed(id, reason);
            }
        }
    }

    /// @notice Guardian veto for a pending forfeit — proof-bug insurance; proofs are
    ///         objective so this should never fire in normal operation.
    function cancelForfeit(uint256 commitmentId) external onlyGuardian {
        ICommitmentManagerMinimal(commitmentManager).cancelForfeit(commitmentId);
        emit ForfeitCancelled(commitmentId);
    }

    // ---------------------------------------------------------------------------------------
    // Vkey rotation (timelocked)
    // ---------------------------------------------------------------------------------------

    function proposeVkey(bytes32 newVkey) external onlyGuardian {
        pendingVkey = newVkey;
        pendingVkeyActiveAt = block.timestamp + vkeyDelay;
        emit VkeyProposed(newVkey, pendingVkeyActiveAt);
    }

    function cancelVkeyProposal() external onlyGuardian {
        if (pendingVkeyActiveAt == 0) revert NoPendingVkey();
        emit VkeyProposalCancelled(pendingVkey);
        pendingVkey = bytes32(0);
        pendingVkeyActiveAt = 0;
    }

    /// @notice Activate a proposed vkey after its timelock. Permissionless: activation is
    ///         mechanical once the delay every operator could exit within has elapsed.
    function activateVkey() external {
        if (pendingVkeyActiveAt == 0) revert NoPendingVkey();
        if (block.timestamp < pendingVkeyActiveAt) revert VkeyTimelockActive(pendingVkeyActiveAt);
        vkey = pendingVkey;
        emit VkeyActivated(pendingVkey);
        pendingVkey = bytes32(0);
        pendingVkeyActiveAt = 0;
    }

    // ---------------------------------------------------------------------------------------
    // IArbiter
    // ---------------------------------------------------------------------------------------

    function arbiterCapabilities() external pure override returns (uint256) {
        return ArbiterCapabilities.INITIATE_FORFEIT | ArbiterCapabilities.CANCEL_FORFEIT;
    }

    function arbiterMetadataURI() external view override returns (string memory) {
        return metadataURI;
    }

    function setMetadataURI(string calldata uri) external onlyGuardian {
        metadataURI = uri;
        emit MetadataURIUpdated(uri);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        // IArbiter id per upstream convention: xor of its three selectors.
        bytes4 arbiterId = IArbiter.commitmentManager.selector ^ IArbiter.arbiterCapabilities.selector
            ^ IArbiter.arbiterMetadataURI.selector;
        return interfaceId == arbiterId || interfaceId == 0x01ffc9a7; // ERC-165
    }
}
