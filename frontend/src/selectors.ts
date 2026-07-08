import * as E from "./engine/engine";
import type { Address } from "./engine/engine";

export function accountOf(s: E.ExchangeState, owner: Address): E.Account | undefined {
  const a = owner.toLowerCase();
  return s.accounts.find((x) => x.owner === a);
}

export function marginFor(s: E.ExchangeState, owner: Address): E.Margin {
  return E.accountMargin(s, owner);
}

export type PositionView = {
  marketId: number;
  size: bigint;
  avgEntry: bigint;
  oracle: bigint;
  uPnl: bigint;
  fundingOwed: bigint;
};

export function positionViews(s: E.ExchangeState, owner: Address): PositionView[] {
  const a = accountOf(s, owner);
  if (!a) return [];
  return a.positions
    .filter((p) => p.size !== 0n)
    .map((p) => {
      const m = s.markets.find((mm) => mm.id === p.marketId);
      const oracle = m?.oracle ?? 0n;
      const cumF = m?.cumFunding ?? p.entryFunding;
      return {
        marketId: p.marketId,
        size: p.size,
        avgEntry: p.avgEntry,
        oracle,
        uPnl: (p.size * (oracle - p.avgEntry)) / E.WAD,
        fundingOwed: (p.size * (cumF - p.entryFunding)) / E.WAD,
      };
    });
}

export function ordersForMarket(s: E.ExchangeState, marketId: number) {
  const rows = s.orders.filter((o) => o.marketId === marketId && o.size > 0n);
  const bids = rows.filter((o) => o.isBid).sort((a, b) => (a.price === b.price ? cmp(a.placedAt, b.placedAt) : cmp(b.price, a.price)));
  const asks = rows.filter((o) => !o.isBid).sort((a, b) => (a.price === b.price ? cmp(a.placedAt, b.placedAt) : cmp(a.price, b.price)));
  return { bids, asks };
}

const cmp = (a: bigint, b: bigint) => (a < b ? -1 : a > b ? 1 : 0);

export type Liquidatable = { owner: Address; marketId: number; margin: E.Margin };

export function liquidatable(s: E.ExchangeState): Liquidatable[] {
  const out: Liquidatable[] = [];
  for (const a of s.accounts) {
    const margin = E.marginOfAccount(a, s.markets);
    if (a.positions.some((p) => p.size !== 0n) && margin.equity < margin.maintenanceMargin) {
      for (const p of a.positions.filter((pp) => pp.size !== 0n)) out.push({ owner: a.owner, marketId: p.marketId, margin });
    }
  }
  return out;
}
