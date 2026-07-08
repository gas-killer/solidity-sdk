import { Button } from "@breadcoop/ui";
import { useStore, fmtWad, short } from "../store";
import { Card, Th, Td, Pill } from "./ui";
import { liquidatable } from "../selectors";
import type { Address } from "../engine/engine";

export function LiquidatePanel() {
  const { state, acting, liquidate, busy } = useStore();
  const targets = liquidatable(state);

  return (
    <Card title="Liquidations" subtitle={`accounts below maintenance margin — ${acting.label} would be the liquidator`}>
      {targets.length === 0 ? (
        <div className="rounded-lg bg-neutral-50 px-3 py-4 text-center text-sm text-neutral-400">No liquidatable accounts</div>
      ) : (
        <table className="w-full">
          <thead>
            <tr>
              <Th>Victim</Th>
              <Th>Mkt</Th>
              <Th className="text-right">Equity</Th>
              <Th className="text-right">Maint. margin</Th>
              <Th></Th>
              <Th></Th>
            </tr>
          </thead>
          <tbody>
            {targets.map((t) => (
              <tr key={`${t.owner}-${t.marketId}`} className="border-t border-black/5">
                <Td className="text-neutral-600">{short(t.owner)}</Td>
                <Td>#{t.marketId}</Td>
                <Td className="text-right font-mono text-red-600">{fmtWad(t.margin.equity)}</Td>
                <Td className="text-right font-mono">{fmtWad(t.margin.maintenanceMargin)}</Td>
                <Td>
                  <Pill tone="neg">underwater</Pill>
                </Td>
                <Td className="text-right">
                  <Button size="sm" variant="destructive" onClick={() => liquidate(t.owner as Address, t.marketId)} isLoading={busy} disabled={t.owner.toLowerCase() === acting.address.toLowerCase()}>
                    Liquidate
                  </Button>
                </Td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <p className="mt-3 text-xs text-neutral-400">The liquidator inherits the position at the oracle price and must be initial-margin healthy afterwards, so it needs its own collateral.</p>
    </Card>
  );
}
