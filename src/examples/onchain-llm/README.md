# GasKillerLLM — a large language model running on-chain

A complete Llama-2-architecture transformer — tokenizer, RMSNorm, RoPE, grouped-query
attention, SwiGLU, greedy decoding — implemented from scratch in pure Solidity, with the
[stories260K](https://huggingface.co/karpathy/tinyllamas) checkpoint (260K parameters,
trained on TinyStories) stored on-chain as contract bytecode. Wrapped as a Gas Killer SDK
consumer, it turns "call an LLM on Ethereum" from impossible into one storage write.

```
prompt:  "Once upon a time"
on-chain output (bit-exact vs. llama2.c run.c at temperature 0):

  Once upon a time, there was a little girl named Lily. She loved to play
  outside in the park. One day, she saw a big, red ball. She wanted to play
  with it, but it was too high.
  Lily's mom said, "Lily, let's go to the park." ...
```

## The problem

Transformer inference is arithmetic-dense: this tiny model costs ~40–50M gas *per token*
(≈ one-plus mainnet block), and a 200-token story costs **10.47 billion gas** — about 290
mainnet blocks in a single call. No amount of Solidity golf makes that executable
on-chain; the block gas limit, not correctness, is the barrier.

## The Gas Killer approach

`tellStory(prompt, maxNewTokens)` is a tracked function shaped for the unbounded
simulation profile (`SimProfile::UnboundedV1`, gas-analyzer #166):

- **Compute off-chain.** Operators simulate `tellStory` under the pinned 2^40 gas
  environment. A 10.5B-gas generation uses ~1% of that budget and ~13s of wall-clock in
  revm — comfortably inside operator timeouts.
- **One slot on-chain.** The contract's only mutable state is `STORY_ROOT_SLOT`, a
  running keccak commitment over every (prompt, story) pair. The extracted payload is a
  single `STORE` (the StateTracker counter bump is gate-exempt) plus `LOG` ops carrying
  the story text — exactly what the UnboundedV1 shape gate admits. No `CALL`, no
  `CREATE`, no block-environment reads, nothing that reverts on well-formed input
  (the token budget is clamped to the context size; a prompt longer than the 512-token
  context reverts, in which case operators simply sign nothing).
- **Determinism = consensus.** All arithmetic is integer (Q32 fixed-point, integer
  sqrt, bit-product exp2) and sampling is greedy argmax, so every operator computes the
  same diff bit-for-bit and a BLS quorum can sign one message hash.
- **Weights are chain state.** The 536,448-byte quantized model + 5,714-byte tokenizer
  live in 23 immutable data contracts (`0x00 || payload` runtime code), read with
  `EXTCODECOPY` — reads never enter the payload.

| | direct on-chain call | via Gas Killer (UnboundedV1) |
|---|---|---|
| 8-token story | 460,816,973 gas (≈ 13 blocks — undeliverable) | 81,560 gas measured with mock BLS (~0.5M with real quorum check) |
| 200-token story | 10,467,959,687 gas (≈ 290 blocks — undeliverable) | same: one `STORE` + story logs |
| story text availability | return value + event | identical `StoryTold` event, replayed from the signed payload |

## Contract API

Two deployed contracts (split so each stays under EIP-170 with stock compiler
settings): **`LlamaEngine`**, the stateless inference engine (`run(...)` /
`checkArtifacts(...)`, reached via STATICCALL — never extracted into a payload), and
**`GasKillerLLM`**, the Gas Killer consumer:

- `tellStory(string prompt, uint256 maxNewTokens) → string` — tracked mutator. Runs
  full inference, folds the story into the root, emits `StoryTold(transitionIndex,
  newRoot, prompt, story, tokens)`.
- `dryRun(string prompt, uint256 maxNewTokens) → (string, uint16[])` — view twin of
  `tellStory` for `eth_call`, operators and tests.
- `storyRoot() → bytes32` — the single mutable slot.
- `computeStoryRoot(bytes32 prev, string prompt, string story) → bytes32` — `public
  pure`; doubles as the off-chain specification of the state transition.
- `config() → Llama2.Config` — the unpacked model hyperparameters.

## How it works

**Model** — stories260K: dim 64, hidden 172, 5 layers, 8 heads (head size 8), 4 KV heads
(GQA), vocab 512, context 512. Weights quantized to int16 with per-tensor power-of-two
scales (measured shifts 12–16 ≈ 3–4 decimal digits of precision per weight).

**Numerics** — activations are Q32 fixed-point in `int256` words; dot products
accumulate raw in 256-bit registers (overflow-impossible by construction) and requantize
with one arithmetic shift. RMSNorm uses an exact integer floor-sqrt; softmax uses
`exp(x) = 2^(x·log2e)` with a 32-step bit-product of `2^(2^-i)` constants derived by an
integer sqrt chain; SiLU uses the same exp. RoPE angles are precomputed Q30 tables baked
into the weight blob. Sampling is greedy argmax (first maximum wins).

**Bit-exactness** — `tools/reference.py` is a Python mirror of the Solidity arithmetic,
op for op (SAR floor shifts, SDIV truncation, floor isqrt). It reproduces llama2.c
`run.c` **byte-for-byte for 200+ tokens** on this checkpoint at temperature 0 — integer
quantization loses nothing here — and `tools/convert.py` emits its outputs as the test
vectors that pin the Solidity implementation to it exactly.

**Tokenizer** — the from-scratch tok512 SentencePiece-BPE vocabulary (MIT-licensed, not
Meta's Llama tokenizer): greedy highest-score merges, dummy-prefix space, byte-fallback
tokens, all on-chain over a compact blob.

## Engine v2: Qwen3-0.6B — a real chat model on-chain

`Qwen3.sol` + `Qwen3Engine.sol` + `GasKillerChat.sol` scale the same idea three
orders of magnitude: **Qwen3-0.6B** (596M params, Apache 2.0), the smallest genuinely
capable instruct model, running its full forward pass in Solidity. Asked
"What is Ethereum?" on-chain, the integer-exact model answers:

```
Ethereum is a decentralized blockchain platform that allows users to create and
run smart contracts. It was launched in 2015 by a team of developers led by
Vitalik Buterin. ...
```

Measured on anvil (word-batched int8 kernel, `--gas-limit 2^40`): prompt prefill +
1 token = **344.8B gas**; prompt + 8-token answer = **545.1B gas** (~9 min, ~1B gas/s)
— half of one UnboundedV1 round, applied on-chain as one SSTORE + logs. And in
**overlay mode** (see [UNBOUNDED_V2_OVERLAYS.md](./UNBOUNDED_V2_OVERLAYS.md)) the
597MB of weights never touch the chain at all: the consumer commits to a 32-byte
manifest hash, operators mount hash-verified bytes at derived phantom addresses, and
the identical engine bytecode reads them via EXTCODECOPY.

What 0.6B forces beyond v1:

- **Streaming.** 597MB of int8 weights can't sit in EVM memory (quadratic expansion
  would exceed 2^40 gas alone). The engine streams each tensor from its data
  contracts through one reused scratch buffer (~3MB high-water) — 24,299 weight
  chunks behind a two-level directory (root → pages → chunks).
- **Qwen3 architecture.** Per-head QK-RMSNorm, decoupled head_dim (128 ≠ 1024/16),
  RoPE theta 10^6 (HF half-dim convention folded into the weights by permutation at
  conversion), eps 10^-6, SwiGLU, GQA 16/8.
- **v2 numerics.** Q24 activations (Qwen3's residual stream peaks ~2^13; Q24 keeps
  every accumulation provably in range), int8 weights with per-row power-of-two
  scales, KV cache packed as int32 Q16 (8 per word), streaming argmax over the
  151,936-token tied classifier. Teacher-forced prefill skips the classifier
  entirely (~4.5B gas saved per prompt token).
- **Tokenizer split.** Prompts are pre-tokenized off-chain (byte-level BPE + chat
  template — deterministic, part of calldata, so operator consensus is unaffected);
  the answer is decoded fully on-chain from a raw-bytes token table.
- **Quantization quality**: the integer model matches float greedy decoding for the
  first 28/40 tokens on the test prompt, then diverges to an equally coherent
  phrasing — int8 per-row is effectively lossless in quality terms for this model.

The bit-exactness chain is the same as v1: `tools/qwen3_int.py` is the integer spec
(validated against the float model in `tools/qwen3_float.py`, itself a from-scratch
numpy Qwen3 implementation), and the Foundry suite pins the Solidity to it — in CI
via a tiny synthetic Qwen-architecture model (`test/fixtures/onchain-llm-v2/`),
locally against the real 597MB artifacts.

```bash
# real-model artifacts (1.5GB download, ~5 min conversion; artifacts land outside git)
python3 -m venv venv && venv/bin/pip install numpy tokenizers
venv/bin/python src/examples/onchain-llm/tools/qwen3_convert.py \
    --model model.safetensors --config config.json --tokenizer tokenizer.json \
    --out artifacts/ --sol-out src/examples/onchain-llm

# install on anvil (anvil_setCode, seconds) and deploy the consumer
anvil --gas-limit 1099511627776 &
python3 src/examples/onchain-llm/tools/deploy_anvil.py --artifacts artifacts/
forge create ... Qwen3Engine && forge create ... GasKillerChat
```

## Regenerating the artifacts

```bash
curl -LO https://huggingface.co/karpathy/tinyllamas/resolve/main/stories260K/stories260K.bin
curl -LO https://huggingface.co/karpathy/tinyllamas/resolve/main/stories260K/tok512.bin
python3 src/examples/onchain-llm/tools/convert.py \
    --model stories260K.bin --tokenizer tok512.bin \
    --out test/fixtures/onchain-llm --sol-out src/examples/onchain-llm
```

Any llama2.c legacy-format checkpoint converts the same way (stories15M is a drop-in
scale-up: ~630 weight chunks, ~1.5B gas/token — still under 2% of the unbounded budget
per token).

## Tests

```bash
forge test --match-contract OnchainLLM
# 200-token story vs. reference (10.5B gas, ~13s):
ONCHAIN_LLM_LONG_TEST=true forge test --match-test LongStory
```

The suite pins exp/isqrt/tokenizer/logits/generation to the Python reference vectors,
proves the one-app-slot write shape with `vm.record`, and exercises the full
`verifyAndUpdate` flow against a mock BLS quorum, applying the story diff without
executing inference on-chain.

## Deploy

```bash
AVS_ADDRESS=0x... SIG_CHECKER_ADDRESS=0x... \
forge script script/DeployOnchainLLM.s.sol --rpc-url $RPC --private-key $PK --broadcast
```

See [RESEARCH.md](./RESEARCH.md) for the donor-model survey, the integer-numerics
design space, and prior art.
