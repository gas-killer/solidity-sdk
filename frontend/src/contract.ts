import type { Address, Hash } from "viem";
import { publicClient, walletFor, vertexAddr, usdcAddr, vertexAbi, erc20Abi } from "./chain";

export const MAX_UINT = (1n << 256n) - 1n;

/// Read a Vertex view.
export function readVertex<T = unknown>(fn: string, args: unknown[] = []): Promise<T> {
  return publicClient().readContract({ address: vertexAddr(), abi: vertexAbi, functionName: fn as never, args: args as never }) as Promise<T>;
}

export function readErc20<T = unknown>(fn: string, args: unknown[] = []): Promise<T> {
  return publicClient().readContract({ address: usdcAddr(), abi: erc20Abi, functionName: fn as never, args: args as never }) as Promise<T>;
}

/// Simulate (for a decoded custom-error revert) then send a Vertex write from `pk`. Returns the
/// mined block timestamp so callers that need `placedAt` stay in sync with the contract.
export async function writeVertex(pk: `0x${string}`, from: Address, fn: string, args: unknown[]): Promise<{ hash: Hash; blockTime: bigint }> {
  const pub = publicClient();
  const { request } = await pub.simulateContract({
    address: vertexAddr(),
    abi: vertexAbi,
    functionName: fn as never,
    args: args as never,
    account: from,
  });
  const hash = await walletFor(pk).writeContract(request as never);
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${fn} reverted`);
  const block = await pub.getBlock({ blockNumber: receipt.blockNumber });
  return { hash, blockTime: block.timestamp };
}

export async function approveUsdc(pk: `0x${string}`): Promise<Hash> {
  const hash = await walletFor(pk).writeContract({ address: usdcAddr(), abi: erc20Abi, functionName: "approve", args: [vertexAddr(), MAX_UINT] });
  await publicClient().waitForTransactionReceipt({ hash });
  return hash;
}

/// Advance the anvil clock so the emergency-exit gate can be demonstrated.
export async function increaseTime(seconds: number) {
  await publicClient().request({ method: "evm_increaseTime" as never, params: [seconds] as never });
  await publicClient().request({ method: "evm_mine" as never, params: [] as never });
}

/// Extract a human-readable message (custom error name if viem decoded one).
export function errMessage(e: unknown): string {
  const any = e as { shortMessage?: string; message?: string; cause?: { data?: { errorName?: string; args?: unknown[] } } };
  const name = any?.cause?.data?.errorName;
  if (name) return `${name}${any.cause?.data?.args?.length ? `(${(any.cause!.data!.args as unknown[]).map(String).join(", ")})` : ""}`;
  return any?.shortMessage ?? any?.message ?? String(e);
}
