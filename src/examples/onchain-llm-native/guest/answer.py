# answer: the guest behind GasKillerChatNative — typed arguments in, (text, ids) out.
#
#   python3 tools/gk build src/examples/onchain-llm-native/guest/answer.py \
#       --sol-out src/examples/onchain-llm-native/gen
#
# A STAND-IN responder, not a model: the point of this file is the pipeline (type hints →
# generated binding → one staticcall from the consumer), so the "inference" is a 31-bit LCG
# walked over a 32-word vocabulary — small enough that the forge test recomputes it in
# Solidity. Integer-only, no artifact (the consumer's artifactRoot is zero).

VOCAB = (
    "<eos>", "the", "gas", "killer", "operator", "signs", "one", "slot",
    "guest", "runs", "native", "and", "every", "honest", "node", "agrees",
    "on", "a", "single", "answer", "because", "cycles", "are", "counted",
    "not", "timed", "so", "state", "diffs", "stay", "small", "forever",
)
EOS = 0
MAX_NEW = 64
MASK31 = 0x7FFFFFFF


def respond(prompt_ids, max_new):
    state = len(prompt_ids)
    for t in prompt_ids:
        state = (state * 31 + t) & MASK31
    ids = []
    for _ in range(max_new):
        state = (state * 1103515245 + 12345) & MASK31
        tok = (state >> 16) % len(VOCAB)
        if tok == EOS:
            break
        ids.append(tok)
    return ids


def main(prompt_ids: list[int], max_new: int) -> tuple[str, list[int]]:
    if max_new > MAX_NEW:
        raise ValueError("answer: max_new > 64")
    ids = respond(prompt_ids, max_new)
    return " ".join(VOCAB[i] for i in ids), ids
