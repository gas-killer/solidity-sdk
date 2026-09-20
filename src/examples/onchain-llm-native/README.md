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

On any real chain the precompile does not exist: `ask()` and `dryRun()` revert
`GkVmUnavailable`. The guest runs only inside operators' simulation environments, and
`verifyAndUpdate` applies the signed diff — none of which has shipped yet (see the honesty
note in `tools/gk/templates/README.md.tmpl`).
