"""keccak256 (the Ethereum one — original Keccak padding 0x01, NOT NIST SHA3's 0x06).

`hashlib.sha3_256` is the wrong function, and the repo's Python tools carry no
third-party dependency, so this is a plain-Python Keccak-f[1600]. Guest ELFs
are kilobytes to a few megabytes; pycryptodome is used when it happens to be
installed (large inputs), and the two are cross-checked by the test suite.
"""

_MASK = (1 << 64) - 1
_RATE = 136  # bytes; capacity 512 bits

_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]

# rotation offsets, indexed [x][y]
_ROT = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
]


def _rol(v, n):
    n %= 64
    return ((v << n) | (v >> (64 - n))) & _MASK if n else v


def _f1600(a):
    """One Keccak-f[1600] permutation over a 5x5 list-of-lists state a[x][y]."""
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _ROT[x][y])
        a = [[b[x][y] ^ (~b[(x + 1) % 5][y] & b[(x + 2) % 5][y]) for y in range(5)]
             for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256_pure(data):
    """Dependency-free keccak256. Always available; slow on multi-MB inputs."""
    data = bytes(data)
    pad = _RATE - (len(data) % _RATE)
    if pad == 1:
        padded = data + b'\x81'
    else:
        padded = data + b'\x01' + b'\x00' * (pad - 2) + b'\x80'
    a = [[0] * 5 for _ in range(5)]
    for off in range(0, len(padded), _RATE):
        block = padded[off:off + _RATE]
        for i in range(_RATE // 8):
            a[i % 5][i // 5] ^= int.from_bytes(block[8 * i:8 * i + 8], 'little')
        a = _f1600(a)
    out = b''.join(a[i % 5][i // 5].to_bytes(8, 'little') for i in range(4))
    return out


def keccak256(data):
    try:
        from Crypto.Hash import keccak as _k  # pycryptodome, optional
    except ImportError:
        return keccak256_pure(data)
    return _k.new(digest_bits=256, data=bytes(data)).digest()


def hex32(digest):
    return '0x' + digest.hex()
