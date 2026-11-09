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
/// @dev Each variant maps to a different EVM operation: storage writes, external calls, log emissions, or contract deployment
enum StateUpdateType {
    /// @notice Write a 32-byte value directly to a storage slot
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
    /// @notice Apply an SDK-enabled callee's own signed frame of a nested tree
    NESTED
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

/// @title StateChangeHandlerLib
/// @notice Library for decoding and executing batched state update operations
/// @dev Processes ABI-encoded arrays of typed state updates; supports STORE, CALL, LOG0-LOG4, CREATE, CREATE2 and NESTED
library StateChangeHandlerLib {
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
    function _runStateUpdates(StateUpdateType[] memory types, bytes[] memory args) internal {
        NestedContext memory none;
        _run(types, args, none, _rejectNested);
    }

    /// @dev Runs a program inside the tree in `ctx`.
    function _runStateUpdates(StateUpdateType[] memory types, bytes[] memory args, NestedContext memory ctx) internal {
        _run(types, args, ctx, _runNested);
    }

    /// @notice Decodes and executes a series of state updates
    /// @dev This function processes an array of state updates, executing them in sequence. Each update can be one of:
    ///      - STORE: Direct storage writes using assembly
    ///      - CALL: External contract calls with value transfer
    ///      - LOG0-LOG4: Event emission with 0-4 indexed topics
    ///      - CREATE: Contract deployment via CREATE opcode
    ///      - CREATE2: Deterministic contract deployment via CREATE2 opcode
    ///      - NESTED: Hand a callee its own signed frame of the tree in `ctx`
    /// @param types Array of StateUpdateType enums indicating the type of each state update operation
    /// @param args Array of ABI-encoded arguments corresponding to each operation type
    /// @param ctx The tree this program runs inside; a zero root rejects every NESTED op
    /// @param nested The NESTED handler: `_runNested` inside a tree, `_rejectNested` outside one
    /// @dev types and args arrays must be equal length, with args[i] containing the encoded parameters for types[i]
    function _run(
        StateUpdateType[] memory types,
        bytes[] memory args,
        NestedContext memory ctx,
        function(uint256, bytes memory, NestedContext memory) nested
    ) private {
        uint256 length = types.length;
        require(length == args.length, InvalidArguments());
        for (uint256 i = 0; i < length; ++i) {
            StateUpdateType stateUpdateType = types[i];
            bytes memory arg = args[i];

            if (stateUpdateType == StateUpdateType.STORE) {
                (bytes32 slot, bytes32 value) = abi.decode(arg, (bytes32, bytes32));
                assembly {
                    sstore(slot, value)
                }
            } else if (stateUpdateType == StateUpdateType.CALL) {
                // Forwards all remaining gas (no stipend cap). In a batched settlement
                // (e.g. GasKillerSDK.verifyAndUpdateBatch) this is amplified: a
                // greedy or griefing target in an earlier sub-transition's CALL can consume
                // enough gas to starve every later sub-transition in the same batch,
                // reverting the whole (atomic) batch. No partial-state hazard — it's all or
                // nothing — but it does nullify the batch's cost amortization. See
                // IGasKillerSDKBatch for the batch-assembly-side note.
                (address target, uint256 value, bytes memory callargs) = abi.decode(arg, (address, uint256, bytes));
                bool success;
                assembly {
                    success := call(gas(), target, value, add(callargs, 0x20), mload(callargs), 0, 0)
                }
                // TODO: this section needs heavy testing
                if (!success) {
                    uint256 _returndatasize;
                    assembly {
                        _returndatasize := returndatasize()
                    }
                    bytes memory revertData = new bytes(_returndatasize);
                    assembly {
                        returndatacopy(add(revertData, 0x20), 0, _returndatasize)
                    }
                    revert RevertingContext(i, target, revertData, callargs);
                }
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
                (uint256 value, bytes memory initcode) = abi.decode(arg, (uint256, bytes));
                address deployed;
                assembly {
                    deployed := create(value, add(initcode, 0x20), mload(initcode))
                }
                require(deployed != address(0), DeploymentFailed());
            } else if (stateUpdateType == StateUpdateType.CREATE2) {
                (bytes32 salt, uint256 value, bytes memory initcode) = abi.decode(arg, (bytes32, uint256, bytes));
                address deployed;
                assembly {
                    deployed := create2(value, add(initcode, 0x20), mload(initcode), salt)
                }
                require(deployed != address(0), DeploymentFailed());
            } else if (stateUpdateType == StateUpdateType.NESTED) {
                nested(i, arg, ctx);
            }
        }
        if (ctx.consumed != ctx.children.length) revert UnconsumedWitnesses(ctx.children.length, ctx.consumed);
    }

    function _rejectNested(uint256, bytes memory, NestedContext memory) private pure {
        revert NestedOutsideTree();
    }

    /// @dev The child checks `pendingChild()` on its caller before applying anything, which is
    ///      what stops a frame from being applied anywhere but this op. The previous value is
    ///      restored afterwards because a cycle can nest pending children on one contract.
    ///      A call to an address without code, or to a permissive fallback, also succeeds, so
    ///      success alone does not show the frame applied; the child must echo its selector.
    function _runNested(uint256 i, bytes memory arg, NestedContext memory ctx) private {
        if (ctx.root == bytes32(0)) revert NestedOutsideTree();
        (address target, uint256 value, bytes32 childLeaf) = abi.decode(arg, (address, uint256, bytes32));
        if (ctx.consumed >= ctx.children.length) revert MissingWitness(i);
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
}

// src/libraries/StorageGuard.sol

/// @title StorageGuard
/// @notice Checks a signed program's `STORE` writes against a denylist of protected storage
///         ranges, so a quorum-signed update cannot overwrite slots such as an `Ownable` owner,
///         the `StateTracker` counter, the SDK's own configuration or EIP-1967 proxy slots.
/// @dev The list denies rather than allows. Honest writes to mappings and dynamic arrays land on
///      keccak-derived slots spread across the whole slot space, which an allowlist of ranges
///      cannot express, while every slot worth protecting is known at compile time. Reaching a
///      protected slot from an honest write would take a keccak preimage, so a hit means the
///      program is malicious and the whole program is rejected.
///
///      Ranges are inclusive `[start, end]` intervals, strictly ascending and non-overlapping.
///      **The per-write checkers (`checkEach`, `checkEachLinear`, `advance`) assume this and do not
///      check it**: an unsorted or overlapping list fails open, silently letting writes to
///      protected slots through. Their caller must run `validateRanges` once on the list, in a
///      constructor, or before the loop when the list is built at run time. Validating on every
///      write would cost O(k) per write, more than the check itself. `checkProgram` and
///      `checkProgramEach` validate the list themselves, once per program. `mask` is `FULL` to deny every write to the range, even one that
///      stores the value already there, which saves the SLOAD. A narrower mask protects
///      only some bits of one packed slot: a write passes when it leaves those bits as they are
///      in storage, which costs one SLOAD on a hit and nothing otherwise.
///
///      Three checkers, which agree on every input (the test suite fuzzes this):
///        - `checkEach`: stateless, one binary search per write.
///        - `checkEachLinear`: stateless, a scan from the first range; kept for comparison.
///        - `Cursor` + `advance`: one forward pass. Writes in ascending slot order walk the
///          ranges together, and once a write is past the last range every later ascending
///          write costs one comparison. A write below its predecessor re-seats the cursor by
///          binary search instead of reverting, so the order of the writes affects only gas,
///          never the verdict. Input sorted within each CALL/CREATE-bounded slice, as
///          gas-analyzer's canonical extraction emits it, pays one re-seat per slice.
///
///      Masked ranges are checked against storage as it stands when the check runs, so the
///      per-write checkers are sound only when called right before each write executes, inline
///      in `_run`. A pre-pass (`checkProgram`) sees storage as it was before the program. A STORE
///      can't make the two differ on protected bits: any STORE that changed them would itself
///      have been rejected. But a CALL, CREATE, CREATE2 or NESTED op runs code that can
///      legitimately change them, for example by re-entering an owner-gated setter, and a later
///      STORE could then quietly put the old bits back. So once a pre-pass has passed such an
///      op, it rejects every later write to a masked range (`MaskedWriteAfterExternalCode`).
///      Fully protected ranges don't depend on storage and are unaffected.
///
///      Not covered: a `CALL` update to `address(this)` can reach privileged functions directly,
///      so a consumer relying on this guard should also restrict self-calls. `NESTED` frames
///      are checked by each frame's own contract.
library StorageGuard {
    /// @notice One protected interval of storage slots.
    /// @param start First protected slot (inclusive).
    /// @param end Last protected slot (inclusive).
    /// @param mask Protected bits within the slot: `FULL` for every bit, anything narrower only
    ///        when `start == end`.
    struct ProtectedRange {
        uint256 start;
        uint256 end;
        bytes32 mask;
    }

    /// @notice Merge state carried across consecutive writes.
    /// @param next Index of the first range whose end is at or above the previous write's slot.
    /// @param prev The previous write's slot.
    /// @param blind Set by a pre-pass once it has passed an op that runs code. Storage may then
    ///        differ from what the write will see, so a masked hit is rejected. Leave it false
    ///        when checking inline, right before each write.
    struct Cursor {
        uint256 next;
        uint256 prev;
        bool blind;
    }

    bytes32 internal constant FULL = bytes32(type(uint256).max);

    /// @notice A write would change protected bits.
    /// @param index Position of the offending op in its program (or in the caller's own sequence).
    /// @param slot The protected slot it writes.
    error ProtectedSlotWrite(uint256 index, bytes32 slot);

    /// @notice A pre-pass found a write to a masked range after an op that runs code. The pre-pass
    ///      can only compare with storage as it was before the program, and that code may have
    ///      changed the protected bits since.
    /// @param index Position of the offending `STORE` in its program.
    /// @param slot The masked slot it writes.
    error MaskedWriteAfterExternalCode(uint256 index, bytes32 slot);

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

    // The hot paths below walk `ranges` in assembly. A `ProtectedRange[] memory` is a length
    // word followed by one pointer per element, and each element is three words: start, end,
    // mask. Every loop compares its index with the length before dereferencing it. A loop yields
    // `hit`, the pointer of the range covering the slot or zero, and only then calls `_reject`,
    // which reads the mask and decides.

    /// @notice Stateless check of one write: one binary search.
    /// @dev `ranges` must have passed `validateRanges`; an unvalidated list can fail open.
    function checkEach(ProtectedRange[] memory ranges, uint256 index, bytes32 slot, bytes32 value) internal view {
        uint256 hit = _covering(ranges, uint256(slot));
        if (hit != 0) _reject(hit, index, slot, value, false);
    }

    /// @notice Stateless check of one write by linear scan; for comparison with `checkEach`.
    /// @dev `ranges` must have passed `validateRanges`; an unvalidated list can fail open.
    function checkEachLinear(ProtectedRange[] memory ranges, uint256 index, bytes32 slot, bytes32 value) internal view {
        uint256 s = uint256(slot);
        uint256 hit;
        assembly ("memory-safe") {
            let it := add(ranges, 0x20)
            for { let last := add(it, shl(5, mload(ranges))) } lt(it, last) { it := add(it, 0x20) } {
                let r := mload(it)
                if iszero(lt(mload(add(r, 0x20)), s)) {
                    if iszero(gt(mload(r), s)) { hit := r }
                    break
                }
            }
        }
        if (hit != 0) _reject(hit, index, slot, value, false);
    }

    /// @notice Checks one write and moves `c` past it. Start from a zeroed `Cursor`.
    /// @dev `ranges` must have passed `validateRanges`; an unvalidated list can fail open.
    function advance(Cursor memory c, ProtectedRange[] memory ranges, uint256 index, bytes32 slot, bytes32 value)
        internal
        view
    {
        uint256 s = uint256(slot);
        uint256 i = c.next;
        if (s < c.prev) i = _lowerBound(ranges, s);
        uint256 hit;
        assembly ("memory-safe") {
            let len := mload(ranges)
            let base := add(ranges, 0x20)
            for {} lt(i, len) { i := add(i, 1) } {
                if iszero(lt(mload(add(mload(add(base, shl(5, i))), 0x20)), s)) { break }
            }
            mstore(c, i)
            mstore(add(c, 0x20), s)
            if lt(i, len) {
                let r := mload(add(base, shl(5, i)))
                if iszero(gt(mload(r), s)) { hit := r }
            }
        }
        if (hit != 0) _reject(hit, index, slot, value, c.blind);
    }

    /// @notice Checks every `STORE` in a decoded program with one cursor, before it runs.
    /// @dev Expects the same `(types, args)` pair `StateChangeHandlerLib._runStateUpdates` takes
    ///      and rejects the same malformed input (`InvalidArguments`, a short STORE payload).
    ///      After the first op that runs code, a write to a masked range reverts with
    ///      `MaskedWriteAfterExternalCode`, since its protected bits can no longer be predicted.
    ///      Validates `ranges` first (`InvalidRanges`), even for a program with no STOREs.
    function checkProgram(StateUpdateType[] memory types, bytes[] memory args, ProtectedRange[] memory ranges)
        internal
        view
    {
        uint256 len = types.length;
        require(len == args.length, StateChangeHandlerLib.InvalidArguments());
        validateRanges(ranges);
        if (ranges.length == 0) return;
        Cursor memory c;
        for (uint256 i = 0; i < len; i = _inc(i)) {
            StateUpdateType t = types[i];
            if (t != StateUpdateType.STORE) {
                if (!c.blind) c.blind = _runsCode(t);
                continue;
            }
            (bytes32 slot, bytes32 value) = abi.decode(args[i], (bytes32, bytes32));
            advance(c, ranges, i, slot, value);
        }
    }

    /// @notice `checkProgram` with a stateless check per write; for comparison. Validates `ranges`
    ///         first, as `checkProgram` does.
    function checkProgramEach(StateUpdateType[] memory types, bytes[] memory args, ProtectedRange[] memory ranges)
        internal
        view
    {
        uint256 len = types.length;
        require(len == args.length, StateChangeHandlerLib.InvalidArguments());
        validateRanges(ranges);
        if (ranges.length == 0) return;
        bool ranCode;
        for (uint256 i = 0; i < len; i = _inc(i)) {
            StateUpdateType t = types[i];
            if (t != StateUpdateType.STORE) {
                if (!ranCode) ranCode = _runsCode(t);
                continue;
            }
            (bytes32 slot, bytes32 value) = abi.decode(args[i], (bytes32, bytes32));
            uint256 hit = _covering(ranges, uint256(slot));
            if (hit != 0) _reject(hit, i, slot, value, ranCode);
        }
    }

    /// @dev Index of the first range whose end is at or above `s`, or `ranges.length` when there
    ///      is none. `lo < hi <= length` keeps `mid` in bounds and every sum below 2^256.
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

    /// @dev Pointer to the range covering `s`, or zero: `_lowerBound` plus the start check.
    function _covering(ProtectedRange[] memory ranges, uint256 s) private pure returns (uint256 hit) {
        assembly ("memory-safe") {
            let len := mload(ranges)
            let base := add(ranges, 0x20)
            let lo := 0
            for { let hi := len } lt(lo, hi) {} {
                let mid := shr(1, add(lo, hi))
                switch lt(mload(add(mload(add(base, shl(5, mid))), 0x20)), s)
                case 1 { lo := add(mid, 1) }
                default { hi := mid }
            }
            if lt(lo, len) {
                let r := mload(add(base, shl(5, lo)))
                if iszero(gt(mload(r), s)) { hit := r }
            }
        }
    }

    /// @dev Ops that execute code which can write this contract's storage. LOGs don't.
    function _runsCode(StateUpdateType t) private pure returns (bool) {
        return t == StateUpdateType.CALL || t == StateUpdateType.CREATE || t == StateUpdateType.CREATE2
            || t == StateUpdateType.NESTED;
    }

    /// @dev Increment for an index bounded by an array length, which cannot overflow.
    function _inc(uint256 i) private pure returns (uint256) {
        unchecked {
            return i + 1;
        }
    }

    /// @dev `range` points at a range covering `slot`. Reverts unless the range is masked and the
    ///      write leaves every masked bit as it is in storage. `blind` means storage may not be
    ///      what it will be when the write runs (a pre-pass past code-running ops), so a masked
    ///      hit can't be judged and is rejected.
    function _reject(uint256 range, uint256 index, bytes32 slot, bytes32 value, bool blind) private view {
        bytes32 mask;
        assembly ("memory-safe") {
            mask := mload(add(range, 0x40))
        }
        if (mask != FULL) {
            if (blind) revert MaskedWriteAfterExternalCode(index, slot);
            bytes32 current;
            assembly ("memory-safe") {
                current := sload(slot)
            }
            if ((current ^ value) & mask == 0) return;
        }
        revert ProtectedSlotWrite(index, slot);
    }
}
