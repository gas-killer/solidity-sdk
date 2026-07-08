import { useState } from "react";
import { Button, Body } from "@breadcoop/ui";
import { useStore, parseWad } from "../store";
import { Card, Field, TextInput } from "./ui";

export function OperationsPanel() {
  const { settleEpoch, settleViaOperator, warp7Days, emergencyWithdraw, busy, state } = useStore();
  const [amount, setAmount] = useState("100");
  const hasOrders = state.orders.length > 0;

  return (
    <Card title="Operator & settlement" subtitle="run the matching engine and the Gas Killer commit path">
      <div className="rounded-xl border border-black/10 p-3">
        <Body bold className="!text-sm">
          Settle epoch
        </Body>
        <p className="mb-2 mt-1 text-xs text-neutral-500">
          Matches every market's book in price-time priority and opens perp positions. Off-chain this can exceed the block gas limit; on-chain it lands as a single state commitment.
        </p>
        <div className="flex gap-2">
          <Button variant="secondary" onClick={settleEpoch} isLoading={busy} disabled={!hasOrders}>
            settleEpoch (standalone)
          </Button>
          <Button onClick={settleViaOperator} isLoading={busy} disabled={!hasOrders}>
            Settle via operator → 1 STORE
          </Button>
        </div>
        <p className="mt-1 text-[11px] text-neutral-400">The operator path computes the result off-chain and commits it via a BLS-attested <code>verifyAndUpdate</code> (one SSTORE).</p>
      </div>

      <div className="mt-3 rounded-xl border border-black/10 p-3">
        <Body bold className="!text-sm">
          Emergency exit
        </Body>
        <p className="mb-2 mt-1 text-xs text-neutral-500">If no transition lands for 7 days, any user with no open positions may withdraw their free collateral.</p>
        <div className="flex items-end gap-2">
          <Button variant="light" onClick={warp7Days} isLoading={busy}>
            ⏩ warp chain +7 days
          </Button>
          <Field label="Amount (USDC)">
            <TextInput value={amount} onChange={(e) => setAmount(e.target.value)} />
          </Field>
          <Button variant="destructive" onClick={() => emergencyWithdraw(parseWad(amount))} isLoading={busy}>
            emergencyWithdraw
          </Button>
        </div>
      </div>
    </Card>
  );
}
