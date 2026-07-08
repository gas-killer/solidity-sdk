import { useState } from "react";
import { Button } from "@breadcoop/ui";
import { useStore, parseWad, fmtWad, short } from "../store";
import { Card, Field, TextInput, Th, Td } from "./ui";
import { ordersForMarket } from "../selectors";

export function TradePanel() {
  const { state, acting, placeOrder, cancelOrder, busy } = useStore();
  const markets = state.markets;
  const [marketId, setMarketId] = useState<number>(markets[0]?.id ?? 1);
  const [side, setSide] = useState<"bid" | "ask">("bid");
  const [price, setPrice] = useState("3000");
  const [size, setSize] = useState("1");

  const mkt = markets.find((m) => m.id === marketId) ?? markets[0];
  const effMarketId = mkt?.id ?? marketId;
  const { bids, asks } = ordersForMarket(state, effMarketId);

  return (
    <Card
      title="Trade"
      subtitle="place resting limit orders — settleEpoch matches them into perp positions"
      right={
        markets.length > 1 ? (
          <select className="h-9 rounded-lg border border-black/15 bg-white px-2 text-sm" value={effMarketId} onChange={(e) => setMarketId(Number(e.target.value))}>
            {markets.map((m) => (
              <option key={m.id} value={m.id}>
                Market #{m.id}
              </option>
            ))}
          </select>
        ) : undefined
      }
    >
      {markets.length === 0 ? (
        <div className="rounded-lg bg-neutral-50 px-3 py-6 text-center text-sm text-neutral-400">List a market first.</div>
      ) : (
        <>
          <div className="flex items-end gap-2">
            <Field label="Side">
              <div className="flex overflow-hidden rounded-lg border border-black/15">
                <button className={`px-3 py-2 text-sm ${side === "bid" ? "bg-emerald-500 text-white" : "bg-white"}`} onClick={() => setSide("bid")}>
                  Buy / Long
                </button>
                <button className={`px-3 py-2 text-sm ${side === "ask" ? "bg-red-500 text-white" : "bg-white"}`} onClick={() => setSide("ask")}>
                  Sell / Short
                </button>
              </div>
            </Field>
            <Field label="Price">
              <TextInput value={price} onChange={(e) => setPrice(e.target.value)} />
            </Field>
            <Field label="Size">
              <TextInput value={size} onChange={(e) => setSize(e.target.value)} />
            </Field>
            <Button onClick={() => placeOrder(effMarketId, side === "bid", parseWad(price), parseWad(size))} isLoading={busy}>
              Place order
            </Button>
          </div>

          <div className="mt-4 grid grid-cols-2 gap-4">
            <OrderColumn title="Bids" tone="pos" rows={bids} acting={acting.address} onCancel={cancelOrder} busy={busy} />
            <OrderColumn title="Asks" tone="neg" rows={asks} acting={acting.address} onCancel={cancelOrder} busy={busy} />
          </div>
        </>
      )}
    </Card>
  );
}

function OrderColumn({ title, tone, rows, acting, onCancel, busy }: { title: string; tone: "pos" | "neg"; rows: ReturnType<typeof ordersForMarket>["bids"]; acting: string; onCancel: (id: bigint) => void; busy: boolean }) {
  return (
    <div>
      <div className={`mb-1 text-[11px] font-semibold uppercase tracking-wide ${tone === "pos" ? "text-emerald-600" : "text-red-600"}`}>{title}</div>
      {rows.length === 0 ? (
        <div className="rounded-lg bg-neutral-50 px-3 py-3 text-center text-xs text-neutral-400">empty</div>
      ) : (
        <table className="w-full">
          <thead>
            <tr>
              <Th className="text-right">Price</Th>
              <Th className="text-right">Size</Th>
              <Th>Maker</Th>
              <Th></Th>
            </tr>
          </thead>
          <tbody>
            {rows.map((o) => (
              <tr key={o.id.toString()} className="border-t border-black/5">
                <Td className={`text-right font-mono ${tone === "pos" ? "text-emerald-600" : "text-red-600"}`}>{fmtWad(o.price)}</Td>
                <Td className="text-right font-mono">{fmtWad(o.size, 4)}</Td>
                <Td className="text-neutral-500">{short(o.maker)}</Td>
                <Td>
                  {o.maker.toLowerCase() === acting.toLowerCase() && (
                    <button className="text-xs text-neutral-400 underline hover:text-red-600 disabled:opacity-40" onClick={() => onCancel(o.id)} disabled={busy}>
                      cancel
                    </button>
                  )}
                </Td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
