# UNBOUNDED_V2: pinned code overlays

Specification for extending Gas Killer's unbounded simulation profile
(`SimProfile::UnboundedV1`, gas-analyzer #166) with **pinned code overlays**, so that
large immutable data — model weights, lookup tables, any read-only blob — participates
in simulation as contract code **without ever being deployed on-chain**. The consumer
side of this spec is implemented in this directory (`Qwen3Engine` overlay mode); the
analyzer/service/guest side is specified here for the companion gas-analyzer PR.

## Motivation

Qwen3-0.6B needs 597MB of int8 weights. As on-chain data contracts that is 24,299
deployments, ~130B gas, roughly $400K–$4.5M on mainnet. As an overlay it is **one
32-byte hash** in the consumer's immutables. UnboundedV1 already established the
governing principle: the simulation environment may deviate from the real chain
env, provided every deviation is a **versioned protocol constant** that operators,
the analyzer, and the SP1 slashing guest agree on bit-for-bit. V1 pins gas limits;
V2 additionally pins a set of `address → code` bindings.

## Mechanism

**Manifest.** A model ships as two byte blobs (weights, tokenizer). Its identity is

```
manifestHash = keccak256(abi.encodePacked(keccak256(weightsBlob), keccak256(tokenizerBlob)))
```

**Derived addresses.** The blobs are split into 24,575-byte chunks (EIP-170 payload
minus the STOP prefix), indexed globally — weight chunks first, then tokenizer chunks.
Chunk `i` is addressed at

```
address_i = address(uint160(uint256(keccak256(abi.encodePacked(
    "gaskiller.llm.overlay.v1", manifestHash, uint64(i))))))
```

(`Qwen3Engine.overlayChunkAddress`; mirrored by `tools/deploy_anvil.py`). Domain
separation makes collisions with deployed contracts or other manifests cryptographically
irrelevant, and derivation removes any need for on-chain address directories.

**Mounting.** Each chunk is mounted as code `0x00 || chunkBytes` at its derived
address in the simulation env — revm state overrides in-process for operators, the
`stateOverrides` parameter of `debug_traceCall` for RPC-driven flows, `anvil_setCode`
for local work. To EVM execution an overlaid chunk is indistinguishable from a
deployed data contract: `EXTCODESIZE`/`EXTCODECOPY` behave identically, which is why
the engine code is byte-for-byte the same in both modes.

**Consumer commitment.** The consumer (e.g. `GasKillerChat`) is deployed with
`weightsRoot = address(0)` and `weightsManifest = manifestHash`. That immutable is the
entire on-chain footprint of the model and the root of trust: operators refuse to mount
bytes whose hashes do not reproduce `manifestHash`.

## Consensus and slashing safety

Exactly V1's env-binding pattern, extended:

- The overlay set — canonically `(manifestHash, chunkCount)`, or equivalently the
  sorted `(address, codeHash)` pairs — joins `UNBOUNDED_V2_*` versioned constants.
- The env commitment that the SP1 guest binds into `chainConfigHash` covers gas
  limits **and** the overlay set. A fraud proof simulated under different weights
  (or without them) produces a different `chainConfigHash` and cannot verify;
  honest operators using the pinned overlay cannot be slashed.
- Task flow is unchanged: same calldata, same reference block, same
  `sha256(transitionIndex, target, selector, storageUpdates)` signing payload.
- Shape gate is unchanged; additionally, a payload `Store`/`Create` targeting an
  overlaid address is invalid (overlays are read-only by construction — reads never
  enter payloads anyway, so this is belt-and-suspenders).

## Operator lifecycle

1. Fetch the blobs out-of-band (HuggingFace, IPFS, mirror — availability, not trust).
2. Verify: hash blobs, recompute `manifestHash`, compare against the consumer's
   `weightsManifest` and the AVS's registered overlay constants.
3. Mount: chunk, derive addresses, install as env overrides (or `anvil_setCode` on a
   local fork).
4. Validate end-to-end: `engine.checkArtifacts(address(0), manifestHash, packedConfig)`
   must pass in the mounted env (it verifies chunk presence and total lengths).
5. Serve: simulate tracked calls exactly as under V1.

## Trade-off: data availability

Overlay mode moves the weights' availability off-chain. This is a **liveness**
exposure, never a safety one: nobody can forge bytes against `manifestHash`; if every
mirror of the blob disappeared, tracked calls simply could not be simulated until
someone re-serves it. Deployed-code mode (the two-level directory this example also
supports) keeps availability on-chain forever at deployment cost. Choose per model:
small models on-chain, large models overlaid, and the same engine serves both.

## Status

- Consumer + engine + tooling + tests: implemented here (overlay mode of
  `Qwen3Engine`/`GasKillerChat`, `deploy_anvil.py --overlay`,
  `test_OverlayModeMatchesDirectoryMode`).
- Analyzer (`SimProfile` V2 constants, override threading, overlay store,
  env-commitment helper) and SP1 guest binding: specified above, to land as a
  gas-analyzer PR stacked on #166 and a companion guest change.
- Service: same one-argument profile wiring V1 already needs, plus operator
  config for the artifact store path.
