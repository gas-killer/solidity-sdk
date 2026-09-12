#!/usr/bin/env python3
"""Keeper for FlyPolicy rounds (HANDOFF §4.6, §5): builds the `decide(FlyState)` calldata from the last
`FlyDecided` log (or the genesis state), submits it to the Gas Killer router, and replays the word chain.

  fly_keeper.py state    --rpc URL --policy A                 → the FlyState the next round must extend (JSON)
  fly_keeper.py calldata --rpc URL --policy A                 → 0x… calldata for decide(prev)
  fly_keeper.py submit   --rpc URL --policy A --router URL --api-key K [--from A] [--block N]
                                                              → POST /tasks {body:{target_address, from_address, call_data, transition_index, value, block_height}}
  fly_keeper.py verify   --rpc URL --policy A                 → replays every FlyDecided log: pack(next) == flyWord topic, prevWord chain, slot == last word
  fly_keeper.py should-run --rpc URL --policy A --pool A      → exit 0 iff the pool's last closed window is newer than the last decision

Only the standard library + eth_abi/eth_hash are used, so this runs in the deploy tools' environment.
"""
import argparse, json, sys, urllib.request
from eth_abi import encode, decode
from eth_hash.auto import keccak

FLY_STATE = '(bytes32,uint32,uint32,uint16,int16,uint8,uint32[4],bytes32)'
READOUT = '(uint32[4],uint32[4],uint32[14],uint64)'
EVENT_SIG = 'FlyDecided(uint256,bytes32,bytes32,' + FLY_STATE + ',bytes,' + READOUT + ')'
MEMORY_ROOT_ZERO = bytes.fromhex('c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470')
FLY_SLOT = '0xcbecd64d5226c3b53f872ce956484768a63c3b8a34d2c1088c069f9663d00d00'


def rpc(url, method, params):
    req = urllib.request.Request(url, json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode(),
                                 {'Content-Type': 'application/json', 'User-Agent': 'curl/8.4.0'})
    with urllib.request.urlopen(req, timeout=120) as r:
        out = json.loads(r.read())
    if 'error' in out:
        raise RuntimeError(out['error'])
    return out['result']


def genesis():
    return (b'\0' * 32, 0, 0, 0, 0, 0, (0, 0, 0, 0), MEMORY_ROOT_ZERO)


def pack(s):
    """FlyPolicy.pack: fee[255:240] | skew[239:224] | flags[223:216] | windowId[215:184] | epoch[183:160] | keccak(abi.encode(s))[159:0]"""
    prev_word, epoch, wid, fee, skew, flags, rates, mem = s
    w = int.from_bytes(keccak(encode([FLY_STATE], [s])), 'big') & ((1 << 160) - 1)
    w |= (epoch & 0xffffff) << 160
    w |= wid << 184
    w |= flags << 216
    w |= (skew & 0xffff) << 224
    w |= fee << 240
    return w.to_bytes(32, 'big')


def state_json(s):
    prev_word, epoch, wid, fee, skew, flags, rates, mem = s
    return {'prevWord': '0x' + prev_word.hex(), 'epoch': epoch, 'windowId': wid, 'feeBps': fee, 'skewBps': skew, 'flags': flags,
            'rateMilliHz': list(rates), 'memoryRoot': '0x' + mem.hex()}


LOG_LOOKBACK = 90_000   # blocks; pruned nodes refuse fromBlock 0 (reth: "pruned history unavailable")


def logs(url, policy, from_block=None):
    topic = '0x' + keccak(EVENT_SIG.encode()).hex()
    if from_block is None:
        head = int(rpc(url, 'eth_blockNumber', []), 16)
        from_block = hex(max(0, head - LOG_LOOKBACK))
    raw = rpc(url, 'eth_getLogs', [{'address': policy, 'topics': [topic], 'fromBlock': from_block, 'toBlock': 'latest'}])
    out = []
    for lg in raw:
        nxt, frame, r = decode([FLY_STATE, 'bytes', READOUT], bytes.fromhex(lg['data'][2:]))
        out.append({'transitionIndex': int(lg['topics'][1], 16), 'flyWord': bytes.fromhex(lg['topics'][2][2:]),
                    'spikeRoot': bytes.fromhex(lg['topics'][3][2:]), 'next': nxt, 'frame': frame, 'readout': r,
                    'blockNumber': int(lg['blockNumber'], 16), 'tx': lg['transactionHash']})
    return sorted(out, key=lambda x: (x['blockNumber'], x['transitionIndex']))


def last_state(url, policy):
    ls = logs(url, policy)
    return (ls[-1]['next'], ls[-1]['flyWord']) if ls else (genesis(), b'\0' * 32)


def slot_word(url, policy):
    return bytes.fromhex(rpc(url, 'eth_getStorageAt', [policy, FLY_SLOT, 'latest'])[2:].rjust(64, '0'))


def calldata(prev):
    return keccak(b'decide(' + FLY_STATE.encode() + b')')[:4] + encode([FLY_STATE], [prev])


def cmd_state(a):
    prev, word = last_state(a.rpc, a.policy)
    print(json.dumps({'prev': state_json(prev), 'word': '0x' + word.hex(), 'slot': '0x' + slot_word(a.rpc, a.policy).hex()}, indent=1))


def cmd_calldata(a):
    prev, _ = last_state(a.rpc, a.policy)
    print('0x' + calldata(prev).hex())


def cmd_submit(a):
    prev, word = last_state(a.rpc, a.policy)
    if slot_word(a.rpc, a.policy) != word:
        sys.exit('FLY_SLOT does not match the last FlyDecided word: a round is in flight or the chain was replaced')
    sel = keccak(b'stateTransitionCount()')[:4]
    ti = int(rpc(a.rpc, 'eth_call', [{'to': a.policy, 'data': '0x' + sel.hex()}, 'latest']), 16)
    block = a.block or int(rpc(a.rpc, 'eth_blockNumber', []), 16)
    body = {'body': {'target_address': a.policy, 'from_address': a.sender, 'call_data': list(calldata(prev)),
                     'transition_index': ti, 'value': '0x0', 'block_height': block}}
    if a.dry_run:
        print(json.dumps(body)); return
    req = urllib.request.Request(a.router.rstrip('/') + '/tasks', json.dumps(body).encode(),
                                 {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + a.api_key, 'User-Agent': 'curl/8.4.0'})
    with urllib.request.urlopen(req, timeout=60) as r:
        print(r.status, r.read().decode())


def cmd_verify(a):
    ls = logs(a.rpc, a.policy)
    prev_word = b'\0' * 32
    for k, lg in enumerate(ls):
        nxt = lg['next']
        assert nxt[0] == prev_word, f'log {k}: prevWord chain broken'
        assert pack(nxt) == lg['flyWord'], f'log {k}: pack(next) != flyWord topic'
        assert nxt[1] == k + 1, f'log {k}: epoch'
        prev_word = lg['flyWord']
        print(f'#{k + 1} tx {lg["tx"]} window {nxt[2]} fee {nxt[3]} skew {nxt[4]} flags {nxt[5]} word 0x{lg["flyWord"].hex()[:16]}… spikeRoot 0x{lg["spikeRoot"].hex()[:16]}…')
    slot = slot_word(a.rpc, a.policy)
    assert slot == prev_word, f'FLY_SLOT 0x{slot.hex()} != last word 0x{prev_word.hex()}'
    print(f'OK: {len(ls)} decisions replay; FLY_SLOT == last word')


def cmd_should_run(a):
    prev, _ = last_state(a.rpc, a.policy)
    sel = keccak(b'closed()')[:4]
    raw = rpc(a.rpc, 'eth_call', [{'to': a.pool, 'data': '0x' + sel.hex()}, 'latest'])
    closed_wid = decode(['uint32', 'uint64', 'uint128', 'uint128', 'uint64', 'uint64'], bytes.fromhex(raw[2:]))[0]
    print(json.dumps({'lastDecidedWindow': prev[2], 'lastClosedWindow': closed_wid, 'shouldRun': closed_wid > prev[2]}))
    sys.exit(0 if closed_wid > prev[2] else 1)


def main():
    ap = argparse.ArgumentParser(description=__doc__); sub = ap.add_subparsers(dest='cmd', required=True)
    def common(s):
        s.add_argument('--rpc', required=True); s.add_argument('--policy', required=True)
    for name in ('state', 'calldata', 'verify'):
        common(sub.add_parser(name))
    s = sub.add_parser('submit'); common(s); s.add_argument('--router', required=True); s.add_argument('--api-key', default='')
    s.add_argument('--from', dest='sender', default='0x0000000000000000000000000000000000000001'); s.add_argument('--block', type=int)
    s.add_argument('--dry-run', action='store_true')
    r = sub.add_parser('should-run'); common(r); r.add_argument('--pool', required=True)
    a = ap.parse_args()
    {'state': cmd_state, 'calldata': cmd_calldata, 'submit': cmd_submit, 'verify': cmd_verify, 'should-run': cmd_should_run}[a.cmd](a)


if __name__ == '__main__':
    main()
