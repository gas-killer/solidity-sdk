// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IGasKillerSDK} from "./interface/IGasKillerSDK.sol";
import {IGasKillerSDKBatch, TaskSubmission} from "./interface/IGasKillerSDKBatch.sol";
import {IGasKillerValueBound} from "./interface/IGasKillerValueBound.sol";
import {StateTracker} from "./StateTracker.sol";
import {TransitionGuard} from "./TransitionGuard.sol";
import {StateChangeHandlerLib, StateUpdateType, CallPolicy} from "./StateChangeHandlerLib.sol";
import {StorageGuard} from "./libraries/StorageGuard.sol";
import {ISchnorrStakeRegistry} from "./interface/ISchnorrStakeRegistry.sol";

/// @title GasKillerSDK
/// @notice Base contract for Gas Killer targets. Authorises a state transition with a
///         **single** aggregate Schnorr signature verified against a `SchnorrStakeRegistry`
///         (constant gas, non-signer subtraction) and applies the signed state updates.
///
/// @dev The signed message is `sha256(abi.encode(transitionIndex, address(this),
///      targetFunction, storageUpdates))` for a transition settled with no ETH, and
///      `sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates,
///      value))` for one settled with `value` wei. It is independent of the signature scheme,
///      so the off-chain digest and the slashing/fraud-proof machinery do not depend on it.
///
///      Binding the value is what makes inbound ETH safe: a tracked function that credits
///      `msg.value` replays as plain `STORE` updates, so without it anyone could settle a
///      deposit while sending nothing. A zero-value transition keeps the original four-field
///      encoding, so every zero-value signature is unchanged; the two encodings cannot collide
///      because their heads differ in length.
///
///      Both entrypoints are `guardTransition`-protected (see `TransitionGuard`): a `CALL`
///      state update runs arbitrary external code mid-transition, so re-entering
///      `verifyAndUpdate` with the *next* transition's valid signature would otherwise
///      interleave two signed transitions. The same transient flag is queryable as
///      `inTransition()` so external readers can reject mid-transition state.
///
///      Both entrypoints are also `payable`. The value is part of what the quorum signs, so a
///      transition settles only with the value it was analyzed with; see the per-function docs.
///
///      Nested settlement is opt-in through `GasKillerNestedSDK`, so a consumer that never
///      nests does not carry its bytecode; a `NESTED` op settled here reverts.
///
///      Protected storage: every `STORE` a signed program carries is checked, right before it
///      executes, against `gasKillerProtectedRanges()`. A write that would change a protected bit reverts
///      the transition (`StorageGuard.ProtectedSlotWrite`). The SDK always protects its own
///      storage: the transition counter and the whole ERC-7201 namespace of the configuration
///      struct (AVS address, registry, stale-block window), and, behind a proxy, the EIP-1967 slots.
///      Consumers add theirs, such as an `Ownable` owner slot, by overriding `_protectedRanges()`.
///      A write that leaves protected bits unchanged passes, which is what keeps the counter copy
///      gas-analyzer puts in every program working. The counter may also move forward, never
///      back, so a tracked function that bumps it more than once natively still settles
///      (`StorageGuard.COUNTER_SLOT`).
abstract contract GasKillerSDK is
    StateTracker,
    TransitionGuard,
    ERC165,
    IGasKillerSDK,
    IGasKillerSDKBatch,
    IGasKillerValueBound
{
    /// @dev Lives in the ERC-7201 namespace at `STORAGE_LOCATION`, and signed programs may not
    ///      change any slot of that namespace (see `_settlementRanges`). Two rules keep every field
    ///      covered when the struct grows: it must fit in the namespace's 256 slots, and it must
    ///      hold only value types. A mapping or dynamic array here would store its entries at
    ///      keccak-derived slots outside the namespace, where they would be unprotected.
    ///
    ///      **Its setters (`_setAvsAddress`, `_setSchnorrRegistry`, `_setBlockStaleMeasure`) must
    ///      not be called from a `trackState` function.** A tracked function that changes a
    ///      config value carries that write in its program, and settlement rejects it every time
    ///      with `StorageGuard.ProtectedSlotWrite`: the transition can never settle. Call them
    ///      from the constructor, an initializer, or an admin function that is not `trackState`,
    ///      all of which run natively and are never settled. Storing the value already there
    ///      changes nothing and passes.
    struct GasKillerSDKStorage {
        address avsAddress;
        ISchnorrStakeRegistry registry;
        uint96 blockStaleMeasure;
        OutgoingBucket outgoing;
        TokenLimits tokens;
    }

    /// @dev The outgoing-value budget of `GasKillerOutgoingRateLimit`, kept here so that it is
    ///      protected storage: a signed program that could write it could refill its own budget.
    ///      All zero, and never read, in a contract that doesn't use the extension. One slot.
    /// @param limit Most wei the budget holds, which is also what refills over one `period`.
    /// @param available Wei left at `updated`.
    /// @param period Seconds a full refill takes.
    /// @param updated Timestamp `available` was last computed at.
    struct OutgoingBucket {
        uint96 limit;
        uint96 available;
        uint32 period;
        uint32 updated;
    }

    /// @dev The per-token budgets of `TokenRateLimit`, kept here for the same reason as
    ///      `OutgoingBucket`. A fixed array rather than a mapping: a mapping's entries would live
    ///      at keccak-derived slots outside the protected namespace. All zero, and never read, in a
    ///      contract that doesn't use per-token limits. 17 slots.
    /// @param count Tokens in use, the first `count` entries of `buckets`.
    struct TokenLimits {
        uint256 count;
        TokenBucket[8] buckets;
    }

    /// @dev One token's budget: like `OutgoingBucket`, in two slots.
    struct TokenBucket {
        address token;
        uint32 period;
        uint32 updated;
        uint128 limit;
        uint128 available;
    }

    // keccak256(abi.encode(uint256(keccak256("gaskiller.SchnorrGasKillerSDK.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION = 0x1d6f9f139320a34a32f3b29eb8638270178e831962a74100c9e8b433f21e1200;

    /// @dev Last slot of the ERC-7201 namespace that starts at `STORAGE_LOCATION`. The formula
    ///      clears the low byte, so the namespace is the 256-slot block ending here, whatever the
    ///      struct's current size.
    uint256 private constant CONFIG_NAMESPACE_END = uint256(STORAGE_LOCATION) | 0xff;

    uint256 private constant DEFAULT_BLOCK_STALE_MEASURE = 300;

    /// @dev The address this code was deployed to. Running anywhere else means a proxy
    ///      delegatecalled it, and settlement then protects the EIP-1967 slots too.
    address private immutable _self = address(this);

    /// @dev The EIP-1967 proxy slots: behind a proxy, a signed `STORE` to the implementation slot
    ///      would replace the contract's code.
    uint256 private constant EIP1967_IMPLEMENTATION =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 private constant EIP1967_BEACON = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    uint256 private constant EIP1967_ADMIN = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    error FutureBlockNumber();
    error StaleBlockNumber();
    error InvalidTransitionIndex();
    error InvalidSignature();
    error InvalidQuorumSignature();
    error EmptyBatch();
    error InsufficientBatchValue(uint256 sent, uint256 required);
    error BlockStaleMeasureOverflow();

    /// @notice Validates the protected-range list once, at deployment.
    /// @dev `_protectedRanges` is `pure`, so the list can't depend on anything a consumer's own
    ///      constructor sets later, and it can't change after deployment. Settlement therefore
    ///      relies on this check instead of repeating it. A malformed list reverts here with
    ///      `StorageGuard.InvalidRanges`. Behind a proxy, the implementation's constructor runs it
    ///      against the same code the proxy executes.
    constructor() {
        StorageGuard.validateRanges(_mergeRanges(false));
        StorageGuard.validateRanges(_mergeRanges(true));
    }

    /// @notice Verify an aggregate Schnorr quorum signature and apply the state updates.
    /// @dev `msg.value` is bound into the digest, so the transition settles only with exactly
    ///      the value the task was analyzed with: a deposit cannot be credited without its ETH,
    ///      and no surplus can be sent. Value moved by `CALL`/`CREATE`/`CREATE2` updates is fixed
    ///      inside the signed `storageUpdates` and paid out of this contract's balance, which
    ///      includes `msg.value`; a shortfall reverts the whole transition (`RevertingContext` for
    ///      a CALL, `DeploymentFailed` for a CREATE/CREATE2).
    /// @param msgHash             the task digest (recomputed and checked below).
    /// @param referenceBlockNumber block at which stake/keys are evaluated by the registry.
    /// @param storageUpdates      ABI-encoded `(StateUpdateType[], bytes[])`.
    /// @param transitionIndex     expected `stateTransitionCount() - 1`.
    /// @param targetFunction      selector bound into the digest.
    /// @param s                   aggregate Schnorr response scalar.
    /// @param Raddr               aggregate nonce address `address(R)`.
    /// @param nonSigners          operators that did not sign, strictly ascending.
    function verifyAndUpdate(
        bytes32 msgHash,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes4 targetFunction,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners
    ) external payable guardTransition {
        _verifyTransition(
            msgHash,
            referenceBlockNumber,
            storageUpdates,
            transitionIndex,
            targetFunction,
            msg.value,
            s,
            Raddr,
            nonSigners
        );
        // Inline rather than a helper: a helper isn't inlined and costs ~22 gas per settlement.
        // Must match `_guardRanges`.
        StorageGuard.ProtectedRange[] memory ranges;
        if (!_unsafeDisableStorageGuard()) ranges = _settlementRanges();
        _stateChangeHandler(storageUpdates, ranges);
    }

    /// @notice Verify and apply a sequence of independently signed state transitions in
    ///         one transaction, amortizing the intrinsic and cold-access costs across the
    ///         batch (sub-transitions after the first verify at warm-access prices).
    /// @dev Each applied submission is checked exactly as a standalone `verifyAndUpdate`
    ///      would check it — same digest, same registry verification — so batching changes
    ///      nothing for the off-chain signing path. Transitions apply in order; the
    ///      `guardTransition` latch is held across the whole batch, and any failing
    ///      sub-transition reverts the entire batch.
    ///
    ///      A submission whose `transitionIndex` is already settled is SKIPPED (not
    ///      validated, not applied) rather than reverting the batch: settlement is
    ///      permissionless, so a third party who lifts one submission from the mempool
    ///      and settles it standalone could otherwise nullify the whole batch with one
    ///      cheap front-run. An index below the counter was either settled or jumped over
    ///      by a transition that moved the counter forward, so it can never settle.
    ///      Reverts (`InvalidTransitionIndex`) only on a genuine gap — an index above the
    ///      next expected one.
    ///
    ///      Batch assemblers: a `CALL` state update forwards all remaining gas to its target
    ///      with no cap (see `StateChangeHandlerLib`). A greedy/griefing target in an early
    ///      sub-transition can therefore starve every later one in the same batch, reverting
    ///      the whole (atomic) batch — no partial-state hazard, but it does nullify the
    ///      amortization this function exists for.
    ///
    ///      Each submission's digest binds its own `value`, and `msg.value` must cover the sum
    ///      over the submissions actually applied (`InsufficientBatchValue` otherwise), so no
    ///      applied transition is credited ETH the batch did not bring. The check is "covers"
    ///      rather than "equals" because a skipped submission must not revert the batch. The
    ///      surplus, such as a front-run item's share, is refunded to `msg.sender` once every
    ///      update has applied. A sender that can't accept it leaves it in this contract
    ///      rather than reverting the batch.
    /// @param submissions The transitions to apply, in order of ascending transition index.
    function verifyAndUpdateBatch(TaskSubmission[] calldata submissions) external payable guardTransition {
        uint256 len = submissions.length;
        require(len != 0, EmptyBatch());
        // Built once for the whole batch: the list is a compile-time constant, validated at
        // deployment, so every item would rebuild the same thing. Inline, and must match
        // `_guardRanges`, as in `verifyAndUpdate`.
        StorageGuard.ProtectedRange[] memory ranges;
        if (!_unsafeDisableStorageGuard()) ranges = _settlementRanges();
        uint256 required;
        for (uint256 i = 0; i < len; ++i) {
            TaskSubmission calldata sub = submissions[i];
            // Already settled (e.g. front-run or redelivered) → skip, don't poison the batch.
            if (sub.transitionIndex + 1 <= stateTransitionCount()) continue;
            required += sub.value;
            _verifyTransition(
                sub.msgHash,
                sub.referenceBlockNumber,
                sub.storageUpdates,
                sub.transitionIndex,
                sub.targetFunction,
                sub.value,
                sub.s,
                sub.Raddr,
                sub.nonSigners
            );
            _stateChangeHandler(sub.storageUpdates, ranges);
        }
        require(msg.value >= required, InsufficientBatchValue(msg.value, required));
        if (msg.value > required) {
            // Under the latch, so the refund can't re-enter settlement. A sender that rejects ETH
            // keeps the surplus here rather than reverting a batch the skip exists to protect.
            (bool refunded,) = msg.sender.call{value: msg.value - required}("");
            refunded;
        }
    }

    /// @dev The checks shared by both entrypoints: bumps the transition counter (`trackState`)
    ///      and verifies the transition, but doesn't apply it. Callers must hold the
    ///      `guardTransition` latch and apply the program with `_stateChangeHandler` straight
    ///      after, which keeps the order the same as before: count, check, run.
    function _verifyTransition(
        bytes32 msgHash,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes4 targetFunction,
        uint256 value,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners
    ) private trackState {
        require(referenceBlockNumber < block.number, FutureBlockNumber());
        require((uint256(referenceBlockNumber) + _getBlockStaleMeasure()) >= block.number, StaleBlockNumber());

        require(transitionIndex + 1 == stateTransitionCount(), InvalidTransitionIndex());
        require(_digest(transitionIndex, targetFunction, storageUpdates, value) == msgHash, InvalidSignature());

        _verifyQuorum(msgHash, s, Raddr, nonSigners, referenceBlockNumber);
    }

    function _verifyQuorum(
        bytes32 msgHash,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners,
        uint32 referenceBlockNumber
    ) private view {
        bool ok = _schnorrRegistry().isValidSignature(msgHash, s, Raddr, nonSigners, referenceBlockNumber);
        require(ok, InvalidQuorumSignature());
    }

    /// @dev `ranges` is the `_guardRanges()` list, built inline by the entrypoint once per call.
    ///      The opt-out is dispatched here (and in `GasKillerNestedSDK._runProgram`), never by
    ///      the list: an opted-out program ignores `ranges`, and a guarded one with an empty list
    ///      reverts (`NoProtectedRanges`), so the list alone never turns protection off.
    ///      Every CALL, CREATE, CREATE2 and NESTED goes through `_callPolicy()`.
    function _stateChangeHandler(bytes calldata storageUpdates, StorageGuard.ProtectedRange[] memory ranges) private {
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        _beforeProgram();
        CallPolicy memory policy = _callPolicy();
        if (_unsafeDisableStorageGuard()) StateChangeHandlerLib._runStateUpdatesUnguarded(types, args, policy);
        else StateChangeHandlerLib._runStateUpdatesPrevalidated(types, args, ranges, policy);
        _afterProgram();
    }

    /// @notice Override to act right before a signed program runs, after it was verified.
    ///         Does nothing by default. Runs before the program's call policy is built, so
    ///         `_maxOutgoingValue` sees what it sets.
    /// @dev Paired with `_afterProgram`. Programs can nest on one contract (a nested tree can
    ///      re-enter it), so per-program state should be kept per depth, for example in
    ///      transient storage, as `TokenRateLimit` does.
    function _beforeProgram() internal virtual {}

    /// @notice Override to act right after a signed program ran; revert to reject it. Does
    ///         nothing by default.
    function _afterProgram() internal virtual {}

    /// @dev The policy a program runs under: `_maxOutgoingValue`'s cap, the self-call check and
    ///      `_authorizeCall`. Fresh per program, so each transition of a batch has its own cap.
    ///
    ///      None of the policy hooks is told which tracked function a transition is for. The
    ///      quorum names that function and nothing checks it against the program, so a
    ///      per-function rule would only look narrower than it is: every hook must hold for any
    ///      program.
    function _callPolicy() internal view returns (CallPolicy memory) {
        return CallPolicy(_maxOutgoingValue(), 0, _authorizeCall, _allowSelfCall);
    }

    /// @notice Override to let a signed program `CALL` this contract. Rejects every self-call
    ///         by default (`StateChangeHandlerLib.SelfCall`).
    /// @dev Checked by `StateChangeHandlerLib` first, before the op's value is counted against
    ///      `_maxOutgoingValue` and before `_authorizeCall`, so an `_authorizeCall` override that
    ///      leaves out `super` can't drop it. A rejected self-call reverts with `SelfCall` even if
    ///      it would also pass the cap.
    ///      A self-call runs with `msg.sender == address(this)`, so it reaches functions gated
    ///      on it (self-governed setters, `onlyGovernance`-style admin), and a tracked function
    ///      it reaches runs natively, bumping the transition counter outside `StorageGuard`.
    ///      gas-analyzer does emit a tracked function's `this.foo()` (including
    ///      `try this.foo()`) as a self-`CALL`, so a contract whose tracked functions do that
    ///      must allow those selectors, and only those:
    ///      ```
    ///      function _allowSelfCall(bytes4 selector) internal pure override returns (bool) {
    ///          return selector == this.doThing.selector;
    ///      }
    ///      ```
    ///      Internal calls (`foo()`, `_foo()`) are jumps, not `CALL`s, and never get here. Nor
    ///      do `NESTED` ops, which the callee checks against its own signed frame. Keep it
    ///      `pure` where you can: a constant list costs no storage read and can't be changed.
    ///
    ///      Only calls to `address(this)` are covered. Another contract that trusts this one as
    ///      `msg.sender` (a vault gated `onlyRouter`, a sibling in a nested tree, a `ProxyAdmin`
    ///      this contract owns) is reached by an ordinary `CALL`: restrict those in
    ///      `_authorizeCall`.
    ///
    ///      **An allowed selector runs outside the call policy.** Its function runs natively, so
    ///      what it does (its own `CALL`s, ETH it sends on, including the self-call's own value)
    ///      isn't seen by `_authorizeCall`, `_maxOutgoingValue` or an outgoing rate limit. A
    ///      malicious quorum chooses its arguments. Allow only functions that are safe to call
    ///      with any arguments, or that enforce their own limits.
    ///
    ///      The list applies to every program, root and nested frames alike (see `_callPolicy`).
    /// @param selector The first 4 bytes of the call's data, or zero for empty calldata (a plain
    ///        ETH transfer to this contract). Other calldata under 4 bytes, and calldata with
    ///        selector zero and a payload, is rejected before this hook is asked.
    function _allowSelfCall(bytes4 selector) internal view virtual returns (bool) {
        selector;
        return false;
    }

    /// @notice Override to restrict what a signed program may do with this contract's authority.
    ///         Called before every `CALL`, `CREATE`, `CREATE2` and `NESTED` op of a program;
    ///         revert to reject the op, and with it the whole transition. Allows everything by
    ///         default, apart from self-calls, which are rejected before this hook runs unless
    ///         `_allowSelfCall` allows them.
    /// @dev `StorageGuard` only checks `STORE`s. A `CALL` runs real code as this contract, so
    ///      without a policy a quorum that signs a malicious program can, for example:
    ///      - transfer or approve tokens this contract holds;
    ///      - send this contract's ETH through a `CALL`, `CREATE`, `CREATE2` or `NESTED` value;
    ///      - call this contract's own functions gated on `msg.sender == address(this)`, if
    ///        `_allowSelfCall` allows their selectors.
    ///
    ///      A signed program doesn't carry the user's arguments or `msg.sender`, and honest
    ///      programs often call targets only known at run time, so the policy is code rather than
    ///      a list: check what the tracked functions can legitimately do. The hook is not `view`,
    ///      so it can keep state, such as a rate limit. For example, to allow tokens out only to
    ///      a known payee:
    ///      ```
    ///      function _authorizeCall(uint256 index, StateUpdateType, address target, uint256, bytes memory data)
    ///          internal override
    ///      {
    ///          if (target == address(token) && !_isTransferToPayee(data)) revert DisallowedCall(index);
    ///      }
    ///      ```
    ///      Per-program value totals are capped with `_maxOutgoingValue`, which runs first.
    ///
    ///      **This only sees what the program's own ops do.** A quorum can also `STORE` into this
    ///      contract's own state (a balance mapping can't be protected) and then withdraw through
    ///      the contract's normal functions in a later transaction, which no call policy sees.
    /// @param index The op's position in the program.
    /// @param kind `CALL`, `CREATE`, `CREATE2` or `NESTED`.
    /// @param target The callee; zero for `CREATE`/`CREATE2`.
    /// @param value Wei the op sends.
    /// @param data The calldata of a `CALL`, the initcode of a `CREATE`/`CREATE2`, empty for a
    ///        `NESTED` op (the callee checks its own signed frame). **Read it, never write it**:
    ///        it is the buffer the op runs from, so a change would run a call nobody signed.
    function _authorizeCall(uint256 index, StateUpdateType kind, address target, uint256 value, bytes memory data)
        internal
        virtual {}

    /// @notice Override to cap the wei one signed program may send out of this contract, summed
    ///         over its `CALL`, `CREATE`, `CREATE2` and `NESTED` ops. A program that would send
    ///         more reverts with `StateChangeHandlerLib.OutgoingValueExceeded`. Unlimited by
    ///         default.
    /// @dev Read once per program, before it runs. The total counts what the program sends,
    ///      whatever `msg.value` brought in. Value sent to this contract itself, by a self-call
    ///      `_allowSelfCall` allowed, stays here and doesn't count; what the allowed function then
    ///      sends natively isn't counted either. Each item of a batch, and each frame of a nested
    ///      tree, is capped on its own.
    ///
    ///      **Not a drain bound.** A malicious quorum can sign any number of transitions, or batch
    ///      items, each with its own cap. This guards against an honest program sending more than
    ///      intended; to bound outflow over time, use an outgoing rate limit.
    function _maxOutgoingValue() internal view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @notice The storage ranges a signed program may not change: the SDK's own slots merged
    ///         with the consumer's `_protectedRanges()`, in ascending order. Empty when the
    ///         consumer has opted out of the check (`_unsafeDisableStorageGuard`); a guarded
    ///         contract always lists at least the SDK's two ranges, five behind a proxy.
    /// @dev A compile-time constant of this contract's code, validated once by the constructor
    ///      (see `constructor`), so it can't be malformed once deployed. Prefixed like no other
    ///      SDK getter because a generic `protectedRanges` could already exist in a consumer.
    function gasKillerProtectedRanges() external view returns (StorageGuard.ProtectedRange[] memory) {
        return _guardRanges();
    }

    /// @dev The list settlement checks against: `_settlementRanges()`, or empty, without building
    ///      it, when the consumer has opted out. The two settlement entry points build the same
    ///      list inline, for gas. Only the list; whether STOREs are checked is decided by
    ///      `_stateChangeHandler`.
    function _guardRanges() private view returns (StorageGuard.ProtectedRange[] memory ranges) {
        if (!_unsafeDisableStorageGuard()) ranges = _settlementRanges();
    }

    /// @notice **Unsafe.** Override to return true to stop settlement checking signed STOREs
    ///         against protected storage. Saves about 1,800 gas per call (2,900 behind a proxy),
    ///         70 per transition (550 behind a proxy), 500 per declared range, and about 280 per
    ///         STORE (see `bench/SettlementGas.t.sol`).
    /// @dev With the check off, a quorum that signs a malicious program can overwrite any slot of
    ///      this contract: an owner, an upgrade slot, the transition counter (replaying old
    ///      transitions) and the SDK's own configuration, including the registry that
    ///      verifies signatures and the rate-limit budgets (`OutgoingRateLimit`, `TokenRateLimit`),
    ///      which a program could then refill before spending them: the rate limits stay in the
    ///      code but bound nothing. Opt out only if the contract's correctness already rests on
    ///      trusting the quorum completely, for example one with no owner, no upgrade path and
    ///      nothing else a rewrite could take over.
    ///
    ///      The function is `pure`, so the choice is fixed in the contract's code: no signed
    ///      program, owner or setter can switch it at runtime. It applies to `verifyAndUpdate`,
    ///      `verifyAndUpdateBatch` and nested settlement alike, and `gasKillerProtectedRanges`
    ///      returns an empty list so off-chain tooling can see it. `_protectedRanges` is ignored
    ///      while it returns true, though the constructor still validates it.
    function _unsafeDisableStorageGuard() internal pure virtual returns (bool) {
        return false;
    }

    /// @notice Storage the consumer wants protected from signed programs. Override to add slots.
    /// @dev Return inclusive `[start, end]` ranges in strictly ascending order, not overlapping
    ///      each other or the SDK's own slots (see `gasKillerProtectedRanges`). Use `StorageGuard.FULL` to
    ///      protect whole slots, or a narrower mask on a single slot to protect part of a packed
    ///      slot. The function is `pure`, so the list is a constant of the contract's code: it
    ///      can't read storage or immutables, and the constructor validates it once, so a
    ///      malformed list makes deployment revert with `StorageGuard.InvalidRanges`. For example:
    ///      ```
    ///      function _protectedRanges() internal pure override returns (StorageGuard.ProtectedRange[] memory r) {
    ///          r = new StorageGuard.ProtectedRange[](1);
    ///          r[0] = StorageGuard.ProtectedRange(0, 0, StorageGuard.FULL); // Ownable._owner
    ///      }
    ///      ```
    ///
    ///      Behind a proxy the SDK already protects the EIP-1967 slots: don't list them, as the
    ///      overlap fails deployment. A tracked function that upgrades the contract can't be settled.
    function _protectedRanges() internal pure virtual returns (StorageGuard.ProtectedRange[] memory) {
        return new StorageGuard.ProtectedRange[](0);
    }

    /// @dev The list every program is checked against: the consumer's ranges with the SDK's fixed
    ///      ranges merged in by start. Not virtual, so a consumer cannot drop the SDK's own
    ///      protection. The constructor validates the result once, so a consumer list that is
    ///      unsorted or collides with an SDK range makes deployment revert instead of failing open.
    ///      Settlement doesn't re-validate: the list is `pure`, so it is the one that was checked.
    ///
    ///      Behind a proxy (this code running at an address other than the one it was deployed
    ///      to, as a delegatecall does) the EIP-1967 implementation, beacon and admin slots are
    ///      protected too; elsewhere nothing reads them, so they are left out. The SDK ranges are
    ///      constants in ascending order (config namespace, the EIP-1967 slots, counter), so the
    ///      merge is one copy pass split at their starts. Consumer entries keep their relative
    ///      order, so a consumer list that descends or overlaps still does after the merge and
    ///      still fails validation. Each pass compares its position with the end before reading.
    function _settlementRanges() internal view returns (StorageGuard.ProtectedRange[] memory) {
        return _mergeRanges(address(this) != _self);
    }

    /// @dev `_settlementRanges` for a contract running behind a proxy (`proxied`) or not. Pure,
    ///      so the constructor can validate both.
    function _mergeRanges(bool proxied) private pure returns (StorageGuard.ProtectedRange[] memory out) {
        StorageGuard.ProtectedRange[] memory consumer = _protectedRanges();
        out = _pointerArray(consumer.length + (proxied ? 5 : 2));
        uint256 configEnd = CONFIG_NAMESPACE_END;
        // The SDK's ranges, ascending: the config namespace (the whole of it, not the struct's
        // current slots, so a field added later is covered), the EIP-1967 slots behind a proxy,
        // and the counter. Before each, the consumer entries starting below it.
        assembly ("memory-safe") {
            // Copies consumer entries from `src` that start below `start`.
            function below(src, end, dst, start) -> s, d {
                s := src
                d := dst
                for {} lt(s, end) {} {
                    let r := mload(s)
                    if iszero(lt(mload(r), start)) { break }
                    mstore(d, r)
                    s := add(s, 0x20)
                    d := add(d, 0x20)
                }
            }
            // Appends a new full-mask range `[start, end]` at `dst`.
            function put(dst, start, end) -> d {
                let r := mload(0x40)
                mstore(r, start)
                mstore(add(r, 0x20), end)
                mstore(add(r, 0x40), not(0))
                mstore(0x40, add(r, 0x60))
                mstore(dst, r)
                d := add(dst, 0x20)
            }
            let src := add(consumer, 0x20)
            let end := add(src, shl(5, mload(consumer)))
            let dst := add(out, 0x20)
            src, dst := below(src, end, dst, STORAGE_LOCATION)
            dst := put(dst, STORAGE_LOCATION, configEnd)
            if proxied {
                src, dst := below(src, end, dst, EIP1967_IMPLEMENTATION)
                dst := put(dst, EIP1967_IMPLEMENTATION, EIP1967_IMPLEMENTATION)
                src, dst := below(src, end, dst, EIP1967_BEACON)
                dst := put(dst, EIP1967_BEACON, EIP1967_BEACON)
                src, dst := below(src, end, dst, EIP1967_ADMIN)
                dst := put(dst, EIP1967_ADMIN, EIP1967_ADMIN)
            }
            src, dst := below(src, end, dst, STATE_TRACKER_STORAGE_LOCATION)
            dst := put(dst, STATE_TRACKER_STORAGE_LOCATION, STATE_TRACKER_STORAGE_LOCATION)
            for {} lt(src, end) {} {
                mstore(dst, mload(src))
                src := add(src, 0x20)
                dst := add(dst, 0x20)
            }
        }
    }

    /// @dev A `ProtectedRange[]` of `length` uninitialized pointers: `new ProtectedRange[](n)`
    ///      would also allocate and zero a struct behind every slot, and callers set every pointer.
    function _pointerArray(uint256 length) private pure returns (StorageGuard.ProtectedRange[] memory a) {
        assembly ("memory-safe") {
            a := mload(0x40)
            mstore(a, length)
            mstore(0x40, add(add(a, 0x20), shl(5, length)))
        }
    }

    /// @notice Query if a contract implements an interface
    /// @dev Supports ERC-165, IGasKillerSDK detection (the router's preflight
    ///      probes the schnorr `verifyAndUpdate` selector before submitting), and the
    ///      IGasKillerSDKBatch batching/latch extension. Defers to `super` so a
    ///      contract inheriting both this SDK and another OpenZeppelin ERC-165 module reports
    ///      the union of both ID sets.
    /// @param interfaceId The interface identifier, as specified in ERC-165
    /// @return `true` if the contract implements `interfaceId` and `false` otherwise
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IGasKillerSDK).interfaceId || interfaceId == type(IGasKillerSDKBatch).interfaceId
            || interfaceId == type(IGasKillerValueBound).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice Compute the expected message hash for a transition settled with no ETH
    /// @dev Exact mirror of the ECDSA `GasKillerSDK.getMessageHash` — the digest is
    ///      scheme-agnostic, so off-chain parity checks work unchanged.
    /// @param transitionIndex The transition index
    /// @param targetFunction The target function selector
    /// @param storageUpdates The ABI-encoded storage updates
    /// @return The expected SHA-256 hash
    function getMessageHash(uint256 transitionIndex, bytes4 targetFunction, bytes calldata storageUpdates)
        external
        view
        returns (bytes32)
    {
        return _digest(transitionIndex, targetFunction, storageUpdates, 0);
    }

    /// @notice Compute the expected message hash for a transition settled with `value` wei
    /// @dev Named apart from `getMessageHash` because an overload would rename the generated
    ///      off-chain binding of the existing function.
    /// @param transitionIndex The transition index
    /// @param targetFunction The target function selector
    /// @param storageUpdates The ABI-encoded storage updates
    /// @param value The `msg.value` the transition settles with
    /// @return The expected SHA-256 hash
    function getMessageHashWithValue(
        uint256 transitionIndex,
        bytes4 targetFunction,
        bytes calldata storageUpdates,
        uint256 value
    ) external view returns (bytes32) {
        return _digest(transitionIndex, targetFunction, storageUpdates, value);
    }

    /// @dev Mirrored by `NestedFrames.rootLeaf`, which must stay byte-identical.
    function _digest(uint256 transitionIndex, bytes4 targetFunction, bytes calldata storageUpdates, uint256 value)
        private
        view
        returns (bytes32)
    {
        if (value == 0) return sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates));
        return sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates, value));
    }

    /// @inheritdoc TransitionGuard
    function inTransition() public view override(TransitionGuard, IGasKillerSDKBatch) returns (bool locked) {
        return TransitionGuard.inTransition();
    }

    function schnorrRegistry() external view returns (address) {
        return address(_schnorrRegistry());
    }

    function avsAddress() external view returns (address) {
        return _sto().avsAddress;
    }

    function blockStaleMeasure() external view returns (uint256) {
        return _getBlockStaleMeasure();
    }

    /// @notice Sets the AVS service manager this contract is scoped to.
    /// @dev **Do not call from a `trackState` function**: see `GasKillerSDKStorage`.
    function _setAvsAddress(address _avsAddress) internal {
        _sto().avsAddress = _avsAddress;
    }

    /// @notice Sets the registry that verifies quorum signatures for this contract.
    /// @dev **Do not call from a `trackState` function**: see `GasKillerSDKStorage`.
    function _setSchnorrRegistry(address _registry) internal {
        _sto().registry = ISchnorrStakeRegistry(_registry);
    }

    function _schnorrRegistry() internal view returns (ISchnorrStakeRegistry) {
        return _sto().registry;
    }

    /// @notice Sets how many blocks old a settlement's reference block may be (0 means the
    ///         default of 300).
    /// @dev **Do not call from a `trackState` function**: see `GasKillerSDKStorage`.
    function _setBlockStaleMeasure(uint256 _blockStaleMeasure) internal {
        require(_blockStaleMeasure <= type(uint96).max, BlockStaleMeasureOverflow());
        _sto().blockStaleMeasure = uint96(_blockStaleMeasure);
    }

    function _getBlockStaleMeasure() internal view returns (uint256) {
        uint256 v = _sto().blockStaleMeasure;
        return v == 0 ? DEFAULT_BLOCK_STALE_MEASURE : v;
    }

    /// @dev Storage of `GasKillerOutgoingRateLimit`'s budget. Not for other use.
    function _outgoingBucket() internal view returns (OutgoingBucket storage) {
        return _sto().outgoing;
    }

    /// @dev Storage of `TokenRateLimit`'s budgets. Not for other use.
    function _tokenLimits() internal view returns (TokenLimits storage) {
        return _sto().tokens;
    }

    function _sto() private pure returns (GasKillerSDKStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}
