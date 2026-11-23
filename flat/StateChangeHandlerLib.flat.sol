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

// src/libraries/StorageGuard.sol

/// @title StorageGuard
/// @notice Checks a signed program's `STORE` writes against a denylist of protected storage
///         ranges, so a quorum-signed update cannot overwrite slots such as an `Ownable` owner,
///         the `StateTracker` counter, the SDK's own configuration or EIP-1967 proxy slots. The
///         SDK protects its own counter and configuration and, behind a proxy, the EIP-1967 slots;
///         anything else is protected only if the consumer lists it in `_protectedRanges`.
///         `StateChangeHandlerLib._run` calls `advance` right before every STORE executes.
/// @dev The list denies rather than allows. Honest writes to mappings and dynamic arrays land on
///      keccak-derived slots spread across the whole slot space, which an allowlist of ranges
///      cannot express, while every slot worth protecting is known at compile time. Reaching a
///      protected slot from an honest write would take a keccak preimage, so a hit means the
///      program is malicious and the whole program is rejected.
///
///      Ranges are inclusive `[start, end]` intervals, strictly ascending and non-overlapping.
///      **`advance` assumes this and does not check it**: an unsorted or overlapping list fails
///      open, silently letting writes to protected slots through. Run `validateRanges` once on the
///      list; `GasKillerSDK` does so in its constructor. Validating on every write would cost
///      O(k) per write, more than the check itself.
///
///      A write to a protected range is rejected when it would change a protected bit, and allowed
///      when it leaves every protected bit as it is in storage. `mask` is `FULL` to protect the
///      whole slot. A narrower mask protects only some bits of one packed slot. Allowing writes
///      that change nothing is what lets the SDK protect its own transition counter: gas-analyzer
///      copies the counter's new value into every program as a STORE, and `trackState` has usually
///      written that same value by the time the program runs. The counter also accepts a bounded
///      move forward, for tracked functions that bump it more than once (`COUNTER_SLOT`).
///      Deciding costs one SLOAD, paid only by a write that lands in a range.
///
///      `advance` makes one forward pass with a `Cursor`. Writes in ascending slot order walk the
///      ranges together, and once a write is past the last range every later ascending write costs
///      one comparison. Before walking, `advance` checks that the cursor's position is valid for
///      the slot, which holds exactly when no range before it reaches the slot. If it isn't, it
///      re-seats by binary search (`_lowerBound`) instead of reverting. That happens on a write
///      below the previous range, and also on a cursor carried over from another list, never
///      reset, or holding garbage. So neither the order of the writes nor the cursor's contents
///      can change the verdict, only the gas. Input sorted within each CALL/CREATE-bounded slice,
///      as gas-analyzer's canonical extraction emits it, pays at most one re-seat per slice.
///
///      Writes are judged against storage as it stands when the check runs, which is exact only
///      right before each write executes. That is how `_run` calls it. Comparison checkers, and a
///      pre-pass over a whole program with the extra rule a pre-pass needs, live in
///      `test/utils/StorageGuardVariants.sol`, where the tests check this library against them.
library StorageGuard {
    /// @notice One protected interval of storage slots.
    /// @param start First protected slot (inclusive).
    /// @param end Last protected slot (inclusive).
    /// @param mask Protected bits within each slot: `FULL` for every bit, anything narrower only
    ///        when `start == end`. A write is rejected when it would change a protected bit.
    struct ProtectedRange {
        uint256 start;
        uint256 end;
        bytes32 mask;
    }

    /// @notice Merge state carried across consecutive writes. Start from a zeroed one. Its contents
    ///         only steer the search: `advance` re-checks `next` on every write, so a stale or
    ///         foreign cursor costs gas but cannot let a write through.
    /// @param next Where the last write's search ended: a hint for the next write's search.
    struct Cursor {
        uint256 next;
    }

    bytes32 internal constant FULL = bytes32(type(uint256).max);

    /// @notice `StateTracker`'s transition counter slot, which gets its own rule: a write may move
    ///         the counter forward, by at most `MAX_COUNTER_ADVANCE`, but never back.
    /// @dev A tracked function that calls another `trackState` function, or is re-entered, bumps
    ///      the counter more than once natively, and gas-analyzer copies that value into the
    ///      program. Settlement has bumped it only once, so an unchanged-only rule would reject the
    ///      copy on every attempt. Moving back is what would let old signed transitions replay, and
    ///      stays rejected; the bound keeps the counter from ever wrapping round to an old index.
    ///      Must equal `StateTracker.STATE_TRACKER_STORAGE_LOCATION` (pinned by a test).
    bytes32 internal constant COUNTER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;

    /// @notice Most a single write may move the transition counter forward.
    uint256 internal constant MAX_COUNTER_ADVANCE = type(uint32).max;

    /// @notice A write would change protected bits.
    /// @param index Position of the offending op in its program (or in the caller's own sequence).
    /// @param slot The protected slot it writes.
    error ProtectedSlotWrite(uint256 index, bytes32 slot);

    /// @notice The range list is unsorted, overlapping, empty-masked or masks more than one slot.
    error InvalidRanges();

    /// @notice Reverts with `InvalidRanges` unless `ranges` is a well-formed denylist.
    /// @dev Per range: `start <= end`, a nonzero mask, a partial mask only on a single slot, and a
    ///      start above the previous range's end. The first range has no predecessor, so it is
    ///      checked with `first` set rather than against a sentinel end.
    function validateRanges(ProtectedRange[] memory ranges) internal pure {
        bool bad;
        assembly ("memory-safe") {
            let it := add(ranges, 0x20)
            let last := add(it, shl(5, mload(ranges)))
            let prevEnd := 0
            for { let first := 1 } lt(it, last) { it := add(it, 0x20) } {
                let r := mload(it)
                let start := mload(r)
                let end := mload(add(r, 0x20))
                let mask := mload(add(r, 0x40))
                bad := or(bad, gt(start, end))
                bad := or(bad, iszero(mask))
                bad := or(bad, and(iszero(eq(mask, not(0))), iszero(eq(start, end))))
                bad := or(bad, and(iszero(first), iszero(gt(start, prevEnd))))
                prevEnd := end
                first := 0
            }
        }
        if (bad) revert InvalidRanges();
    }

    // `advance` and `_lowerBound` walk `ranges` in assembly. A `ProtectedRange[] memory` is a
    // length word followed by one pointer per element, and each element is three words: start,
    // end, mask. Every loop compares its index with the length before dereferencing it.

    /// @notice Checks one write against `ranges` and moves `c` past it. Reverts with
    ///         `ProtectedSlotWrite` if the write would change a protected bit.
    /// @dev `ranges` must have passed `validateRanges`; an unvalidated list can fail open.
    function advance(Cursor memory c, ProtectedRange[] memory ranges, uint256 index, bytes32 slot, bytes32 value)
        internal
        view
    {
        uint256 s = uint256(slot);
        uint256 i = c.next;
        // The forward walk from `i` is right only if no range before `i` reaches `s`. Ends ascend
        // strictly in a validated list, so that holds exactly when `i <= len` and (`i == 0` or
        // `ranges[i-1].end < s`). Otherwise re-seat. `i` is compared with `len` before
        // `ranges[i-1]` is read.
        bool reseat;
        assembly ("memory-safe") {
            let len := mload(ranges)
            reseat := gt(i, len)
            if and(iszero(reseat), gt(i, 0)) {
                reseat := iszero(lt(mload(add(mload(add(ranges, shl(5, i))), 0x20)), s))
            }
        }
        if (reseat) i = _lowerBound(ranges, s);
        uint256 hit;
        assembly ("memory-safe") {
            let len := mload(ranges)
            let base := add(ranges, 0x20)
            for {} lt(i, len) { i := add(i, 1) } {
                if iszero(lt(mload(add(mload(add(base, shl(5, i))), 0x20)), s)) { break }
            }
            mstore(c, i)
            if lt(i, len) {
                let r := mload(add(base, shl(5, i)))
                if iszero(gt(mload(r), s)) { hit := r }
            }
        }
        if (hit != 0) _reject(hit, index, slot, value);
    }

    /// @dev Index of the first range whose end is at or above `s`, or `ranges.length` when there
    ///      is none. The library's only binary search. `lo < hi <= length` keeps `mid` in bounds
    ///      and every sum below 2^256.
    function _lowerBound(ProtectedRange[] memory ranges, uint256 s) private pure returns (uint256 lo) {
        assembly ("memory-safe") {
            let base := add(ranges, 0x20)
            for { let hi := mload(ranges) } lt(lo, hi) {} {
                let mid := shr(1, add(lo, hi))
                switch lt(mload(add(mload(add(base, shl(5, mid))), 0x20)), s)
                case 1 { lo := add(mid, 1) }
                default { hi := mid }
            }
        }
    }

    /// @dev `range` points at a range covering `slot`. Reverts unless the write leaves every
    ///      protected bit as it is in storage or, for the transition counter, moves it forward by
    ///      at most `MAX_COUNTER_ADVANCE` (see `COUNTER_SLOT`).
    function _reject(uint256 range, uint256 index, bytes32 slot, bytes32 value) private view {
        bytes32 mask;
        bytes32 current;
        assembly ("memory-safe") {
            mask := mload(add(range, 0x40))
            current := sload(slot)
        }
        if (slot == COUNTER_SLOT) {
            // Checked separately: the difference alone would let a write wrap round to zero.
            unchecked {
                if (value >= current && uint256(value) - uint256(current) <= MAX_COUNTER_ADVANCE) return;
            }
            revert ProtectedSlotWrite(index, slot);
        }
        if ((current ^ value) & mask != 0) revert ProtectedSlotWrite(index, slot);
    }
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
///      mocks they are tested against, see no new surface. Implementations must report this
///      interface through ERC-165: a consumer reports `IGasKillerNested` only when its registry
///      does.
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
    /// @return             `applyNested.selector`; the parent rejects any other return.
    function applyNested(bytes32 root, bytes32 expectedLeaf, bytes calldata witness) external payable returns (bytes4);

    /// @notice The leaf of the child this contract is calling right now, or zero.
    function pendingChild() external view returns (bytes32);
}

// src/StateChangeHandlerLib.sol

/// @notice Discriminator enum for the type of state update operation to execute
/// @dev Two groups, kept contiguous:
///      - EVM ops (0-8), each the replay of one opcode the consumer executed in the trace:
///        `SSTORE`, `CALL`, `LOG0`-`LOG4`, `CREATE`, `CREATE2`. `CALL` and `CREATE` carry an
///        optional pin of their result.
///      - SDK ops (9 and up), which have no single opcode behind them: `NESTED` hands a callee
///        its own signed frame, and the `*_CHECK` ops re-check a read the trace made.
///      New SDK ops go at the end.
enum StateUpdateType {
    // ---- EVM ops: replay an opcode
    /// @notice Write a 32-byte value directly to a storage slot (`SSTORE`)
    STORE,
    /// @notice Execute an external call with optional ETH value transfer
    CALL,
    /// @notice Emit a log with no indexed topics
    LOG0,
    /// @notice Emit a log with one indexed topic
    LOG1,
    /// @notice Emit a log with two indexed topics
    LOG2,
    /// @notice Emit a log with three indexed topics
    LOG3,
    /// @notice Emit a log with four indexed topics
    LOG4,
    /// @notice Deploy a contract using CREATE (nonce-derived address)
    CREATE,
    /// @notice Deploy a contract using CREATE2 (salt-derived deterministic address)
    CREATE2,
    // ---- SDK ops: no single opcode behind them
    /// @notice Apply an SDK-enabled callee's own signed frame of a nested tree
    NESTED,
    /// @notice Re-run a read-only call and check its result against the trace
    STATICCALL_CHECK,
    /// @notice Check an account's ETH balance against the trace
    BALANCE_CHECK,
    /// @notice Check an account's code hash against the trace
    CODEHASH_CHECK
}

/// @notice The tree a program runs inside, when it runs inside one.
/// @dev `root` is zero for single-transition settlement, where `NESTED` ops are rejected.
///      `children` holds one witness per `NESTED` op in program order; `consumed` counts the
///      ones handed out so far.
struct NestedContext {
    bytes32 root;
    bytes[] children;
    uint256 consumed;
}

/// @notice What a program may send out of its contract. Checked before every op that runs other
///         code with the contract's authority or moves its ETH: `CALL`, `CREATE`, `CREATE2` and
///         `NESTED`. Not before the read checks (`STATICCALL_CHECK` and the like): they can run
///         code at any address, as the consumer, but can't change state.
/// @dev `StorageGuard` only sees `STORE`s. A signed `CALL` runs real code as the consumer, so a
///      malicious quorum could otherwise spend anything the consumer holds or controls elsewhere.
///      Before each such op, `_run` adds its value to `sent`, reverts with
///      `OutgoingValueExceeded` once the total passes `valueCap`, and then calls `authorize`,
///      which reverts to reject the op. Before all that, a `CALL` to the running contract
///      itself reverts with `SelfCall` unless `allowSelfCall` allows its selector.
/// @param valueCap The most wei the program's ops may send in total. Value an op sends to the
///        running contract itself (an allowed self-call) stays in it and doesn't count.
/// @param sent Wei sent so far by the program's ops. Start it at zero.
/// @param authorize Called as `(index, kind, target, value, data)`. For a
///        `CALL`, `data` is the calldata. For `CREATE`/`CREATE2` it is the initcode, with a zero
///        `target`, since the address isn't known before the deployment. For `NESTED`, `data` is
///        empty: the callee applies and checks its own signed frame.
/// @param allowSelfCall Called with the selector of a `CALL` to the running contract; returns
///        whether to let it run. `selector` is zero only for empty calldata;
///        malformed calldata (1 to 3 bytes, or a zero selector with a payload) is rejected
///        without asking. Checked here rather than left to `authorize`, so an `authorize` that is
///        overridden can't drop it, and so a `CALL` elsewhere only pays one comparison. Inside a
///        `GasKillerSDK` contract, build the policy with its `_callPolicy`. A policy built by
///        hand should pass `StateChangeHandlerLib._rejectSelfCalls` unless it means to allow
///        self-calls; `_unrestrictedCalls()` allows them all.
///      The policy isn't told which tracked function the program is for: the quorum names that
///      function and nothing checks it against the program, so no rule may depend on it.
struct CallPolicy {
    uint256 valueCap;
    uint256 sent;
    function(uint256, StateUpdateType, address, uint256, bytes memory) authorize;
    function(bytes4) view returns (bool) allowSelfCall;
}

/// @title StateChangeHandlerLib
/// @notice Library for decoding and executing batched state update operations
/// @dev Processes ABI-encoded arrays of typed state updates; supports STORE, CALL, LOG0-LOG4,
///      CREATE, CREATE2, NESTED and the observation checks.
///
///      The consumer's writes were computed against external state as of the trace, and its
///      `CALL`s run against external state as of settlement. To keep the two from drifting
///      apart silently (a swap that returns less than the trace credited), a program pins what
///      its contract observed from outside: a `CALL`'s result hash, a `CREATE`'s address,
///      and the `*_CHECK` ops for reads that changed no state (`STATICCALL`, `BALANCE`,
///      `SELFBALANCE`, `EXTCODEHASH`, `EXTCODESIZE`), each at its position in the trace. A
///      mismatch reverts with `ObservationMismatch`. Block values (`block.timestamp` and the
///      like) can't be pinned, as settlement lands in a later block: a transition is defined as
///      of its reference block, and the program carries the values it saw there.
///
///      A result hash is `keccak256(abi.encodePacked(success, returndata))`. Pinning a `CALL` or
///      `CREATE` is optional: with a zero hash a `CALL` must still succeed, but its return data
///      isn't checked, and a zero address leaves a deployment's address unchecked. A pinned
///      `CALL` that sends no value may revert if the trace saw it revert with data (a caught
///      revert): its hash then covers the failure, and the program goes on. Its policy hooks ran before it,
///      so they charge it as if it had gone through (a deposit `transferFrom` that now fails is
///      charged as tokens out): never less than it moved. A caught revert whose result depended
///      on a gas cap (an out-of-gas from `f{gas: n}()`) can't be pinned: settlement replays the
///      cap, but an out-of-gas returns no data, and the callee's gas use differs from the trace
///      (other slots are warm), so the analyzer has to reject the task. The read checks run code
///      at any address without the call policy (the allow list doesn't cover them); they can't
///      change state.
library StateChangeHandlerLib {
    /// @dev keccak256("gasKiller.unattributedValue") - 1. The part of the contract's balance the
    ///      running program's trace didn't see: in a batch, the value later items brought, and
    ///      any surplus. A `BALANCE_CHECK` of the contract itself subtracts it.
    bytes32 internal constant UNATTRIBUTED_VALUE_SLOT =
        0xf604dfbedb1e391be66692991e94988183c331594e7cf996e89aff22b10f3d1b;

    /// @dev Sets the value `BALANCE_CHECK` subtracts from this contract's own balance. Zero
    ///      outside a batch.
    function _setUnattributedValue(uint256 value) internal {
        assembly {
            tstore(UNATTRIBUTED_VALUE_SLOT, value)
        }
    }

    /// keccak256("gasKiller.pendingChild") - 1, following `StateTracker`'s slot convention.
    bytes32 internal constant PENDING_CHILD_SLOT = 0x70b036af5917f7c22df33faec4b5fd311a27d9e8310987dea3cc060d66152963;

    function _pendingChild() internal view returns (bytes32 leaf) {
        assembly {
            leaf := tload(PENDING_CHILD_SLOT)
        }
    }

    function _setPendingChild(bytes32 leaf) private {
        assembly {
            tstore(PENDING_CHILD_SLOT, leaf)
        }
    }

    /// @dev Runs a program outside any tree, rejecting every NESTED op. Dispatching NESTED
    ///      through a function pointer keeps `_runNested` out of consumers that never nest.
    ///      Every STORE is checked against `ranges` (see `_run`). The list is validated first
    ///      (`StorageGuard.InvalidRanges`), so a malformed one reverts rather than failing open,
    ///      and an empty one reverts with `NoProtectedRanges` rather than running unchecked; the
    ///      only unchecked path is the explicitly named `_runStateUpdatesUnguarded`. Validating
    ///      costs O(k) per program; a caller whose list is already validated, as `GasKillerSDK`'s
    ///      is at deployment, can use `_runStateUpdatesPrevalidated` instead. Every CALL, CREATE,
    ///      CREATE2 and NESTED is checked against `policy` (see `CallPolicy`); pass
    ///      `_unrestrictedCalls()` for none.
    function _runStateUpdates(
        StateUpdateType[] memory types,
        bytes[] memory args,
        StorageGuard.ProtectedRange[] memory ranges,
        CallPolicy memory policy
    ) internal {
        StorageGuard.validateRanges(ranges);
        _runStateUpdatesPrevalidated(types, args, ranges, policy);
    }

    /// @dev Runs a program inside the tree in `ctx`, checking every STORE against `ranges`. As
    ///      above, `ranges` is validated first and may not be empty.
    function _runStateUpdates(
        StateUpdateType[] memory types,
        bytes[] memory args,
        StorageGuard.ProtectedRange[] memory ranges,
        CallPolicy memory policy,
        NestedContext memory ctx
    ) internal {
        StorageGuard.validateRanges(ranges);
        _runStateUpdatesPrevalidated(types, args, ranges, policy, ctx);
    }

    /// @dev `_runStateUpdates` without validating `ranges`. **`ranges` must already have passed
    ///      `StorageGuard.validateRanges`**: a malformed list fails open, silently letting writes
    ///      to protected slots through. `GasKillerSDK` uses it with `_settlementRanges()`, one of two
    ///      constants of the contract's code (with and without the proxy slots), both validated
    ///      by its constructor. An empty list
    ///      still reverts with `NoProtectedRanges`.
    function _runStateUpdatesPrevalidated(
        StateUpdateType[] memory types,
        bytes[] memory args,
        StorageGuard.ProtectedRange[] memory ranges,
        CallPolicy memory policy
    ) internal {
        require(ranges.length != 0, NoProtectedRanges());
        NestedContext memory none;
        _run(types, args, ranges, StorageGuard.advance, policy, none, _rejectNested);
    }

    /// @dev `_runStateUpdates` inside the tree in `ctx`, without validating `ranges`. Same
    ///      precondition as above.
    function _runStateUpdatesPrevalidated(
        StateUpdateType[] memory types,
        bytes[] memory args,
        StorageGuard.ProtectedRange[] memory ranges,
        CallPolicy memory policy,
        NestedContext memory ctx
    ) internal {
        require(ranges.length != 0, NoProtectedRanges());
        _run(types, args, ranges, StorageGuard.advance, policy, ctx, _runNested);
    }

    /// @dev Runs a program outside any tree **without checking any STORE**: a signed program can
    ///      overwrite any slot, including the transition counter, the SDK's configuration and an
    ///      owner. Only for a consumer that has opted out with
    ///      `GasKillerSDK._unsafeDisableStorageGuard`. A separate, explicitly named entry point:
    ///      the guarded ones reject an empty list, so no list a caller builds can turn protection
    ///      off.
    ///      `policy` still applies: the opt-out covers STOREs only.
    function _runStateUpdatesUnguarded(StateUpdateType[] memory types, bytes[] memory args, CallPolicy memory policy)
        internal
    {
        NestedContext memory none;
        StorageGuard.ProtectedRange[] memory noRanges;
        _run(types, args, noRanges, _skipCheck, policy, none, _rejectNested);
    }

    /// @dev Runs a program inside the tree in `ctx` without checking any STORE. As above, only
    ///      for a consumer that has opted out.
    function _runStateUpdatesUnguarded(
        StateUpdateType[] memory types,
        bytes[] memory args,
        CallPolicy memory policy,
        NestedContext memory ctx
    ) internal {
        StorageGuard.ProtectedRange[] memory noRanges;
        _run(types, args, noRanges, _skipCheck, policy, ctx, _runNested);
    }

    /// @dev A policy that allows every op, self-calls included, and any total value, for callers
    ///      outside a `GasKillerSDK` contract.
    function _unrestrictedCalls() internal pure returns (CallPolicy memory) {
        return CallPolicy(type(uint256).max, 0, _allowCall, _allowAllSelfCalls);
    }

    function _allowCall(uint256, StateUpdateType, address, uint256, bytes memory) private pure {}

    function _allowAllSelfCalls(bytes4) private pure returns (bool) {
        return true;
    }

    /// @dev An `allowSelfCall` that rejects every self-call: the safe choice for a `CallPolicy`
    ///      built by hand.
    function _rejectSelfCalls(bytes4) internal pure returns (bool) {
        return false;
    }

    /// @dev Counts `value` against the policy's cap, unless the op sends it to the running
    ///      contract itself, then hands the op to its `authorize`.
    function _authorize(
        CallPolicy memory policy,
        uint256 index,
        StateUpdateType kind,
        address target,
        uint256 value,
        bytes memory data
    ) private {
        if (value != 0) _countValue(policy, index, target, value);
        policy.authorize(index, kind, target, value, data);
    }

    /// @dev Adds `value` to the policy's total, or reverts once it passes the cap. Value sent to
    ///      the running contract itself stays in it and isn't counted. Out of line, like
    ///      `_checkSelfCall`, so a zero-value op pays only the `value` check.
    function _countValue(CallPolicy memory policy, uint256 index, address target, uint256 value) private view {
        if (target == address(this)) return;
        uint256 sent = policy.sent;
        uint256 cap = policy.valueCap;
        // Compared against the headroom, not as `sent + value > cap`: with a cap near
        // `type(uint256).max` the sum could overflow into a panic instead of this error.
        // `sent > cap` is checked first, since a hand-built policy may not start `sent` at zero
        // and the subtraction would then wrap. The reported total saturates rather than wrapping,
        // and once both checks pass `sent + value <= cap`.
        unchecked {
            if (sent > cap || value > cap - sent) {
                uint256 total = sent + value;
                revert OutgoingValueExceeded(index, total < sent ? type(uint256).max : total, cap);
            }
            policy.sent = sent + value;
        }
    }

    /// @dev Rejects a `CALL` to the running contract unless the policy's `allowSelfCall` allows
    ///      its selector. Kept out of line so a `CALL` elsewhere pays only the address check.
    ///      Selector zero stands only for empty calldata (a plain ETH transfer). Calldata of 1 to 3
    ///      bytes, or of 4 or more starting with `0x00000000`, is rejected without asking
    ///      `allowSelfCall`: Solidity routes it to the fallback with a payload, so allowing the
    ///      ETH-transfer case, or a selector its zero-padding matches, must not let it through.
    function _checkSelfCall(CallPolicy memory policy, uint256 index, bytes memory data) private view {
        uint256 length = data.length;
        bytes4 selector;
        if (length >= 4) {
            // One `mload` rather than `bytes4(data)`, which costs about 240 gas more, as in
            // `CallAllowList.check`.
            assembly ("memory-safe") {
                selector := and(mload(add(data, 0x20)), shl(224, 0xffffffff))
            }
            require(selector != bytes4(0), SelfCall(index, selector));
        } else if (length != 0) {
            revert SelfCall(index, bytes4(data)); // zero-padded
        }
        require(policy.allowSelfCall(selector), SelfCall(index, selector));
    }

    /// @dev The STORE check of an unguarded run: none.
    function _skipCheck(StorageGuard.Cursor memory, StorageGuard.ProtectedRange[] memory, uint256, bytes32, bytes32)
        private
        pure {}

    /// @notice Decodes and executes a series of state updates
    /// @dev This function processes an array of state updates, executing them in sequence. Each update can be one of:
    ///      - STORE: Direct storage writes using assembly
    ///      - CALL: External contract calls with value transfer
    ///      - LOG0-LOG4: Event emission with 0-4 indexed topics
    ///      - CREATE: Contract deployment via CREATE opcode
    ///      - CREATE2: Deterministic contract deployment via CREATE2 opcode
    ///      - NESTED: Hand a callee its own signed frame of the tree in `ctx`
    ///      - STATICCALL_CHECK, BALANCE_CHECK, CODEHASH_CHECK: check a read against the trace
    ///      A CALL can pin its result and a CREATE its address (see the library's notes).
    /// @param types Array of StateUpdateType enums indicating the type of each state update operation
    /// @param args Array of ABI-encoded arguments corresponding to each operation type
    /// @param ranges Protected storage. Nonempty when `check` is `StorageGuard.advance`: the
    ///        guarded entry points reject an empty list (`NoProtectedRanges`), so a caller can't
    ///        turn protection off by passing one. Empty from `_runStateUpdatesUnguarded`, whose
    ///        `_skipCheck` never reads it. When checked, it has passed
    ///        `StorageGuard.validateRanges`: in `_runStateUpdates`, or before the caller of
    ///        `_runStateUpdatesPrevalidated` (`GasKillerSDK`'s constructor). Every
    ///        STORE is checked right before it executes and reverts with
    ///        `StorageGuard.ProtectedSlotWrite` if it would change a protected bit. Checking at
    ///        that moment is exact even after a CALL has legitimately changed protected storage.
    /// @param check The STORE check: `StorageGuard.advance`, or `_skipCheck` (which ignores
    ///        `ranges`) from `_runStateUpdatesUnguarded`. A function pointer rather than a flag,
    ///        so neither path pays a per-write branch for the other.
    /// @param policy Checked before every CALL, CREATE, CREATE2 and NESTED, before it runs (see
    ///        `CallPolicy`). `policy.sent` accumulates across the program.
    /// @param ctx The tree this program runs inside; a zero root rejects every NESTED op
    /// @param nested The NESTED handler: `_runNested` inside a tree, `_rejectNested` outside one
    /// @dev types and args arrays must be equal length, with args[i] containing the encoded parameters for types[i]
    function _run(
        StateUpdateType[] memory types,
        bytes[] memory args,
        StorageGuard.ProtectedRange[] memory ranges,
        function(StorageGuard.Cursor memory, StorageGuard.ProtectedRange[] memory, uint256, bytes32, bytes32)
            view check,
        CallPolicy memory policy,
        NestedContext memory ctx,
        function(uint256, bytes memory, NestedContext memory, CallPolicy memory) nested
    ) private {
        require(types.length == args.length, InvalidArguments());
        StorageGuard.Cursor memory cursor;
        // `types.length` is re-read rather than held in a local: with `policy` the STORE branch
        // would otherwise be one slot past the stack limit.
        for (uint256 i = 0; i < types.length; ++i) {
            StateUpdateType stateUpdateType = types[i];
            bytes memory arg = args[i];

            if (stateUpdateType == StateUpdateType.STORE) {
                (bytes32 slot, bytes32 value) = abi.decode(arg, (bytes32, bytes32));
                check(cursor, ranges, i, slot, value);
                assembly {
                    sstore(slot, value)
                }
            } else if (stateUpdateType == StateUpdateType.CALL) {
                _call(policy, i, arg);
            } else if (stateUpdateType == StateUpdateType.LOG0) {
                // `_validateLogArg` checks that `arg` is a canonical, in-bounds encoding before this reads
                // directly out of its buffer. The `data` length word sits at `base + canonicalOffset`, and
                // any topics sit inline in the head at `base + 0x20*k`.
                _validateLogArg(arg, 0x20);
                assembly {
                    let dataPtr := add(add(arg, 0x20), 0x20)
                    log0(add(dataPtr, 0x20), mload(dataPtr))
                }
            } else if (stateUpdateType == StateUpdateType.LOG1) {
                _validateLogArg(arg, 0x40);
                assembly {
                    let base := add(arg, 0x20)
                    let dataPtr := add(base, 0x40)
                    log1(add(dataPtr, 0x20), mload(dataPtr), mload(add(base, 0x20)))
                }
            } else if (stateUpdateType == StateUpdateType.LOG2) {
                _validateLogArg(arg, 0x60);
                assembly {
                    let base := add(arg, 0x20)
                    let dataPtr := add(base, 0x60)
                    log2(add(dataPtr, 0x20), mload(dataPtr), mload(add(base, 0x20)), mload(add(base, 0x40)))
                }
            } else if (stateUpdateType == StateUpdateType.LOG3) {
                _validateLogArg(arg, 0x80);
                assembly {
                    let base := add(arg, 0x20)
                    let dataPtr := add(base, 0x80)
                    log3(
                        add(dataPtr, 0x20),
                        mload(dataPtr),
                        mload(add(base, 0x20)),
                        mload(add(base, 0x40)),
                        mload(add(base, 0x60))
                    )
                }
            } else if (stateUpdateType == StateUpdateType.LOG4) {
                _validateLogArg(arg, 0xa0);
                assembly {
                    let base := add(arg, 0x20)
                    let dataPtr := add(base, 0xa0)
                    log4(
                        add(dataPtr, 0x20),
                        mload(dataPtr),
                        mload(add(base, 0x20)),
                        mload(add(base, 0x40)),
                        mload(add(base, 0x60)),
                        mload(add(base, 0x80))
                    )
                }
            } else if (stateUpdateType == StateUpdateType.CREATE) {
                _create(policy, i, arg);
            } else if (stateUpdateType == StateUpdateType.CREATE2) {
                (bytes32 salt, uint256 value, bytes memory initcode) = abi.decode(arg, (bytes32, uint256, bytes));
                _authorize(policy, i, StateUpdateType.CREATE2, address(0), value, initcode);
                address deployed;
                assembly {
                    deployed := create2(value, add(initcode, 0x20), mload(initcode), salt)
                }
                require(deployed != address(0), DeploymentFailed());
            } else if (stateUpdateType == StateUpdateType.NESTED) {
                nested(i, arg, ctx, policy);
            } else {
                _check(stateUpdateType, i, arg);
            }
        }
        if (ctx.consumed != ctx.children.length) revert UnconsumedWitnesses(ctx.children.length, ctx.consumed);
    }

    /// @dev A `CALL`: `(target, value, callargs, resultHash, gasLimit)`.
    ///      `gasLimit` is the gas the callee gets, and never more than the traced `CALL` passed:
    ///      forwarding all gas instead would let a callee that only had the stipend in the trace
    ///      run real code mid-transition, such as re-entering the consumer's other functions
    ///      while the program is half applied. The EVM adds the 2,300 stipend when value is
    ///      sent, so a `transfer` or `send` (operand 0 with value, 2,300 without) gets the
    ///      stipend here too. A larger cap is the gas the callee needs at settlement (see
    ///      below), or the traced operand itself.
    ///      Settlement reverts with `InsufficientCallGas` unless the callee can get all of
    ///      `gasLimit`, so whoever submits the settlement can't starve the callee into another
    ///      path (an inner call that runs out of gas and is caught) while the call still
    ///      succeeds. A cap more than a settlement can supply, such as one recorded in a trace
    ///      run past the block gas limit, therefore makes the program unsettleable. The analyzer
    ///      clamps it.
    ///      `type(uint256).max` forwards everything left, unchecked, as before. The settler then
    ///      decides how much gas the callee gets: the fallback for a callee whose needed gas
    ///      wasn't worked out.
    ///      The cap has to cover settlement, not just the trace. An account or slot the trace had
    ///      warm is cold here unless an EIP-2930 access list warms it, and the settler picks the
    ///      access list. A callee short of gas doesn't always revert: one that catches an inner
    ///      out-of-gas succeeds down another path, and no pin need notice. So the analyzer sizes
    ///      `gasLimit` with nothing warm but what the program touched before this op, checks the
    ///      callee also reproduces with everything it touches warm, and rejects the task
    ///      otherwise. An access list then only makes the call cheaper.
    ///      Gas spent here also starves later items of a batch (e.g.
    ///      GasKillerSDK.verifyAndUpdateBatch): a greedy or griefing target can make the whole
    ///      atomic batch revert. No partial-state hazard, but it nullifies the batch's cost
    ///      amortization. See IGasKillerSDKBatch for the batch-assembly side.
    ///      A nonzero `resultHash` pins the result: a call that succeeds with other return data,
    ///      or fails when the trace saw it succeed, reverts. A pinned failure lets the program go
    ///      on, unless the call sends value: a failure with empty data can also be the EVM's own
    ///      (a value shortfall, call depth), which the trace didn't see, so such a call must
    ///      succeed.
    function _call(CallPolicy memory policy, uint256 i, bytes memory arg) private {
        // Earlier layouts, `(target, value, callargs)` and `(target, value, callargs,
        // resultHash)`, would decode with other words in place of the hash and the gas limit:
        // reject anything but the canonical offset.
        _requireOffset(arg, 0x40, 0xa0, i);
        (address target, uint256 value, bytes memory callargs, bytes32 expected, uint256 gasLimit) =
            abi.decode(arg, (address, uint256, bytes, bytes32, uint256));
        if (target == address(this)) _checkSelfCall(policy, i, callargs);
        _authorize(policy, i, StateUpdateType.CALL, target, value, callargs);
        if (gasLimit != type(uint256).max) _requireCallGas(i, gasLimit);
        bool success;
        assembly {
            success := call(gasLimit, target, value, add(callargs, 0x20), mload(callargs), 0, 0)
        }
        if (expected != bytes32(0) && (success || _pinnableFailure(value))) {
            bytes32 actual = _resultHash(success);
            if (actual == expected) return;
            // A failure is reported with its revert data, which says more than a hash.
            if (success) revert ObservationMismatch(i, expected, actual);
        }
        if (!success) revert RevertingContext(i, target, _returnData(), callargs);
    }

    /// @dev The most a `CALL` itself can cost before its callee starts: a cold account (2,600),
    ///      a value transfer (9,000) and a new account (25,000), plus the few operations between
    ///      the check and the `CALL`. Generous on purpose: overestimating only asks the settler
    ///      for a little more gas, which is refunded.
    uint256 private constant _CALL_OVERHEAD = 40_000;

    /// @dev Reverts unless the next `CALL` can give its callee all of `gasLimit`: the EVM passes
    ///      at most 63/64 of the gas left after the `CALL`'s own cost.
    function _requireCallGas(uint256 i, uint256 gasLimit) private view {
        uint256 left = gasleft();
        uint256 available = left > _CALL_OVERHEAD ? left - _CALL_OVERHEAD : 0;
        require(available - available / 64 >= gasLimit, InsufficientCallGas(i, gasLimit));
    }

    /// @dev A `CREATE`: `(value, initcode, expected)`. A nonzero `expected` pins the deployed
    ///      address, which depends on this contract's nonce, and the contract's own functions
    ///      can move that outside any program. `CREATE2`'s address is fixed by the signed salt
    ///      and initcode, so it carries none.
    function _create(CallPolicy memory policy, uint256 i, bytes memory arg) private {
        _requireOffset(arg, 0x20, 0x60, i); // as in `_call`
        (uint256 value, bytes memory initcode, address expected) = abi.decode(arg, (uint256, bytes, address));
        _authorize(policy, i, StateUpdateType.CREATE, address(0), value, initcode);
        address deployed;
        assembly {
            deployed := create(value, add(initcode, 0x20), mload(initcode))
        }
        require(deployed != address(0), DeploymentFailed());
        if (expected != address(0) && deployed != expected) {
            revert ObservationMismatch(i, bytes32(uint256(uint160(expected))), bytes32(uint256(uint160(deployed))));
        }
    }

    /// @dev The read checks. They change no state, so the call policy doesn't see them.
    ///      - `STATICCALL_CHECK`: `(target, data, resultHash)`. Re-runs the read with all
    ///        remaining gas and compares its result hash; a read that reverted in the trace is
    ///        pinned as a failure the same way, if it reverted with data (as for `CALL`).
    ///      - `BALANCE_CHECK`: `(account, balance)`, this contract included (`SELFBALANCE`),
    ///        less the value the trace didn't see (`UNATTRIBUTED_VALUE_SLOT`). Reverts with
    ///        `UnattributedValueSpent` if the balance is below that value: the program spent
    ///        ETH later batch items brought.
    ///        Exact, so anyone who can push ETH to the account (even by `SELFDESTRUCT`) can make
    ///        it fail: pin a balance only when a write depends on it.
    ///      - `CODEHASH_CHECK`: `(account, codehash)`. Pins `EXTCODESIZE` too: the same code hash
    ///        means the same code. An account with no code hashes to 0 until it holds a balance or
    ///        a nonce, then to `keccak256("")`; the two count as equal, so a wei sent to an empty
    ///        address doesn't fail the check (which also means 0 and `keccak256("")` can't be
    ///        told apart).
    function _check(StateUpdateType kind, uint256 i, bytes memory arg) private view {
        bytes32 expected;
        bytes32 actual;
        if (kind == StateUpdateType.STATICCALL_CHECK) {
            address target;
            bytes memory data;
            (target, data, expected) = abi.decode(arg, (address, bytes, bytes32));
            bool success;
            assembly {
                success := staticcall(gas(), target, add(data, 0x20), mload(data), 0, 0)
            }
            if (!success && !_pinnableFailure(0)) revert RevertingContext(i, target, "", data);
            actual = _resultHash(success);
        } else if (kind == StateUpdateType.BALANCE_CHECK) {
            (address account, uint256 balance) = abi.decode(arg, (address, uint256));
            uint256 held = account.balance;
            if (account == address(this)) {
                uint256 unattributed;
                assembly {
                    unattributed := tload(UNATTRIBUTED_VALUE_SLOT)
                }
                require(held >= unattributed, UnattributedValueSpent());
                held -= unattributed;
            }
            (expected, actual) = (bytes32(balance), bytes32(held));
        } else {
            address account;
            (account, expected) = abi.decode(arg, (address, bytes32));
            actual = account.codehash;
            if (actual == _EMPTY_CODEHASH) actual = 0;
            if (expected == _EMPTY_CODEHASH) expected = 0;
        }
        if (actual != expected) revert ObservationMismatch(i, expected, actual);
    }

    /// @dev `keccak256("")`: the code hash of an account with no code that exists.
    bytes32 private constant _EMPTY_CODEHASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    /// @dev Whether the last call's failure may match a pinned failure. Not with value, nor with
    ///      empty return data: the EVM's own failures (a value shortfall, out of gas from the
    ///      settler's gas limit, call depth) return nothing, and the trace didn't see them. So
    ///      only a revert with data can be pinned; the analyzer rejects a caught `revert()`.
    function _pinnableFailure(uint256 value) private pure returns (bool ok) {
        assembly {
            ok := and(iszero(value), gt(returndatasize(), 0))
        }
    }

    /// @dev Reverts with `MalformedOp` unless the word at `at` in `arg` is `offset`: the head
    ///      offset of the op's dynamic field in its canonical encoding.
    function _requireOffset(bytes memory arg, uint256 at, uint256 offset, uint256 i) private pure {
        uint256 word;
        if (arg.length >= at + 0x20) {
            assembly {
                word := mload(add(add(arg, 0x20), at))
            }
        }
        require(word == offset, MalformedOp(i));
    }

    /// @dev `keccak256(abi.encodePacked(success, returndata))` of the last call, hashed in
    ///      scratch memory past the free pointer, which isn't moved.
    function _resultHash(bool success) private pure returns (bytes32 h) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore8(ptr, success)
            returndatacopy(add(ptr, 1), 0, returndatasize())
            h := keccak256(ptr, add(returndatasize(), 1))
        }
    }

    /// @dev The last call's return data, copied into memory.
    function _returnData() private pure returns (bytes memory data) {
        uint256 size;
        assembly {
            size := returndatasize()
        }
        data = new bytes(size);
        assembly {
            returndatacopy(add(data, 0x20), 0, size)
        }
    }

    function _rejectNested(uint256, bytes memory, NestedContext memory, CallPolicy memory) private pure {
        revert NestedOutsideTree();
    }

    /// @dev The child checks `pendingChild()` on its caller before applying anything, which is
    ///      what stops a frame from being applied anywhere but this op. The previous value is
    ///      restored afterwards because a cycle can nest pending children on one contract.
    ///      A call to an address without code, or to a permissive fallback, also succeeds, so
    ///      success alone does not show the frame applied; the child must echo its selector.
    function _runNested(uint256 i, bytes memory arg, NestedContext memory ctx, CallPolicy memory policy) private {
        if (ctx.root == bytes32(0)) revert NestedOutsideTree();
        (address target, uint256 value, bytes32 childLeaf) = abi.decode(arg, (address, uint256, bytes32));
        // The cheap structural check first, so a malformed tree reverts with `MissingWitness`
        // before the policy spends budgets or calls out.
        if (ctx.consumed >= ctx.children.length) revert MissingWitness(i);
        _authorize(policy, i, StateUpdateType.NESTED, target, value, "");
        bytes memory callargs =
            abi.encodeCall(IGasKillerNested.applyNested, (ctx.root, childLeaf, ctx.children[ctx.consumed++]));

        bytes32 previous = _pendingChild();
        _setPendingChild(childLeaf);
        bool success;
        bytes32 ack;
        assembly {
            success := call(gas(), target, value, add(callargs, 0x20), mload(callargs), 0, 0)
            if eq(returndatasize(), 0x20) {
                returndatacopy(0, 0, 0x20)
                ack := mload(0)
            }
        }
        _setPendingChild(previous);

        if (!success) {
            uint256 size;
            assembly {
                size := returndatasize()
            }
            bytes memory revertData = new bytes(size);
            assembly {
                returndatacopy(add(revertData, 0x20), 0, size)
            }
            revert RevertingContext(i, target, revertData, callargs);
        }
        if (ack != bytes32(IGasKillerNested.applyNested.selector)) revert NestedNotApplied(i, target);
    }

    /// @notice Validate that `arg` is a canonical, in-bounds ABI encoding of a LOG payload
    /// @dev Reverts with `MalformedLogPayload` on a truncated head, a non-canonical `data` offset, or a
    ///      `data` length that runs past the end of `arg`. `canonicalOffset` is the encoding's head size
    ///      `0x20 * (numTopics + 1)` (0x20 for LOG0, 0x40 for LOG1, ... 0xa0 for LOG4); it is also where the
    ///      `data` length word lives, and every fixed `bytes32` topic sits within the head before it.
    /// @param arg The ABI-encoded LOG payload to validate
    /// @param canonicalOffset The expected offset of the `data` field (equals the encoding's head size)
    function _validateLogArg(bytes memory arg, uint256 canonicalOffset) private pure {
        uint256 len = arg.length;
        // The head (offset word + topics) and the `data` length word must both be readable.
        if (len < canonicalOffset + 0x20) revert MalformedLogPayload();
        uint256 off;
        uint256 dataLen;
        assembly {
            let base := add(arg, 0x20)
            off := mload(base)
            dataLen := mload(add(base, canonicalOffset))
        }
        // Offset must match what abi.encode produces, and the data bytes must fit inside `arg`.
        // `len >= canonicalOffset + 0x20` above makes the subtraction below safe.
        if (off != canonicalOffset) revert MalformedLogPayload();
        if (dataLen > len - canonicalOffset - 0x20) revert MalformedLogPayload();
    }

    /// @notice Thrown when `types` and `args` arrays have different lengths
    error InvalidArguments();

    /// @notice Thrown when a program is run with an empty protected-range list. Every settlement
    ///         protects at least the SDK's own storage, so an empty list means a caller has
    ///         switched protection off, usually by accident.
    error NoProtectedRanges();

    /// @notice Thrown when a program's CALL, CREATE, CREATE2 and NESTED ops together would send
    ///         more than its `CallPolicy.valueCap`
    /// @param index The zero-based position of the op that passed the cap
    /// @param total The program's outgoing value including that op
    /// @param cap The cap
    error OutgoingValueExceeded(uint256 index, uint256 total, uint256 cap);

    /// @notice Thrown when a CALL op targets the running contract with a selector its
    ///         `CallPolicy.allowSelfCall` doesn't allow
    /// @param index The zero-based position of the op
    /// @param selector The call's first 4 bytes, zero-padded when its calldata is shorter
    error SelfCall(uint256 index, bytes4 selector);

    /// @notice Thrown when a LOG operation's payload is not a canonical, in-bounds ABI encoding
    error MalformedLogPayload();

    /// @notice Thrown when a CALL operation's external call reverts
    /// @param index The zero-based position of the failing operation in the batch
    /// @param target The contract address that was called
    /// @param revertData The raw revert data returned by the failed call
    /// @param callargs The calldata that was passed to the failed call
    error RevertingContext(uint256 index, address target, bytes revertData, bytes callargs);

    /// @notice Thrown when a NESTED operation appears in a program settled outside a tree
    error NestedOutsideTree();

    /// @notice Thrown when a NESTED operation has no witness left to hand its child
    /// @param index The zero-based position of the NESTED operation in the batch
    error MissingWitness(uint256 index);

    /// @notice Thrown when a NESTED operation's call succeeds without the child acknowledging it
    /// @param index The zero-based position of the NESTED operation in the batch
    /// @param target The address the NESTED operation called
    error NestedNotApplied(uint256 index, address target);

    /// @notice Thrown when a program finishes with witnesses no NESTED operation consumed
    error UnconsumedWitnesses(uint256 supplied, uint256 consumed);

    /// @notice Thrown when a CREATE or CREATE2 operation returns address(0)
    error DeploymentFailed();

    /// @notice Thrown when something the program pinned from the trace differs at settlement:
    ///         external state moved between the trace and settlement
    /// @param index The zero-based position of the operation
    /// @param expected What the trace observed: a result hash, a balance, a code hash or an
    ///        address, as a word
    /// @param actual What settlement observed, in the same form
    error ObservationMismatch(uint256 index, bytes32 expected, bytes32 actual);

    /// @notice Thrown when a CALL or CREATE payload isn't in its canonical layout, such as the
    ///         one from before result pinning
    /// @param index The zero-based position of the operation
    error MalformedOp(uint256 index);

    /// @notice Thrown when the gas left can't give a CALL op's callee all of its signed
    ///         `gasLimit`. Retrying with a higher gas limit settles it.
    /// @param index The zero-based position of the operation
    /// @param gasLimit The gas the callee must get
    error InsufficientCallGas(uint256 index, uint256 gasLimit);

    /// @notice Thrown when a batch item spent ETH that later items in the batch brought: on its
    ///         own, it couldn't have
    error UnattributedValueSpent();
}
