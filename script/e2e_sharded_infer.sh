#!/usr/bin/env bash
# Sharded-inference e2e against LIVE nodes, in one command: N anvil workers ->
# overlay the synthetic model on each (anvil_setCode, zero deployment) -> mount
# Qwen3Engine + Qwen3SegEngine -> run the monolithic baseline on one worker ->
# run the same generation as hash-committed segments distributed across the
# workers (S layer stages x committee k, M parallel argmax shards, wavefront-
# pipelined prefill) -> assert the sharded token ids equal the monolithic ones
# bit-exactly. The same driver runs the real Qwen3-0.6B artifacts with --real
# (expect minutes; see the driver docstring).
#
# Requirements: foundry (anvil/forge), python3 with pycryptodome.
set -euo pipefail

cd "$(dirname "$0")/.."
DRIVER=src/examples/onchain-llm/tools/sharded_infer.py

echo "== sharded inference e2e: S=2 stages, committee k=2, M=2 argmax shards =="
python3 "$DRIVER" --mode sharded --stages 2 --committee 2 --argmax-shards 2 \
  --max-new "${MAX_NEW_TOKENS:-3}" --base-port "${BASE_PORT:-9600}"

echo
echo "== sharded inference e2e: S=4 stages, committee k=1, M=4 argmax shards =="
python3 "$DRIVER" --mode sharded --stages 4 --committee 1 --argmax-shards 4 \
  --max-new "${MAX_NEW_TOKENS:-3}" --base-port "${BASE_PORT:-9600}"

echo
echo "PASS: sharded == monolithic (bit-exact) in both topologies"
