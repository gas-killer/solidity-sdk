import { useState } from "react";
import { Button } from "@breadcoop/ui";
import { useStore, parseWad } from "../store";
import { Card, Field, TextInput } from "./ui";

export function CollateralPanel() {
  const { deposit, withdraw, busy } = useStore();
  const [amount, setAmount] = useState("1000");
  const amt = parseWad(amount);

  return (
    <Card title="Collateral" subtitle="deposit / withdraw quote (USDC) as cross-margin">
      <div className="flex items-end gap-3">
        <Field label="Amount (USDC)">
          <TextInput value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal" />
        </Field>
        <Button variant="positive" onClick={() => deposit(amt)} isLoading={busy} disabled={amt <= 0n}>
          Deposit
        </Button>
        <Button variant="secondary" onClick={() => withdraw(amt)} isLoading={busy} disabled={amt <= 0n}>
          Withdraw
        </Button>
      </div>
      <p className="mt-3 text-xs text-neutral-400">Withdraw requires the account to stay initial-margin healthy after the withdrawal.</p>
    </Card>
  );
}
