import { create } from "zustand";
import { encodeAbiParameters, sha256, toHex, getAbiItem, toFunctionSelector, type Address } from "viem";
import * as E from "./engine/engine";
import { DEV_ACCOUNTS, type DevAccount, vertexAddr, vertexAbi, publicClient } from "./chain";
import { readVertex, readErc20, writeVertex, approveUsdc, increaseTime, errMessage, MAX_UINT } from "./contract";

const LS_KEY = `gkv:state:${vertexAddr()}`;

export type LogEntry = { label: string; ok: boolean; hash?: string; msg?: string };

function loadPersisted(): E.ExchangeState {
  try {
    const raw = localStorage.getItem(LS_KEY);
    if (raw) return E.deserialize(raw);
  } catch {
    /* ignore */
  }
  return E.emptyState();
}

function persist(s: E.ExchangeState) {
  try {
    localStorage.setItem(LS_KEY, E.serialize(s));
  } catch {
    /* ignore */
  }
}

type OnchainReads = {
  onchainHash: bigint | null;
  computedHash: bigint | null;
  synced: boolean;
  transitionCount: bigint;
  lastTransitionAt: bigint;
  stateSlot: `0x${string}` | null;
  usdcBalance: bigint;
  usdcAllowance: bigint;
};

type Store = OnchainReads & {
  state: E.ExchangeState;
  acting: DevAccount;
  busy: boolean;
  error: string | null;
  log: LogEntry[];

  setActing: (a: DevAccount) => void;
  resetLocalState: () => void;
  refresh: () => Promise<void>;

  approve: () => Promise<void>;
  deposit: (amount: bigint) => Promise<void>;
  withdraw: (amount: bigint) => Promise<void>;
  listMarket: (id: number, imf: bigint, mmf: bigint, oracle: bigint) => Promise<void>;
  syncMarket: (id: number, oracle: bigint, fundingDelta: bigint) => Promise<void>;
  placeOrder: (marketId: number, isBid: boolean, price: bigint, size: bigint) => Promise<void>;
  cancelOrder: (id: bigint) => Promise<void>;
  settleEpoch: () => Promise<void>;
  settleViaOperator: () => Promise<void>;
  liquidate: (victim: Address, marketId: number) => Promise<void>;
  warp7Days: () => Promise<void>;
  emergencyWithdraw: (amount: bigint) => Promise<void>;
  seedDemo: () => Promise<void>;
};

export const useStore = create<Store>((set, get) => {
  async function run(label: string, doTx: () => Promise<{ hash: string; blockTime: bigint }>, applyLocal: (bt: bigint) => E.ExchangeState) {
    set({ busy: true, error: null });
    try {
      const { hash, blockTime } = await doTx();
      const next = applyLocal(blockTime);
      set({ state: next });
      persist(next);
      set((s) => ({ log: [{ label, ok: true, hash }, ...s.log].slice(0, 40) }));
      await get().refresh();
    } catch (e) {
      const msg = errMessage(e);
      set((s) => ({ error: msg, log: [{ label, ok: false, msg }, ...s.log].slice(0, 40) }));
    } finally {
      set({ busy: false });
    }
  }

  return {
    state: loadPersisted(),
    acting: DEV_ACCOUNTS[1], // Alice by default
    busy: false,
    error: null,
    log: [],
    onchainHash: null,
    computedHash: null,
    synced: false,
    transitionCount: 0n,
    lastTransitionAt: 0n,
    stateSlot: null,
    usdcBalance: 0n,
    usdcAllowance: 0n,

    setActing: (a) => {
      set({ acting: a });
      void get().refresh();
    },

    resetLocalState: () => {
      const empty = E.emptyState();
      set({ state: empty });
      persist(empty);
      void get().refresh();
    },

    refresh: async () => {
      const { state, acting } = get();
      try {
        const [onchainHash, computedHash, transitionCount, lastTransitionAt, stateSlot, usdcBalance, usdcAllowance] = await Promise.all([
          readVertex<bigint>("stateHash"),
          readVertex<bigint>("computeStateHash", [E.toWitness(state)]),
          readVertex<bigint>("stateTransitionCount"),
          readVertex<bigint>("lastTransitionAt"),
          readVertex<`0x${string}`>("STATE_SLOT"),
          readErc20<bigint>("balanceOf", [acting.address]),
          readErc20<bigint>("allowance", [acting.address, vertexAddr()]),
        ]);
        set({ onchainHash, computedHash, synced: onchainHash === computedHash, transitionCount, lastTransitionAt, stateSlot, usdcBalance, usdcAllowance });
      } catch (e) {
        set({ error: errMessage(e) });
      }
    },

    approve: async () => {
      const { acting } = get();
      set({ busy: true, error: null });
      try {
        const hash = await approveUsdc(acting.pk);
        set((s) => ({ log: [{ label: `approve USDC (${acting.label})`, ok: true, hash }, ...s.log].slice(0, 40) }));
        await get().refresh();
      } catch (e) {
        set({ error: errMessage(e) });
      } finally {
        set({ busy: false });
      }
    },

    deposit: (amount) => {
      const { acting, state } = get();
      return run(
        `${acting.label} deposit ${fmtWad(amount)} USDC`,
        () => writeVertex(acting.pk, acting.address, "deposit", [E.toWitness(state), amount]),
        () => E.applyDeposit(state, acting.address, amount),
      );
    },

    withdraw: (amount) => {
      const { acting, state } = get();
      return run(
        `${acting.label} withdraw ${fmtWad(amount)} USDC`,
        () => writeVertex(acting.pk, acting.address, "withdraw", [E.toWitness(state), amount]),
        () => E.applyWithdraw(state, acting.address, amount),
      );
    },

    listMarket: (id, imf, mmf, oracle) => {
      const { acting, state } = get();
      return run(
        `list market #${id} (oracle ${fmtWad(oracle)})`,
        () => writeVertex(acting.pk, acting.address, "listMarket", [E.toWitness(state), id, imf, mmf, oracle]),
        () => E.applyListMarket(state, id, imf, mmf, oracle),
      );
    },

    syncMarket: (id, oracle, fundingDelta) => {
      const { acting, state } = get();
      return run(
        `sync market #${id} → oracle ${fmtWad(oracle)}, funding ${fmtWad(fundingDelta)}`,
        () => writeVertex(acting.pk, acting.address, "syncMarket", [E.toWitness(state), id, oracle, fundingDelta]),
        () => E.applySyncMarket(state, id, oracle, fundingDelta),
      );
    },

    placeOrder: (marketId, isBid, price, size) => {
      const { acting, state } = get();
      return run(
        `${acting.label} ${isBid ? "bid" : "ask"} ${fmtWad(size)} @ ${fmtWad(price)} (mkt #${marketId})`,
        () => writeVertex(acting.pk, acting.address, "placeOrder", [E.toWitness(state), marketId, isBid, price, size]),
        (bt) => E.applyPlaceOrder(state, acting.address, marketId, isBid, price, size, bt),
      );
    },

    cancelOrder: (id) => {
      const { acting, state } = get();
      return run(
        `${acting.label} cancel order #${id}`,
        () => writeVertex(acting.pk, acting.address, "cancelOrder", [E.toWitness(state), id]),
        () => E.applyCancelOrder(state, id),
      );
    },

    settleEpoch: () => {
      const { acting, state } = get();
      return run(
        `settleEpoch (standalone)`,
        () => writeVertex(acting.pk, acting.address, "settleEpoch", [E.toWitness(state)]),
        () => E.applySettleEpoch(state),
      );
    },

    // The Gas Killer path: run settleEpoch OFF-CHAIN, commit the result as a single BLS-attested STORE.
    settleViaOperator: async () => {
      const { acting, state } = get();
      set({ busy: true, error: null });
      const label = "settleEpoch via operator (verifyAndUpdate → 1 STORE)";
      try {
        const next = E.applySettleEpoch(state);
        const newHash = await readVertex<bigint>("computeStateHash", [E.toWitness(next)]);
        const stateSlot = (get().stateSlot ?? (await readVertex<`0x${string}`>("STATE_SLOT")));

        const now = BigInt(Math.floor(Date.now() / 1000));
        const packed = toHex((newHash << 64n) | now, { size: 32 });
        const store0 = encodeAbiParameters([{ type: "bytes32" }, { type: "bytes32" }], [stateSlot, packed]);
        const storageUpdates = encodeAbiParameters([{ type: "uint8[]" }, { type: "bytes[]" }], [[0], [store0]]);

        const transitionIndex = await readVertex<bigint>("stateTransitionCount");
        const selector = toFunctionSelector(getAbiItem({ abi: vertexAbi, name: "settleEpoch" }) as never);
        const msgHash = sha256(
          encodeAbiParameters(
            [{ type: "uint256" }, { type: "address" }, { type: "bytes4" }, { type: "bytes" }],
            [transitionIndex, vertexAddr(), selector, storageUpdates],
          ),
        );

        const curBlock = await publicClient().getBlockNumber();
        const refBlock = Number(curBlock - 1n);

        const emptySig = {
          nonSignerQuorumBitmapIndices: [],
          nonSignerPubkeys: [],
          quorumApks: [],
          apkG2: { X: [0n, 0n], Y: [0n, 0n] },
          sigma: { X: 0n, Y: 0n },
          quorumApkIndices: [],
          totalStakeIndices: [],
          nonSignerStakeIndices: [],
        };

        const { hash } = await writeVertex(acting.pk, acting.address, "verifyAndUpdate", [
          msgHash,
          "0x00",
          refBlock,
          storageUpdates,
          transitionIndex,
          selector,
          emptySig,
        ]);

        set({ state: next });
        persist(next);
        set((s) => ({ log: [{ label, ok: true, hash }, ...s.log].slice(0, 40) }));
        await get().refresh();
      } catch (e) {
        const msg = errMessage(e);
        set((s) => ({ error: msg, log: [{ label, ok: false, msg }, ...s.log].slice(0, 40) }));
      } finally {
        set({ busy: false });
      }
    },

    liquidate: (victim, marketId) => {
      const { acting, state } = get();
      return run(
        `${acting.label} liquidates ${short(victim)} (mkt #${marketId})`,
        () => writeVertex(acting.pk, acting.address, "liquidate", [E.toWitness(state), victim, marketId]),
        () => E.applyLiquidate(state, victim, marketId, acting.address),
      );
    },

    warp7Days: async () => {
      set({ busy: true, error: null });
      try {
        await increaseTime(7 * 24 * 3600 + 1);
        set((s) => ({ log: [{ label: "⏩ warped chain +7 days", ok: true }, ...s.log].slice(0, 40) }));
        await get().refresh();
      } catch (e) {
        set({ error: errMessage(e) });
      } finally {
        set({ busy: false });
      }
    },

    emergencyWithdraw: (amount) => {
      const { acting, state } = get();
      return run(
        `${acting.label} emergencyWithdraw ${fmtWad(amount)} USDC`,
        () => writeVertex(acting.pk, acting.address, "emergencyWithdraw", [E.toWitness(state), amount]),
        () => E.applyEmergencyWithdraw(state, acting.address, amount),
      );
    },

    // One-click scenario: list an ETH market, fund Alice+Bob, cross a 2-ETH order pair, settle.
    seedDemo: async () => {
      const WAD = E.WAD;
      const by = (label: string) => set({ acting: DEV_ACCOUNTS.find((a) => a.label === label)! });
      const acct = (label: string) => DEV_ACCOUNTS.find((a) => a.label === label)!;
      set({ error: null });
      try {
        by("Deployer");
        if (!get().state.markets.some((m) => m.id === 1)) {
          await get().listMarket(1, 5n * 10n ** 16n, 3n * 10n ** 16n, 3000n * WAD);
        }
        for (const label of ["Alice", "Bob"]) {
          by(label);
          const allow = await readErc20<bigint>("allowance", [acct(label).address, vertexAddr()]);
          if (allow < 1_000_000n * WAD) await get().approve();
          await get().deposit(10_000n * WAD);
        }
        by("Alice");
        await get().placeOrder(1, true, 3000n * WAD, 2n * WAD);
        by("Bob");
        await get().placeOrder(1, false, 3000n * WAD, 2n * WAD);
        by("Deployer");
        await get().settleEpoch();
        by("Alice");
      } catch (e) {
        set({ error: errMessage(e) });
      }
    },
  };
});

export { MAX_UINT };

// ---- formatting helpers (shared) ---------------------------------------------------------------

export function fmtWad(v: bigint, dp = 2): string {
  const neg = v < 0n;
  let x = neg ? -v : v;
  const int = x / E.WAD;
  const frac = ((x % E.WAD) * 10n ** BigInt(dp)) / E.WAD;
  const fracStr = dp > 0 ? "." + frac.toString().padStart(dp, "0") : "";
  return `${neg ? "-" : ""}${int.toString()}${fracStr}`;
}

export function parseWad(s: string): bigint {
  const t = s.trim();
  if (!t) return 0n;
  const neg = t.startsWith("-");
  const [i, f = ""] = (neg ? t.slice(1) : t).split(".");
  const frac = (f + "0".repeat(18)).slice(0, 18);
  const v = BigInt(i || "0") * E.WAD + BigInt(frac || "0");
  return neg ? -v : v;
}

export function short(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}
