# Gas Killer Solidity SDK

[![Solidity](https://img.shields.io/badge/solidity-%5E0.8.0-blue)](https://docs.soliditylang.org)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-green)](LICENSE)
[![Experimental](https://img.shields.io/badge/status-experimental-red)](https://github.com/gas-killer/solidity-sdk)

> **Disclaimer:** This code is experimental and has not been audited. It is provided as-is, without warranty of any kind. The authors and contributors accept no liability for any loss of funds or damages arising from the use of this software in production. **Use at your own risk.**

Solidity SDK for integrating Gas Killer functionality into EigenLayer AVS contracts. Inherit from `GasKillerSDK` to let off-chain operators propose and verify state updates, approved by a single aggregate Schnorr signature, instead of running expensive computations on-chain.

> 📖 **Integrating this into your own contract?** Start with the
> [Solidity Reference](https://gaskiller.xyz/docs/solidity/integrate) in the Gas Killer docs — it covers
> installation, the live addresses to configure, `trackState` semantics and storage-layout rules, and a
> revert-selector lookup table. This README is the SDK's own reference: verification, chain
> requirements, operator-set mechanics, and the code-level contract.

## Overview

Contracts that inherit GasKillerSDK expose a public `verifyAndUpdate` function, which enables expensive state-changing computations to be performed off-chain. Operators sign a payload describing the resulting state updates, the router aggregates their Schnorr (MuSig2) signatures once a quorum threshold is reached, and the result is submitted on-chain through `verifyAndUpdate`.

## Verification

`GasKillerSDK` verifies a **single** aggregate secp256k1 Schnorr signature against a
`SchnorrStakeRegistry` in constant gas: one `ecrecover`, with non-signers subtracted from the
cached aggregate key. Registration requires a proof of possession, which makes the aggregate
rogue-key-safe.

## Chain requirements

`TransitionGuard` (used by every `GasKillerSDK` settlement entrypoint, see
`src/TransitionGuard.sol`) is a reentrancy/in-transition guard built on EIP-1153 transient
storage, and nested settlement keeps its registry approvals and pending-child markers there too.
None of these has a fallback path for a pre-Cancun EVM — deploying it to a chain
without EIP-1153 breaks settlement itself, not just the guard. `foundry.toml` pins
`evm_version = "cancun"` accordingly. Ethereum mainnet has supported EIP-1153 since Dencun;
before deploying to any other chain (in particular an L2 settlement target), confirm it has
activated the equivalent of Cancun/EIP-1153.

## Operator-set changes

`SchnorrStakeRegistry` stores a single *current* aggregate key and total weight rather than a
per-block history. Any change to the operator set — registration **or** deregistration —
therefore invalidates a signature that an off-chain round has already assembled against the
previous set. The round must be re-assembled and resubmitted.

The cost is a retry, not a soundness risk: the failure mode is a rejected signature, never
acceptance of one that no current-set quorum endorsed. Depending on when the reference block is
chosen, the rejection surfaces one of two ways:

| Reference block pinned | Result |
|---|---|
| Before the mutation | `StaleSnapshot` revert — `refBlock` is below the registry's `effectiveBlock` watermark |
| After the mutation (freshest block, `block.number - 1`) | `isValidSignature` returns `false`, surfacing as `InvalidQuorumSignature` — the cached aggregate no longer matches what the operators signed |

The window of exposure runs from the operator set the signers observed through to the block the
settlement is included in — the signing round's duration plus however long the assembled payload
waits before inclusion. `verifyAndUpdate` bounds the second part: a reference block must be within
`blockStaleMeasure` blocks of the current block (300 by default), so a payload expires rather than
lingering indefinitely.

A mutation also changes *what counts as* a quorum, since the threshold is measured against the
current total weight. Removing an operator can turn a signature that held less than the threshold
share of the old set into a valid quorum of the smaller one — correctly, because the remaining
signers do carry that share. Signatures stay bound to one signer set by the aggregate match, not
by the reference block.

### Scheduling changes with a notice window

`SchnorrStakeRegistry` takes a `noticeWindow` (in blocks) at construction, which turns the
quiescence requirement above from an assumption into something a router can check:

| Call | Effect |
|---|---|
| `announceRegister` / `announceDeregister` | Queue a change, applicable after `noticeWindow` blocks. Nothing is mutated yet |
| `commitNextChange` | Apply the oldest announced change, once its window has elapsed |
| `cancelNextChange` | Drop the oldest announced change without applying it |
| `cancelChange(operator)` | Drop one identity's announced change, wherever it sits in the queue |
| `nextPossibleMutationBlock()` | The earliest block the set can change, or `type(uint256).max` when nothing is queued |

A round is safe from set-mutation invalidation while the block its settlement lands in is below
`nextPossibleMutationBlock()`. Size `noticeWindow` to exceed the signing round's duration plus the
consumer's `blockStaleMeasure`, or a round can still be assembled under one set and settled under
another.

Registration is validated in full at announcement — curve membership, weight bounds, proof of
possession — so an unusable entry cannot sit in the queue holding the horizon. An announced
operator is *not* in the aggregate until its change commits, so it must not sign before then; an
operator announced for removal stays in the aggregate and in the threshold denominator until
commit, so it is expected to keep signing throughout its window.

`registerOperator` and `deregisterOperator` bypass the window, for bootstrapping a registry that
does not yet back any consumer and for emergencies such as a compromised key. They emit
`ForcedMutation` so consumers relying on the horizon can detect the bypass, and the fail-closed
watermark remains the backstop for it.

They refuse to act on an identity that has a change queued, so that the scheduled and forced paths
can never both apply to it. Clearing the way is `cancelChange(operator)` followed by the forced
call, in the same block if needed — cancelling by identity reaches into the middle of the queue, so
other operators keep both their positions and their remaining notice windows.

Consequences for integrators:

- Prefer the announced path once the registry is live, and enforce the horizon check before
  submitting.
- Treat `ForcedMutation`, and any `OperatorRegistered` / `OperatorDeregistered` without a
  preceding announcement, as a "re-snapshot required" signal.
- An exited operator's record is kept as a tombstone rather than deleted: its key, weight and
  `exitBlock` stay readable so the identity remains attributable after it leaves, while
  `registered` going false is what removes it from the active set.
- `blockStaleMeasure` is set per consumer contract and is owner-adjustable, while one registry
  may back several consumers. The registry cannot enforce any relationship between its own
  mutation timing and each consumer's staleness bound, so keeping the two consistent is
  deployment discipline rather than a contract guarantee.

## Settling with value

Both settlement entrypoints, `verifyAndUpdate` and `verifyAndUpdateBatch`, are `payable`, and the
value is part of what the quorum signs. A transition settles only with exactly the `msg.value` the
task was analyzed with:

| Settled with | Signed digest |
|---|---|
| no ETH | `sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates))` |
| `value` wei | `sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates, value))` |

Zero-value transitions keep the original encoding, so their signatures and off-chain parity are
unchanged. The two encodings cannot collide, because their heads differ in length.
`getMessageHash` returns the zero-value digest and `getMessageHashWithValue` either one.

The `IGasKillerSDK` interface ID (`0x82b35a01`) is unchanged, so it can't tell a consumer that binds
the value from one built on an older SDK, which accepts a value-bearing signature with any
`msg.value`. Consumers that bind it also report `IGasKillerValueBound` (`0x0fd29ece`, the
`getMessageHashWithValue` selector) through ERC-165. Check for it before sending a task with value.

This is what makes inbound value safe. A tracked function that credits `msg.value` (a deposit, a
mint for ETH, a payable purchase) replays as plain `STORE` updates, so without the binding anyone
could settle it while sending nothing, and the contract would record ETH it never received.

A `CALL`, `CREATE` or `CREATE2` update moves an amount fixed inside the signed `storageUpdates`,
paid out of the contract's balance, which includes `msg.value`. A shortfall reverts the whole
transition: `RevertingContext` with empty revert data for a `CALL` (the EVM fails the call before the
target runs), `DeploymentFailed` for a `CREATE`/`CREATE2`.

The settler can't top that balance up. Any ETH the task wasn't analyzed with fails the digest, so a
transition analyzed with no value rejects all ETH. A pass-through call, such as a deposit that
forwards its `msg.value`, still works, because the value it forwards is the value it was analyzed
with. A contract whose updates pay out of its own balance has to be funded some other way.
`GasKillerSDK` has no `receive()`, so add one or a payable funding function. If the balance has
dropped since the task was analyzed, the transition fails until the contract is funded and the task
is resubmitted.

For `verifyAndUpdateBatch`, each `TaskSubmission` carries the `value` its transition was analyzed
with, and its digest binds that value. `msg.value` must cover the sum over the submissions actually
applied, or the batch reverts with `InsufficientBatchValue`. The check is "covers" rather than
"equals" because a submission skipped as already settled (the front-run tolerance described above)
must not revert the batch. The surplus, such as that item's share, is refunded to `msg.sender` after
the batch applies. If the sender can't accept ETH, the surplus stays in the contract and the batch
still succeeds.

## Nested settlement

A transition can extend down a call stack when the contracts it calls are SDK consumers too.
If `A` calls `B` and `B` calls `C`, and all three inherit `GasKillerNestedSDK`, the whole call
stack settles as one tree: each contract applies its own signed frame instead of `B` and `C`
running natively.

Nesting is opt-in. `GasKillerNestedSDK` extends `GasKillerSDK` with the tree entrypoints and adds
about 4 KB of runtime bytecode, so a contract that never nests should inherit `GasKillerSDK` and
not carry it. Only contracts that report `IGasKillerNested` through ERC-165 can join a tree; a
root that does not report it settles flat.

- **One signature.** The quorum signs a Merkle root over an expiry leaf and one leaf per frame,
  in execution order. The root contract settles it through `verifyAndUpdateTree`. The registry
  verifies the signature and the expiry once, through `verifyAndApprove`, and caches the approval
  in transient storage for the rest of the transaction.
- **Frames apply in place.** Where the native call happened, the parent's program holds a
  `NESTED` op naming the child's leaf. The parent calls `applyNested` on the child with the
  child's program and proof, and the child checks the approval in its own registry, its leaf,
  the proof, and that the parent reports this leaf as its pending child. The child returns the
  `applyNested` selector, and the parent reverts with `NestedNotApplied` on any other return, so a
  target with no code or a permissive fallback cannot silently skip its frame.
- **What binds a frame.** A frame's leaf hashes its contract, caller, ETH value and transition
  index from the call itself. A frame applied by anyone but its signed parent, with any other
  value, or out of order fails. A frame cannot be applied after the signed expiry, whatever
  contract calls it.
- **Cycles work.** `A → B → A` applies two `A` frames in one tree. The transition guard holds the
  active root, so a frame of the same root may re-enter, and every other re-entry still reverts.
- **The single-transition digest is unchanged.** A root frame's leaf is exactly the
  `verifyAndUpdate` digest, value included, so consumers that never nest sign and settle as
  before.

Rules for a contract that may be nested:

- It must inherit `GasKillerNestedSDK`.
- The function called into must be `trackState`, and the counter increment must come before any
  other storage write or external call in that function. Replay increments first.
- It must use the same registry as the root contract, and that registry must implement
  `ISchnorrApprovalRegistry`.
- Its own `blockStaleMeasure` still bounds the reference block it accepts, so the tightest window
  in a tree applies to the whole tree.
- Every nested frame pins its contract's transition index. Any other transition on that contract
  between signing and settlement reverts the whole tree, so a contract with heavy native traffic
  may be better left as a plain `CALL`.

See `src/examples/nested-chain` (`NestedRouter` → `NestedVault` → `NestedLedger`),
`src/examples/nested-cycle` (`CycleRoot` → `CycleRelay` → `CycleRoot`) and
`src/examples/nested-deposit` (`DepositGateway` → `DepositVault`, a `NESTED` op that forwards
ETH). The root leaf binds the `msg.value` the tree settles with, just as the `verifyAndUpdate`
digest does, and each nested leaf binds the value its parent forwards.

## Protected storage

A signed program's `STORE` updates write any slot they name. Without a check, a compromised quorum
could sign one update that overwrites an `Ownable` owner, the SDK's registry address or the
transition counter, and take over the contract. Settlement therefore checks every `STORE` against a
list of protected storage ranges, right before the write executes, and reverts the whole transition
(`StorageGuard.ProtectedSlotWrite`) if the write would change a protected bit.

**On by default.** Every consumer protects the SDK's own storage with no code: the transition
counter, and the configuration struct holding the AVS address, the registry and the stale-block
window. The protected range for the struct is its whole 256-slot ERC-7201 namespace, not just the
slots it uses today, so a field added to the struct later is covered automatically. A tracked
function that natively changes any of those settings can't be settled through Gas Killer. Protection
stays on unless the contract's code opts out (see **Opting out** below).

**Adding your own slots.** Override `_protectedRanges()` and return a list of inclusive
`[start, end]` ranges in ascending order, for example the owner slot of an `Ownable` that is your
contract's first state variable. The function is `pure`, so the list is a constant of your contract's
code: it can't be computed from storage, immutables or constructor arguments.

```solidity
import {StorageGuard} from "gas-killer-sdk/libraries/StorageGuard.sol";

function _protectedRanges() internal pure override returns (StorageGuard.ProtectedRange[] memory r) {
    r = new StorageGuard.ProtectedRange[](1);
    r[0] = StorageGuard.ProtectedRange(0, 0, StorageGuard.FULL); // Ownable._owner
}
```

- `StorageGuard.FULL` protects every bit of every slot in the range. A narrower mask, on a single
  slot, protects part of a packed slot, such as an owner address that shares its slot with a counter.
- The SDK merges your list with its own and validates the result once, in its constructor. A list
  that is unsorted, overlapping, or collides with an SDK slot makes deployment revert
  (`InvalidRanges`), so it can't reach a live settlement. Because the list is `pure`, the one that was
  validated is the one every settlement uses, and settlement doesn't re-check it.
  `gasKillerProtectedRanges()` returns the merged list.
- Nested settlement checks each frame against its own contract's list, and a batch reverts as a whole
  if any of its transitions writes protected storage.

**The rule: no protected bit may change.** A write that leaves every protected bit as it is in
storage passes. That is what keeps honest programs working: gas-analyzer copies the counter's new
value into every program, and `trackState` has already written that value when the program runs.
Each `STORE` is judged against storage at the moment it executes. So if a `CALL` legitimately changes
protected storage, for example by having the pending owner claim ownership, a later `STORE` that
quietly restores the old value is rejected, and one that keeps the new value passes.

**What it is not.** Protection applies to the signed `STORE` entries only. It does not watch the slot
itself, so your own functions, called normally, are unaffected, and so is native code a signed
`CALL` runs. A `CALL` acts with the contract's authority: it can't pass an `onlyOwner` check,
because `msg.sender` is the contract, but it can reach functions that trust `msg.sender ==
address(this)`, and it can spend what the contract holds elsewhere (tokens, approvals, ETH).
See [Restricting calls](#restricting-calls).

**Opting out.** A contract whose security already rests on trusting the quorum completely, for
example one with no owner, no upgrade path and nothing else a rewrite could take over, can turn the
check off:

```solidity
function _unsafeDisableStorageGuard() internal pure override returns (bool) {
    return true;
}
```

With it off, a quorum that signs a malicious program can overwrite any slot: an owner, an upgrade
slot, the transition counter, and the SDK's configuration, including the registry that verifies
signatures. The hook is `pure`, so the choice is fixed in the contract's code at deployment. No
signed program, owner or setter can switch it at runtime. It applies to single, batched and nested
settlement, and an opted-out contract's `gasKillerProtectedRanges()` returns an empty list, so
tooling can tell; a protected one always lists at least the SDK's two ranges. Nested settlement
checks each frame against its own contract, so one opted-out contract in a tree doesn't weaken the
others.

**Cost at settlement.** Measured through `verifyAndUpdate` (`bench/SettlementGas.t.sol`), against the
same settlement before protection was wired in: a program of the counter copy plus n fresh `STORE`s,
for a consumer declaring k ranges, or opted out.

| n `STORE`s | Before | Opted out | k = 0 | k = 1 | k = 4 |
|---|---|---|---|---|---|
| 1 | 53,513 | +135 (+0.3%) | +2,075 (+3.9%) | +2,552 (+4.8%) | +4,108 (+7.7%) |
| 8 | 215,998 | +541 (+0.3%) | +4,499 (+2.1%) | +4,978 (+2.3%) | +6,541 (+3.0%) |
| 32 | 773,288 | +1,933 (+0.2%) | +12,820 (+1.7%) | +13,317 (+1.7%) | +14,912 (+1.9%) |

Protected, that is about 340 gas per `STORE` (the counter copy included), about 500 per declared
range per settlement call (building and merging the list), and about 1,400 fixed. Opted out, about
60 per `STORE` remains, the cost of skipping the check. A `verifyAndUpdateBatch` builds the list
once for all of its items. A 20-item batch of single-`STORE` transitions, over 653,659 before,
costs +34,750 (+5.3%) at k = 0, +46,963 (+7.2%) at k = 4, and +8,323 (+1.3%) opted out.

### Design and measurements

The check lives in `libraries/StorageGuard.sol`, and was specified and measured in
[#107](https://github.com/gas-killer/solidity-sdk/issues/107).

**A denylist, not an allowlist.** Honest writes to mappings and dynamic arrays land on keccak-derived
slots spread across the whole slot space, and an allowlist of ranges can't express those. Every slot
worth protecting is known at compile time, and an honest write can only reach one through a keccak
preimage, so a hit means the program is malicious.

**Sorted input is optional.** Settlement uses the merge checker (`Cursor` + `advance`): it keeps a
position in the range list and moves it forward as the slots ascend. Before each write it checks that
its position is still valid for the slot, meaning no earlier range reaches it, and re-seats by binary
search if not. Neither the order of the writes nor the cursor's state can change the verdict, only the
gas. gas-analyzer's canonical extraction, ascending within each slice between `CALL`/`CREATE`
boundaries, pays at most one re-seat per slice; journal-order input is still checked correctly, just
less cheaply. Sorting on-chain isn't an option, because reordering `STORE`s across a `CALL` changes
what the call observes.

**Why inline.** A pre-pass over a whole program before it runs was measured too
(`StorageGuardVariants.checkProgram`, in test utilities). It decodes every `STORE` a second time
(about 350 gas each), and since it sees storage from before the program, it has to reject any
protected write that follows a code-running op (`ProtectedWriteAfterExternalCode`), which an inline
check judges exactly. The library therefore ships only `validateRanges` and `advance`.

**Choosing the checker.** Per-write marginals from `bench/StorageGuardGas.t.sol` for 128 writes
against k ranges shaped like a real protected set (slot 0 plus high keccak slots), over three layouts:
low slots, mapping entries, and mixed. Merge is the library's `advance`; binary search
(`checkEach`) and the linear scan are comparison variants in `test/utils/StorageGuardVariants.sol`.

| Write order | k | Binary search | Linear scan | Merge |
|---|---|---|---|---|
| sorted | 1 | 294 | 205 | 255 |
| sorted | 4 | 540–602 | 281–350 | 320–350 |
| sorted | 16 | 730–864 | 281–832 | 350–361 |
| sorted within slices of 8 | 16 | 730–864 | 281–832 | 350–564 |
| unsorted | 16 | 730–864 | 281–832 | 350–805 |

- **Sorted input.** The merge's cost is flat in k, the effect the issue predicted. It beats the
  binary search at every k.
- **Unsorted input.** The merge stays roughly even with the binary search: ahead at k = 4, and at
  k = 16 ahead on low and mixed slots, behind (805 against 730) on mapping entries. A write
  only re-seats when it falls below the previous range, not merely below the previous write.
- **Linear scan.** It's cheapest at k = 1, at least as cheap at k = 4, and cheapest on writes below
  every high range. The merge pulls ahead at k = 16 on mapping entries (359–361 against 568–832).
- **Cursor safety.** About 65 gas of the merge's cost per write goes to re-checking the cursor's
  position against the list, so a stale or foreign cursor can't let a write through.

Both benchmarks run with `FOUNDRY_PROFILE=gas forge test -vv`.

**Not covered:**

- Restricting what a signed `CALL` may do: see [Restricting calls](#restricting-calls).
- A target function that is a general-purpose VM over all of its storage can't be restricted this
  way.
- Ranges are declared by the consumer. Deriving them by scanning a contract's functions is left for
  later.

## Restricting calls

A signed `CALL` runs real code with your contract's authority, and protected storage doesn't see it.
With no policy, a program signed by a compromised quorum can call your own functions that trust
`msg.sender == address(this)`, transfer or approve the tokens your contract holds, and send its ETH
through the value of a `CALL`, `CREATE`, `CREATE2` or `NESTED` op. Settlement gives you two hooks
to stop that. Both run before the op does, and a revert in either reverts the whole transition.

**Off by default.** Both hooks allow everything unless you override them, so existing consumers
behave as before. A consumer that makes no external calls and holds nothing has nothing to restrict.
One that holds value, or has self-gated functions, should write a policy.

**`_authorizeCall`** is called before every `CALL`, `CREATE`, `CREATE2` and `NESTED` op with the
signed selector, the op's position, its kind, its target, its value and its data (a `CALL`'s
calldata, or the initcode of a deployment, whose target is zero since the address isn't known yet).
Revert to reject the op. It is code rather than a list because a signed program doesn't carry the
user's arguments or `msg.sender`, and honest programs often call targets known only at run time,
such as a user-supplied token or the caller being paid out. It isn't `view`, so it can keep state;
don't declare your override `view` if you might later combine it with the rate limit below.

```solidity
function _authorizeCall(bytes4, uint256 index, StateUpdateType kind, address target, uint256, bytes memory data)
    internal
    override
{
    if (target == address(this)) revert SelfCall(index);
    if (kind == StateUpdateType.CREATE || kind == StateUpdateType.CREATE2) revert NoDeployments(index);
    if (target == address(token) && bytes4(data) != IERC20.transfer.selector) revert DisallowedCall(index);
}
```

**`_maxOutgoingValue(targetFunction)`** caps the wei one program may send, summed over its `CALL`,
`CREATE`, `CREATE2` and `NESTED` values. It is read once per program, and a program that would pass it
reverts with `OutgoingValueExceeded(index, total, cap)` at the op that passes it, before that op
runs. The total counts what the program sends, whatever `msg.value` brought in.

- **Self-calls.** gas-analyzer emits a tracked function's `this.foo()` as a `CALL` to your own
  contract, so a policy that rejects self-calls also rejects those programs. Reject them unless your
  tracked functions call themselves that way.
- **Batches and trees.** Each transition of a `verifyAndUpdateBatch` is checked and capped on its
  own. In a nested tree, each frame runs its own contract's policy: the root frame's hooks get the
  signed selector, and a callee's frame gets zero, since the tree binds a callee's call by calldata
  hash only. A `NESTED` op's target and value go through the parent's policy; the callee checks its
  own frame.
- **Opting out of protected storage** doesn't turn the call policy off.

### Rate-limiting outgoing ETH

`_maxOutgoingValue` caps one program. To bound what a compromised quorum can drain over time, across
any number of programs, add the optional outgoing rate limit: a token bucket that holds at most
`limit` wei and refills continuously, a full `limit` every `period` seconds. Every op that sends value
spends from it, and one that would send more than the bucket holds reverts the transition with
`OutgoingRateLimitExceeded(index, value, available)` before it runs.

Inherit the drop-in instead of the SDK base:

```solidity
import {GasKillerOutgoingRateLimit} from "gas-killer-sdk/extensions/GasKillerOutgoingRateLimit.sol";

contract Vault is GasKillerOutgoingRateLimit {
    constructor(address registry) GasKillerOutgoingRateLimit(10 ether, 1 days) {
        _setSchnorrRegistry(registry);
    }
}
```

Use `GasKillerNestedOutgoingRateLimit` in place of `GasKillerNestedSDK`. A contract that already
inherits another SDK base (Solidity would otherwise ask it to re-override every function the two
paths both touch) can call the `OutgoingRateLimit` library from its own `_authorizeCall` instead:

```solidity
constructor() { OutgoingRateLimit.set(_outgoingBucket(), 10 ether, 1 days); }

function _authorizeCall(bytes4 fn, uint256 index, StateUpdateType kind, address target, uint256 value, bytes memory data)
    internal
    override
{
    super._authorizeCall(fn, index, kind, target, value, data);
    OutgoingRateLimit.spend(_outgoingBucket(), index, value);
}
```

- **The budget can't be refilled by a signed program.** It lives in the SDK's protected config
  namespace, so a `STORE` to it is rejected like one to the registry address.
- **Shared.** All of the contract's programs spend from one bucket: single, batched, and nested
  frames alike. A `NESTED` op's value spends the parent's bucket; a callee with its own limit spends
  its own.
- **Signed programs only.** The contract's own functions, called natively, spend nothing from it.
- **ETH only.** A token transfer sends no value; see per-token limits below.
- **Changing the limit.** `_setOutgoingRateLimit(limit, period)` (or `OutgoingRateLimit.set`)
  resets the bucket to full. Call it from the constructor, an initializer or an admin function,
  never from a `trackState` function: like the SDK's config setters, a program carrying that write
  can never settle. Behind a proxy, set it in the initializer; until then the budget is empty and
  every op that sends value reverts. `gasKillerOutgoingAllowance()` returns what is available now,
  the limit and the period.
- **Cost.** About 615 gas per op that sends value, plus about 5,000 once per settlement for the
  first (cold) read and write of the budget slot. Ops that send nothing pay nothing extra.

### Rate-limiting outgoing tokens

`GasKillerTokenRateLimit` (and `GasKillerNestedTokenRateLimit`) extends the ETH limit with
per-token budgets: for each ERC-20 you list, signed programs may move out at most `limit` per
`period`, refilling continuously. Up to 8 tokens; unlisted tokens aren't limited, so restrict
those in `_authorizeCall` if you hold any. It is a separate base so a contract that only limits ETH
doesn't pay for it.

```solidity
import {GasKillerTokenRateLimit} from "gas-killer-sdk/extensions/GasKillerTokenRateLimit.sol";

contract Vault is GasKillerTokenRateLimit {
    constructor(address registry, address usdc) GasKillerTokenRateLimit(type(uint96).max, 1 days) {
        _setSchnorrRegistry(registry);
        _setTokenRateLimit(usdc, 50_000e6, 1 days);
    }
}
```

Pass `type(uint96).max` as the ETH limit to leave ETH effectively unlimited.

**What is charged: net outflow, measured.** A token can leave through `transfer`, through a
`transferFrom` by a contract holding an allowance (a router pulling during a signed `CALL`), or
through whatever else the token implements, so the limit reads `balanceOf(this)` for every listed
token right before the program's first op that runs code, and again when the program ends, and
charges the decrease. Tokens the program receives offset tokens it sends.

**Approvals.** An approval moves nothing until it is used, possibly long after the program. So an
`approve` or `increaseAllowance` call to a listed token is recorded with the spender's allowance
before it, and at the end any allowance left above that is charged in full. Approving a router that
pulls the tokens in the same program is charged once, through the balance; an approval left
standing is charged, and an unlimited one always exceeds the budget. Other ways of granting an
allowance aren't seen, such as `approveAndCall` or Permit2: reject them in `_authorizeCall`.

- The budgets live in the SDK's protected config namespace, like the ETH budget.
- A program that runs no code can't move tokens, so it reads no balances.
- A shortfall reverts the transition at the end of the program with
  `TokenRateLimitExceeded(token, amount, available)`.
- `_setTokenRateLimit` and `_clearTokenRateLimit` follow the same rule as the other setters: never
  from a `trackState` function. `gasKillerTokenAllowance(token)` returns the budget.
- In a nested tree that re-enters the same contract, the inner frame's outflow is charged to it and
  again to the frame around it: conservative, never under-counted.
- A contract that already inherits another SDK base can use the `TokenRateLimit` library directly:
  `begin` in `_beforeProgram`, `beforeOp` in `_authorizeCall`, `endProgram` in `_afterProgram`.
- **Cost.** For a program with one token `transfer`, about +4,200 with no tokens listed, +9,300 with
  one and +20,500 with four. Each listed token costs two `balanceOf` calls and a budget read and
  write per settlement that runs code.

### Cost of the hooks

Measured through `verifyAndUpdate` (`bench/CallPolicyGas.t.sol`) for the counter copy plus
m zero-value `CALL`s to a warm, empty contract, against the same settlement before the hooks:

| m `CALL`s | Before | Default policy | Small policy |
|---|---|---|---|
| 1 | 33,576 | +415 (+1.2%) | +453 (+1.3%) |
| 8 | 47,166 | +1,497 (+3.2%) | +1,815 (+3.8%) |
| 32 | 94,129 | +5,203 (+5.5%) | +6,481 (+6.9%) |

That is about 155 gas per op with the hooks left as they are, about 205 with a self-call check and a
cap, and about 260 per program. A program of `STORE`s only pays the per-program part and about 3 gas
per op. A real `CALL` pays a cold account access (2,600) and its callee's work, so the share is
smaller than against this empty callee.

**Not covered:** checking a call's arguments against what the user asked for. The program doesn't
carry the user's input, so `transfer(to, amount)` is judged on its own: the policy can pin `to` to a
known payee, but can't tell a legitimate payout to an arbitrary user from theft.

## Repository Structure

- **`src/`** — Core SDK contracts
  - `GasKillerSDK.sol` — Abstract base; inherit this in your consumer
  - `GasKillerNestedSDK.sol` — `GasKillerSDK` plus nested settlement; inherit this instead in a contract that roots or joins a tree
  - `SchnorrStakeRegistry.sol` — Aggregate-key registry with proof-of-possession registration and non-signer subtraction
  - `StateTracker.sol` — Tracks state transitions via an ERC-7201 storage slot
  - `StateChangeHandlerLib.sol` — Executes batched `STORE`, `CALL`, `LOG`, `CREATE` and `NESTED` operations
  - `TransitionGuard.sol` — EIP-1153 reentrancy / in-transition latch, keyed by the active nested root
  - `interface/` — `IGasKillerSDK`, `IGasKillerSDKBatch`, `IGasKillerNested`, `ISchnorrStakeRegistry`, `ISchnorrApprovalRegistry`, and the Alloy-compatible `IStateUpdateTypes`
  - `libraries/` — `Secp256k1` (affine point math), `SchnorrVerify` (constant-gas `ecrecover`-trick verify), `NestedFrames` (nested-settlement leaves, tree membership and witnesses) `StorageGuard` (protected storage ranges for `STORE` updates) `OutgoingRateLimit` (token bucket over the ETH signed programs send) and `TokenRateLimit` (per-token budgets over measured ERC-20 outflow)
  - `extensions/` — Optional drop-in bases: `GasKillerOutgoingRateLimit` (outgoing-ETH rate limit) and `GasKillerTokenRateLimit` (plus per-token limits), each with a `Nested` variant
- **`src/examples/`** — Demo apps: `ArraySummation`(`Factory`), `ReentrantCheckpoint`(`Factory`), and the nested-settlement `nested-chain`, `nested-cycle` and `nested-deposit` examples
- **`script/`** — Deployment scripts
- **`test/`** — Unit and integration tests
- **`bench/`** — Gas benchmarks, run with `FOUNDRY_PROFILE=gas forge test -vv`

## Usage

The [Solidity Reference](https://gaskiller.xyz/docs/solidity/integrate) is the full integration guide —
a complete minimal target, the addresses to wire and how to verify them, what keeps a tracked function
extractable, and the whole API surface. This section is the short version.

### Installation

```bash
forge install gas-killer/solidity-sdk
```

Add the remapping:

```
gas-killer-sdk/=lib/solidity-sdk/src/
```

### Integrating the SDK

Inherit `GasKillerSDK`, configure it in the constructor, and mark each state-changing function
`trackState`:

```solidity
import {GasKillerSDK} from "gas-killer-sdk/GasKillerSDK.sol";

contract MyContract is GasKillerSDK {
    uint256 public storedValue;

    constructor(address _avsAddress, address _schnorrRegistry) {
        _setAvsAddress(_avsAddress);
        _setSchnorrRegistry(_schnorrRegistry);
    }

    function updateValue(uint256 newValue) external trackState {
        storedValue = newValue;
    }
}
```

Operators then settle a transition through `verifyAndUpdate`, which requires that:

- the reference block is below the current block and within `blockStaleMeasure` blocks of it,
- `transitionIndex + 1` matches the current `stateTransitionCount`,
- the recomputed message hash matches the one signed,
- the aggregate signature verifies against the registry, and the signers hold at least the
  registry's `thresholdNum / thresholdDen` share of its total weight.

Each `STORE` the program carries must also leave protected storage unchanged: the SDK's own slots
always, plus any your contract declares. If your contract has an owner or other privileged state,
declare its slots by overriding `_protectedRanges()`; see
[Protected storage](#protected-storage).

**The AVS and `SchnorrStakeRegistry` addresses to configure live in
[Configuration](https://gaskiller.xyz/docs/solidity/configuration).** They are properties of a
particular AVS deployment rather than constants of the protocol, so they are maintained there and
deliberately not repeated in this repo.

### State Update Types

The `storageUpdates` payload is an ABI-encoded `(StateUpdateType[], bytes[])` pair. Each entry is one
of the following, applied in order:

| Type | Effect | Encoded args |
|------|--------|--------------|
| `STORE` | Write to a storage slot | `(bytes32 slot, bytes32 value)` |
| `CALL` | External call with optional ETH | `(address target, uint256 value, bytes calldata)` |
| `LOG0`–`LOG4` | Emit a log with 0–4 topics | `(bytes data[, bytes32 topic1, ...])` |
| `CREATE` | Deploy via `CREATE` | `(uint256 value, bytes initcode)` |
| `CREATE2` | Deploy via `CREATE2` | `(bytes32 salt, uint256 value, bytes initcode)` |
| `NESTED` | Apply an SDK callee's own frame of a nested tree (tree settlement only) | `(address target, uint256 value, bytes32 childLeaf)` |

See [Settling with value](#settling-with-value) for how `CALL`,
`CREATE`, `CREATE2` and `NESTED` are paid for. A `NESTED` op forwards its value out of the parent's
balance, exactly as the native call would have.

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Build

```bash
forge build
```

### Test

```bash
forge test
```

Gas benchmarks live in `bench/` and run under their own profile, outside the default run and CI,
because their absolute ceilings move with the toolchain:

```bash
FOUNDRY_PROFILE=gas forge test -vv
```

### Deploy ArraySummation (demo)

Verified against a `SchnorrStakeRegistry`, so it settles against a fleet running
`SIGNATURE_SCHEME=schnorr`.

```bash
forge script script/DeployArraySummation.s.sol --rpc-url <rpc_url> --private-key <private_key> --broadcast
```

Required environment variables: `AVS_ADDRESS`, `SCHNORR_STAKE_REGISTRY_ADDRESS`, `ARRAY_SIZE`, `MAX_VALUE`, `ARRAY_SEED`

The registry is required rather than deployed here. It is an operator set, populated by each
operator registering a secp256k1 key with a proof of possession, which the service repo's
`setup_schnorr_operators` binary does. Deploying one here would produce a target verifying
against an empty set.
