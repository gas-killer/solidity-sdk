import { useStore, fmtWad, short } from "../store";
import { Card, Th, Td, Pill } from "./ui";
import * as E from "../engine/engine";

export function AccountsOverview() {
  const { state } = useStore();
  const rows = state.accounts
    .map((a) => ({ a, m: E.marginOfAccount(a, state.markets), openPos: a.positions.filter((p) => p.size !== 0n).length }))
    .filter((r) => r.a.collateral !== 0n || r.openPos > 0);

  return (
    <Card title="All accounts" subtitle="the operator sees the full off-chain state committed to one slot">
      {rows.length === 0 ? (
        <div className="rounded-lg bg-neutral-50 px-3 py-4 text-center text-sm text-neutral-400">No accounts yet</div>
      ) : (
        <table className="w-full">
          <thead>
            <tr>
              <Th>Account</Th>
              <Th className="text-right">Collateral</Th>
              <Th className="text-right">Equity</Th>
              <Th className="text-right">IM</Th>
              <Th className="text-right">MM</Th>
              <Th className="text-right">Pos.</Th>
              <Th>Health</Th>
            </tr>
          </thead>
          <tbody>
            {rows.map(({ a, m, openPos }) => {
              const tone = m.equity < m.maintenanceMargin && openPos > 0 ? "neg" : m.equity < m.initialMargin ? "warn" : "pos";
              const label = tone === "neg" ? "liquidatable" : tone === "warn" ? "below IM" : "healthy";
              return (
                <tr key={a.owner} className="border-t border-black/5">
                  <Td className="text-neutral-600">{short(a.owner)}</Td>
                  <Td className="text-right font-mono">{fmtWad(a.collateral)}</Td>
                  <Td className={`text-right font-mono ${m.equity < 0n ? "text-red-600" : ""}`}>{fmtWad(m.equity)}</Td>
                  <Td className="text-right font-mono text-neutral-500">{fmtWad(m.initialMargin)}</Td>
                  <Td className="text-right font-mono text-neutral-500">{fmtWad(m.maintenanceMargin)}</Td>
                  <Td className="text-right">{openPos}</Td>
                  <Td>
                    <Pill tone={tone}>{label}</Pill>
                  </Td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </Card>
  );
}
