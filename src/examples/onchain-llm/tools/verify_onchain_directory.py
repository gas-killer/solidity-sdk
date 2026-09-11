#!/usr/bin/env python3
"""Post-deployment verification for an on-chain Qwen3 artifact set.

Two independent checks against a live network:

  1. BYTE INTEGRITY (no contract needed) — streams every chunk's deployed code
     via eth_getProof codeHash and compares to keccak(0x00 || payload) computed
     from the local blobs, then re-derives the page/root payloads from the
     ledger and checks those too. This is the check that proves the on-chain
     bytes ARE the model.

  2. SEMANTIC (engine) — calls Qwen3Engine.checkArtifacts(root, 0, packedConfig)
     via eth_call, which validates directory shape, summed chunk sizes against
     the config-derived layout, and the tokenizer table header.

     NOTE: for Qwen3-0.6B this call costs ~104.3M gas (measured). Public RPCs
     cap eth_call at rpc.gascap (geth default 50M), so this check needs a node
     started with a raised --rpc.gascap. It is skipped unless --engine is given.

Usage:
  verify_onchain_directory.py --artifacts <dir> --ledger <dir> --rpc <url> \
      [--engine 0x... --config-from <vectors.json>]
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from deploy_sepolia import Rpc, Plan, Ledger, expected_codehash, CHUNK  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifacts", required=True)
    ap.add_argument("--ledger", required=True)
    ap.add_argument("--rpc", default="https://ethereum-sepolia-rpc.publicnode.com")
    ap.add_argument("--page-cap", type=int, default=1228)
    ap.add_argument("--engine", help="Qwen3Engine address; enables the checkArtifacts call")
    ap.add_argument("--config-from", help="vectors.json holding packedConfig")
    ap.add_argument("--batch", type=int, default=10)
    args = ap.parse_args()

    rpc = Rpc([u.strip() for u in args.rpc.split(",") if u.strip()])
    plan = Plan(os.path.join(args.artifacts, "weights.bin"),
                os.path.join(args.artifacts, "tokenizer.bin"))
    ledger = Ledger(os.path.join(args.ledger, "ledger.jsonl"))

    n_pages = (plan.n_chunks + args.page_cap - 1) // args.page_cap
    keys = ([f"c{i}" for i in range(plan.n_chunks)]
            + [f"p{p}" for p in range(n_pages)] + ["root"])

    missing = [k for k in keys
               if not ledger.get(k) or ledger.get(k).get("st") != "conf"]
    if missing:
        sys.exit(f"FAIL: {len(missing)} items not confirmed in ledger "
                 f"(first: {missing[:5]})")

    addrs = {k: ledger.get(k)["addr"] for k in keys}

    def payload_for(key):
        if key[0] == "c":
            return plan.payload(int(key[1:]))
        if key[0] == "p":
            p = int(key[1:])
            lo, hi = p * args.page_cap, min((p + 1) * args.page_cap, plan.n_chunks)
            return b"".join(bytes.fromhex(addrs[f"c{i}"][2:]) for i in range(lo, hi))
        return b"".join(bytes.fromhex(addrs[f"p{p}"][2:]) for p in range(n_pages))

    print(f"verifying {len(keys)} contracts "
          f"({plan.n_chunks} chunks + {n_pages} pages + root)", flush=True)
    bad = 0
    for lo in range(0, len(keys), args.batch):
        group = keys[lo:lo + args.batch]
        results = rpc.batch([("eth_getProof", [addrs[k], [], "latest"]) for k in group])
        for k, res in zip(group, results):
            want = expected_codehash(payload_for(k))
            got = res["codeHash"] if res else None
            if got != want:
                bad += 1
                print(f"  MISMATCH {k} at {addrs[k]}: want {want} got {got}", flush=True)
        if lo and lo % 2000 < args.batch:
            print(f"  {lo}/{len(keys)}", flush=True)
    if bad:
        sys.exit(f"FAIL: {bad} codehash mismatches")
    print(f"OK: all {len(keys)} contracts match keccak(0x00 || payload)", flush=True)
    print(f"    directory root = {addrs['root']}", flush=True)

    if not args.engine:
        print("skipping checkArtifacts (pass --engine and a gas-cap-lifted RPC)")
        return
    from eth_utils import keccak as _kec
    cfg = json.load(open(args.config_from))["packedConfig"]
    # calldata: selector || root || manifest(0) || cfg[0..2]
    selector = "0x" + _kec(b"checkArtifacts(address,bytes32,bytes32[3])")[:4].hex()
    data = (selector
            + addrs["root"][2:].rjust(64, "0")
            + "00" * 32
            + "".join(c[2:] for c in cfg))
    try:
        rpc.call("eth_call", [{"to": args.engine, "data": data,
                               "gas": hex(200_000_000)}, "latest"])
        print("OK: engine.checkArtifacts passed on-chain", flush=True)
    except Exception as e:
        sys.exit(f"FAIL: checkArtifacts reverted or RPC refused: {e}")


if __name__ == "__main__":
    main()
