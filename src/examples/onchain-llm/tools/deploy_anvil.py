"""Install engine-v2 model artifacts on an anvil node via anvil_setCode.

Splits weights.bin + tokenizer.bin into 24,575-byte chunks, injects each as a
data contract (0x00 STOP prefix + payload) at deterministic addresses, builds
the two-level directory (pages + root), and prints the root address plus the
packed config for the consumer deployment.

anvil_setCode produces byte-identical chain state to real CREATE deployments,
minus the deployment transactions — ideal for local runs. Public-network
deployments use real transactions (~24.4k of them for Qwen3-0.6B; ~123B gas of
code deposits total).

Usage:
  python3 deploy_anvil.py --artifacts .context/qwen3/artifacts --rpc http://127.0.0.1:9557
"""
import argparse
import json
import urllib.request


def keccak256(data):
    from Crypto.Hash import keccak as _k
    h = _k.new(digest_bits=256)
    h.update(data)
    return h.digest()


OVERLAY_DOMAIN = b'gaskiller.llm.overlay.v1'


def overlay_chunk_addr(manifest, i):
    """Mirrors Qwen3Engine.overlayChunkAddress."""
    return '0x' + keccak256(OVERLAY_DOMAIN + manifest + i.to_bytes(8, 'big'))[12:].hex()

CHUNK = 24_575
PAGE_CAP = 1_228  # 20-byte addresses per 24,575-byte page


def rpc_batch(url, calls):
    payload = json.dumps(
        [{'jsonrpc': '2.0', 'id': i, 'method': m, 'params': p} for i, (m, p) in enumerate(calls)]
    ).encode()
    req = urllib.request.Request(url, payload, {'Content-Type': 'application/json'})
    with urllib.request.urlopen(req) as r:
        out = json.loads(r.read())
    if isinstance(out, dict):  # top-level error (e.g. request too large)
        raise RuntimeError(out.get('error', out))
    for item in out:
        if 'error' in item:
            raise RuntimeError(item['error'])
    return out


def chunk_addr(i):
    return '0x51' + format(i, '038x')


def page_addr(i):
    return '0x52' + format(i, '038x')


ROOT_ADDR = '0x53' + '0' * 37 + '1'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--artifacts', required=True)
    ap.add_argument('--rpc', default='http://127.0.0.1:9557')
    ap.add_argument('--batch', type=int, default=10)
    ap.add_argument('--overlay', action='store_true',
                    help='mount chunks at derived overlay addresses (no directory)')
    args = ap.parse_args()

    weights = open(f'{args.artifacts}/weights.bin', 'rb').read()
    tok = open(f'{args.artifacts}/tokenizer.bin', 'rb').read()
    vectors = json.load(open(f'{args.artifacts}/vectors.json'))

    chunks = []
    for blob in (weights, tok):
        for at in range(0, len(blob), CHUNK):
            chunks.append(blob[at:at + CHUNK])
    print(f'{len(chunks)} chunks ({len(weights):,} weight bytes + {len(tok):,} tokenizer bytes)')

    calls = []
    if args.overlay:
        manifest = keccak256(keccak256(weights) + keccak256(tok))
        for i, data in enumerate(chunks):
            calls.append(('anvil_setCode', [overlay_chunk_addr(manifest, i), '0x00' + data.hex()]))
        done = 0
        for at in range(0, len(calls), args.batch):
            rpc_batch(args.rpc, calls[at:at + args.batch])
            done += len(calls[at:at + args.batch])
            if done % 5000 < args.batch:
                print(f'  setCode {done}/{len(calls)}')
        sample = rpc_batch(args.rpc, [('eth_getCode', [overlay_chunk_addr(manifest, 0), 'latest'])])
        assert len(sample[0]['result']) == 2 * (1 + len(chunks[0])) + 2, 'chunk 0 code mismatch'
        print(f'overlay manifest: 0x{manifest.hex()}')
        print(f'packedConfig: {vectors["packedConfig"]}')
        print(f'promptIds:    {vectors["promptIds"]}')
        return

    for i, data in enumerate(chunks):
        calls.append(('anvil_setCode', [chunk_addr(i), '0x00' + data.hex()]))
    pages = []
    for p in range(0, len(chunks), PAGE_CAP):
        payload = b''.join(bytes.fromhex(chunk_addr(i)[2:]) for i in range(p, min(p + PAGE_CAP, len(chunks))))
        pages.append(page_addr(len(pages)))
        calls.append(('anvil_setCode', [pages[-1], '0x00' + payload.hex()]))
    root_payload = b''.join(bytes.fromhex(a[2:]) for a in pages)
    calls.append(('anvil_setCode', [ROOT_ADDR, '0x00' + root_payload.hex()]))

    done = 0
    for at in range(0, len(calls), args.batch):
        rpc_batch(args.rpc, calls[at:at + args.batch])
        done += len(calls[at:at + args.batch])
        if done % 5000 < args.batch:
            print(f'  setCode {done}/{len(calls)}')

    # verify a sample
    sample = rpc_batch(args.rpc, [('eth_getCode', [chunk_addr(0), 'latest']),
                                  ('eth_getCode', [ROOT_ADDR, 'latest'])])
    assert len(sample[0]['result']) == 2 * (1 + len(chunks[0])) + 2, 'chunk 0 code mismatch'
    assert len(sample[1]['result']) == 2 * (1 + len(root_payload)) + 2, 'root code mismatch'

    print(f'weights root: {ROOT_ADDR}')
    print(f'packedConfig: {vectors["packedConfig"]}')
    print(f'promptIds:    {vectors["promptIds"]}')


if __name__ == '__main__':
    main()
