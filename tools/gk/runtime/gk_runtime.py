# gk_runtime — the ABI edge of a typed Python guest. `gk build` freezes this module next to
# the user's script and a generated entry that calls run(main, <param types>, <return types>):
# the payload is what the generated Solidity binding abi.encode()d, the output is what it
# abi.decode()s. MicroPython (gkvm port: mpz big ints, no floats), so nothing here may need
# more than that. Frozen into the image => part of every typed guest's programHash.
#
# Types are Solidity type strings: "uint256", "bool", "bytes", "string", and "<T>[]".
# A malformed payload or a return value of the wrong shape raises; uncaught, that is the
# port's deterministic 0xD0000001 trap carrying the traceback.
import gkvm

_UINT_LIMIT = 1 << 256


def _dynamic(t):
    return t != "uint256" and t != "bool"


def _word(buf, at):
    if at + 32 > len(buf):
        raise ValueError("abi: payload truncated")
    return int.from_bytes(buf[at:at + 32], "big")


def _decode_tuple(buf, base, types):
    out = []
    head = base
    for t in types:
        w = _word(buf, head)
        if _dynamic(t):
            out.append(_decode_dynamic(buf, base + w, t))
        elif t == "bool":
            if w > 1:
                raise ValueError("abi: bool word is not 0 or 1")
            out.append(w == 1)
        else:
            out.append(w)
        head += 32
    return out


def _decode_dynamic(buf, at, t):
    n = _word(buf, at)
    at += 32
    if t == "bytes" or t == "string":
        if at + n > len(buf):
            raise ValueError("abi: payload truncated")
        raw = bytes(buf[at:at + n])
        return raw if t == "bytes" else str(raw, "utf-8")
    # every element owns at least one head word: bounds n before anything is allocated
    if n > (len(buf) - at) // 32:
        raise ValueError("abi: array length exceeds the payload")
    return _decode_tuple(buf, at, [t[:-2]] * n)


def _u256(v):
    return v.to_bytes(32, "big")


def _encode_tuple(values, types):
    if len(values) != len(types):
        raise TypeError("abi: expected %d values, got %d" % (len(types), len(values)))
    heads = []
    tails = []
    offset = 32 * len(types)
    for v, t in zip(values, types):
        if _dynamic(t):
            tail = _encode_dynamic(v, t)
            heads.append(_u256(offset))
            tails.append(tail)
            offset += len(tail)
        elif t == "bool":
            if type(v) is not bool:
                raise TypeError("abi: expected bool")
            heads.append(_u256(1 if v else 0))
        else:
            if type(v) is not int:
                raise TypeError("abi: expected int")
            if v < 0 or v >= _UINT_LIMIT:
                raise ValueError("abi: int does not fit uint256")
            heads.append(_u256(v))
    return b"".join(heads) + b"".join(tails)


def _encode_dynamic(v, t):
    if t == "bytes" or t == "string":
        if t == "string":
            if not isinstance(v, str):
                raise TypeError("abi: expected str")
            v = v.encode()
        elif not isinstance(v, (bytes, bytearray, memoryview)):
            raise TypeError("abi: expected bytes")
        return _u256(len(v)) + bytes(v) + bytes(-len(v) % 32)
    if not isinstance(v, (list, tuple)):
        raise TypeError("abi: expected list")
    return _u256(len(v)) + _encode_tuple(v, [t[:-2]] * len(v))


def decode(payload, types):
    return _decode_tuple(payload, 0, types)


def encode(values, types):
    return _encode_tuple(values, types)


def run(main, param_types, return_types):
    """Decode the payload, call main, emit its result. return_types None = main returns
    bytes and they ARE the output (the binding hands them back undecoded); a tuple of types
    = the output is their ABI encoding (one type: main returns the bare value)."""
    result = main(*_decode_tuple(gkvm.input(), 0, param_types))
    if return_types is None:
        if not isinstance(result, (bytes, bytearray, memoryview)):
            raise TypeError("main() is declared -> bytes")
        gkvm.output(result)
    else:
        if len(return_types) == 1:
            result = (result,)
        elif not isinstance(result, (list, tuple)):
            raise TypeError("main() is declared -> tuple[...]")
        gkvm.output(_encode_tuple(result, return_types))
