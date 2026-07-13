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
import weight_shard as ws  # noqa: E402  (layout mirror + per-worker chunk sets + self-check)

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


def install_worker(w, weights, tok, engine_code, seg_code, batch=10, keep=None):
    """Directory-mode model install (mirrors deploy_anvil.py main) + engine mounts.

    keep=None installs the WHOLE model (every chunk) — unchanged behavior. When
    `keep` is a set of global chunk indices (weight-sharding), only those CHUNK
    contracts are set; the two-level page directory + root are ALWAYS installed
    in full (pages are tiny) so Qwen3SegEngine._resolveWeights still resolves the
    complete nWeightChunks+nTokChunks address list. Address resolution reads the
    directory; only unheld CHUNK payloads are omitted, and the self-check proves
    a worker never reads a chunk it doesn't hold.

    Returns (n_all_chunks, installed_bytes, n_installed_chunks)."""
    chunks = []
    for blob in (weights, tok):
        for at in range(0, len(blob), da.CHUNK):
            chunks.append(blob[at:at + da.CHUNK])
    n_all = len(chunks)
    keep_idx = set(range(n_all)) if keep is None else {i for i in keep if 0 <= i < n_all}
    calls = [('anvil_setCode', [da.chunk_addr(i), '0x00' + chunks[i].hex()])
             for i in sorted(keep_idx)]
    pages = []
    for p in range(0, n_all, da.PAGE_CAP):
        payload = b''.join(bytes.fromhex(da.chunk_addr(i)[2:])
                           for i in range(p, min(p + da.PAGE_CAP, n_all)))
        pages.append(da.page_addr(len(pages)))
        calls.append(('anvil_setCode', [pages[-1], '0x00' + payload.hex()]))
    root_payload = b''.join(bytes.fromhex(a[2:]) for a in pages)
    calls.append(('anvil_setCode', [da.ROOT_ADDR, '0x00' + root_payload.hex()]))
    calls.append(('anvil_setCode', [ENGINE_ADDR, engine_code]))
    calls.append(('anvil_setCode', [SEG_ADDR, seg_code]))
    for at in range(0, len(calls), batch):
        da.rpc_batch(w.url, calls[at:at + batch])
    probe = min(keep_idx)
    got = rpc(w.url, 'eth_getCode', [da.chunk_addr(probe), 'latest'])
    assert len(got) == 2 * (1 + len(chunks[probe])) + 2, f'worker {w.index}: chunk {probe} mismatch'
    installed_bytes = sum(len(chunks[i]) for i in keep_idx)
    return n_all, installed_bytes, len(keep_idx)


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
        # single source of truth for the DAG assignment — shared verbatim with
        # weight_shard.plan_worker_chunks so installed chunk sets can never drift
        # from the calls actually dispatched (see weight_shard.dag_plan).
        self.plan = ws.dag_plan(n_layers, c['vocab'], stages, committee, argmax_shards, len(workers))
        self.s = self.plan.stages
        if self.s != stages:
            print(f'  note: requested S={stages} clamped to {self.s} (model has {n_layers} layers)')
        self.bounds = self.plan.bounds
        self.stage_committee = [[workers[idx] for idx in stage] for stage in self.plan.stage_workers]
        self.k_acc = [b''] * n_layers  # accumulated wire-format K per absolute layer
        self.v_acc = [b''] * n_layers
        self.chk_chain = []
        self.tally = Tally()
        self.pool = ThreadPoolExecutor(max_workers=max(8, len(workers) * committee))

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
        data = [enc_argmax_range(da.ROOT_ADDR, b'\x00' * 32, self.cfg, xb_final, lo, hi)
                for _, lo, hi in self.plan.argmax]
        futs = []
        for j, (members_idx, _lo, _hi) in enumerate(self.plan.argmax):
            members = [self.workers[i] for i in members_idx]
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


def print_footprint(lay, plan, keep_sets, stats, weights, tok):
    """Per-worker installed footprint — the headline: each worker holds only the
    chunks its assigned layers/roles read, not the whole model."""
    full = len(weights) + len(tok)
    roles = {w: {'layers': [], 'emb': False, 'cls': []} for w in range(plan.n_workers)}
    for i, wids in enumerate(plan.stage_workers):
        lo, hi = plan.bounds[i]
        for w in wids:
            roles[w]['layers'].append((lo, hi))
            if lo == 0:
                roles[w]['emb'] = True
    for members, v_lo, v_hi in plan.argmax:
        for w in members:
            roles[w]['cls'].append((v_lo, v_hi))
    line = '-' * 92
    print(f'\n{line}\n WEIGHT-SHARD FOOTPRINT  (full model {full:,} B = {full / 1e6:.1f}MB '
          f'weights+tok; {lay.nWeightChunks:,} weight + {lay.nTokChunks} tok chunks)\n{line}')
    print(f'  {"worker":>6}  {"layers held":>12}  {"emb":>3}  {"argmax vocab rows":>19}  '
          f'{"chunks":>6}  {"installed":>11}  {"%full":>6}')
    tot = 0
    for w in range(plan.n_workers):
        _, ib, n_inst = stats[w]
        tot += ib
        lr = roles[w]['layers']
        layer_str = ','.join(f'[{lo},{hi})' for lo, hi in lr) if lr else '-'
        cls = roles[w]['cls']
        cls_str = ','.join(f'[{a},{b})' for a, b in cls) if cls else '-'
        print(f'  {w:>6}  {layer_str:>12}  {"Y" if roles[w]["emb"] else "-":>3}  '
              f'{cls_str:>19}  {n_inst:>6}  {ib / 1e6:>8.1f}MB  {100 * ib / full:>5.1f}%')
    print(f'{line}')
    print(f'  monolithic install = {full / 1e6:.1f}MB on EVERY worker '
          f'({plan.n_workers} workers x full = {plan.n_workers * full / 1e6:,.1f}MB); '
          f'weight-sharded total = {tot / 1e6:,.1f}MB '
          f'({100 * tot / (plan.n_workers * full):.1f}% of the replicated footprint)')
    print(line)


def print_weight_shard_result(args, ids, expect_ids):
    line = '-' * 92
    print(f'\n  token ids  weight-shard: {ids}')
    print(f'  token ids  full-model:  {expect_ids}   (--expect-ids)')
    ok = ids == expect_ids
    print(f'\n  BIT-EXACT (weight-shard == full model): {"PASS" if ok else "FAIL"}')
    print(line)
    if not ok:
        raise SystemExit('FAIL: weight-shard token ids diverge from the full-model ids')


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
    ap.add_argument('--weight-shard', action='store_true',
                    help='partial per-worker install: each worker holds ONLY the chunks '
                         'its assigned layers/roles read (union over its DAG segments). '
                         'Prints the per-worker footprint. Implies --mode sharded; the '
                         'partial workers cannot run the monolithic chat baseline, so pass '
                         '--expect-ids for the bit-exactness gate.')
    ap.add_argument('--expect-ids', default='',
                    help='comma-separated token ids the run must reproduce exactly '
                         '(bit-exactness gate; required by --weight-shard).')
    args = ap.parse_args()

    if args.real:
        args.artifacts = os.path.join(REPO_ROOT, '.context/qwen3/artifacts')
    if shutil.which('anvil') is None or shutil.which('forge') is None:
        raise SystemExit('foundry (anvil/forge) is required on PATH')
    if args.weight_shard:
        args.mode = 'sharded'  # partial installs only make sense for the sharded DAG
    expect_ids = [int(x) for x in args.expect_ids.split(',') if x.strip()] if args.expect_ids else None
    if args.weight_shard and expect_ids is None:
        raise SystemExit('--weight-shard needs --expect-ids (partial workers cannot run '
                         'the monolithic baseline; supply the ids a full run produces)')

    weights, tok, vectors, cfg = load_artifacts(args.artifacts)
    c = unpack_config(cfg)
    prompt_ids = ([int(x) for x in args.prompt_ids.split(',') if x.strip()]
                  if args.prompt_ids else [int(i) for i in vectors['promptIds']])
    max_pos = min(len(prompt_ids) + args.max_new, c['seqCap'])
    stages_eff = min(args.stages, c['nLayers'])
    n_workers = 1 if args.mode == 'mono' else (args.workers or stages_eff * args.committee)

    # ---- weight-sharding plan: per-worker chunk sets + no-gap/no-leak self-check
    keep_sets = None
    if args.weight_shard:
        lay = ws.Layout(ws.parse_config(cfg))
        assert len(weights) == lay.weightLen, (len(weights), lay.weightLen)
        plan = ws.dag_plan(c['nLayers'], c['vocab'], args.stages, args.committee,
                           args.argmax_shards, n_workers)
        keep_sets = ws.plan_worker_chunks(lay, plan, max_pos)
        union, ref = ws.selfcheck(lay, keep_sets, max_pos)  # raises on gap/leak
        print(f'weight-shard self-check: union of {n_workers} worker chunk sets == '
              f'{len(ref)} chunks the monolithic run reads (no gap, no leak) OK')

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
            stats = list(pool.map(
                lambda w: install_worker(w, weights, tok, engine_code, seg_code,
                                         keep=(keep_sets[w.index] if keep_sets else None)),
                workers))
        n_chunks = stats[0][0]
        if args.weight_shard:
            print(f'weight-shard install ({n_chunks} chunks total) + engines in '
                  f'{time.monotonic() - t0:.1f}s (per-worker footprint below)')
        else:
            print(f'installed model ({n_chunks} chunks) + engines on every worker '
                  f'in {time.monotonic() - t0:.1f}s')

        # ---- mono baseline: full-model chat; skipped when workers are partial
        mono = None
        if not args.weight_shard:
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
            tag = 'weight-shard' if args.weight_shard else 'full-shard'
            print(f'\n== {tag} sharded: S={args.stages} stages, committee k={args.committee}, '
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

        final_ids = sharded['ids'] if sharded else (mono['ids'] if mono else [])
        if args.weight_shard:
            print_footprint(lay, plan, keep_sets, stats, weights, tok)
            print_weight_shard_result(args, sharded['ids'], expect_ids)
        else:
            print_table(args, mono, sharded, runner)
            if expect_ids is not None and final_ids != expect_ids:
                raise SystemExit(f'FAIL: ids {final_ids} != --expect-ids {expect_ids}')
        print(f'\nRESULT_IDS={",".join(str(i) for i in final_ids)}')
    finally:
        for w in workers:
            w.stop()


if __name__ == '__main__':
    main()
