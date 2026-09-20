# onchain-llm-native

`GasKillerChat`, with the on-chain engine replaced by a native guest (UNBOUNDED_V3 — see
[`../onchain-llm/UNBOUNDED_V3_NATIVE.md`](../onchain-llm/UNBOUNDED_V3_NATIVE.md)).

| file | what it is |
|---|---|
| `guest/answer.py` | the guest: `main(prompt_ids: list[int], max_new: int) -> tuple[str, list[int]]` |
| `gen/GkAnswer.sol` | the binding `gk build` generated from those type hints — do not edit |
| `GasKillerChatNative.sol` | the consumer: `ask()` = one staticcall through the binding, fold the root, one `sstore(CHAT_ROOT_SLOT)`, one event |

`answer.py` is a **stand-in responder, not a model** — a 31-bit LCG over a 32-word vocabulary,
small enough that the forge test recomputes it in Solidity. What the example shows is the
pipeline: nothing between `answer.py` and `ask()` is written by hand.

```bash
# from the sdk root: rebuild the guest (docker + MicroPython v1.29.0 at the pinned commit),
# regenerate the binding in place
python3 tools/gk build src/examples/onchain-llm-native/guest/answer.py \
    --out cache/gkvm/build/native-answer --sol-out src/examples/onchain-llm-native/gen

# the same, then: the committed binding must not have moved (the build reproduces its
# PROGRAM_HASH), and the consumer's suites run with the real guest behind GkVmFfiShim
make -C tools/gk native-example-check
```

The guest ELF (~1 MB) is not committed; `PROGRAM_HASH` in the binding commits to it, and the
ffi suite asserts the rebuilt image hashes to exactly that. Without `GK_RUN`,
`GasKillerChatNativeFfiTest` skips and `GasKillerChatNativeTest` runs the consumer against a
stand-in precompile that answers with the Solidity reference.

### The zero-glue check

```bash
# answer.py → gk build → forge test → gas-analyzer's local executor, in one target
# (needs the sibling gas-analyzer checkout on a branch that has crates/evmsketch/src/tests/gkvm_native.rs)
make -C tools/gk zero-glue-check
```

"Nothing is written by hand" is checked, not asserted: the target lints `answer.py` (no
imports, no hostcall, no codec), the consumer (no `abi.decode`, no `GkVm.exec`, its only
`abi.encode` is the chat-root fold) and the binding (byte-equal to the generator's output for
those type hints); records six `ask` tasks of the real guest behind `GkVmFfiShim` as encoded
`StateUpdate` payloads (`test/fixtures/gkvm/native_tasks.json`, with the consumer's production
bytecode); and then has gas-analyzer's local executor run that bytecode and calldata against
the real gkvm precompile with the same image installed. Both legs must produce the same
bytes — including the revert data of the task whose guest raises `ValueError`. What an operator
would sign for this consumer is therefore a function of `answer.py` and the consumer alone.

From fresh checkouts, the whole loop is these commands and nothing else. Needs `git`, `forge`,
`python3`, `cargo`, `make`, docker and network — the sdk's submodules and, on the first
`gk build`, MicroPython v1.29.0 (into `cache/gkvm/micropython/src`) are fetched from GitHub.
Until this work is on the default branches, `<branch>` is `Rubydusa/gkvm-m5-dx` for the sdk and
`Rubydusa/gkvm-m5-local-exec` for gas-analyzer; the two checkouts must be siblings.

```bash
git clone --branch <branch> https://github.com/gas-killer/solidity-sdk
git clone --branch <branch> https://github.com/gas-killer/gas-analyzer
cd solidity-sdk
git submodule update --init --recursive
(cd ../gas-analyzer && cargo build --release -p gas-analyzer-gkvm --bin gk-run)
make -C tools/gk zero-glue-check
```

`make -C tools/gk zero-glue-proof` replays exactly that in a scratch directory outside every
checkout (cloning the local checkouts' HEAD commits) and refuses any command not written above.

## stories260K, in Python

The second guest is a model: engine v1 of [`../onchain-llm`](../onchain-llm) — stories260K,
`Llama2.sol` + `LlamaTokenizer.sol` — as one Python file.

| file | what it is |
|---|---|
| `guest/stories260k.py` | tokenizer + integer Llama-2 forward pass + greedy decode: `main(prompt: str, max_new: int) -> tuple[str, list[int]]` |
| `gen/GkStories260k.sol` | its generated binding — do not edit |
| `GasKillerLLMNative.sol` | the consumer: `GasKillerLLM` with `engine.run(...)` replaced by the binding; same `STORY_DOMAIN`, same slot, same root fold |

The arithmetic is `../onchain-llm/tools/reference.py` op for op, and the weights are the donor's
blobs byte for byte, mounted as artifacts (kind 0 = weight blob, kind 1 = tokenizer blob, read
once front to back: `--schedule sequential`) — so the guest is held to the donor's own
vectors: the 32-token and the 200-token story, ids and text, bit for bit.

```bash
# artifacts from the committed hex fixtures (+ their manifest-v3 root), guest + binding
# rebuilt (the committed binding must not move), then the consumer's suites with the real
# guest behind GkVmFfiShim; STORIES_LONG=1 adds the 200-token vector
make -C tools/gk native-stories-check
```

Measured (gk-run, x86_64; instruction counts are tier-independent, walls are the jit tier on
a quiet laptop):

| | EVM bytecode (donor) | this guest |
|---|---|---|
| 200-token story | 10,467,959,687 gas, ~13 s on revm | 124,865,966,723 cycles = 31,216,491,681 gas-equivalent at 4 cycles/gas, 122.9 s |
| 32-token story | — | 9,526,500,966 cycles, 10.2 s |
| model load (133 verified pages → tuples) | — | 111,743,124 cycles |

**Read the first row before quoting this demo as a speed-up: it is not one.** Interpreted
Python pays roughly 800 instructions per multiply-accumulate all-in (≈ 186M cycles for a
≈ 227K-MAC forward pass at a short context; the flagship's C guest pays ~4.4 in its matmul
loop), which is more than the EVM's own interpretive overhead: the Python guest costs ~3× the
donor's gas-equivalent and ~9× its wall clock. What it demonstrates is the other half of the
promise — one 371-line Python file, no Solidity kernels, no data contracts, no EVM memory
wall, bit-identical answers — i.e. Python for logic, C for kernels.

On any real chain the precompile does not exist: `ask()` and `dryRun()` revert
`GkVmUnavailable`. The guest runs only inside operators' simulation environments, and
`verifyAndUpdate` applies the signed diff — none of which has shipped yet (see the honesty
note in `tools/gk/templates/README.md.tmpl`).
