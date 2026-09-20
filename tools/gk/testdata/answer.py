# answer: the doc's developer contract in miniature — typed arguments in, raw bytes out.
# (tools/gk test guest; PyGuests.t.sol recomputes the same sequence in Solidity.)


def respond(prompt_ids, max_new):
    acc = 0
    for t in prompt_ids:
        acc = (acc * 31 + t) % 65521
    ids = []
    for i in range(max_new):
        acc = (acc * 31 + i) % 65521
        ids.append(acc)
    return ids


def main(prompt_ids: list[int], max_new: int) -> bytes:
    if max_new > 64:
        raise ValueError("answer: max_new > 64")
    return b"".join(i.to_bytes(4, "big") for i in respond(prompt_ids, max_new))
