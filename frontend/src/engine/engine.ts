// ------------------------------------------------------------------------------------------------
// GasKillerVertex off-chain exchange engine
//
// A faithful TypeScript port of the contract's ExchangeState + transition logic. The frontend is
// the "operator": it maintains this mirror, passes it to the contract as the `witness`, and applies
// each transition here after the tx confirms. Because the contract canonicalizes + re-hashes the
// witness on-chain, this mirror only has to represent the same *set* of accounts/positions/orders/
// markets — every numeric operation below matches the Solidity exactly so the state never diverges.
//
// All fixed-point values are WAD (1e18) bigints, mirroring the contract.
// ------------------------------------------------------------------------------------------------

export type Address = `0x${string}`;

export type Position = {
  marketId: number; // uint32
  size: bigint; // int256 (signed: + long, − short)
  avgEntry: bigint; // int256 (WAD quote-per-base)
  entryFunding: bigint; // int256
};

export type Account = {
  owner: Address;
  collateral: bigint; // int256
  positions: Position[];
};

export type Order = {
  id: bigint; // uint64
  maker: Address;
  marketId: number; // uint32
  isBid: boolean;
  price: bigint; // uint256 (WAD)
  size: bigint; // uint256 (WAD)
  placedAt: bigint; // uint64
};

export type Market = {
  id: number; // uint32
  oracle: bigint; // uint256 (WAD)
  cumFunding: bigint; // int256
  imf: bigint; // uint256 (WAD)
  mmf: bigint; // uint256 (WAD)
};

export type ExchangeState = {
  nextOrderId: bigint;
  insuranceFund: bigint;
  accounts: Account[];
  orders: Order[];
  markets: Market[];
};

export const WAD = 10n ** 18n;
const E36 = 10n ** 36n;
export const LIQUIDATION_PENALTY = 25_000_000_000_000_000n; // 0.025e18

// ---- helpers ---------------------------------------------------------------------------------

const lc = (a: string): Address => a.toLowerCase() as Address;
const absB = (x: bigint): bigint => (x < 0n ? -x : x);

export function emptyState(): ExchangeState {
  return { nextOrderId: 0n, insuranceFund: 0n, accounts: [], orders: [], markets: [] };
}

export function clone(s: ExchangeState): ExchangeState {
  return {
    nextOrderId: s.nextOrderId,
    insuranceFund: s.insuranceFund,
    accounts: s.accounts.map((a) => ({
      owner: a.owner,
      collateral: a.collateral,
      positions: a.positions.map((p) => ({ ...p })),
    })),
    orders: s.orders.map((o) => ({ ...o })),
    markets: s.markets.map((m) => ({ ...m })),
  };
}

const idxAccount = (s: ExchangeState, owner: Address) => s.accounts.findIndex((a) => a.owner === lc(owner));
const idxPosition = (a: Account, marketId: number) => a.positions.findIndex((p) => p.marketId === marketId);
const idxMarket = (s: ExchangeState, marketId: number) => s.markets.findIndex((m) => m.id === marketId);
const idxOrder = (s: ExchangeState, id: bigint) => s.orders.findIndex((o) => o.id === id);

function ensureAccount(s: ExchangeState, owner: Address): Account {
  const i = idxAccount(s, owner);
  if (i >= 0) return s.accounts[i];
  const a: Account = { owner: lc(owner), collateral: 0n, positions: [] };
  s.accounts.push(a);
  return a;
}

// ---- funding / position math (mirror of _realizeFundingOnAccount / _applyDeltaToAccount) -------

function realizeFunding(a: Account, pi: number, markets: Market[]) {
  const p = a.positions[pi];
  const mi = markets.findIndex((m) => m.id === p.marketId);
  const cumFunding = mi >= 0 ? markets[mi].cumFunding : p.entryFunding;
  const owed = (p.size * (cumFunding - p.entryFunding)) / WAD;
  a.collateral -= owed;
  p.entryFunding = cumFunding;
}

function applyDeltaToAccount(a: Account, markets: Market[], marketId: number, delta: bigint, price: bigint) {
  if (delta === 0n) return;
  const mi = markets.findIndex((m) => m.id === marketId);
  const cumFunding = mi >= 0 ? markets[mi].cumFunding : 0n;

  const pi = idxPosition(a, marketId);
  if (pi < 0) {
    a.positions.push({ marketId, size: delta, avgEntry: price, entryFunding: cumFunding });
    return;
  }

  realizeFunding(a, pi, markets);
  const p = a.positions[pi];
  const oldSize = p.size;
  const newSize = oldSize + delta;

  if (oldSize === 0n) {
    p.avgEntry = price;
  } else if (oldSize > 0n === delta > 0n) {
    const absOld = absB(oldSize);
    const absDelta = absB(delta);
    p.avgEntry = (absOld * p.avgEntry + absDelta * price) / (absOld + absDelta);
  } else {
    const closed = absB(delta) < absB(oldSize) ? absB(delta) : absB(oldSize);
    const dir = oldSize > 0n ? 1n : -1n;
    const pnl = (dir * closed * (price - p.avgEntry)) / WAD;
    a.collateral += pnl;
    if (newSize > 0n !== oldSize > 0n && newSize !== 0n) p.avgEntry = price;
  }
  p.size = newSize;
}

// ---- cross-margin health (mirror of _marginOfAccount) ------------------------------------------

export type Margin = { equity: bigint; initialMargin: bigint; maintenanceMargin: bigint };

export function marginOfAccount(a: Account, markets: Market[]): Margin {
  let equity = a.collateral;
  let initialMargin = 0n;
  let maintenanceMargin = 0n;
  for (const p of a.positions) {
    const mi = markets.findIndex((m) => m.id === p.marketId);
    if (mi < 0) continue;
    const m = markets[mi];
    equity += (p.size * (m.oracle - p.avgEntry)) / WAD;
    equity -= (p.size * (m.cumFunding - p.entryFunding)) / WAD;
    const absNotional = absB(p.size) * m.oracle;
    initialMargin += (absNotional * m.imf) / E36;
    maintenanceMargin += (absNotional * m.mmf) / E36;
  }
  return { equity, initialMargin, maintenanceMargin };
}

export function accountMargin(s: ExchangeState, owner: Address): Margin {
  const i = idxAccount(s, owner);
  if (i < 0) return { equity: 0n, initialMargin: 0n, maintenanceMargin: 0n };
  return marginOfAccount(s.accounts[i], s.markets);
}

// ---- canonical prune (mirror of the contract's canonicalization drops) -------------------------

function prune(s: ExchangeState) {
  for (const a of s.accounts) a.positions = a.positions.filter((p) => p.size !== 0n);
  s.accounts = s.accounts.filter((a) => a.collateral !== 0n || a.positions.length > 0);
}

// ------------------------------------------------------------------------------------------------
// Transitions — each returns a NEW state (clone + mutate + prune)
// ------------------------------------------------------------------------------------------------

export function applyDeposit(s0: ExchangeState, owner: Address, amount: bigint): ExchangeState {
  const s = clone(s0);
  ensureAccount(s, owner).collateral += amount;
  prune(s);
  return s;
}

export function applyWithdraw(s0: ExchangeState, owner: Address, amount: bigint): ExchangeState {
  const s = clone(s0);
  ensureAccount(s, owner).collateral -= amount;
  prune(s);
  return s;
}

export function applyListMarket(
  s0: ExchangeState,
  id: number,
  imf: bigint,
  mmf: bigint,
  oracle: bigint,
): ExchangeState {
  const s = clone(s0);
  s.markets.push({ id, oracle, cumFunding: 0n, imf, mmf });
  return s;
}

export function applySyncMarket(s0: ExchangeState, id: number, oracle: bigint, fundingDelta: bigint): ExchangeState {
  const s = clone(s0);
  const mi = idxMarket(s, id);
  if (mi >= 0) {
    s.markets[mi].oracle = oracle;
    s.markets[mi].cumFunding += fundingDelta;
  }
  return s;
}

export function applyPlaceOrder(
  s0: ExchangeState,
  maker: Address,
  marketId: number,
  isBid: boolean,
  price: bigint,
  size: bigint,
  placedAt: bigint,
): ExchangeState {
  const s = clone(s0);
  s.orders.push({ id: s.nextOrderId, maker: lc(maker), marketId, isBid, price, size, placedAt });
  s.nextOrderId += 1n;
  return s;
}

export function applyCancelOrder(s0: ExchangeState, id: bigint): ExchangeState {
  const s = clone(s0);
  const i = idxOrder(s, id);
  if (i >= 0) s.orders.splice(i, 1);
  return s;
}

// Mirror of _matchAllMarkets + _matchMarket (price-time priority, self-trade prevention).
export function applySettleEpoch(s0: ExchangeState): ExchangeState {
  const s = clone(s0);
  for (const m of s.markets) matchMarket(s, m.id);
  s.orders = s.orders.filter((o) => o.size > 0n);
  prune(s);
  return s;
}

function matchMarket(s: ExchangeState, marketId: number) {
  const bids = s.orders.filter((o) => o.marketId === marketId && o.size > 0n && o.isBid);
  const asks = s.orders.filter((o) => o.marketId === marketId && o.size > 0n && !o.isBid);
  // price-time priority: bids price desc then placedAt asc; asks price asc then placedAt asc
  bids.sort((a, b) => (a.price === b.price ? cmp(a.placedAt, b.placedAt) : cmp(b.price, a.price)));
  asks.sort((a, b) => (a.price === b.price ? cmp(a.placedAt, b.placedAt) : cmp(a.price, b.price)));

  let bi = 0;
  let ai = 0;
  while (bi < bids.length && ai < asks.length) {
    if (bids[bi].price < asks[ai].price) break;

    // self-trade prevention: cancel the newer of the two crossing orders (tie-break by id)
    if (bids[bi].maker === asks[ai].maker) {
      const cancelBid =
        bids[bi].placedAt > asks[ai].placedAt ||
        (bids[bi].placedAt === asks[ai].placedAt && bids[bi].id > asks[ai].id);
      if (cancelBid) {
        bids[bi].size = 0n;
        bi++;
      } else {
        asks[ai].size = 0n;
        ai++;
      }
      continue;
    }

    const fillPrice = asks[ai].price;
    const fillSize = bids[bi].size < asks[ai].size ? bids[bi].size : asks[ai].size;

    applyDeltaToAccount(ensureAccount(s, bids[bi].maker), s.markets, marketId, fillSize, fillPrice);
    applyDeltaToAccount(ensureAccount(s, asks[ai].maker), s.markets, marketId, -fillSize, fillPrice);

    bids[bi].size -= fillSize;
    asks[ai].size -= fillSize;
    if (bids[bi].size === 0n) bi++;
    if (asks[ai].size === 0n) ai++;
  }
}

const cmp = (a: bigint, b: bigint) => (a < b ? -1 : a > b ? 1 : 0);

// Mirror of liquidate().
export function applyLiquidate(
  s0: ExchangeState,
  victim: Address,
  marketId: number,
  liquidator: Address,
): ExchangeState {
  const s = clone(s0);
  const ai = idxAccount(s, victim);
  if (ai < 0) return s;
  const acc = s.accounts[ai];
  const pi = idxPosition(acc, marketId);
  if (pi < 0) return s;
  const mi = idxMarket(s, marketId);
  const oracle = s.markets[mi].oracle;

  realizeFunding(acc, pi, s.markets);
  const pos = acc.positions[pi];
  acc.collateral += (pos.size * (oracle - pos.avgEntry)) / WAD;

  const notional = (absB(pos.size) * oracle) / WAD;
  const penalty = (notional * LIQUIDATION_PENALTY) / WAD;
  acc.collateral -= penalty;
  s.insuranceFund += penalty;

  if (acc.collateral < 0n) {
    s.insuranceFund += acc.collateral;
    acc.collateral = 0n;
  }

  acc.positions.splice(pi, 1);
  applyDeltaToAccount(ensureAccount(s, liquidator), s.markets, marketId, pos.size, oracle);
  prune(s);
  return s;
}

export function applyEmergencyWithdraw(s0: ExchangeState, owner: Address, amount: bigint): ExchangeState {
  const s = clone(s0);
  const i = idxAccount(s, owner);
  if (i >= 0) s.accounts[i].collateral -= amount;
  prune(s);
  return s;
}

// ------------------------------------------------------------------------------------------------
// Witness — the tuple passed to the contract (named keys matching the ABI components)
// ------------------------------------------------------------------------------------------------

export type Witness = {
  nextOrderId: bigint;
  insuranceFund: bigint;
  accounts: { owner: Address; collateral: bigint; positions: Position[] }[];
  orders: Order[];
  markets: Market[];
};

export function toWitness(s: ExchangeState): Witness {
  return {
    nextOrderId: s.nextOrderId,
    insuranceFund: s.insuranceFund,
    accounts: s.accounts.map((a) => ({
      owner: a.owner,
      collateral: a.collateral,
      positions: a.positions.map((p) => ({ ...p })),
    })),
    orders: s.orders.map((o) => ({ ...o })),
    markets: s.markets.map((m) => ({ ...m })),
  };
}

// ---- (de)serialization for localStorage persistence (bigint-safe) ------------------------------

export function serialize(s: ExchangeState): string {
  return JSON.stringify(s, (_k, v) => (typeof v === "bigint" ? `${v.toString()}n` : v));
}

export function deserialize(str: string): ExchangeState {
  return JSON.parse(str, (_k, v) => (typeof v === "string" && /^-?\d+n$/.test(v) ? BigInt(v.slice(0, -1)) : v));
}
