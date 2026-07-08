import { useStore, fmtWad } from "../store";
import { Card, StatRow, Pill } from "./ui";

export function StateInspector() {
  const { state, onchainHash, computedHash, synced, transitionCount, lastTransitionAt, stateSlot } = useStore();
  const hex = (v: bigint | null) => (v === null ? "—" : `0x${v.toString(16).padStart(48, "0")}`);

  return (
    <Card title="Single-slot commitment" subtitle="the entire exchange hashes into one 32-byte storage slot" right={synced ? <Pill tone="pos">in sync</Pill> : <Pill tone="neg">out of sync</Pill>}>
      <div className="space-y-1">
        <div className="text-[11px] uppercase tracking-wide text-neutral-400">STATE_SLOT</div>
        <div className="mb-2 break-all font-mono text-xs text-neutral-600">{stateSlot ?? "—"}</div>
        <div className="text-[11px] uppercase tracking-wide text-neutral-400">on-chain state hash (192-bit)</div>
        <div className="break-all font-mono text-xs text-neutral-700">{hex(onchainHash)}</div>
        <div className="mt-2 text-[11px] uppercase tracking-wide text-neutral-400">operator-computed hash (from witness)</div>
        <div className={`break-all font-mono text-xs ${synced ? "text-emerald-700" : "text-red-700"}`}>{hex(computedHash)}</div>
      </div>
      <div className="mt-3 grid grid-cols-2 gap-x-6">
        <StatRow label="Transitions" value={`#${transitionCount.toString()}`} mono />
        <StatRow label="Last transition" value={lastTransitionAt === 0n ? "—" : new Date(Number(lastTransitionAt) * 1000).toLocaleTimeString()} mono />
        <StatRow label="Insurance fund" value={`${fmtWad(state.insuranceFund)} USDC`} mono />
        <StatRow label="Next order id" value={`#${state.nextOrderId.toString()}`} mono />
        <StatRow label="Accounts" value={state.accounts.length} mono />
        <StatRow label="Open orders" value={state.orders.length} mono />
      </div>
    </Card>
  );
}
