import type { Address } from "viem";
import baked from "../deployments.json";

/**
 * Runtime contract-address hydration — the same convention as
 * BreadchainCoop/crowdstake.fun (`src/lib/remote-addresses.ts`).
 *
 * A deploy publishes an `addresses.json` manifest to the repo's `addresses`
 * branch (the "etherform" contracts-deploy step). Because this frontend is a
 * static export (GitHub Pages), fetching that manifest at runtime means a new
 * deployment goes live WITHOUT a frontend rebuild — the baked-in
 * `deployments.json` values become mere fallbacks.
 *
 * Precedence (strongest first):
 *   1. Build-time VITE_* env pins
 *   2. This manifest (latest deploy)
 *   3. Baked-in fallback (src/deployments.json, written by DeployVertex.s.sol)
 *
 * CORS note: raw.githubusercontent.com sends `access-control-allow-origin: *`,
 * so the `addresses` branch is fetchable in-browser (a GitHub release-asset
 * download would 302 to a host without CORS).
 */
export type AppConfig = {
  chainId: number;
  rpcUrl: string;
  vertex: Address;
  usdc: Address;
  bls: Address;
};

const env = (import.meta.env ?? {}) as unknown as Record<string, string | undefined>;

// (1) env pins > (3) baked fallback. (2) manifest is merged in at runtime below.
export const CONFIG: AppConfig = {
  chainId: Number(env.VITE_CHAIN_ID || baked.chainId),
  rpcUrl: env.VITE_RPC_URL || baked.rpcUrl,
  vertex: (env.VITE_VERTEX || baked.vertex) as Address,
  usdc: (env.VITE_USDC || baked.usdc) as Address,
  bls: (env.VITE_BLS || baked.bls) as Address,
};

// CORS-fetchable manifest mirror on the `addresses` branch. Override with
// VITE_ADDRESSES_URL, or set it to "off" to disable runtime hydration.
const MANIFEST_URL = env.VITE_ADDRESSES_URL || "https://raw.githubusercontent.com/RonTuretzky/gaskiller-vertex-ui/addresses/addresses.json";

const FETCH_TIMEOUT_MS = 5000;

type ManifestChain = Partial<Pick<AppConfig, "rpcUrl" | "vertex" | "usdc" | "bls">>;
type Manifest = { version: number; chains: Record<string, ManifestChain> };

/**
 * Fetch the latest published addresses and merge them into CONFIG in place.
 * Fail-soft: on any error the baked-in addresses stay untouched.
 * @returns true if anything changed.
 */
export async function hydrateRemoteAddresses(): Promise<boolean> {
  if (env.VITE_ADDRESSES_URL === "off") return false;
  if (typeof window === "undefined") return false;
  let manifest: Manifest;
  try {
    const r = await fetch(MANIFEST_URL, { cache: "no-store", signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    manifest = (await r.json()) as Manifest;
  } catch (e) {
    console.warn("[addresses] using baked-in addresses:", e);
    return false;
  }
  if (manifest?.version !== 1 || typeof manifest.chains !== "object") return false;

  const entry = manifest.chains[String(CONFIG.chainId)];
  if (!entry) return false;

  let updated = false;
  for (const k of ["rpcUrl", "vertex", "usdc", "bls"] as const) {
    const v = entry[k];
    // Don't let the manifest override an explicit build-time env pin.
    const pinned = Boolean((env as Record<string, string | undefined>)[`VITE_${k.toUpperCase()}`]);
    if (v && !pinned && CONFIG[k] !== v) {
      (CONFIG as Record<string, unknown>)[k] = v;
      updated = true;
    }
  }
  return updated;
}
