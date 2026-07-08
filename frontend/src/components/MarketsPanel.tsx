import { useState } from "react";
import { Button } from "@breadcoop/ui";
import { useStore, parseWad, fmtWad } from "../store";
import { Card, Field, TextInput, Th, Td } from "./ui";

const pctToWad = (s: string) => parseWad(s) / 100n;
const wadToPct = (v: bigint) => fmtWad(v * 100n, 2);

export function MarketsPanel() {
  const { state, listMarket, syncMarket, busy } = useStore();
  const markets = state.markets;

  const nextId = (markets.reduce((mx, m) => Math.max(mx, m.id), 0) + 1) || 1;
  const [id, setId] = useState(String(nextId));
  const [imf, setImf] = useState("5");
  const [mmf, setMmf] = useState("3");
  const [oracle, setOracle] = useState("3000");

  const [syncId, setSyncId] = useState(String(markets[0]?.id ?? 1));
  const [syncOracle, setSyncOracle] = useState("3000");
  const [funding, setFunding] = useState("0");

  return (
    <Card title="Markets" subtitle="operator lists perp markets & posts oracle price + funding">
      {markets.length === 0 ? (
        <div className="rounded-lg bg-neutral-50 px-3 py-4 text-center text-sm text-neutral-400">No markets listed yet</div>
      ) : (
        <table className="w-full">
          <thead>
            <tr>
              <Th>Market</Th>
              <Th className="text-right">Oracle</Th>
              <Th className="text-right">Cum. funding</Th>
              <Th className="text-right">IMF</Th>
              <Th className="text-right">MMF</Th>
            </tr>
          </thead>
          <tbody>
            {markets.map((m) => (
              <tr key={m.id} className="border-t border-black/5">
                <Td>#{m.id}</Td>
                <Td className="text-right font-mono">{fmtWad(m.oracle)}</Td>
                <Td className="text-right font-mono text-neutral-500">{fmtWad(m.cumFunding)}</Td>
                <Td className="text-right font-mono">{wadToPct(m.imf)}%</Td>
                <Td className="text-right font-mono">{wadToPct(m.mmf)}%</Td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <div className="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2">
        <div className="rounded-xl border border-black/10 p-3">
          <div className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-neutral-400">List a new market</div>
          <div className="grid grid-cols-4 gap-2">
            <Field label="ID">
              <TextInput value={id} onChange={(e) => setId(e.target.value)} />
            </Field>
            <Field label="IMF %">
              <TextInput value={imf} onChange={(e) => setImf(e.target.value)} />
            </Field>
            <Field label="MMF %">
              <TextInput value={mmf} onChange={(e) => setMmf(e.target.value)} />
            </Field>
            <Field label="Oracle">
              <TextInput value={oracle} onChange={(e) => setOracle(e.target.value)} />
            </Field>
          </div>
          <Button className="mt-2 w-full" onClick={() => listMarket(Number(id), pctToWad(imf), pctToWad(mmf), parseWad(oracle))} isLoading={busy}>
            List market
          </Button>
        </div>

        <div className="rounded-xl border border-black/10 p-3">
          <div className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-neutral-400">Sync oracle + funding (sequencer)</div>
          <div className="grid grid-cols-3 gap-2">
            <Field label="Market">
              <select className="h-10 rounded-lg border border-black/15 bg-white px-2 text-sm" value={syncId} onChange={(e) => setSyncId(e.target.value)}>
                {markets.map((m) => (
                  <option key={m.id} value={m.id}>
                    #{m.id}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="New oracle">
              <TextInput value={syncOracle} onChange={(e) => setSyncOracle(e.target.value)} />
            </Field>
            <Field label="Funding Δ" hint="+ longs pay">
              <TextInput value={funding} onChange={(e) => setFunding(e.target.value)} />
            </Field>
          </div>
          <Button className="mt-2 w-full" variant="secondary" onClick={() => syncMarket(Number(syncId), parseWad(syncOracle), parseWad(funding))} isLoading={busy} disabled={markets.length === 0}>
            Sync market
          </Button>
        </div>
      </div>
    </Card>
  );
}
