# Multi-Call Mode — Architecture

Design for letting one GasKillerSDK contract forward quorum-signed storage updates to
other GasKillerSDK contracts it calls, so a single bundle (one ECDSA quorum verification) can
apply state diffs across a call graph of SDK-enabled contracts.

The SDK side (§3) is implemented in this repo: `applyForwardedUpdates`, the
trusted-forwarder allowlist, the reserved-slot policy, `IGasKillerForwardee`, and the
`verifyAndUpdate` quorum hardening, with coverage in `test/GasKillerForwarding.t.sol`.
The service side (§9) describes the corresponding gas-analyzer changes.

---

## 1. Problem and current behavior

**SDK side** (`src/GasKillerSDK.sol`): `verifyAndUpdate` verifies one ECDSA operator
quorum — the operators' signatures over `sha256(abi.encode(transitionIndex,
address(this), targetFunction, storageUpdates))` are checked via EigenLayer's
`ECDSAStakeRegistry` (ERC-1271) — then `StateChangeHandlerLib._runStateUpdates`
applies ops. `STORE` is a raw `sstore` — it can only ever write the **executing**
contract's storage. `trackState` (StateTracker.sol:19) pre-increments the transition
counter; `verifyAndUpdate` requires `transitionIndex + 1 == stateTransitionCount()`.

**Analyzer side** (`gas-analyzer`): `compute_state_updates`
(crates/core/src/trace.rs:199-301) walks the Geth trace with a depth cursor.
DELEGATECALL/CALLCODE frames are traversed transparently (correct — they write caller
storage). A plain CALL becomes a single `Call{target,value,callargs}` op and **every
state-changing op inside that frame is discarded** (trace.rs:256-263): the callee's
effects are reproduced only by live re-execution of the CALL on-chain, whose gas is
counted as non-optimizable (heuristic.rs:47). `Store` carries no address field
(types.rs:23-26); the whole pipeline assumes exactly one contract per batch
(anvil/src/lib.rs:583,645; gas-estimator/src/lib.rs:109).

**So today:** when GasKiller contract A calls GasKiller contract B, B's execution is
replayed at full cost inside A's bundle. Multi-call mode recovers exactly that gas.

**Also established:** gas-analyzer never computes `msgHash`/`transitionIndex` — the
signing message is assembled in the router/operator layer (repo-wide grep confirms).
The analyzer's output stops at the `storageUpdates` blob + gas estimate.

---

## 2. Design space considered

| Proposal | Idea | Verdict |
|---|---|---|
| **ForwardedApply** (chosen) | Callee sub-payload embedded as an ordinary `CALL` op to a new `applyForwardedUpdates` entrypoint; per-contract trusted-forwarder allowlist; one ECDSA quorum verification per bundle | Smallest delta, wire format unchanged, best transitionIndex coherence; trust bottoms out in allowlist policy |
| GasKiller Gateway | Singleton per-AVS verifier contract verifies a multi-target bundle once and dispatches to each target; targets trust only the gateway | Clean O(1) trust topology, but new contract + new wire format + migration; global counter serializes all bundles |
| Hub-Attested Bundles | Merkle-committed per-target leaves; callees self-verify inclusion + transient-storage attestation from their own configured hub | Strongest cryptographic story, but largest SDK/service delta, Cancun dependency, 2× complexity for marginal practical gain |

The Gateway's trust topology survives as a *deployment pattern* of the winner (§6), and
the strongest ideas from both losers are grafted on as hardening (§7).

Key insight that makes ForwardedApply near-free: **A's signed `msgHash` already
transitively commits to every byte nested inside `storageUpdates`.** Embedding B's
sub-payload (including B's expected transition index) inside a CALL op in A's list
means the quorum signature over A's bundle *is* a signature over B's diff and sequence
number. No second quorum verification, no new wire format, no new signing scheme.

---

## 3. On-chain changes (solidity-sdk)

`StateTracker.sol`, `IStateUpdateTypes.sol` unchanged. No new `StateUpdateType` variant
(a `FORWARD` enum was rejected: it forces lockstep churn in gas-analyzer's types,
encoder, and the embedded estimator artifact for zero gas or soundness benefit — the
forward *is* semantically an external call).

### 3.1 New storage field (append-only to the ERC-7201 struct)

```solidity
struct GasKillerSDKStorage {
    bytes namespace;                             // base + 0
    address avsAddress;                          // base + 1
    IERC1271Upgradeable ecdsaStakeRegistry;      // base + 2
    uint256 blockStaleMeasure;                   // base + 3
    mapping(address => bool) trustedForwarders;  // NEW, base + 4
}
```

Base slot is the ECDSA storage location `0x6056...e700`
(`erc7201:gaskiller.GasKillerSDKECDSA.storage`, `GAS_KILLER_SDK_STORAGE_LOCATION` in
`src/GasKillerSDK.sol`). The `trustedForwarders` mapping is appended at base+4; existing
fields are never reordered. The reserved range checked by `_isReservedSlot` is
`[base, base+5)` plus the state-tracker slot.

### 3.2 New entrypoint

```solidity
function applyForwardedUpdates(bytes calldata storageUpdates, uint256 expectedTransitionIndex)
    external
    payable
    trackState
{
    require(_getGasKillerSDKStorage().trustedForwarders[msg.sender], UntrustedForwarder(msg.sender));
    require(expectedTransitionIndex + 1 == stateTransitionCount(), InvalidTransitionIndex());

    (StateUpdateType[] memory types, bytes[] memory args) =
        abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
    _checkReservedSlots(types, args);   // §7 hardening: reject STOREs to tracker/config slots
    StateChangeHandlerLib._runStateUpdates(types, args);

    emit ForwardedUpdatesApplied(msg.sender, expectedTransitionIndex);
}
```

Load-bearing details:
- `trackState` pre-increments, so the index check is bit-for-bit the `verifyAndUpdate`
  pattern (GasKillerSDK.sol:67) and reuses `InvalidTransitionIndex`.
- `payable` lets the forwarding CALL op carry the ETH the original A→B call transferred.
- **No** `referenceBlockNumber` check here — freshness is gated once at the bundle
  root's `verifyAndUpdate`; the signature commitment makes that sufficient.
- Recursion is free: B's sub-payload may itself contain a CALL to
  `C.applyForwardedUpdates` (C allowlists B).

### 3.3 Auth management + discovery

```solidity
function _setTrustedForwarder(address forwarder, bool trusted) internal;
function isTrustedForwarder(address forwarder) external view returns (bool);
event ForwardedUpdatesApplied(address indexed forwarder, uint256 transitionIndex);
error UntrustedForwarder(address caller);

interface IGasKillerForwardee {   // new file: src/interface/IGasKillerForwardee.sol
    function applyForwardedUpdates(bytes calldata storageUpdates, uint256 expectedTransitionIndex) external payable;
    function isTrustedForwarder(address forwarder) external view returns (bool);
}
```

- `supportsInterface` additionally returns true for
  `type(IGasKillerForwardee).interfaceId`. **Do not touch `IGasKillerSDK`** — its
  interfaceId is asserted in tests and used for discovery of deployed consumers; a
  separate interface keeps old and new contracts distinguishable on-chain.
- Post-deploy allowlist changes need no new admin root: the quorum can toggle an entry
  via a signed `STORE` through B's own `verifyAndUpdate` to
  `keccak256(abi.encode(forwarder, uint256(BASE_SLOT) + 4))`.

---

## 4. Wire format and signing

**Unchanged.** `storageUpdates = abi.encode(StateUpdateType[], bytes[])`, existing
discriminants. Nesting lives entirely inside an ordinary CALL op's arg:

```
CALL arg = abi.encode(
  address target   = B,
  uint256 value    = ETH the original A→B call transferred,
  bytes   callargs = abi.encodeCall(IGasKillerForwardee.applyForwardedUpdates,
                       (storageUpdates_B, expectedTransitionIndex_B))
)
```

`storageUpdates_B` is recursively the same format. The forwarding CALL op sits at the
exact index where the original A→B call occurred, so global effect ordering (LOGs,
external calls) is preserved by construction. If the original tx calls B twice, two
forwarding ops carry consecutive expected indices (n, n+1).

**What the quorum signs — unchanged:**
`msgHash = sha256(abi.encode(transitionIndex_A, address(A), targetFunction_A, storageUpdates_A))`.
One signature, one ECDSA quorum verification per bundle. Operators independently
re-derive the full nested blob from `(tx_request, block_number)` and sign only on
byte-equality. A single-contract bundle encodes byte-identically to today — zero
migration for existing consumers and routers.

---

## 5. Trust model, replay, ordering

### Trust
B's runtime question — "were these bytes quorum-signed?" — is answered by a proxy
claim: *msg.sender is a contract whose only path to emitting `applyForwardedUpdates`
is its own post-verification `_stateChangeHandler`*. That is a property of A's **code**, fixed
at allowlist time. The effective authorizer of B's writes remains the quorum — the same
party that can already write any slot of B via B's own `verifyAndUpdate`. No new trust
root.

Rejected naive alternatives (all spoofable or weaker):
- *same-AVS / same-checker check*: `avsAddress` is self-declared; anyone can claim it.
- *ERC-165 "is GasKiller" on msg.sender*: inheriting the SDK is permissionless; a
  malicious inheritor can forward from unverified code paths.
- *global registry / factory attestation*: adds a trusted owner without attesting that
  the registered code confines forwarding to the verified path.

**Allowlist policy (normative):** only immutable, unmodified-SDK contracts. An
allowlisted upgradeable proxy grants its admin root over the callee.

### Replay & sequencing
- `expectedTransitionIndex_B` is byte-committed inside A's signed root → a forward is
  valid at exactly one counter value of B; standalone replay fails the allowlist; whole-
  bundle replay fails A's root index; reordering fails position commitment.
- Concurrent bundles / post-signing state drift: first bundle to land bumps B's
  counter; the loser reverts `InvalidTransitionIndex` inside B, surfaces as
  `RevertingContext(i, B, ...)`, and atomically reverts the whole outer bundle.
  Operators re-derive and re-sign. (Same liveness property as single mode, wider blast
  radius — router must serialize per contact-set.)
- The consumer invariant "**every** state-mutating function carries `trackState`" is
  now load-bearing for callees too: an untracked mutator lets a forwarded diff computed
  against stale state land silently. Pre-existing risk, widened; document loudly.

### Ordering, atomicity, reentrancy
Sub-payloads execute depth-first at their CALL op's index; ops within each level keep
original trace order. B's LOGs emit from B; B's calls to non-GK contracts run with
`msg.sender == B`. Any failure anywhere bubbles through the `RevertingContext` chain —
whole-bundle atomicity. Reentrancy needs no mutex: re-entering any apply path requires
either a fresh quorum signature or a trusted forwarder with a currently-valid index —
i.e., exactly the authorized operations. A callback that bumps a callee's counter
mid-bundle (via some tracked public function) can only *revert* the bundle (grief), not
corrupt state.

---

## 6. Deployment topologies

Both are supported by the same mechanism; choose per fleet size.

1. **Direct peer allowlist** (matches the A-calls-B shape): B allowlists A. Trust
   reviews are pairwise — fine for small clusters (factory + instances, app + vault).
   Contention only on overlapping contract sets.
2. **Shared relay** (Gateway topology with zero new code): deploy one audited,
   immutable, business-logic-free GasKillerSDK instance per AVS as the bundle **root**;
   every consumer allowlists only the relay. Bundles enter via
   `relay.verifyAndUpdate(...)` and fan out as forwards. Collapses N×N reviews to N×1.
   **Cost:** the relay's transition counter globally serializes all bundles through it —
   any two in-flight relay bundles conflict. Use direct mode for hot paths, relay for
   long-tail fleets.

---

## 7. Hardening grafts (from the judge panel, adopted)

1. **Reserved-slot denylist** in `applyForwardedUpdates` (~200 gas): reject forwarded
   `STORE`s to `STATE_TRACKER_STORAGE_LOCATION` and the ERC-7201 config slots
   `base..base+4`. Note the limit honestly: mapping *entries* (e.g.
   `trustedForwarders[x]`) live at keccak-derived slots and cannot be enumerated
   on-chain — the denylist shrinks the blast radius of a buggy signer; the allowlist
   remains the real boundary. Root `verifyAndUpdate` is intentionally not restricted
   (quorum stays able to manage config).
2. **Operator diff-equivalence gate** (service-side, mandatory): before signing,
   simulate *applying the bundle* in revm and require its post-state to equal the
   simulated original tx's post-state (`result.state` comparison; today this data is
   discarded at gas-estimator/src/lib.rs:265-285). This is the backstop for the new
   address-attribution code — a misattributed SSTORE becomes a signed write to the
   wrong contract, and only this gate catches it structurally.
3. **Quorum-verification delegated to the registry.** Under the ECDSA scheme, the
   empty/insufficient-quorum checks live in `ECDSAStakeRegistry.isValidSignature`
   (ascending operators, per-signature validity, signed stake ≥ threshold at the
   reference block), so `verifyAndUpdate` only asserts the registry returns the ERC-1271
   magic value (`InvalidQuorumSignature` otherwise) — no in-contract threshold loop to
   harden.
4. **Preimage v2 (future, breaking):** add `block.chainid` + a domain-separation tag to
   the signed preimage. Today's preimage has no chain binding — CREATE2-twinned
   deployments on another chain where the same operators control the quorum are
   replayable. Multi-call inherits this single-mode gap; fix in a coordinated v2.
5. **Paranoid fallback, zero new code:** a callee that refuses to allowlist anyone can
   still participate — embed a nested single-mode `B.verifyAndUpdate(...)` as an
   ordinary CALL op (costs one extra quorum verification, needs a per-callee signature from the
   operators). Document as the opt-out path for frozen/high-value contracts.
6. **Per-callee demotion, surfaced:** SELFDESTRUCT/TSTORE (and any unattributable
   frame) inside a forwardee demotes *that callee* to today's flattened CALL, not the
   whole bundle; the analyzer report must state each demotion and the forfeited savings
   (no silent caps).

---

## 8. Adversarial review — residual risks

Attacks that fail by construction: direct call to `applyForwardedUpdates`
(allowlist), sub-payload replay (index + allowlist), bundle replay (root index),
forward reordering (position commitment), reentrant re-application (index),
callee-counter races (atomic revert). Residual:

| # | Risk | Status |
|---|---|---|
| R1 | Allowlisted forwarder is root over the callee (compromised/upgradeable A ⇒ arbitrary writes to B) | Accepted + policy (§5) + denylist (§7.1) + relay topology (§6.2) |
| R2 | Front-run grief: bump any callee's counter before the bundle lands → router pays quorum-verification gas for a revert | Same class as single mode; router serialization + re-sign loop |
| R3 | Mid-bundle counter bump via a *flattened* CALL re-execution that reaches a forwardee's tracked function | Analyzer must derive expected indices from **bundle-application simulation**, not forward counting (§9.3); diff-gate catches misses |
| R4 | Cross-chain replay of twinned deployments | Preimage v2 (§7.4) |
| R5 | Misattributed SSTORE in the new address-stack walk (proxies, OOG frame aborts, CREATE subtrees) | Diff-equivalence gate (§7.2) + adversarial fixtures (§9.7) |
| R6 | CREATE inside a forwardee frame: callee nonce drift between trace and execution shifts the deployed address | Tracked mutators bump the counter (caught); untracked CREATE paths violate the trackState invariant — document |
| R7 | Callee upgraded/selfdestructed between signing and execution | Policy (immutable-only allowlist); optionally operator-side code-hash pinning at signing |
| R8 | Two forwards to same callee with interleaved external bumps | Consecutive-index construction + atomic revert; router re-derives |

---

## 9. Service/validator-side changes (gas-analyzer)

The encoder, wire format, estimator contract, injection machinery (selector
`0x7a888dbc`, backup address `0xba..ba`), and `abis/StateChangeHandlerGasEstimator.json`
are untouched. The diff concentrates in trace extraction and callee discovery.

1. **`crates/core/src/trace.rs`** — new
   `compute_state_updates_multi(trace, root, forwardees: HashMap<Address, u64>)`
   alongside the existing function (kept for single mode and pinned fixtures).
   Maintains a storage-context **address stack** (StructLogs carry depth, not address):
   CALL pushes `stack[1]`; DELEGATECALL/CALLCODE push the *current* context;
   CREATE/CREATE2 subtrees stay opaque initcode blobs. When a CALL targets a forwardee:
   recurse into the frame, strip SSTOREs to the tracker slot `0xdebf...deaf`
   (trackState supplies the increment), assign the expected index, emit the forwarding
   `Call` op. Otherwise keep today's flattening (trace.rs:256-263).
2. **`crates/core/src/encoding.rs`** — add
   `encode_forward_call(target, value, sub_updates, expected_index) -> Call` arg.
   Single-contract output stays byte-identical.
3. **Expected-index derivation** — indices must come from simulating the *applied
   bundle* against the anchored post-replay CacheDB (same DB used for estimation), not
   from counting forwards: a flattened CALL re-execution can itself bump a forwardee's
   counter mid-bundle (risk R3). Two forwards to the same callee get consecutive
   indices only when nothing tracked runs between them.
4. **Callee discovery** (`crates/evmsketch/src/lib.rs`,
   `call_to_encoded_state_updates_with_evmsketch`, 769-834) — pre-pass over CALL
   targets from a first flat extraction: `eth_call`
   `supportsInterface(IGasKillerForwardee)` + `isTrustedForwarder(callerContext)` at
   the anchor block; read counters from the post-replay DB. Enablement passes into core
   as a parameter (core stays network-free). Failing probes ⇒ stay flattened — mixed
   bundles work by construction.
5. **`crates/gas-estimator/src/lib.rs`** — mechanically unchanged: during simulation
   `B.applyForwardedUpdates` executes as B's real bytecode from SimpleRpcDb, so
   measured gas automatically includes forward overhead, allowlist and index checks; a
   wrong index reverts the simulation exactly as on-chain. Add the §7.2
   diff-equivalence gate here (post-state comparison currently discarded at 265-285).
6. **`crates/core/src/heuristic.rs`** — per-target split of CALL gas tracking:
   forwarded callees' frame gas leaves `external_call_gas`, replaced by
   ~13k/forward + 5000/STORE + LOG/CREATE costs of the sub-list; foreign CALL gas stays
   verbatim. `TURETZKY_UPPER_GAS_LIMIT` (250k) stays **once per bundle** — still exactly
   one ECDSA quorum verification.
7. **Fixtures/tests** — adversarial attribution fixtures well beyond current
   DelegateCallTestContracts: GK→GK, GK→proxy(GK impl), GK→non-GK→GK,
   delegatecall-inside-forwardee, OOG-aborted frames, repeated callee, CREATE inside
   forwardee.
8. **Config/reporting** — multicall enable flag + optional forwardee allowlist override
   in env/API; per-callee demotion reasons in the report. WASM path (EmptyDB — no
   callee code) stays single-contract.
9. **Router/operator layer (outside this repo)** — assembles per-callee expected
   indices into the blob before hashing (analyzer should emit them structured);
   enforces sub-payload slot policy (reject reserved-slot STOREs it did not derive);
   serializes in-flight bundles per contact-set; optional code-hash pinning per callee.

### Gas budget per forwarded contract
Fixed overhead ≈ **12–15k** (cold CALL 2600–3000, dispatch+decode ~1k, allowlist SLOAD
2100, trackState ~5000, index check + event ~2k) plus calldata (~16/nonzero byte;
often dominant for big diffs) plus the sub-list's own op costs. Versus alternatives:
a second independent bundle costs a full ECDSA quorum verification + registry reads + 21k base (modeled
250k flat) — forwarding saves ~235k per additional contract; versus status-quo live
re-execution, forwarding wins whenever the callee's execution gas exceeds ~15k + diff
cost, i.e. precisely the >250k transactions the eligibility gate targets.

---

## 10. Open questions

1. Router serialization mechanism for overlapping contact-sets (per-contract nonce
   reservation vs a single per-AVS sequencer)?
2. Allowlist governance UX: constructor wiring + quorum-signed STORE only, or an
   owner-gated setter (adds a second, non-quorum auth root — recommend against)?
3. Replace the address-stack walk with Geth `prestateTracer(diffMode)`/`callTracer`
   for attribution? Simpler, but changes rpc/src/lib.rs:29-52, every fixture, and the
   determinism story operators sign against.
4. `targetFunction` is signed but unused on-chain; should forwarded sub-payloads carry
   a callee selector for observability?
5. Timing of preimage v2 (chainid + domain tag) — coordinate with any other breaking
   change.

## 11. Rollout order

1. **Done (this repo):** storage field + `applyForwardedUpdates` + reserved-slot denylist +
   interface, layered on the ECDSA signature scheme; mock-registry test harness and
   A→B / A→B→C / repeated-B integration tests in `test/GasKillerForwarding.t.sol`.
2. Analyzer: address-stack walk behind a flag + fixtures; discovery probe; forward
   encoding; heuristic split; diff-equivalence gate.
3. Router/operators: expected-index assembly, slot policy, serialization.
4. Fleet: redeploy/upgrade consumers with allowlists (or stand up the per-AVS relay),
   then enable the analyzer flag per network.
