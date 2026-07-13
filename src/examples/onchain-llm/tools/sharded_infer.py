"""Sharded-inference driver: one LLM inference distributed across parallel anvil workers.

Proves the sharded-inference-v0 design end to end against LIVE nodes:

  * N anvil worker processes (ports 9601..960N, lifted gas caps), each with the
    model installed via anvil_setCode (same machinery as deploy_anvil.py) and the
    Qwen3Engine / Qwen3SegEngine facades mounted.
  * --mode mono: one worker runs Qwen3Engine.chat end to end (the baseline).
  * --mode sharded: a DAG scheduler splits the layer range [0, L) into S contiguous
    stages, pins stage i to committee workers (i*k .. i*k+k-1 mod N), pipelines the
    PREFILL across stages as a wavefront (stage i works position p while stage i+1
    works p-1; calls in one wave are dispatched concurrently), runs DECODE
    sequentially per token through the S stages, and fans the final-stage output
    into M PARALLEL argmaxRange vocab shards merged by (score desc, id asc).
  * committee k >= 2: every call goes to ALL k members concurrently and their
    returned (xOut, kvAppend, chk) MUST be identical — committee redundancy is a
    hash check, not a re-orchestration.
  * checkpoints: keccak(xOut) of stage i is fed as stage i+1's expectXIn witness
    (the facade reverts on mismatch); the full chk chain is kept and its root
    printed.
  * asserts sharded token ids == monolithic token ids (bit-exactness).

Synthetic fixture (CI-speed, default):
  python3 src/examples/onchain-llm/tools/sharded_infer.py --mode sharded \
      --stages 2 --committee 2 --argmax-shards 2

Real Qwen3-0.6B artifacts (~600 MB installed on EVERY worker — expect a few
minutes of setCode per worker plus multi-minute inference; keep the prompt and
--max-new small):
  python3 src/examples/onchain-llm/tools/sharded_infer.py --mode sharded --real \
      --stages 4 --committee 1 --argmax-shards 4 --max-new 2

Requires: foundry (anvil/forge), python3 + pycryptodome (same as deploy_anvil.py).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_anvil as da  # noqa: E402  (rpc_batch, chunk/page/root addresses, keccak256)

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', '..'))

# stateless facades are mounted via anvil_setCode at fixed addresses (no storage,
# no immutables, so runtime code == a real CREATE deployment)
ENGINE_ADDR = '0xe1' + '0' * 37 + '1'
SEG_ADDR = '0xe2' + '0' * 37 + '1'

SEL_CHAT = '09a41261'          # chat(address,bytes32,bytes32[3],uint32[],uint256)
SEL_FORWARD_RANGE = '568f9e26' # forwardRange(address,bytes32,bytes32[3],((uint256,...),uint32[],bytes,bytes,bytes32,bytes32))
SEL_ARGMAX_RANGE = 'cfa1c545'  # argmaxRange(address,bytes32,bytes32[3],bytes,uint256,uint256)

CALL_GAS = hex(1 << 40)
KECCAK_EMPTY = da.keccak256(b'')


# ---------------------------------------------------------------- rpc plumbing


def rpc(url, method, params):
    return da.rpc_batch(url, [(method, params)])[0]['result']


class Worker:
    """One anvil process + its RPC endpoint."""

    def __init__(self, index, port):
        self.index = index
        self.port = port
        self.url = f'http://127.0.0.1:{port}'
        self.proc = None
        self.trace_gas = True  # flips off if debug_traceCall is unsupported

    def start(self):
        self.proc = subprocess.Popen(
            ['anvil', '--port', str(self.port), '--gas-limit', str(1 << 40), '--silent'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                rpc(self.url, 'eth_blockNumber', [])
                return
            except Exception:
                time.sleep(0.1)
        raise RuntimeError(f'anvil worker {self.index} (port {self.port}) did not come up')

    def stop(self):
        if self.proc:
            self.proc.terminate()

    def call(self, to, data):
        """eth_call via debug_traceCall(callTracer) so one execution yields both the
        return data and the gas used; falls back to plain eth_call (gas=None)."""
        tx = {'to': to, 'data': '0x' + data.hex(), 'gas': CALL_GAS}
        if self.trace_gas:
            try:
                res = rpc(self.url, 'debug_traceCall', [tx, 'latest', {'tracer': 'callTracer'}])
                if res.get('error') or res.get('revertReason'):
                    raise RuntimeError(f"reverted: {res.get('revertReason') or res.get('error')} "
                                       f"(output {res.get('output', '0x')[:74]})")
                return bytes.fromhex(res.get('output', '0x')[2:]), int(res['gasUsed'], 16)
            except RuntimeError as e:
                if 'reverted' in str(e):
                    raise
                self.trace_gas = False  # method not supported; degrade gracefully
        out = rpc(self.url, 'eth_call', [tx, 'latest'])
        return bytes.fromhex(out[2:]), None


# ------------------------------------------------------------- abiic encoding


def _w(v):
    return int(v).to_bytes(32, 'big')


def _pad(b):
    return b + b'\x00' * (-len(b) % 32)


def _dyn_bytes(b):
    return _w(len(b)) + _pad(b)


def _dyn_u32s(ids):
    return _w(len(ids)) + b''.join(_w(i) for i in ids)


def enc_chat(root, manifest, cfg, prompt_ids, max_new):
    head = bytes.fromhex(root[2:]).rjust(32, b'\x00') + manifest + b''.join(cfg)
    head += _w(7 * 32) + _w(max_new)
    return bytes.fromhex(SEL_CHAT) + head + _dyn_u32s(prompt_ids)


def enc_forward_range(root, manifest, cfg, span, token_ids, x_in, kv_in, expect_x, expect_kv):
    # tuple: (Span span, uint32[] tokenIds, bytes xIn, bytes kvIn, bytes32 x2, bytes32 k2)
    toks = _dyn_u32s(token_ids)
    xb = _dyn_bytes(x_in)
    base = 10 * 32
    tup = b''.join(_w(v) for v in span)  # maxPos, posLo, posHi, layerLo, layerHi
    tup += _w(base) + _w(base + len(toks)) + _w(base + len(toks) + len(xb))
    tup += expect_x + expect_kv
    tup += toks + xb + _dyn_bytes(kv_in)
    head = bytes.fromhex(root[2:]).rjust(32, b'\x00') + manifest + b''.join(cfg) + _w(6 * 32)
    return bytes.fromhex(SEL_FORWARD_RANGE) + head + tup


def enc_argmax_range(root, manifest, cfg, xb_final, lo, hi):
    head = bytes.fromhex(root[2:]).rjust(32, b'\x00') + manifest + b''.join(cfg)
    head += _w(8 * 32) + _w(lo) + _w(hi)
    return bytes.fromhex(SEL_ARGMAX_RANGE) + head + _dyn_bytes(xb_final)


def dec_word(buf, i):
    return int.from_bytes(buf[i * 32:(i + 1) * 32], 'big')


def dec_bytes_at(buf, off):
    n = int.from_bytes(buf[off:off + 32], 'big')
    return buf[off + 32:off + 32 + n]


def dec_chat(buf):
    ids_off = dec_word(buf, 1)
    n = int.from_bytes(buf[ids_off:ids_off + 32], 'big')
    ids = [dec_word(buf[ids_off + 32:], i) for i in range(n)]
    return dec_bytes_at(buf, dec_word(buf, 0)), ids


def dec_forward_range(buf):
    return dec_bytes_at(buf, dec_word(buf, 0)), dec_bytes_at(buf, dec_word(buf, 1)), buf[64:96]


def dec_argmax_range(buf):
    score = dec_word(buf, 0)
    if score >= 1 << 255:
        score -= 1 << 256
    return score, dec_word(buf, 1)


# ------------------------------------------------------------ model / engines


def unpack_config(cfg_words):
    """Mirrors Qwen3.unpack (packed bytes32[3])."""
    w0 = int.from_bytes(cfg_words[0], 'big')
    w2 = int.from_bytes(cfg_words[2], 'big')
    c = {
        'dim': w0 >> 240,
        'nLayers': (w0 >> 216) & 0xff,
        'nKv': (w0 >> 200) & 0xff,
        'headDim': (w0 >> 184) & 0xffff,
        'vocab': (w0 >> 152) & 0xffffffff,
        'seqCap': (w0 >> 136) & 0xffff,
        'stop0': (w2 >> 192) & 0xffffffff,
        'stop1': (w2 >> 160) & 0xffffffff,
    }
    c['kvd'] = c['nKv'] * c['headDim']
    return c


def load_artifacts(art_dir):
    weights = open(os.path.join(art_dir, 'weights.bin'), 'rb').read()
    tok = open(os.path.join(art_dir, 'tokenizer.bin'), 'rb').read()
    vectors = json.load(open(os.path.join(art_dir, 'vectors.json')))
    cfg = [bytes.fromhex(w[2:]) for w in vectors['packedConfig']]
    return weights, tok, vectors, cfg


def engine_runtime(contract_file, name):
    out = subprocess.run(
        ['forge', 'inspect', f'src/examples/onchain-llm/{contract_file}:{name}', 'deployedBytecode'],
        cwd=REPO_ROOT, capture_output=True, text=True, check=True).stdout.strip()
    assert out.startswith('0x') and len(out) > 2, f'no runtime bytecode for {name}'
    return out


def install_worker(w, weights, tok, engine_code, seg_code, batch=10):
    """Directory-mode model install (mirrors deploy_anvil.py main) + engine mounts."""
    chunks = []
    for blob in (weights, tok):
        for at in range(0, len(blob), da.CHUNK):
            chunks.append(blob[at:at + da.CHUNK])
    calls = [('anvil_setCode', [da.chunk_addr(i), '0x00' + c.hex()]) for i, c in enumerate(chunks)]
    pages = []
    for p in range(0, len(chunks), da.PAGE_CAP):
        payload = b''.join(bytes.fromhex(da.chunk_addr(i)[2:])
                           for i in range(p, min(p + da.PAGE_CAP, len(chunks))))
        pages.append(da.page_addr(len(pages)))
        calls.append(('anvil_setCode', [pages[-1], '0x00' + payload.hex()]))
    root_payload = b''.join(bytes.fromhex(a[2:]) for a in pages)
    calls.append(('anvil_setCode', [da.ROOT_ADDR, '0x00' + root_payload.hex()]))
    calls.append(('anvil_setCode', [ENGINE_ADDR, engine_code]))
    calls.append(('anvil_setCode', [SEG_ADDR, seg_code]))
    for at in range(0, len(calls), batch):
        da.rpc_batch(w.url, calls[at:at + batch])
    got = rpc(w.url, 'eth_getCode', [da.chunk_addr(0), 'latest'])
    assert len(got) == 2 * (1 + len(chunks[0])) + 2, f'worker {w.index}: chunk 0 mismatch'
    return len(chunks)


# ------------------------------------------------------------------ scheduler


class Tally:
    def __init__(self):
        self.gas = {'prefill': 0, 'decode': 0, 'argmax': 0, 'mono': 0}
        self.wall = {'prefill': 0.0, 'decode': 0.0, 'argmax': 0.0, 'mono': 0.0}
        self.calls = {'prefill': 0, 'decode': 0, 'argmax': 0, 'mono': 0}
        self.act_bytes = 0   # inter-stage activation bytes (xOut shipped stage i -> i+1, once)
        self.argmax_in_bytes = 0
        self.kv_bytes = 0    # KV wire bytes round-tripped through this driver
        self.gas_ok = True

    def add_gas(self, phase, gas):
        if gas is None:
            self.gas_ok = False
        else:
            self.gas[phase] += gas


class ShardedRunner:
    """The DAG scheduler: S layer stages x committee k x M argmax shards."""

    def __init__(self, workers, cfg, c, stages, committee, argmax_shards, max_pos):
        self.workers = workers
        self.cfg = cfg
        self.c = c
        self.k = committee
        self.m = argmax_shards
        self.max_pos = max_pos
        n_layers = c['nLayers']
        self.s = min(stages, n_layers)
        if self.s != stages:
            print(f'  note: requested S={stages} clamped to {self.s} (model has {n_layers} layers)')
        self.bounds = [(i * n_layers // self.s, (i + 1) * n_layers // self.s) for i in range(self.s)]
        n = len(workers)
        self.stage_committee = [[workers[(i * committee + j) % n] for j in range(committee)]
                                for i in range(self.s)]
        self.k_acc = [b''] * n_layers  # accumulated wire-format K per absolute layer
        self.v_acc = [b''] * n_layers
        self.chk_chain = []
        self.tally = Tally()
        self.pool = ThreadPoolExecutor(max_workers=max(8, n * committee))

    def _kv_in(self, stage):
        lo, hi = self.bounds[stage]
        return b''.join(self.k_acc[l] + self.v_acc[l] for l in range(lo, hi))

    def _fold_kv(self, stage, pos_n, kv_append):
        lo, hi = self.bounds[stage]
        blk = pos_n * self.c['kvd'] * 4
        assert len(kv_append) == (hi - lo) * 2 * blk, 'kvAppend length'
        for j, l in enumerate(range(lo, hi)):
            at = j * 2 * blk
            self.k_acc[l] += kv_append[at:at + blk]
            self.v_acc[l] += kv_append[at + blk:at + 2 * blk]

    def _segment(self, phase, stage, pos_lo, pos_hi, token_ids, x_in, expect_x):
        """One segment on stage `stage`'s FULL committee; members must agree."""
        kv_in = self._kv_in(stage)
        lo, hi = self.bounds[stage]
        span = (self.max_pos, pos_lo, pos_hi, lo, hi)
        data = enc_forward_range(da.ROOT_ADDR, b'\x00' * 32, self.cfg, span, token_ids,
                                 x_in, kv_in, expect_x, da.keccak256(kv_in))
        futs = [self.pool.submit(w.call, SEG_ADDR, data) for w in self.stage_committee[stage]]
        results = [f.result() for f in futs]
        decoded = [dec_forward_range(out) for out, _ in results]
        for out, gas in results:
            self.tally.add_gas(phase, gas)
            self.tally.calls[phase] += 1
        first = decoded[0]
        for other in decoded[1:]:
            assert other[2] == first[2] and other[0] == first[0] and other[1] == first[1], (
                f'COMMITTEE DIVERGENCE stage {stage} pos [{pos_lo},{pos_hi}): chk mismatch')
        x_out, kv_append, chk = first
        self.chk_chain.append(chk)
        if stage > 0:
            self.tally.act_bytes += len(x_in)
        self.tally.kv_bytes += len(kv_in) + len(kv_append)
        self._fold_kv(stage, pos_hi - pos_lo, kv_append)
        return x_out

    def prefill(self, prompt_ids):
        """Wavefront pipeline: cell (stage s, position p); wave t = s + p runs
        concurrently (stage s works position p while stage s+1 works p-1)."""
        t0 = time.monotonic()
        p_len = len(prompt_ids)
        x = {}  # (stage, pos) -> xOut
        for t in range(self.s + p_len - 1):
            cells = [(s, t - s) for s in range(self.s) if 0 <= t - s < p_len]
            futs = {}
            for s, p in cells:
                if s == 0:
                    x_in, toks, exp = b'', [prompt_ids[p]], KECCAK_EMPTY
                else:
                    x_in, toks = x[(s - 1, p)], []
                    exp = da.keccak256(x_in)  # checkpoint chain: stage s-1's xOut hash
                futs[(s, p)] = self.pool.submit(self._segment, 'prefill', s, p, p + 1, toks, x_in, exp)
            for (s, p), f in sorted(futs.items()):
                x[(s, p)] = f.result()
        self.tally.wall['prefill'] += time.monotonic() - t0
        return x[(self.s - 1, p_len - 1)]  # final-stage vector of the last prompt position

    def decode_step(self, pos, token):
        """One decode position sequentially through the S stages."""
        t0 = time.monotonic()
        x, exp, toks = b'', KECCAK_EMPTY, [token]
        for s in range(self.s):
            x = self._segment('decode', s, pos, pos + 1, toks, x if s else b'', exp)
            exp, toks = da.keccak256(x), []
        self.tally.wall['decode'] += time.monotonic() - t0
        return x

    def argmax(self, xb_final):
        """M parallel vocab shards (each on a k-committee), merged (score desc, id asc)."""
        t0 = time.monotonic()
        vocab, n = self.c['vocab'], len(self.workers)
        step = vocab // self.m
        shards = [(j * step, vocab if j + 1 == self.m else (j + 1) * step) for j in range(self.m)]
        data = [enc_argmax_range(da.ROOT_ADDR, b'\x00' * 32, self.cfg, xb_final, lo, hi)
                for lo, hi in shards]
        futs = []
        for j in range(self.m):
            members = [self.workers[(j * self.k + i) % n] for i in range(self.k)]
            futs.append([self.pool.submit(w.call, SEG_ADDR, data[j]) for w in members])
        best = None
        for j, group in enumerate(futs):
            results = [f.result() for f in group]
            vals = [dec_argmax_range(out) for out, _ in results]
            for out, gas in results:
                self.tally.add_gas('argmax', gas)
                self.tally.calls['argmax'] += 1
            assert all(v == vals[0] for v in vals), f'COMMITTEE DIVERGENCE argmax shard {j}'
            score, tid = vals[0]
            if best is None or score > best[0] or (score == best[0] and tid < best[1]):
                best = (score, tid)
            self.tally.argmax_in_bytes += len(xb_final)
        self.tally.wall['argmax'] += time.monotonic() - t0
        return best[1]

    def generate(self, prompt_ids, max_new):
        """Replays Qwen3.generate's exact loop/stop semantics over segments."""
        p_len = len(prompt_ids)
        last_x = self.prefill(prompt_ids)
        gen = [self.argmax(last_x[-self.c['dim'] * 32:])]
        pos = p_len
        while pos + 1 < self.max_pos and gen[-1] not in (self.c['stop0'], self.c['stop1']):
            gen.append(self.argmax(self.decode_step(pos, gen[-1])))
            pos += 1
        return gen

    def chain_root(self):
        return da.keccak256(b''.join(self.chk_chain))


# ------------------------------------------------------------------- reporting


def fmt(n):
    return f'{n:,}' if n is not None else 'n/a'


def print_table(args, mono, sharded, runner):
    line = '-' * 78
    print(f'\n{line}\n RESULTS  (model: {"real Qwen3-0.6B" if args.real else "synthetic fixture"}, '
          f'prompt {len(mono["prompt"])} ids, maxNew {args.max_new})\n{line}')
    print(f'  {"":24}  {"wall-clock":>12}  {"gas":>18}  {"eth_calls":>9}')
    print(f'  {"mono (Qwen3Engine.chat)":24}  {mono["wall"]:>11.3f}s  {fmt(mono["gas"]):>18}  {1:>9}')
    if sharded:
        t = runner.tally
        for ph in ('prefill', 'decode', 'argmax'):
            print(f'  {"sharded " + ph:24}  {t.wall[ph]:>11.3f}s  {fmt(t.gas[ph] if t.gas_ok else None):>18}'
                  f'  {t.calls[ph]:>9}')
        tot_gas = sum(t.gas[p] for p in ('prefill', 'decode', 'argmax')) if t.gas_ok else None
        tot_wall = sharded['wall']
        tot_calls = sum(t.calls[p] for p in ('prefill', 'decode', 'argmax'))
        print(f'  {"sharded TOTAL":24}  {tot_wall:>11.3f}s  {fmt(tot_gas):>18}  {tot_calls:>9}')
        print(f'\n  network bytes shipped between stages:')
        print(f'    inter-stage activations (xOut -> next stage xIn): {fmt(t.act_bytes)} B'
              f'{" x" + str(runner.k) + " committee copies" if runner.k > 1 else ""}')
        print(f'    final vector -> argmax shards:                    {fmt(t.argmax_in_bytes)} B')
        print(f'    KV wire round-trip via driver (stage-local state): {fmt(t.kv_bytes)} B')
        print(f'\n  checkpoint chain: {len(runner.chk_chain)} segment commitments')
        print(f'    chk chain root: 0x{runner.chain_root().hex()}')
        if tot_gas is not None and mono['gas']:
            print(f'\n  work-factor comparison (execution gas as work proxy):')
            print(f'    production replication (~8 executions: router 2 tracers + 3 ops x 2):'
                  f' {fmt(8 * mono["gas"])}')
            print(f'    sharded committee k={runner.k} ({runner.k} executions/segment + hash checks): '
                  f'{fmt(tot_gas)}   ({tot_gas / mono["gas"]:.2f}x mono, vs 8.00x today)')
        print(f'\n  token ids  mono:    {mono["ids"]}')
        print(f'  token ids  sharded: {sharded["ids"]}')
        ok = sharded['ids'] == mono['ids']
        print(f'\n  BIT-EXACT: {"PASS" if ok else "FAIL"}')
        print(line)
        if not ok:
            raise SystemExit('FAIL: sharded token ids diverge from monolithic run')
    else:
        print(line)


# ------------------------------------------------------------------------ main


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--mode', choices=['mono', 'sharded'], default='sharded')
    ap.add_argument('--stages', '-S', type=int, default=2, help='layer-range stages (clamped to nLayers)')
    ap.add_argument('--committee', '-k', type=int, default=1, help='workers per stage; all must agree')
    ap.add_argument('--argmax-shards', '-M', type=int, default=2, help='parallel vocab shards for argmax')
    ap.add_argument('--workers', '-N', type=int, default=0, help='worker count (default stages*committee)')
    ap.add_argument('--artifacts', default=os.path.join(REPO_ROOT, 'test/fixtures/onchain-llm-v2'))
    ap.add_argument('--real', action='store_true',
                    help='use the real Qwen3-0.6B artifacts (.context/qwen3/artifacts; ~minutes)')
    ap.add_argument('--prompt-ids', default='', help='comma-separated token ids (default: vectors.json)')
    ap.add_argument('--max-new', type=int, default=3)
    ap.add_argument('--base-port', type=int, default=9600, help='workers use base-port+1..+N')
    args = ap.parse_args()

    if args.real:
        args.artifacts = os.path.join(REPO_ROOT, '.context/qwen3/artifacts')
    if shutil.which('anvil') is None or shutil.which('forge') is None:
        raise SystemExit('foundry (anvil/forge) is required on PATH')

    weights, tok, vectors, cfg = load_artifacts(args.artifacts)
    c = unpack_config(cfg)
    prompt_ids = ([int(x) for x in args.prompt_ids.split(',') if x.strip()]
                  if args.prompt_ids else [int(i) for i in vectors['promptIds']])
    max_pos = min(len(prompt_ids) + args.max_new, c['seqCap'])
    stages_eff = min(args.stages, c['nLayers'])
    n_workers = 1 if args.mode == 'mono' else (args.workers or stages_eff * args.committee)

    print(f'model: {args.artifacts} ({len(weights):,} weight B, dim {c["dim"]}, '
          f'{c["nLayers"]} layers, vocab {c["vocab"]})')
    print(f'compiling engine facades (forge inspect)...')
    engine_code = engine_runtime('Qwen3Engine.sol', 'Qwen3Engine')
    seg_code = engine_runtime('Qwen3SegEngine.sol', 'Qwen3SegEngine')

    workers = [Worker(i, args.base_port + 1 + i) for i in range(n_workers)]
    try:
        print(f'starting {n_workers} anvil worker(s) on ports '
              f'{args.base_port + 1}..{args.base_port + n_workers} ...')
        for w in workers:
            w.start()
        t0 = time.monotonic()
        with ThreadPoolExecutor(max_workers=n_workers) as pool:
            n_chunks = list(pool.map(
                lambda w: install_worker(w, weights, tok, engine_code, seg_code), workers))[0]
        print(f'installed model ({n_chunks} chunks) + engines on every worker '
              f'in {time.monotonic() - t0:.1f}s')

        # ---- mono baseline (always: sharded mode asserts bit-exactness against it)
        print(f'\n== mono baseline: Qwen3Engine.chat on worker 0 ==')
        t0 = time.monotonic()
        out, gas = workers[0].call(
            ENGINE_ADDR, enc_chat(da.ROOT_ADDR, b'\x00' * 32, cfg, prompt_ids, args.max_new))
        mono_wall = time.monotonic() - t0
        answer, mono_ids = dec_chat(out)
        mono = {'wall': mono_wall, 'gas': gas, 'ids': mono_ids, 'prompt': prompt_ids}
        print(f'   {len(mono_ids)} tokens in {mono_wall:.3f}s, gas {fmt(gas)}: {mono_ids}')

        sharded = None
        runner = None
        if args.mode == 'sharded':
            print(f'\n== sharded: S={args.stages} stages, committee k={args.committee}, '
                  f'M={args.argmax_shards} argmax shards, {n_workers} workers ==')
            runner = ShardedRunner(workers, cfg, c, args.stages, args.committee,
                                   args.argmax_shards, max_pos)
            for i, com in enumerate(runner.stage_committee):
                lo, hi = runner.bounds[i]
                print(f'   stage {i}: layers [{lo},{hi}) -> worker(s) '
                      f'{[w.index for w in com]} (ports {[w.port for w in com]})')
            t0 = time.monotonic()
            ids = runner.generate(prompt_ids, args.max_new)
            sharded = {'wall': time.monotonic() - t0, 'ids': ids}
            runner.pool.shutdown()

        print_table(args, mono, sharded, runner)
    finally:
        for w in workers:
            w.stop()


if __name__ == '__main__':
    main()
