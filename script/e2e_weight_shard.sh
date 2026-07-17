#!/usr/bin/env bash
# Weight-sharding e2e against LIVE nodes, in one command (CI-speed synthetic
# fixture). For each topology this:
#   1. runs the driver WITHOUT --weight-shard: full model on every worker; asserts
#      the sharded token ids equal the MONOLITHIC Qwen3Engine.chat baseline
#      bit-exactly (mono == full-shard), and captures the ids;
#   2. runs the same topology WITH --weight-shard: each worker gets ONLY the chunks
#      its assigned layers/roles read (union over its DAG segments; the driver runs
#      weight_shard's no-gap/no-leak self-check first), and asserts the ids equal
#      the captured full-model ids (weight-shard == full model).
# Together: monolithic == full-shard == weight-shard, bit-exactly.
#
# The pure chunk-set arithmetic is additionally self-checked (no anvil) by
# weight_shard.py's standalone entrypoint, run first below.
#
# The same driver proves the real Qwen3-0.6B with --real (expect minutes).
# Requirements: foundry (anvil/forge), python3 with pycryptodome.
set -euo pipefail

cd "$(dirname "$0")/.."
DRIVER=src/examples/onchain-llm/tools/sharded_infer.py
BASE_PORT="${BASE_PORT:-9600}"
MAX_NEW="${MAX_NEW_TOKENS:-3}"

echo "== weight_shard.py standalone self-check (union == monolithic reads; no anvil) =="
python3 src/examples/onchain-llm/tools/weight_shard.py

run_topology() {
  local S="$1" K="$2" M="$3" port="$4"
  echo
  echo "== topology S=$S k=$K M=$M: full-shard baseline (asserts mono == full-shard) =="
  local full_out ids
  full_out="$(python3 "$DRIVER" --mode sharded --stages "$S" --committee "$K" \
    --argmax-shards "$M" --max-new "$MAX_NEW" --base-port "$port")"
  echo "$full_out" | grep -E "BIT-EXACT|RESULT_IDS"
  ids="$(echo "$full_out" | sed -n 's/^RESULT_IDS=//p')"
  if [ -z "$ids" ]; then echo "FAIL: no RESULT_IDS from full-shard run"; exit 1; fi

  echo "== topology S=$S k=$K M=$M: weight-shard (asserts weight-shard == full model, ids=$ids) =="
  python3 "$DRIVER" --mode sharded --stages "$S" --committee "$K" --argmax-shards "$M" \
    --max-new "$MAX_NEW" --weight-shard --expect-ids "$ids" --base-port "$((port + 10))" \
    | grep -E "self-check|installed|%full|BIT-EXACT|RESULT_IDS|monolithic install"
}

# task-spec synthetic topology (both workers cover every chunk here — proves the
# flag path is correct), plus an argmax-shards=1 topology that makes a non-embedding
# worker genuinely OMIT the embedding chunk yet still match bit-exactly.
run_topology 2 1 2 "$BASE_PORT"
run_topology 2 1 1 "$((BASE_PORT + 20))"

echo
echo "PASS: monolithic == full-shard == weight-shard (bit-exact) on the synthetic fixture"
