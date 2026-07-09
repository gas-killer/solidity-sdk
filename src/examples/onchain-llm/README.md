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
