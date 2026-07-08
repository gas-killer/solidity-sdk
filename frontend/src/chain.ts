import { createPublicClient, createWalletClient, http, defineChain, type Address, type Chain, type PublicClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { CONFIG } from "./lib/addresses";
import { vertexAbi } from "./abi/vertex";
import { erc20Abi } from "./abi/erc20";

export { vertexAbi, erc20Abi, CONFIG };

/// Resolved contract addresses (env pin → runtime manifest → baked fallback; see lib/addresses.ts).
export const vertexAddr = (): Address => CONFIG.vertex;
export const usdcAddr = (): Address => CONFIG.usdc;

/// Default anvil dev accounts — the operator console sends txs as the selected one.
/// (Local demo only; these keys are public knowledge and only used on chain 31337.)
export type DevAccount = { label: string; address: Address; pk: `0x${string}` };

export const DEV_ACCOUNTS: DevAccount[] = [
  { label: "Deployer", address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", pk: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" },
  { label: "Alice", address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", pk: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" },
  { label: "Bob", address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC", pk: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a" },
  { label: "Carol", address: "0x90F79bf6EB2c4f870365E785982E1f101E93b906", pk: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6" },
  { label: "Liquidator", address: "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65", pk: "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a" },
];

let _chain: Chain | undefined;
let _pub: PublicClient | undefined;

export function getChain(): Chain {
  return (_chain ??= defineChain({
    id: CONFIG.chainId,
    name: CONFIG.chainId === 31337 ? "Anvil" : `Chain ${CONFIG.chainId}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [CONFIG.rpcUrl] } },
  }));
}

export function publicClient(): PublicClient {
  return (_pub ??= createPublicClient({ chain: getChain(), transport: http(CONFIG.rpcUrl) }));
}

export function walletFor(pk: `0x${string}`) {
  return createWalletClient({ account: privateKeyToAccount(pk), chain: getChain(), transport: http(CONFIG.rpcUrl) });
}
