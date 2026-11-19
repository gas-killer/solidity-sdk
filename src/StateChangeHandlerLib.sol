// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IGasKillerNested} from "./interface/IGasKillerNested.sol";
import {StorageGuard} from "./libraries/StorageGuard.sol";

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

/// @notice What a program may send out of its contract. Checked before every op that runs other
///         code with the contract's authority or moves its ETH: `CALL`, `CREATE`, `CREATE2` and
///         `NESTED`.
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
    ///      to protected slots through. `GasKillerSDK` uses it with `_settlementRanges()`, which
    ///      is a constant of the contract's code and validated by its constructor. An empty list
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
        uint256 sent = policy.sent + value;
        if (sent > policy.valueCap) revert OutgoingValueExceeded(index, sent, policy.valueCap);
        policy.sent = sent;
    }

    /// @dev Rejects a `CALL` to the running contract unless the policy's `allowSelfCall` allows
    ///      its selector. Kept out of line so a `CALL` elsewhere pays only the address check.
    ///      Selector zero stands only for empty calldata (a plain ETH transfer). Calldata of 1 to 3
    ///      bytes, or of 4 or more starting with `0x00000000`, is rejected without asking
    ///      `allowSelfCall`: Solidity routes it to the fallback with a payload, so allowing the
    ///      ETH-transfer case, or a selector its zero-padding matches, must not let it through.
    function _checkSelfCall(CallPolicy memory policy, uint256 index, bytes memory data) private view {
        uint256 length = data.length;
        bytes4 selector = bytes4(data); // zero-padded when shorter than 4 bytes
        bool wellFormed = length == 0 || (length >= 4 && selector != bytes4(0));
        require(wellFormed && policy.allowSelfCall(selector), SelfCall(index, selector));
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
                // Forwards all remaining gas (no stipend cap). In a batched settlement
                // (e.g. GasKillerSDK.verifyAndUpdateBatch) this is amplified: a
                // greedy or griefing target in an earlier sub-transition's CALL can consume
                // enough gas to starve every later sub-transition in the same batch,
                // reverting the whole (atomic) batch. No partial-state hazard — it's all or
                // nothing — but it does nullify the batch's cost amortization. See
                // IGasKillerSDKBatch for the batch-assembly-side note.
                (address target, uint256 value, bytes memory callargs) = abi.decode(arg, (address, uint256, bytes));
                if (target == address(this)) _checkSelfCall(policy, i, callargs);
                _authorize(policy, i, StateUpdateType.CALL, target, value, callargs);
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
                _authorize(policy, i, StateUpdateType.CREATE, address(0), value, initcode);
                address deployed;
                assembly {
                    deployed := create(value, add(initcode, 0x20), mload(initcode))
                }
                require(deployed != address(0), DeploymentFailed());
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
            }
        }
        if (ctx.consumed != ctx.children.length) revert UnconsumedWitnesses(ctx.children.length, ctx.consumed);
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
        _authorize(policy, i, StateUpdateType.NESTED, target, value, "");
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
}
