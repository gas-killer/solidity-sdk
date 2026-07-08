import { Button } from "@breadcoop/ui";
import { useStore, fmtWad, short } from "../store";
import { Card, StatRow, Pill, Th, Td } from "./ui";
import { accountOf, marginFor, positionViews } from "../selectors";

export function AccountPanel() {
  const { state, acting, usdcAllowance, approve, busy } = useStore();
  const acc = accountOf(state, acting.address);
  const m = marginFor(state, acting.address);
  const positions = positionViews(state, acting.address);
  const collateral = acc?.collateral ?? 0n;
  const healthy = m.equity >= m.initialMargin;
  const needsApproval = usdcAllowance < 1_000_000n * 10n ** 18n;

  return (
    <Card
      title={`${acting.label}'s account`}
      subtitle={short(acting.address)}
      right={healthy ? <Pill tone="pos">healthy</Pill> : m.equity < m.maintenanceMargin ? <Pill tone="neg">liquidatable</Pill> : <Pill tone="warn">below IM</Pill>}
    >
      <div className="grid grid-cols-2 gap-x-6">
        <StatRow label="Collateral" value={`${fmtWad(collateral)} USDC`} mono />
        <StatRow label="Equity" value={`${fmtWad(m.equity)} USDC`} mono tone={m.equity < 0n ? "neg" : undefined} />
        <StatRow label="Initial margin" value={fmtWad(m.initialMargin)} mono />
        <StatRow label="Maint. margin" value={fmtWad(m.maintenanceMargin)} mono />
      </div>

      {needsApproval && (
        <div className="mt-3 flex items-center justify-between rounded-lg bg-amber-50 px-3 py-2">
          <span className="text-xs text-amber-700">This account hasn't approved the exchange to pull USDC.</span>
          <Button size="sm" variant="secondary" onClick={approve} isLoading={busy}>
            Approve USDC
          </Button>
        </div>
      )}

      <div className="mt-4">
        <div className="mb-1 text-[11px] font-semibold uppercase tracking-wide text-neutral-400">Open positions</div>
        {positions.length === 0 ? (
          <div className="rounded-lg bg-neutral-50 px-3 py-4 text-center text-sm text-neutral-400">No open positions</div>
        ) : (
          <table className="w-full">
            <thead>
              <tr>
                <Th>Mkt</Th>
                <Th className="text-right">Size</Th>
                <Th className="text-right">Avg entry</Th>
                <Th className="text-right">Oracle</Th>
                <Th className="text-right">uPnL</Th>
                <Th className="text-right">Funding</Th>
              </tr>
            </thead>
            <tbody>
              {positions.map((p) => (
                <tr key={p.marketId} className="border-t border-black/5">
                  <Td>#{p.marketId}</Td>
                  <Td className={`text-right font-mono ${p.size > 0n ? "text-emerald-600" : "text-red-600"}`}>
                    {p.size > 0n ? "+" : ""}
                    {fmtWad(p.size, 4)}
                  </Td>
                  <Td className="text-right font-mono">{fmtWad(p.avgEntry)}</Td>
                  <Td className="text-right font-mono">{fmtWad(p.oracle)}</Td>
                  <Td className={`text-right font-mono ${p.uPnl >= 0n ? "text-emerald-600" : "text-red-600"}`}>{fmtWad(p.uPnl)}</Td>
                  <Td className="text-right font-mono text-neutral-500">{fmtWad(p.fundingOwed)}</Td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </Card>
  );
}
