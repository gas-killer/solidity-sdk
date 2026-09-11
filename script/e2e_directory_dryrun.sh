#!/usr/bin/env bash
# Directory-mode operator rehearsal against the REAL on-chain Qwen3-0.6B directory.
#
#   anvil (no fork) -> mirror the live directory at its real addresses
#   (tools/mirror_directory_anvil.py: root+pages fetched from the network, chunks
#   from the codehash-verified local blobs, live spot-check of random chunks)
#   -> deploy mock quorum + Qwen3Engine + GasKillerChatUnchecked(root)
#   -> operator shape check (checkArtifacts, ~104.3M gas)
#   -> DRY RUN: eth_call dryRun(promptIds, N)  (what an operator simulates)
#   -> REAL RUN: script/OperatorReplay.s.sol re-simulates ask(), builds the
#      single-STORE + LOG3 payload + sha256 msgHash, settles via verifyAndUpdate.
#
# Then settle the SAME answer on the public network with script/OperatorSettle.s.sol
# (no inference over a public RPC — operators only ship the diff).
#
# Requirements: foundry, python3 venv with eth_utils (the deploy_sepolia.py venv).
set -euo pipefail

PORT="${PORT:-8630}"
RPC="http://127.0.0.1:$PORT"
LIVE_RPC="${LIVE_RPC:-https://ethereum-sepolia-rpc.publicnode.com}"
ARTIFACTS="${ARTIFACTS:-.context/qwen3/artifacts}"
LEDGER="${LEDGER:-.context/qwen3/deploy-ledger}"
PY="${PY:-.context/qwen3/deploy-venv/bin/python}"
PK="${PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"   # anvil account 0
AVS="${AVS:-0x0000000000000000000000000000000000001234}"
ROOT="${ROOT:-0x9d1ddc25c098da26417d0a061b647f3a3511d7b0}"
CFG='[0x04000c001c100800800002518004000101000000000000000000000000000000,0x0000000010c6f7a10000000016a09e6600000000239791f10000000000000000,0x00182bc20002505d0002505b0000000000000000000000000000000000000000]'
PROMPT_IDS="${PROMPT_IDS:-151644,872,198,3838,374,33946,30,151645,198,151644,77091,198,151667,271,151668,271}"  # "What is Ethereum?"
MAX_NEW="${MAX_NEW_TOKENS:-8}"

anvil --port "$PORT" --gas-limit 1099511627776 --silent &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
sleep 2

echo "== mirroring the live directory onto anvil at its real addresses =="
"$PY" src/examples/onchain-llm/tools/mirror_directory_anvil.py \
  --artifacts "$ARTIFACTS" --ledger "$LEDGER" --rpc "$LIVE_RPC" --anvil "$RPC" --sample 48

dep() { forge create "$1" --rpc-url "$RPC" --private-key "$PK" --broadcast --json "${@:2}" 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['deployedTo'])"; }
echo "== deploying mock quorum + engine + directory-mode consumer =="
MOCK=$(dep test/examples/OnchainLLM.t.sol:MockBLSSignatureChecker)
ENGINE=$(dep src/examples/onchain-llm/Qwen3Engine.sol:Qwen3Engine)
CHAT=$(dep src/examples/onchain-llm/GasKillerChatUnchecked.sol:GasKillerChatUnchecked \
        --constructor-args "$AVS" "$MOCK" "$ENGINE" "$ROOT" \
        0x0000000000000000000000000000000000000000000000000000000000000000 "$CFG")
echo "mock=$MOCK engine=$ENGINE chat=$CHAT"

echo "== operator shape check: checkArtifacts over the mirrored directory =="
cast call "$ENGINE" "checkArtifacts(address,bytes32,bytes32[3])" "$ROOT" \
  0x0000000000000000000000000000000000000000000000000000000000000000 "$CFG" \
  --rpc-url "$RPC" --gas-limit 1000000000

echo "== DRY RUN: eth_call dryRun (expect ~25 min on anvil for 16 prompt + $MAX_NEW new tokens) =="
SECONDS=0
cast call "$CHAT" "dryRun(uint32[],uint256)(string,uint32[])" "[$PROMPT_IDS]" "$MAX_NEW" \
  --rpc-url "$RPC" --gas-limit 1000000000000 --rpc-timeout 7200
echo "dryRun wall clock: ${SECONDS}s"

echo "== REAL RUN: operator replay -> verifyAndUpdate =="
ROOT_BEFORE=$(cast call "$CHAT" "chatRoot()(bytes32)" --rpc-url "$RPC")
CHAT_ADDRESS="$CHAT" PROMPT_IDS="$PROMPT_IDS" MAX_NEW_TOKENS="$MAX_NEW" \
  forge script script/OperatorReplay.s.sol --rpc-url "$RPC" --private-key "$PK" --broadcast -vv
ROOT_AFTER=$(cast call "$CHAT" "chatRoot()(bytes32)" --rpc-url "$RPC")
[ "$ROOT_BEFORE" != "$ROOT_AFTER" ] || { echo "FAIL: chat root unchanged"; exit 1; }
echo "PASS: chat root $ROOT_BEFORE -> $ROOT_AFTER"
