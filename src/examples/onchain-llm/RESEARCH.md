# Research notes: building an LLM in Solidity from scratch

Working notes behind GasKillerLLM: which open-source from-scratch LLM to port, how to do
transformer math on a 256-bit integer machine, and why this fits Gas Killer's unbounded
simulation mode. Full source-level references live in the repos cited inline.

## 1. Donor survey — which "LLM from scratch" to port

The requirement: an LLM implemented from scratch in another language, small enough that
its full inference is *executable* (not just expressible) inside an EVM simulation, with
licensing that permits shipping code *and* weights.

| Candidate | Verdict |
|---|---|
| **karpathy/llama2.c** (`run.c`, ~700 lines of dependency-free C99) | **Chosen.** MIT code, MIT weights (tinyllamas model card), single-file executable spec of the Llama-2 architecture, deterministic argmax path at temperature 0, official int8 recipe (`runq.c`) proving the model tolerates quantization. |
| karpathy/llm.c, picoGPT, minGPT/nanoGPT | GPT-2 family: smallest checkpoint 124M params, 50K vocab, LayerNorm-with-bias + tabular GELU. Two to three orders of magnitude too big; nothing sub-1M exists. |
| llama2.zig / llama2.rs / llama2.go / llama2.f90 / llama2.java | Faithful MIT ports of the same spec — useful as cross-checks, identical donor question. |
| TinyLlama / SmolLM / Qwen-0.5B etc. | ≥135M params; weights licensing varies; non-starters for full on-chain storage. |

**Checkpoint:** `stories260K` (dim 64, hidden 172, 5 layers, 8 heads / 4 KV heads,
vocab 512, seq 512; 260,032 params) — trained by Karpathy on TinyStories specifically to
be the smallest checkpoint that still tells coherent stories. Its `tok512` tokenizer was
trained from scratch on TinyStories (unlike stories15M's tokenizer, which is derived from
Meta's Llama-2 tokenizer and carries the Llama 2 Community License — avoided).

Format notes that matter for the converter (`tools/convert.py`): the `.bin` is llama2.c's
*legacy v0* export — 7 little-endian int32 header, fp32 tensors in fixed order,
`vocab_size > 0` signaling a shared classifier, and two dead legacy RoPE tables
(`freq_cis_real/imag`) that must be skipped. `tok512.bin` is `{max_len, then per token:
f32 score, i32 len, bytes}` with byte-fallback tokens at ids 3–258.

**Prior art:** no transformer/LLM inference implemented natively in Solidity was found
(multiple searches, confirming the user's own). Closest neighbors: tiny on-chain
perceptrons/MNIST demos (orders of magnitude simpler), and the zkML/opML ecosystem
(EZKL, Giza, Modulus, ORA) — which all run inference *off-chain* and verify proofs
on-chain. Running the actual forward pass in EVM opcodes appears to be new territory —
enabled here precisely because Gas Killer changes what "executable" means.

## 2. Integer-only inference — design space

The EVM has no floats; it has 256-bit integers, cheap MUL/ADD/SAR/SDIV, and exact
determinism. That maps remarkably well onto integer-only inference literature (I-BERT's
integer GELU/softmax/LayerNorm; W8A8 practice; FQ-ViT's finding that attention
probabilities need ≥8 uniform bits):

- **Weights: int16, per-tensor power-of-two scale.** Group-wise Q8_0 (runq.c's scheme)
  halves storage but adds per-group bookkeeping; int16 per-tensor is effectively
  lossless for a 260K model (measured shifts 12–16) and keeps the matmul inner loop to
  `SIGNEXTEND(SHR(MLOAD))`. Storage cost is a non-issue: 536KB ≈ 22 data contracts.
- **Activations: Q32 in int256.** The 256-bit word is the EVM's superpower here: a
  dot product of ≤768 Q32×Q15 terms peaks ~2^80 — accumulate everything raw, requantize
  once per output with a single arithmetic shift. No saturation logic anywhere.
- **exp for softmax/SiLU:** base-2 range reduction (`exp(x) = 2^(x·log2e)`), integer
  part by SAR (floor — exactly right), fractional part via 32-step bit-product of
  `2^(2^-i)` constants — the ABDK/PRB-Math family algorithm, but with constants derived
  from scratch by a pure-integer sqrt chain (`C_0 = isqrt(2 << 128)`,
  `C_i = isqrt(C_{i-1} << 64)`), so the on-chain implementation is self-contained and
  the Python mirror derives identical constants. Chosen over I-BERT's degree-2/3
  polynomial for ~30 extra bits of accuracy at negligible cost (exp is <1% of runtime).
- **RMSNorm:** sum of squares in Q64, `+ eps(1e-5)`, exact integer floor-sqrt (Newton
  from a power-of-two overestimate, 7 iterations), then per-element `SDIV`.
- **RoPE:** no on-chain trig — cos/sin precomputed at conversion time into Q30 int32
  tables (they are *data*, like the weights) and shipped in the weight blob.
- **Sampling: greedy argmax.** Not just cheap — necessary. Operators must agree
  bit-for-bit for BLS aggregation; argmax over integer logits removes the last source
  of divergence. (Seeded integer RNG sampling would also be deterministic, an easy
  extension.)

**Validation methodology:** a Python reference (`tools/reference.py`) restricted to the
exact EVM op semantics (SAR = floor shift, SDIV = truncate toward zero, floor isqrt)
generates every test vector. The reference itself reproduces float `run.c` generation
**byte-for-byte for 200+ tokens** at temperature 0 — so the quantization scheme is
empirically lossless on this model — and the Foundry suite pins Solidity to the
reference exactly (per-op vectors, all 512 logits at pos 0, and full 32/200-token
generations).

## 3. Fitting Gas Killer's unbounded mode

Constraints from `SimProfile::UnboundedV1` (gas-analyzer #166) and the service flow,
and how the contract meets them:

| Constraint | Design response |
|---|---|
| Shape gate: ≤1 `Store` (StateTracker slot exempt), no `CREATE`; `Log`s pass | All mutable state is one commitment slot (`STORY_ROOT_SLOT`), PR #51's single-slot pattern; story text travels in the `StoryTold` log |
| `Call` ops re-execute on-chain at real gas | Zero external calls in the tracked path; weights read via `EXTCODECOPY` (reads never enter the payload) |
| Deterministic across operators | Integer-only math + argmax; no block-env reads; output depends only on calldata + the root at the reference block |
| Tracked function must not revert (revert ⇒ #165 fallback, nothing signed) | Token budget clamped to context size; the only input-dependent revert is a >512-token prompt (operators then sign nothing); malformed-artifact reverts are ruled out by deploy-time validation |
| 2^40 gas budget, 30–300s operator wall-clock | 10.5B gas / ~13s (revm) for 200 tokens — ~1% of budget; stories15M at ~1.5B gas/token remains feasible for short generations |
| 128KB transport cap on calldata + payload | Prompt + story + tokens ≈ 1–2KB worst case |

Measured end-to-end (Foundry, mock BLS): 8-token story = 460,816,973 gas simulated →
**81,560 gas** applied on-chain; 200-token story = 10,467,959,687 gas simulated → same
one-STORE application (~0.5M gas with a real quorum check). That is the pitch of this
example in one line: **a four-order-of-magnitude gas kill on a workload that no amount
of on-chain optimization could ever make deliverable.**

## 4. What "most meaningful" meant here

- **Real model, real weights, real text** — not a toy MLP: the canonical smallest
  coherent LLM, producing the same stories as its C reference, verifiable token-by-token.
- **The full pipeline on-chain** — tokenizer encode → transformer → argmax → detokenize;
  prompt in, prose out, no off-chain pre/post-processing to trust.
- **Architecture-faithful** — RMSNorm/RoPE/GQA/SwiGLU exactly as Llama-2 defines them,
  parameterized by config: bigger llama2.c checkpoints drop in via the same converter.
- **Consensus-grade determinism** — the property that makes it not a demo but a Gas
  Killer consumer: N operators, one hash, one slot.
