"""diff two native_tasks.json fixtures, ignoring solc's CBOR metadata trailer in `consumerCode`.

The trailer's ipfs hash covers the compiler settings, and those list forge's auto-detected
remappings — a function of which nested submodules happen to be checked out, not of the
consumer's source. Everything executable (and every other field) must still match byte for byte.
"""
import difflib
import json
import sys


def strip_metadata(code):
    raw = bytes.fromhex(code[2:])
    n = int.from_bytes(raw[-2:], 'big')
    if len(raw) < n + 2 or raw[-2 - n] & 0xe0 != 0xa0:  # not a CBOR map: leave it alone
        return code
    return '0x' + raw[:-2 - n].hex()


def load(path):
    with open(path) as f:
        doc = json.load(f)
    doc['consumerCode'] = strip_metadata(doc['consumerCode'])
    return json.dumps(doc, indent=1).splitlines(keepends=True)


def main(a, b):
    delta = list(difflib.unified_diff(load(a), load(b), a, b))
    sys.stdout.writelines(line[:240] + ('\n' if len(line) > 240 else '') for line in delta)
    return 1 if delta else 0


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:3]))
