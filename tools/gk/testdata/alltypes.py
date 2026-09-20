# alltypes: every row of gk build's type map, in both directions (tools/gk test guest;
# PyGuests.t.sol holds the expected values).


def main(nums: list[int], big: int, flag: bool, blob: bytes, name: str,
         rows: list[list[int]]) -> tuple[str, list[int], bool, list[bytes], int]:
    total = sum(nums) + sum(sum(r) for r in rows)
    return (
        name + "!" * len(rows),
        [n * 2 for n in nums] + [len(r) for r in rows],
        not flag,
        [bytes(reversed(blob)), name.encode(), b""],
        (big + total) % (1 << 256),
    )
