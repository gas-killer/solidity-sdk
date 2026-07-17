#!/usr/bin/env bash
# Full Gas Killer lifecycle for the on-chain LLM against a LIVE node, in one command:
# anvil -> overlay-mount the synthetic model (anvil_setCode, zero deployment) ->
# deploy mock quorum + engine + overlay-mode consumer -> simulate the tracked ask()
# off-chain -> apply the single-STORE + LOG3 diff via verifyAndUpdate -> assert the
# chat root landed. This is the operator rehearsal (script/OperatorReplay.s.sol);
# the same steps run with the real Qwen3-0.6B artifacts by pointing ARTIFACTS at
# them (see TESTNET.md).
#
# Requirements: foundry (anvil/forge/cast), python3 with pycryptodome.
set -euo pipefail

RPC="${RPC:-http://127.0.0.1:8560}"
PORT="${RPC##*:}"
ARTIFACTS="${ARTIFACTS:-test/fixtures/onchain-llm-v2}"
PK="${PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d96d4956c1e}"
AVS="0x0000000000000000000000000000000000001234"

anvil --gas-limit 1099511627776 --port "$PORT" --silent &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
sleep 2

ADDR=$(cast wallet address --private-key "$PK")
cast rpc anvil_setBalance "$ADDR" 0x21e19e0c9bab2400000 --rpc-url "$RPC" > /dev/null

echo "== mounting model overlay (anvil_setCode; no deployment) =="
MANIFEST=$(python3 src/examples/onchain-llm/tools/deploy_anvil.py \
  --artifacts "$ARTIFACTS" --rpc "$RPC" --overlay | tee /dev/stderr \
  | grep "overlay manifest:" | awk '{print $3}')
CONFIG="[$(python3 -c "import json; print(','.join(json.load(open('$ARTIFACTS/vectors.json'))['packedConfig']))")]"
PROMPT_IDS=$(python3 -c "import json; print(','.join(str(i) for i in json.load(open('$ARTIFACTS/vectors.json'))['promptIds']))")

echo "== deploying mock quorum + engine + overlay-mode consumer =="
MOCK=$(forge create test/examples/OnchainLLM.t.sol:MockBLSSignatureChecker \
  --rpc-url "$RPC" --private-key "$PK" --broadcast | grep "Deployed to" | awk '{print $3}')
ENGINE=$(forge create src/examples/onchain-llm/Qwen3Engine.sol:Qwen3Engine \
  --rpc-url "$RPC" --private-key "$PK" --broadcast | grep "Deployed to" | awk '{print $3}')
CHAT=$(forge create src/examples/onchain-llm/GasKillerChat.sol:GasKillerChat \
  --rpc-url "$RPC" --private-key "$PK" --broadcast \
  --constructor-args "$AVS" "$MOCK" "$ENGINE" \
  0x0000000000000000000000000000000000000000 "$MANIFEST" "$CONFIG" \
  | grep "Deployed to" | awk '{print $3}')
echo "manifest=$MANIFEST chat=$CHAT"

echo "== operator validation: checkArtifacts in the mounted env =="
cast call "$ENGINE" "checkArtifacts(address,bytes32,bytes32[3])" \
  0x0000000000000000000000000000000000000000 "$MANIFEST" "$CONFIG" --rpc-url "$RPC"

echo "== operator replay: simulate ask(), apply diff via verifyAndUpdate =="
ROOT_BEFORE=$(cast call "$CHAT" "chatRoot()(bytes32)" --rpc-url "$RPC")
CHAT_ADDRESS="$CHAT" PROMPT_IDS="$PROMPT_IDS" MAX_NEW_TOKENS="${MAX_NEW_TOKENS:-6}" \
  forge script script/OperatorReplay.s.sol --rpc-url "$RPC" --private-key "$PK" --broadcast -vv
ROOT_AFTER=$(cast call "$CHAT" "chatRoot()(bytes32)" --rpc-url "$RPC")

if [ "$ROOT_BEFORE" = "$ROOT_AFTER" ]; then
  echo "FAIL: chat root unchanged"; exit 1
fi
TRANSITIONS=$(cast call "$CHAT" "stateTransitionCount()(uint256)" --rpc-url "$RPC")
echo "PASS: chat root $ROOT_BEFORE -> $ROOT_AFTER (transitions: $TRANSITIONS)"
