import { useEffect } from "react";
import { Button, Body } from "@breadcoop/ui";
import { useStore } from "./store";
import { Header } from "./components/Header";
import { StateInspector } from "./components/StateInspector";
import { AccountPanel } from "./components/AccountPanel";
import { CollateralPanel } from "./components/CollateralPanel";
import { MarketsPanel } from "./components/MarketsPanel";
import { TradePanel } from "./components/TradePanel";
import { OperationsPanel } from "./components/OperationsPanel";
import { LiquidatePanel } from "./components/LiquidatePanel";
import { AccountsOverview } from "./components/AccountsOverview";
import { ActivityLog } from "./components/ActivityLog";

export function App() {
  const { refresh, error, seedDemo, busy, transitionCount } = useStore();

  useEffect(() => {
    void refresh();
    const t = setInterval(() => void refresh(), 5000);
    return () => clearInterval(t);
  }, [refresh]);

  return (
    <div className="min-h-screen text-neutral-800">
      <Header />

      {error && (
        <div className="mx-auto mt-3 max-w-[1400px] px-6">
          <div className="rounded-xl border border-red-200 bg-red-50 px-4 py-2 text-sm text-red-700">{error}</div>
        </div>
      )}

      <main className="mx-auto max-w-[1400px] px-6 py-5">
        {transitionCount === 0n && (
          <div className="mb-5 flex items-center justify-between rounded-2xl border border-orange-200 bg-orange-50 px-5 py-4">
            <div>
              <Body bold>Fresh exchange.</Body>
              <Body className="!text-sm text-neutral-600">
                The frontend is the off-chain operator: it holds the full exchange state and commits a single 32-byte hash on-chain. Seed a scenario, or drive everything by hand below.
              </Body>
            </div>
            <Button onClick={seedDemo} isLoading={busy}>
              Seed demo scenario
            </Button>
          </div>
        )}

        <div className="grid grid-cols-1 gap-5 lg:grid-cols-3">
          <div className="space-y-5 lg:col-span-2">
            <MarketsPanel />
            <TradePanel />
            <div className="grid grid-cols-1 gap-5 md:grid-cols-2">
              <OperationsPanel />
              <LiquidatePanel />
            </div>
            <AccountsOverview />
          </div>

          <div className="space-y-5">
            <AccountPanel />
            <CollateralPanel />
            <StateInspector />
            <ActivityLog />
          </div>
        </div>

        <footer className="mt-8 pb-8 text-center text-xs text-neutral-400">
          GasKillerVertex demo · off-chain matching + single-slot commitment · local anvil · UI by <span className="font-medium">@breadcoop/ui</span>
        </footer>
      </main>
    </div>
  );
}
