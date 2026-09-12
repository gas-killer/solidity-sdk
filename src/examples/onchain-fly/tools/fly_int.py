#!/usr/bin/env python3
"""fly_int.py — THE fixed-point reference for FlyEngine (HANDOFF §3, §4.2-4.3, §7.1).

Bit-for-bit definition of what `FlyEngine.sol` must compute: integer LIF kernel (Q24 int64 state,
Q64 decay tables, round-half-up), the stateIn/stateOut wire format, the rasterizer, the decoder,
and the commitment hashes.  Two kernel backends share one arithmetic spec:

  * `py`  — pure-Python integers, straight from the spec (slow; for small graphs and cross-checks)
  * `c`   — fly_int_core.c via ctypes (int128), for the 166,700-neuron graph

Pinned decisions (not in the HANDOFF, or clarified here):
  D-A  `step()` does NOT materialize: the wire format carries lazy state (`last`), so
       step([0,t1)) ∘ step([t1,T)) == step([0,T)) exactly.  `decide()` and `warmup()` materialize
       once at their end so the snapshots they hash are canonical.
  D-B  `decide()` runs pre-pass + binSteps per bin WITHOUT materializing between bins.
  D-C  Wire `ringHead` is always 0 (the ring is linearized head-first on output; nonzero on input
       is malformed).  `inflight` must equal sum(slotCount).
  D-D  Entry validation: version==1, N matches, clock>=1, every last <= clock-1, nActive/inflight
       <= N, active ids in range with flags bit0 set exactly on listed ids, refr <= rfc.
  D-E  Far decay: q=d>>10, r=d&1023; a = rhu64(pow(tA[1024],q) · tA[r]) with pow = right-to-left
       square-and-multiply starting from 2^64, rhu64 at every product; b likewise; b:=0 for
       d>=2219; a:=b:=c:=0 for d>=8873; c = (a-b)/3 floor.
  D-F  Luminance filter starts at 0 in every episode (black warm-up); update per bin
       Lf += (ALPHA·(L−Lf)) >> 16 with arithmetic (floor) shift.
  D-G  raw_mHz = binCount · 10_000_000 / binSteps (= 100,000 · count at 100 steps).
  D-H  Rasterizer: dev strip lit = min(|spot−twap|·10000/twap · 65535 / devRefBps, 65535), floor
       divisions; spot==twap lights nothing; bar height 0 when volRef == 0.
  D-I  abi.encodePacked(uint32[]) pads every element to 32 bytes (Solidity semantics).
"""
import argparse, ctypes as C, json, os, struct, sys
from decimal import Decimal, getcontext
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent

# ----------------------------------------------------------------------------- constants
Q16, Q24, ONE64 = 1 << 16, 1 << 24, 1 << 64
HALF64, HALF56 = 1 << 63, 1 << 55
MASK64 = ONE64 - 1
R_Q24, THR_Q24 = -52 << 24, -45 << 24
BOUND_Q16, BOUND_Q24 = 7 << 16, 7 << 24
A1, B1 = 18354740553814661001, 18081474067879353234
C1 = (A1 - B1) // 3
W_NUM = 23_068_672                     # 11 · 2^21 ; w_Q24 = sign · count · W_NUM / 5
TBL, FAR_B_ZERO, FAR_ALL_ZERO = 1024, 2219, 8873
SLOTS_DEFAULT = 19
EPC, CHUNK = 6143, 24575
DOMAIN = b"gaskiller.fly.engine.v1"
WARM_DOMAIN = b"gaskiller.fly.amm.warm.v1"
GAIN, HALF_SAT_Q16 = 30, 1311           # drive = (30·Lf<<16)/(1311+Lf), 0.02·65536 = 1310.72 → 1311
LAMINA_Q16, SUGAR_Q16, PPL101_Q16 = 12 << 16, 30 << 16, 4 << 16
ALPHA_Q16_DEFAULT, DECAY_Q16_DEFAULT = 41427, 59299
CANVAS_W, CANVAS_H, STRIP_ROWS = 640, 480, 40


def _check_constants():
    getcontext().prec = 60
    two64 = Decimal(2) ** 64
    assert int((Decimal(-1) / 200).exp() * two64) == A1, 'A1'
    assert int((Decimal(-1) / 50).exp() * two64) == B1, 'B1'
    assert round((1 - Decimal(-1).exp()) * 65536) == ALPHA_Q16_DEFAULT, 'ALPHA'
    assert round(Decimal('-0.1').exp() * 65536) == DECAY_Q16_DEFAULT, 'DECAY'
    assert A1 == 0xfeb923493e945789 and B1 == 0xfaee4cdd6f62db92 and C1 == 91088828645102589
_check_constants()


def keccak(data: bytes) -> bytes:
    from eth_hash.auto import keccak as k
    return k(data)


def word(x: int) -> bytes:
    return (x % (1 << 256)).to_bytes(32, 'big')


def packed_u32(xs) -> bytes:                     # abi.encodePacked(uint32[]) — 32-byte padded elements (D-I)
    return b''.join(word(int(x)) for x in xs)


# ----------------------------------------------------------------------------- fixed-point helpers (spec)
def rhu64(x: int) -> int: return (x + HALF64) >> 64      # floor((x + 2^63) / 2^64) == EVM sar(64, x + 2^63)
def rhu56(x: int) -> int: return (x + HALF56) >> 56


def build_tables():
    tA, tB, tC = [ONE64], [ONE64], [0]
    for d in range(1, TBL + 1):
        tA.append(rhu64(tA[-1] * A1)); tB.append(rhu64(tB[-1] * B1)); tC.append((tA[-1] - tB[-1]) // 3)
    return tA, tB, tC
TA, TB, TC = build_tables()


def powq(x: int, q: int) -> int:
    result, base = ONE64, x
    while q:
        if q & 1: result = rhu64(result * base)
        base = rhu64(base * base)
        q >>= 1
    return result


def far_decay(d: int):
    if d >= FAR_ALL_ZERO: return 0, 0, 0
    q, r = d >> 10, d & 1023
    a = rhu64(powq(TA[TBL], q) * TA[r])                 # TA[0] = 2^64 acts as identity
    b = rhu64(powq(TB[TBL], q) * TB[r]) if d < FAR_B_ZERO else 0
    return a, b, (a - b) // 3


def decay(d: int):
    return (TA[d], TB[d], TC[d]) if d <= TBL else far_decay(d)


# ----------------------------------------------------------------------------- packed config
def pack_cfg(m, *, warm_chunks=0, episode_steps=3000, pulse_steps=2000, bin_steps=100,
             alpha=ALPHA_Q16_DEFAULT, decay_q16=DECAY_Q16_DEFAULT, eta=0,
             min_fee=5, max_fee=100, max_skew=30, rebal_skew=30, rebal_threshold=25, dev_ref=50,
             max_lag=2, vol_bar_rows=440):
    c0 = (m['n'] << 224) | (m['nEdges'] << 192) | (m['ptrChunks'] << 176) | (m['edgeChunks'] << 160) \
        | (m['metaChunks'] << 144) | (warm_chunks << 128) | (m['delaySteps'] << 120) | (m['rfcSteps'] << 112) \
        | (m['entriesPerChunk'] << 96)
    c1 = (episode_steps << 240) | (pulse_steps << 224) | (bin_steps << 216) | (alpha << 200) | (decay_q16 << 184) | (eta << 168)
    c2 = (min_fee << 240) | (max_fee << 224) | (max_skew << 208) | (rebal_skew << 192) | (rebal_threshold << 176) \
        | (dev_ref << 160) | (max_lag << 152) | (vol_bar_rows << 136)
    return [c0, c1, c2]


def unpack_cfg(cfg):
    c0, c1, c2 = cfg
    f = lambda w, sh, bits: (w >> sh) & ((1 << bits) - 1)
    return dict(n=f(c0, 224, 32), nEdges=f(c0, 192, 32), ptrChunks=f(c0, 176, 16), edgeChunks=f(c0, 160, 16),
                metaChunks=f(c0, 144, 16), warmChunks=f(c0, 128, 16), delay=f(c0, 120, 8), rfc=f(c0, 112, 8),
                epc=f(c0, 96, 16),
                episodeSteps=f(c1, 240, 16), pulseSteps=f(c1, 224, 16), binSteps=f(c1, 216, 8), alpha=f(c1, 200, 16),
                decay=f(c1, 184, 16), eta=f(c1, 168, 16),
                minFee=f(c2, 240, 16), maxFee=f(c2, 224, 16), maxSkew=f(c2, 208, 16), rebalSkew=f(c2, 192, 16),
                rebalThreshold=f(c2, 176, 16), devRef=f(c2, 160, 16), maxLag=f(c2, 152, 8), volBarRows=f(c2, 136, 16))


# ----------------------------------------------------------------------------- graph blobs
def unpack_entries(blob: bytes, n_entries: int) -> np.ndarray:
    """Inverse of fly_convert.pack_entries: 6,143 entries + 3 pad bytes per chunk."""
    n_chunks = -(-n_entries // EPC)
    last_take = n_entries - (n_chunks - 1) * EPC
    assert len(blob) == (n_chunks - 1) * CHUNK + 4 * last_take + 3, 'blob length does not match 6,143-entry chunking'
    out = np.empty(n_entries, dtype=np.uint32)
    for c in range(n_chunks):
        take = min(EPC, n_entries - c * EPC)
        off = c * CHUNK
        out[c * EPC:c * EPC + take] = np.frombuffer(blob[off:off + 4 * take], dtype='>u4')
    return out


class Graph:
    def __init__(self, artifacts: Path):
        artifacts = Path(artifacts)
        meta = (artifacts / 'meta.bin').read_bytes()
        (ver, n, E, epc, delay, rfc, nro, offR, offRet, offLam, offSug, offPPL) = struct.unpack('>BIIHHHHIIIII', meta[:37])
        assert ver == 1 and epc == EPC
        self.n, self.E, self.delay, self.rfc = n, E, delay, rfc
        self.ids_keccak, self.npz_sha256 = meta[37:69], meta[69:101]
        self.readouts = [struct.unpack('>IBB', meta[offR + 6 * k: offR + 6 * k + 6]) for k in range(nro)]
        nret = struct.unpack('>I', meta[offRet:offRet + 4])[0]
        self.retina = [struct.unpack('>IHH', meta[offRet + 4 + 8 * k: offRet + 12 + 8 * k]) for k in range(nret)]
        nlam = struct.unpack('>I', meta[offLam:offLam + 4])[0]
        self.lamina = np.frombuffer(meta[offLam + 4: offLam + 4 + 4 * nlam], dtype='>u4').astype(np.int64)
        nsug = struct.unpack('>I', meta[offSug:offSug + 4])[0]
        self.sugar = np.frombuffer(meta[offSug + 4: offSug + 4 + 4 * nsug], dtype='>u4').astype(np.int64)
        self.ppl101 = struct.unpack('>II', meta[offPPL:offPPL + 8])
        self.ptr = unpack_entries((artifacts / 'ptr.bin').read_bytes(), n + 1)
        self.edges = unpack_entries((artifacts / 'edges.bin').read_bytes(), E)
        assert (self.ptr[-1] & 0x7fffffff) == E and (self.ptr[0] & 0x7fffffff) == 0
        self.manifest = json.loads((artifacts / 'fly_manifest.json').read_text()) if (artifacts / 'fly_manifest.json').exists() else None
        self.slots = self.delay + 1

    def cfg(self, **kw):
        m = self.manifest or dict(n=self.n, nEdges=self.E, ptrChunks=-(-(self.n + 1) // EPC), edgeChunks=-(-self.E // EPC),
                                  metaChunks=1, delaySteps=self.delay, rfcSteps=self.rfc, entriesPerChunk=EPC)
        return pack_cfg(m, **kw)


# ----------------------------------------------------------------------------- state + wire format
HDR = 32
class State:
    """Struct-of-arrays mirror of the neuron words + scheduling lists."""
    def __init__(self, n, slots):
        self.n, self.slots = n, slots
        self.v = np.full(n, R_Q24, dtype=np.int64); self.g = np.zeros(n, dtype=np.int64)
        self.drive = np.zeros(n, dtype=np.int32); self.count = np.zeros(n, dtype=np.uint32)
        self.last = np.zeros(n, dtype=np.uint64); self.refr = np.zeros(n, dtype=np.uint8); self.flags = np.zeros(n, dtype=np.uint8)
        self.active = np.zeros(n, dtype=np.int32); self.ring = np.zeros(n, dtype=np.uint32)
        self.slotCount = np.zeros(slots, dtype=np.uint32)
        self.clock, self.nActive, self.head, self.tail, self.inflight = 1, 0, 0, 0, 0

    @staticmethod
    def genesis(n, slots): return State(n, slots)

    def copy(self):
        s = State.__new__(State); s.__dict__.update({k: (v.copy() if isinstance(v, np.ndarray) else v) for k, v in self.__dict__.items()})
        return s

    def to_wire(self) -> bytes:
        n = self.n
        assert self.clock < (1 << 48)
        hdr = (bytes([1]) + n.to_bytes(4, 'big') + self.clock.to_bytes(6, 'big') + self.nActive.to_bytes(4, 'big')
               + self.inflight.to_bytes(4, 'big') + (0).to_bytes(4, 'big'))          # ringHead always 0 (D-C)
        hdr = hdr + b'\0' * (HDR - len(hdr))
        sc = np.asarray(self.slotCount, dtype='>u4').tobytes() + b'\0' * (96 - 4 * self.slots)
        words = np.zeros((n, 32), dtype=np.uint8)
        words[:, 0:8] = np.frombuffer(self.v.astype('>i8').tobytes(), dtype=np.uint8).reshape(n, 8)
        words[:, 8:16] = np.frombuffer(self.g.astype('>i8').tobytes(), dtype=np.uint8).reshape(n, 8)
        words[:, 16:20] = np.frombuffer(self.drive.astype('>i4').tobytes(), dtype=np.uint8).reshape(n, 4)
        words[:, 20:24] = np.frombuffer(self.count.astype('>u4').tobytes(), dtype=np.uint8).reshape(n, 4)
        words[:, 24:30] = np.frombuffer(self.last.astype('>u8').tobytes(), dtype=np.uint8).reshape(n, 8)[:, 2:8]
        words[:, 30] = self.refr; words[:, 31] = self.flags
        act = np.asarray(self.active[:self.nActive], dtype='>u4').tobytes()
        ring = np.asarray(self._ring_linear(), dtype='>u4').tobytes()
        return hdr + sc + words.tobytes() + act + ring

    def _ring_linear(self):
        idx = (self.head + np.arange(self.inflight)) % self.n
        return self.ring[idx]

    @staticmethod
    def from_wire(b: bytes, n_expected: int, slots: int, rfc: int) -> 'State':
        assert len(b) >= 128, 'short state'
        ver, n = b[0], struct.unpack('>I', b[1:5])[0]
        clock = int.from_bytes(b[5:11], 'big')
        nActive, inflight, ringHead = struct.unpack('>III', b[11:23])
        assert ver == 1 and n == n_expected and clock >= 1 and ringHead == 0 and b[23:32] == b'\0' * 9, 'bad header'
        assert nActive <= n and inflight <= n, 'bad list sizes'
        sc = np.frombuffer(b[32:32 + 4 * slots], dtype='>u4').astype(np.uint32)
        assert b[32 + 4 * slots:128] == b'\0' * (96 - 4 * slots) and int(sc.sum()) == inflight, 'bad slot counts'
        end = 128 + 32 * n
        assert len(b) == end + 4 * (nActive + inflight), 'bad length'
        w = np.frombuffer(b[128:end], dtype=np.uint8).reshape(n, 32)
        s = State(n, slots)
        s.v = np.frombuffer(w[:, 0:8].tobytes(), dtype='>i8').astype(np.int64)
        s.g = np.frombuffer(w[:, 8:16].tobytes(), dtype='>i8').astype(np.int64)
        s.drive = np.frombuffer(w[:, 16:20].tobytes(), dtype='>i4').astype(np.int32)
        s.count = np.frombuffer(w[:, 20:24].tobytes(), dtype='>u4').astype(np.uint32)
        last8 = np.zeros((n, 8), dtype=np.uint8); last8[:, 2:8] = w[:, 24:30]
        s.last = np.frombuffer(last8.tobytes(), dtype='>u8').astype(np.uint64)
        s.refr = w[:, 30].copy(); s.flags = w[:, 31].copy()
        assert np.all(s.last <= np.uint64(clock - 1)), 'last >= clock (tampered state)'   # the load-bearing guard (§3.4)
        assert np.all(s.refr <= rfc), 'refr out of range'
        act = np.frombuffer(b[end:end + 4 * nActive], dtype='>u4').astype(np.int32)
        ring = np.frombuffer(b[end + 4 * nActive:], dtype='>u4').astype(np.uint32)
        assert np.all(act < n) and np.all(ring < n) and len(np.unique(act)) == nActive, 'bad ids'
        listed = np.zeros(n, bool); listed[act] = True
        assert np.array_equal(listed, (s.flags & 1) == 1), 'flags bit0 must mark exactly the active list'
        s.active[:nActive] = act; s.ring[:inflight] = ring
        s.slotCount = sc; s.clock, s.nActive, s.head, s.tail, s.inflight = clock, nActive, 0, inflight % n if n else 0, inflight
        return s


def wire_without_counts(b: bytes, n: int) -> bytes:
    """The wire bytes with every neuron word's per-call `count` field zeroed (for composition checks)."""
    w = bytearray(b)
    for i in range(n): w[128 + 32 * i + 20: 128 + 32 * i + 24] = b'\0\0\0\0'
    return bytes(w)


def wire_counts(b: bytes, n: int) -> np.ndarray:
    return np.frombuffer(b[128:128 + 32 * n], dtype=np.uint8).reshape(n, 32)[:, 20:24].tobytes() and \
        np.frombuffer(np.frombuffer(b[128:128 + 32 * n], dtype=np.uint8).reshape(n, 32)[:, 20:24].tobytes(), dtype='>u4').astype(np.int64)


# ----------------------------------------------------------------------------- kernel backends
class PyKernel:
    """Pure-Python integer kernel: the spec, written plainly."""
    def __init__(self, G: Graph, s: State):
        self.G, self.s = G, s
        self.ptr = [int(x) for x in G.ptr]; self.edges = [int(x) for x in G.edges]

    def evolve(self, i, now, I):
        s = self.s
        last = int(s.last[i])
        assert now >= last
        d = now - last
        if d == 0: return
        refr = int(s.refr[i])
        if refr:
            frozen = refr - 1; skip = min(d, frozen)
            refr = 0 if d >= refr else refr - d
            d -= skip; s.refr[i] = refr
        if d > 0:
            a, b, c = decay(d)
            v, g = int(s.v[i]), int(s.g[i])
            v = R_Q24 + rhu64((v - R_Q24) * a) + rhu56(I * (ONE64 - a)) + rhu64(g * c)
            g = rhu64(g * b)
            s.v[i] = v; s.g[i] = g
        s.last[i] = now

    def awaken(self, i):
        s = self.s
        if not (s.flags[i] & 1):
            s.flags[i] |= 1; s.active[s.nActive] = i; s.nActive += 1

    def set_drives(self, new):
        s = self.s
        for i in range(s.n):
            if int(new[i]) != int(s.drive[i]):
                self.evolve(i, s.clock - 1, int(s.drive[i])); s.drive[i] = new[i]; self.awaken(i)

    def advance(self, steps):
        s, G = self.s, self.G
        n = s.n
        for _ in range(steps):
            now = s.clock
            slot, future = now % s.slots, (now + G.delay) % s.slots
            tailBefore, pushed, kept = s.tail, 0, 0
            for k in range(s.nActive):
                i = int(s.active[k]); I = int(s.drive[i])
                self.evolve(i, now, I)
                v, g = int(s.v[i]), int(s.g[i])
                if s.refr[i] == 0 and v > THR_Q24:
                    s.ring[s.tail] = i; s.tail = (s.tail + 1) % n; pushed += 1; s.count[i] += 1
                can_fire = v > THR_Q24 or I > BOUND_Q16 or (I << 8) + g > BOUND_Q24
                if can_fire: s.active[kept] = i; kept += 1
                else: s.flags[i] &= 0xfe
            s.nActive = kept
            n_deliver = int(s.slotCount[slot])
            for _q in range(n_deliver):
                i = int(s.ring[s.head]); s.head = (s.head + 1) % n
                p0, p1 = self.ptr[i], self.ptr[i + 1]
                neg = p0 >> 31
                for e in range(p0 & 0x7fffffff, p1 & 0x7fffffff):
                    edge = self.edges[e]; j = edge >> 14
                    w = ((edge & 0x3fff) * W_NUM) // 5
                    if neg: w = -w
                    self.evolve(j, now, int(s.drive[j]))
                    if s.refr[j] == 0:
                        s.g[j] += w; self.awaken(j)
            s.slotCount[slot] = 0; s.inflight -= n_deliver
            p = tailBefore
            while p != s.tail:
                i = int(s.ring[p]); s.v[i] = R_Q24; s.g[i] = 0; s.refr[i] = G.rfc; p = (p + 1) % n
            s.slotCount[future] = pushed; s.inflight += pushed
            s.clock = now + 1

    def materialize(self):
        s = self.s
        for i in range(s.n): self.evolve(i, s.clock - 1, int(s.drive[i]))


class _CState(C.Structure):
    _fields_ = [('n', C.c_int32), ('ptr', C.c_void_p), ('edges', C.c_void_p), ('v', C.c_void_p), ('g', C.c_void_p),
                ('drive', C.c_void_p), ('count', C.c_void_p), ('last', C.c_void_p), ('refr', C.c_void_p), ('flags', C.c_void_p),
                ('active', C.c_void_p), ('ring', C.c_void_p), ('slotCount', C.c_void_p), ('clock', C.c_uint64),
                ('nActive', C.c_int32), ('head', C.c_uint32), ('tail', C.c_uint32), ('inflight', C.c_uint32),
                ('delay', C.c_int32), ('rfc', C.c_int32), ('slots', C.c_int32)]


_LIB = None
def _lib():
    global _LIB
    if _LIB is None:
        path = HERE / ('libflyint.dylib' if sys.platform == 'darwin' else 'libflyint.so')
        if not path.exists() or path.stat().st_mtime < (HERE / 'fly_int_core.c').stat().st_mtime:
            import subprocess
            subprocess.run(['clang', '-O2', '-std=c11', '-shared', '-fPIC', str(HERE / 'fly_int_core.c'), '-o', str(path)], check=True)
        _LIB = C.CDLL(str(path))
        _LIB.fly_set_drives.argtypes = [C.POINTER(_CState), C.c_void_p]
        _LIB.fly_advance.argtypes = [C.POINTER(_CState), C.c_int64]
        _LIB.fly_materialize.argtypes = [C.POINTER(_CState)]
        _LIB.fly_get_tables.argtypes = [C.c_void_p] * 3
        _LIB.fly_far_decay.argtypes = [C.c_int64] + [C.POINTER(C.c_uint64)] * 3
        _LIB.fly_build_tables()
        assert _LIB.fly_shift_is_arithmetic() == 1, 'C right shift of int128 must be arithmetic'
    return _LIB


class CKernel:
    def __init__(self, G: Graph, s: State):
        self.G, self.s, self.lib = G, s, _lib()
        self.ptr, self.edges = np.ascontiguousarray(G.ptr, dtype=np.uint32), np.ascontiguousarray(G.edges, dtype=np.uint32)

    def _cs(self):
        s = self.s
        for k in ('v', 'g', 'drive', 'count', 'last', 'refr', 'flags', 'active', 'ring', 'slotCount'):
            assert getattr(s, k).flags.c_contiguous
        return _CState(s.n, self.ptr.ctypes.data, self.edges.ctypes.data, s.v.ctypes.data, s.g.ctypes.data, s.drive.ctypes.data,
                       s.count.ctypes.data, s.last.ctypes.data, s.refr.ctypes.data, s.flags.ctypes.data, s.active.ctypes.data,
                       s.ring.ctypes.data, s.slotCount.ctypes.data, s.clock, s.nActive, s.head, s.tail, s.inflight,
                       self.G.delay, self.G.rfc, self.G.slots)

    def _sync(self, cs):
        s = self.s
        s.clock, s.nActive, s.head, s.tail, s.inflight = int(cs.clock), int(cs.nActive), int(cs.head), int(cs.tail), int(cs.inflight)

    def set_drives(self, new):
        new = np.ascontiguousarray(new, dtype=np.int32); cs = self._cs()
        self.lib.fly_set_drives(C.byref(cs), new.ctypes.data); self._sync(cs)

    def advance(self, steps):
        cs = self._cs(); self.lib.fly_advance(C.byref(cs), int(steps)); self._sync(cs)

    def materialize(self):
        cs = self._cs(); self.lib.fly_materialize(C.byref(cs)); self._sync(cs)


def kernel(G, s, backend='c'):
    return CKernel(G, s) if backend == 'c' else PyKernel(G, s)


# ----------------------------------------------------------------------------- rasterizer (§4.2) + decoder (§4.3)
def canvas_value(y, x, o, dev_ref, bar_rows):
    spot, twap, vol_ref = int(o['spotQ64']), int(o['twapQ64']), int(o['volRef'])
    if y < STRIP_ROWS:
        if spot == twap or twap == 0: return 0
        abs_dev = (abs(spot - twap) * 10000) // twap
        lit = min(abs_dev * 65535 // dev_ref, 65535)
        return lit if ((x < 320) == (spot > twap)) else 0
    if x < 320: vol = int(o['buyQuote'][x // 20])
    else: vol = int(o['sellQuote'][(x - 320) // 20])
    h = (bar_rows * min(vol, vol_ref)) // vol_ref if vol_ref else 0
    return 65535 if y >= CANVAS_H - h else 0


def rasterize(G: Graph, cfg, o) -> bytes:
    p = unpack_cfg(cfg)
    out = []
    for (_idx, u, v) in G.retina:
        xq, yq = u * (CANVAS_W - 1), v * (CANVAS_H - 1)
        x0, y0 = xq >> 16, yq >> 16
        x1, y1 = min(x0 + 1, CANVAS_W - 1), min(y0 + 1, CANVAS_H - 1)
        dx, dy = xq & 0xffff, yq & 0xffff
        Y = lambda yy, xx: canvas_value(yy, xx, o, p['devRef'], p['volBarRows'])
        L = ((65536 - dx) * (65536 - dy) * Y(y0, x0) + dx * (65536 - dy) * Y(y0, x1)
             + (65536 - dx) * dy * Y(y1, x0) + dx * dy * Y(y1, x1)) >> 32
        assert 0 <= L <= 65535
        out.append(L)
    return struct.pack('>%dH' % len(out), *out)


def retina_drive(Lf: int) -> int:
    return ((GAIN * Lf) << 16) // (HALF_SAT_Q16 + Lf)


# ----------------------------------------------------------------------------- entry points
def genesis_state(G: Graph) -> bytes:
    return State.genesis(G.n, G.slots).to_wire()


def parse_drive_in(b: bytes, n: int) -> np.ndarray:
    assert len(b) % 8 == 0
    d = np.zeros(n, dtype=np.int32)
    prev = -1
    for k in range(len(b) // 8):
        i, val = struct.unpack('>Ii', b[8 * k: 8 * k + 8])
        assert i > prev and i < n and val != 0, 'driveIn must be sorted, in range, nonzero'
        d[i] = val; prev = i
    return d


def step(G: Graph, cfg, state_in: bytes, drive_in: bytes, readout_ids, n_steps: int, backend='c'):
    s = State.from_wire(state_in, G.n, G.slots, G.rfc)
    s.count[:] = 0
    k = kernel(G, s, backend)
    k.set_drives(parse_drive_in(drive_in, G.n))
    k.advance(n_steps)
    state_out = s.to_wire()                                   # lazy: no materialize (D-A)
    counts = [int(s.count[i]) for i in readout_ids]
    chk = keccak(word(int.from_bytes(keccak(DOMAIN), 'big')) + keccak(state_in) + keccak(drive_in)
                 + keccak(packed_u32(readout_ids)) + word(n_steps) + keccak(state_out) + keccak(packed_u32(counts)))
    return state_out, counts, chk


def base_drive(G: Graph, Lf):
    d = np.zeros(G.n, dtype=np.int32)
    d[G.lamina] = LAMINA_Q16
    for (idx, _u, _v), lf in zip(G.retina, Lf): d[idx] = retina_drive(lf)
    return d


def warmup(G: Graph, cfg, steps: int, backend='c'):
    s = State.genesis(G.n, G.slots)
    k = kernel(G, s, backend)
    k.set_drives(base_drive(G, [0] * len(G.retina)))
    k.advance(steps); k.materialize()
    out = s.to_wire()
    return out, keccak(WARM_DOMAIN + keccak(out))


def encode_readout(r):
    return b''.join(word(x) for x in list(r['rateMilliHz']) + list(r['spikesLast30ms']) + list(r['windowCounts']) + [r['totalSpikes']])


def decide(G: Graph, cfg, warm_state: bytes, frame: bytes, stim, rates0, backend='c', trace=None):
    p = unpack_cfg(cfg)
    D, B = p['episodeSteps'], p['binSteps']
    assert D % B == 0 and len(frame) == 2 * len(G.retina)
    L = list(struct.unpack('>%dH' % len(G.retina), frame))
    s = State.from_wire(warm_state, G.n, G.slots, G.rfc)
    s.count[:] = 0
    k = kernel(G, s, backend)
    Lf = [0] * len(L)
    rates = [int(x) for x in rates0]
    bci = [ro[0] for ro in G.readouts[:4]]
    prev = [0] * 4; hist = []
    for b in range(D // B):
        for i in range(len(L)): Lf[i] += (p['alpha'] * (L[i] - Lf[i])) >> 16
        d = base_drive(G, Lf)
        t0 = b * B
        if t0 < stim['rewardSteps']: d[G.sugar] = SUGAR_Q16
        if t0 < stim['punishSteps']:
            for i in G.ppl101: d[i] += PPL101_Q16
        k.set_drives(d); k.advance(B)
        c4 = [int(s.count[i]) - prev[j] for j, i in enumerate(bci)]; prev = [int(s.count[i]) for i in bci]
        raw = [c * 10_000_000 // B for c in c4]
        rates = [(rates[j] * p['decay'] + raw[j] * (65536 - p['decay'])) >> 16 for j in range(4)]
        hist.append(c4)
        if trace is not None: trace.append({'bin': b, 'counts': c4, 'rates': list(rates), 'nActive': int(s.nActive), 'spikes': int(s.count.sum())})
    k.materialize()
    r = {'rateMilliHz': rates, 'spikesLast30ms': [sum(h[j] for h in hist[-3:]) for j in range(4)],
         'windowCounts': [int(s.count[ro[0]]) for ro in G.readouts] + [0] * (14 - len(G.readouts)),
         'totalSpikes': int(s.count.sum())}
    state_out = s.to_wire()
    spike_root = keccak(word(int.from_bytes(keccak(DOMAIN), 'big')) + keccak(frame) + word(stim['punishSteps']) + word(stim['rewardSteps'])
                        + b''.join(word(x) for x in rates0) + keccak(state_out) + encode_readout(r))
    return r, spike_root, state_out


# ----------------------------------------------------------------------------- CLI
def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest='cmd', required=True)
    w = sub.add_parser('warmup'); w.add_argument('artifacts'); w.add_argument('out'); w.add_argument('--steps', type=int, default=20000)
    w.add_argument('--backend', default='c')
    t = sub.add_parser('tables'); t.add_argument('--out')
    a = ap.parse_args()
    if a.cmd == 'warmup':
        import time
        G = Graph(a.artifacts); cfg = G.cfg()
        t0 = time.perf_counter(); out, commit = warmup(G, cfg, a.steps, a.backend); dt = time.perf_counter() - t0
        Path(a.out).write_bytes(out)
        s = State.from_wire(out, G.n, G.slots, G.rfc)
        print(json.dumps({'steps': a.steps, 'bytes': len(out), 'keccak': keccak(out).hex(), 'warmCommitment': commit.hex(),
                          'nActive': s.nActive, 'inflight': s.inflight, 'totalSpikes': int(s.count.sum()), 'wall_s': round(dt, 2)}))
    elif a.cmd == 'tables':
        print(json.dumps({'A1': A1, 'B1': B1, 'C1': C1, 'tA1024': TA[TBL], 'tB1024': TB[TBL], 'tC1024': TC[TBL]}))


if __name__ == '__main__':
    main()
