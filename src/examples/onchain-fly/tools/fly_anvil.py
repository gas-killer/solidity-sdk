#!/usr/bin/env python3
"""Full-graph anvil rehearsal of FlyEngine against the fly_int.py reference (HANDOFF §7.4, §8 Phase 8).

Prerequisites: anvil started with `--disable-block-gas-limit --code-size-limit 30000 --memory-limit 1073741824`,
the graph directory (ptr/edges/meta) and warm directory mounted by tools/llm/deploy_anvil.py (families 5 and 6),
and `forge build` artifacts under --out (FlyEngine.json).

  fly_anvil.py deploy   --rpc URL --out <forge out dir>                       → prints the engine address
  fly_anvil.py check    --rpc URL --engine A --graph A --warm A --artifacts D
  fly_anvil.py warmup   ...  [--steps 20000]   compares keccak/warmCommitment with artifacts/warm.bin
  fly_anvil.py decide   ...  [--obs busy|empty] [--punish N --reward N]        compares readout + spikeRoot with fly_int
  fly_anvil.py all      ...

Gas is measured with debug_traceCall (callTracer); wall time is the eth_call round trip.
"""
import argparse, json, struct, sys, time, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fly_int as F
import fly_validate as V
from eth_abi import encode, decode
from eth_hash.auto import keccak

GAS = 1 << 40
ANVIL_KEY0 = '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266'   # anvil default account 0


def rpc(url, method, params, timeout=3600):
    req = urllib.request.Request(url, json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode(),
                                 {'Content-Type': 'application/json', 'User-Agent': 'curl/8.4.0'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        out = json.loads(r.read())
    if 'error' in out:
        raise RuntimeError(out['error'])
    return out['result']


def selector(sig): return keccak(sig.encode())[:4]


TRACER = 'callTracer'          # or 'prestateTracer' (diffMode, what the Gas Killer analyzer runs)
BLOCK = 'latest'


def call(url, to, sig, types, args, out_types, measure=True):
    data = '0x' + (selector(sig) + encode(types, args)).hex()
    tx = {'from': ANVIL_KEY0, 'to': to, 'data': data, 'gas': hex(GAS)}
    t0 = time.perf_counter()
    res = rpc(url, 'eth_call', [tx, BLOCK])
    wall = time.perf_counter() - t0
    gas = None
    if measure:
        t1 = time.perf_counter()
        if TRACER == 'prestateTracer':
            tr = rpc(url, 'debug_traceCall', [tx, BLOCK, {'tracer': 'prestateTracer', 'tracerConfig': {'diffMode': True, 'disableCode': True}}])
            gas = -len(json.dumps(tr))   # no gasUsed in the prestate result; report the diff size (negative) instead
        else:
            tr = rpc(url, 'debug_traceCall', [tx, BLOCK, {'tracer': 'callTracer'}])
            gas = int(tr['gasUsed'], 16)
        wall_trace = time.perf_counter() - t1
    else:
        wall_trace = None
    return decode(out_types, bytes.fromhex(res[2:])), wall, gas, wall_trace


def cfg_words(artifacts):
    c = json.load(open(Path(artifacts) / 'fly_config.json'))['packedConfig']
    return [int(x, 16).to_bytes(32, 'big') for x in c]


def cmd_deploy(a):
    art = json.load(open(Path(a.out) / 'FlyEngine.sol' / 'FlyEngine.json'))
    code = art['bytecode']['object']
    txh = rpc(a.rpc, 'eth_sendTransaction', [{'from': ANVIL_KEY0, 'data': code, 'gas': hex(30_000_000)}])
    for _ in range(600):
        rcpt = rpc(a.rpc, 'eth_getTransactionReceipt', [txh])
        if rcpt: break
        time.sleep(0.1)
    assert rcpt and rcpt['status'] == '0x1', rcpt
    print(json.dumps({'engine': rcpt['contractAddress'], 'gasUsed': int(rcpt['gasUsed'], 16)}))


def cmd_check(a):
    cfg = cfg_words(a.artifacts)
    _, wall, gas, _ = call(a.rpc, a.engine, 'checkArtifacts(address,address,bytes32[3])', ['address', 'address', 'bytes32[3]'],
                           [a.graph, a.warm, cfg], [])
    print(json.dumps({'checkArtifacts': 'ok', 'gas': gas, 'wall_s': round(wall, 2)}))


def cmd_warmup(a):
    cfg = cfg_words(a.artifacts)
    (out, commit), wall, gas, wt = call(a.rpc, a.engine, 'warmup(address,bytes32[3],uint256)', ['address', 'bytes32[3]', 'uint256'],
                                        [a.graph, cfg, a.steps], ['bytes', 'bytes32'], measure=not a.no_trace)
    ref = (Path(a.artifacts) / 'warm.bin').read_bytes() if a.steps == 20000 else None
    rep = {'steps': a.steps, 'bytes': len(out), 'keccak': keccak(out).hex(), 'warmCommitment': commit.hex(), 'wall_s': round(wall, 1),
           'gas': gas, 'trace_wall_s': None if wt is None else round(wt, 1)}
    if ref is not None:
        rep['matches_reference_warm_bin'] = (out == ref)
    if gas:
        rep['Ggas_per_sim_second'] = round(gas / 1e9 / (a.steps / 10000), 2)
    if a.save:
        Path(a.save).write_bytes(out)
    print(json.dumps(rep))


def cmd_decide(a):
    G = F.Graph(a.artifacts); cfg = cfg_words(a.artifacts)
    if a.episode_steps:   # override cfg1's episodeSteps (bits 255..240)
        c1 = int.from_bytes(cfg[1], 'big'); c1 = (c1 & ((1 << 240) - 1)) | (a.episode_steps << 240); cfg[1] = c1.to_bytes(32, 'big')
    cfg_ints = [int.from_bytes(c, 'big') for c in cfg]
    o = V.observation(a.obs); frame = F.rasterize(G, cfg_ints, o); stim = dict(punishSteps=a.punish, rewardSteps=a.reward)
    rates0 = [0, 0, 0, 0]
    warm = (Path(a.artifacts) / 'warm.bin').read_bytes()
    t0 = time.perf_counter(); r_ref, root_ref, _ = F.decide(G, cfg_ints, warm, frame, stim, rates0, 'c'); ref_wall = time.perf_counter() - t0
    # rasterize on-chain
    obs_types = '(uint32,uint64[16],uint64[16],uint64,uint128,uint128,uint64,uint64)'
    obs_val = (o['windowId'], o['buyQuote'], o['sellQuote'], o['volRef'], o['spotQ64'], o['twapQ64'], o['feeIncomeQuote'], o['lpLossQuote'])
    (frame_chain,), wall_r, gas_r, _ = call(a.rpc, a.engine, 'rasterize(address,bytes32[3],' + obs_types + ')', ['address', 'bytes32[3]', obs_types],
                                            [a.graph, cfg, obs_val], ['bytes'])
    ro_types = '(uint32[4],uint32[4],uint32[14],uint64)'
    (r, root), wall, gas, wt = call(a.rpc, a.engine, 'decide(address,address,bytes32[3],bytes,(uint16,uint16),uint32[4])',
                                    ['address', 'address', 'bytes32[3]', 'bytes', '(uint16,uint16)', 'uint32[4]'],
                                    [a.graph, a.warm, cfg, frame, (stim['punishSteps'], stim['rewardSteps']), rates0], [ro_types, 'bytes32'],
                                    measure=not a.no_trace)
    got = {'rateMilliHz': list(r[0]), 'spikesLast30ms': list(r[1]), 'windowCounts': list(r[2]), 'totalSpikes': r[3]}
    p = F.unpack_cfg(cfg_ints)
    rep = {'observation': a.obs, 'stimulus': stim, 'frame_matches': frame_chain == frame, 'rasterize_gas': gas_r,
           'readout_chain': got, 'readout_ref': r_ref, 'readout_matches': got == r_ref,
           'spikeRoot_chain': root.hex(), 'spikeRoot_ref': root_ref.hex(), 'spikeRoot_matches': root == root_ref,
           'episode_steps': p['episodeSteps'], 'wall_s': round(wall, 1), 'trace_wall_s': None if wt is None else round(wt, 1), 'gas': gas,
           'reference_wall_s': round(ref_wall, 2)}
    if gas:
        rep['Ggas_per_sim_second'] = round(gas / 1e9 / (p['episodeSteps'] / 10000), 2)
        rep['Ggas_per_episode'] = round(gas / 1e9, 2)
    print(json.dumps(rep))


def main():
    ap = argparse.ArgumentParser(description=__doc__); sub = ap.add_subparsers(dest='cmd', required=True)
    def common(s):
        s.add_argument('--rpc', default='http://127.0.0.1:9558'); s.add_argument('--engine'); s.add_argument('--graph', default='0x5300000000000000000000000000000000000001')
        s.add_argument('--warm', default='0x6300000000000000000000000000000000000001'); s.add_argument('--artifacts', default='artifacts')
        s.add_argument('--no-trace', action='store_true', help='skip the debug_traceCall gas measurement')
        s.add_argument('--tracer', choices=['call', 'prestate'], default='call', help='prestate = diffMode/disableCode, what the analyzer runs')
        s.add_argument('--block', default='latest', help='block tag/number for eth_call and the trace (the fleet fork pins a block)')
        s.add_argument('--from-addr', default=None, help='override the from address')
    d = sub.add_parser('deploy'); d.add_argument('--rpc', default='http://127.0.0.1:9558'); d.add_argument('--out', required=True)
    c = sub.add_parser('check'); common(c)
    w = sub.add_parser('warmup'); common(w); w.add_argument('--steps', type=int, default=20000); w.add_argument('--save')
    e = sub.add_parser('decide'); common(e); e.add_argument('--obs', default='busy'); e.add_argument('--punish', type=int, default=0); e.add_argument('--reward', type=int, default=0)
    e.add_argument('--episode-steps', type=int, default=0, help='override episodeSteps (e.g. 1000 = 100 ms) for timing probes')
    a = ap.parse_args()
    global TRACER, BLOCK, ANVIL_KEY0
    if getattr(a, 'tracer', 'call') == 'prestate': TRACER = 'prestateTracer'
    if getattr(a, 'block', None): BLOCK = a.block if a.block in ('latest', 'pending') else hex(int(a.block))
    if getattr(a, 'from_addr', None): ANVIL_KEY0 = a.from_addr
    {'deploy': cmd_deploy, 'check': cmd_check, 'warmup': cmd_warmup, 'decide': cmd_decide}[a.cmd](a)


if __name__ == '__main__':
    main()
