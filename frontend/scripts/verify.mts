// Engine ↔ contract conformance check. Drives every transition through both the TS engine and the
// live contract on anvil, asserting computeStateHash(witness) == on-chain stateHash() after each.
//
//   (from repo root) anvil is running + DeployVertex has been run
//   cd frontend && npx tsx scripts/verify.mts
import {
  createPublicClient,
  createWalletClient,
  http,
  defineChain,
  type Address,
  type Hash,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import deployments from "../src/deployments.json" with { type: "json" };
import { vertexAbi } from "../src/abi/vertex";
import { erc20Abi } from "../src/abi/erc20";
import * as E from "../src/engine/engine";

const chain = defineChain({
  id: deployments.chainId,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [deployments.rpcUrl] } },
});
const VERTEX = deployments.vertex as Address;
const USDC = deployments.usdc as Address;
const pub = createPublicClient({ chain, transport: http(deployments.rpcUrl) });

const ACCTS: Record<string, `0x${string}`> = {
  deployer: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  alice: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  bob: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  carol: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
  liq: "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
};
const wallet = (pk: `0x${string}`) => createWalletClient({ account: privateKeyToAccount(pk), chain, transport: http(deployments.rpcUrl) });
const addr = (pk: `0x${string}`) => privateKeyToAccount(pk).address.toLowerCase() as Address;

const WAD = 10n ** 18n;
const MAX = (1n << 256n) - 1n;
let state = E.emptyState();
let step = 0;

async function send(pk: `0x${string}`, fn: string, args: unknown[]): Promise<Hash> {
  const hash = await wallet(pk).writeContract({ address: VERTEX, abi: vertexAbi, functionName: fn as never, args: args as never });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${fn} reverted`);
  return hash;
}

async function blockTimeOf(hash: Hash): Promise<bigint> {
  const receipt = await pub.waitForTransactionReceipt({ hash });
  const block = await pub.getBlock({ blockNumber: receipt.blockNumber });
  return block.timestamp;
}

async function approve(pk: `0x${string}`) {
  const hash = await wallet(pk).writeContract({ address: USDC, abi: erc20Abi, functionName: "approve", args: [VERTEX, MAX] });
  await pub.waitForTransactionReceipt({ hash });
}

async function assertSync(label: string, newState: E.ExchangeState) {
  const onchain = (await pub.readContract({ address: VERTEX, abi: vertexAbi, functionName: "stateHash" })) as bigint;
  const computed = (await pub.readContract({ address: VERTEX, abi: vertexAbi, functionName: "computeStateHash", args: [E.toWitness(newState)] })) as bigint;
  const ok = onchain === computed;
  step++;
  console.log(`${ok ? "✓" : "✗"} [${step}] ${label}   onchain=${onchain.toString(16).slice(0, 12)} computed=${computed.toString(16).slice(0, 12)}`);
  if (!ok) {
    console.error("   DIVERGED. local state:", JSON.stringify(E.toWitness(newState), (_k, v) => (typeof v === "bigint" ? v.toString() : v)));
    process.exit(1);
  }
  state = newState;
}

async function main() {
  const A = addr(ACCTS.alice), B = addr(ACCTS.bob), C = addr(ACCTS.carol), L = addr(ACCTS.liq);

  // 0. sanity: fresh deploy is empty
  await assertSync("initial empty state", state);

  // 1. list ETH market
  await send(ACCTS.deployer, "listMarket", [E.toWitness(state), 1, 5n * 10n ** 16n, 3n * 10n ** 16n, 3000n * WAD]);
  await assertSync("listMarket(ETH, imf=5%, mmf=3%, oracle=3000)", E.applyListMarket(state, 1, 5n * 10n ** 16n, 3n * 10n ** 16n, 3000n * WAD));

  // 2. deposits
  await approve(ACCTS.alice);
  await send(ACCTS.alice, "deposit", [E.toWitness(state), 1600n * WAD]);
  await assertSync("Alice deposit 1600", E.applyDeposit(state, A, 1600n * WAD));

  await approve(ACCTS.bob);
  await send(ACCTS.bob, "deposit", [E.toWitness(state), 100000n * WAD]);
  await assertSync("Bob deposit 100000", E.applyDeposit(state, B, 100000n * WAD));

  // 3. crossing orders → open positions
  let h = await send(ACCTS.alice, "placeOrder", [E.toWitness(state), 1, true, 3000n * WAD, 10n * WAD]);
  let t = await blockTimeOf(h);
  await assertSync("Alice bid 10 ETH @3000", E.applyPlaceOrder(state, A, 1, true, 3000n * WAD, 10n * WAD, t));

  h = await send(ACCTS.bob, "placeOrder", [E.toWitness(state), 1, false, 3000n * WAD, 10n * WAD]);
  t = await blockTimeOf(h);
  await assertSync("Bob ask 10 ETH @3000", E.applyPlaceOrder(state, B, 1, false, 3000n * WAD, 10n * WAD, t));

  // 4. settle → Alice long 10, Bob short 10
  await send(ACCTS.alice, "settleEpoch", [E.toWitness(state)]);
  await assertSync("settleEpoch (positions open)", E.applySettleEpoch(state));

  // 5. liquidator funds up, oracle drops → Alice underwater → liquidate
  await approve(ACCTS.liq);
  await send(ACCTS.liq, "deposit", [E.toWitness(state), 5000n * WAD]);
  await assertSync("Liquidator deposit 5000", E.applyDeposit(state, L, 5000n * WAD));

  await send(ACCTS.deployer, "syncMarket", [E.toWitness(state), 1, 2800n * WAD, 0n]);
  await assertSync("syncMarket oracle=2800 (Alice underwater)", E.applySyncMarket(state, 1, 2800n * WAD, 0n));

  await send(ACCTS.liq, "liquidate", [E.toWitness(state), A, 1]);
  await assertSync("liquidate Alice (Liq inherits long)", E.applyLiquidate(state, A, 1, L));

  // 6. funding + oracle move
  await send(ACCTS.deployer, "syncMarket", [E.toWitness(state), 1, 3000n * WAD, 20n * WAD]);
  await assertSync("syncMarket oracle=3000, funding+20", E.applySyncMarket(state, 1, 3000n * WAD, 20n * WAD));

  // 7. cancel flow
  await approve(ACCTS.carol);
  await send(ACCTS.carol, "deposit", [E.toWitness(state), 1000n * WAD]);
  await assertSync("Carol deposit 1000", E.applyDeposit(state, C, 1000n * WAD));

  h = await send(ACCTS.carol, "placeOrder", [E.toWitness(state), 1, true, 3000n * WAD, 10n ** 17n]);
  t = await blockTimeOf(h);
  const carolOrderId = state.nextOrderId;
  await assertSync("Carol bid 0.1 ETH @3000", E.applyPlaceOrder(state, C, 1, true, 3000n * WAD, 10n ** 17n, t));

  await send(ACCTS.carol, "cancelOrder", [E.toWitness(state), carolOrderId]);
  await assertSync("Carol cancelOrder", E.applyCancelOrder(state, carolOrderId));

  // 8. withdraw
  await send(ACCTS.bob, "withdraw", [E.toWitness(state), 100n * WAD]);
  await assertSync("Bob withdraw 100", E.applyWithdraw(state, B, 100n * WAD));

  // 9. emergency exit after 7-day operator inactivity
  await pub.request({ method: "evm_increaseTime" as never, params: [7 * 24 * 3600 + 1] as never });
  await pub.request({ method: "evm_mine" as never, params: [] as never });
  await send(ACCTS.carol, "emergencyWithdraw", [E.toWitness(state), 500n * WAD]);
  await assertSync("Carol emergencyWithdraw 500 (after 7d)", E.applyEmergencyWithdraw(state, C, 500n * WAD));

  console.log("\nAll transitions stayed in sync — the TS engine faithfully mirrors the contract. ✅");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
