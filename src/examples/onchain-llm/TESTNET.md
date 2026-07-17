# Testnet runbook — GasKillerChat (Qwen3-0.6B)

Getting the on-chain LLM in front of real operators, fastest path first.

## What gets deployed where

| Component | Overlay mode (recommended) | Directory mode |
|---|---|---|
| `Qwen3Engine` | 1 tx, ~3.6M gas | same |
| `GasKillerChat` | 1 tx, ~3.5M gas | same + ~66M constructor validation |
| Weights + tokenizer (597MB + 1.6MB) | **nothing on-chain** — one 32-byte manifest in the consumer's immutables | 24,364 data contracts, ~130B gas total (~$1K-scale on an L2 testnet, days of txs on Sepolia) |
| Real `BLSSignatureChecker` | required for verifyAndUpdate (see `DeployOnchainLLM.s.sol` for the deploy-or-validate pattern) | same |

## Overlay-mode deployment (minutes)

```bash
# 1. Build artifacts once (any machine):
venv/bin/python src/examples/onchain-llm/tools/qwen3_convert.py \
    --model model.safetensors --config config.json --tokenizer tokenizer.json \
    --out artifacts/ --sol-out src/examples/onchain-llm
#    -> weights.bin, tokenizer.bin, vectors.json, Qwen3_0_6B.sol
#    manifestHash = keccak(keccak(weights.bin) ++ keccak(tokenizer.bin))

# 2. Publish the blobs anywhere durable (HF repo / IPFS / S3 + mirrors) and
#    record manifestHash.

# 3. Deploy contracts to the testnet:
forge create ...Qwen3Engine --rpc-url $RPC --private-key $PK --broadcast
forge create ...GasKillerChat --rpc-url $RPC --private-key $PK --broadcast \
  --constructor-args $AVS $SIG_CHECKER $ENGINE \
  0x0000000000000000000000000000000000000000 $MANIFEST_HASH \
  "[<3 packed config words from vectors.json>]"

# 4. Operator setup (each operator):
#    - fetch blobs, verify manifestHash
#    - mount overlay in the simulation env (until analyzer-native support lands,
#      an anvil fork works: anvil --fork-url $RPC --gas-limit 1099511627776, then
#      tools/deploy_anvil.py --overlay --rpc <local>)
#    - sanity: cast call $ENGINE "checkArtifacts(address,bytes32,bytes32[3])" \
#        0x0 $MANIFEST_HASH "[...]"  -> must succeed in the mounted env
```

## Serving a request (until service wiring lands)

The service currently calls the pre-#166 (Chain-profile) simulation entrypoint;
UnboundedV1 wiring is a pending one-argument change and overlay support is specified
in [UNBOUNDED_V2_OVERLAYS.md](./UNBOUNDED_V2_OVERLAYS.md). Until both land, the
operator flow can be exercised manually end-to-end:

```bash
# tokenize the prompt off-chain
venv/bin/python -c "
from tools.qwen3_float import chat_ids
print(chat_ids('artifacts/tokenizer.json', 'What is Ethereum?')[1])"

# simulate the tracked call in the overlay env (this is what operators sign over)
cast calldata "ask(uint32[],uint256)" "[...ids...]" 24   # tracked-call calldata
# -> debug_traceCall against the mounted env; extract {Store CHAT_ROOT_SLOT, Log3}
#    exactly as test_VerifyAndUpdateAppliesChatDiff constructs them

# apply on-chain
cast send $CHAT "verifyAndUpdate(...)" ...   # ~82K gas + BLS verification
```

## Budgets to respect (per UnboundedV1 round)

- 2^40 ≈ 1.1T simulated gas. Measured with the batched kernel: see README numbers;
  budget the prompt prefill + `maxNewTokens` accordingly.
- Operator wall-clock: `ROUND_TIMEOUT` 30s default / 300s Helm — a 0.6B answer needs
  the raised setting (or a faster executor); tokens-per-round scales directly with it.
- Transport: `call_data + storage_updates` ≤ 128KB — prompt ids + answer text ≈ 2KB.

## Known upstream dependencies

1. gas-analyzer #166 (UnboundedV1) — open; overlays stack on it (spec in this dir).
2. Service profile wiring (one-arg change per #166 notes).
3. SP1 guest env-commitment binding for overlays (companion to the analyzer PR).
4. service #309 (BLS→ECDSA migration) may change the checker the consumer wires to —
   the consumer only needs `checkSignatures`-compatible semantics either way.
