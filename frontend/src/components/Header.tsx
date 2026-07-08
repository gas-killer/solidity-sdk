import { Logo, Button, Heading2, Caption, Body } from "@breadcoop/ui";
import { useStore, short } from "../store";
import { DEV_ACCOUNTS } from "../chain";
import { fmtWad } from "../store";
import { Pill } from "./ui";

export function Header() {
  const { acting, setActing, onchainHash, synced, transitionCount, usdcBalance, resetLocalState, busy } = useStore();

  return (
    <header className="sticky top-0 z-10 border-b border-black/10 bg-[#f6f4ef]/90 backdrop-blur">
      <div className="mx-auto flex max-w-[1400px] flex-wrap items-center justify-between gap-3 px-6 py-3">
        <div className="flex items-center gap-3">
          <Logo color="orange" size={34} />
          <div>
            <Heading2 className="!text-xl !leading-none">GasKillerVertex</Heading2>
            <Caption className="text-neutral-500">single-slot cross-margin perp DEX · off-chain operator console</Caption>
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-4">
          {/* commitment status */}
          <div className="flex items-center gap-2 rounded-xl border border-black/10 bg-white px-3 py-1.5">
            <div className="flex flex-col leading-tight">
              <span className="text-[10px] uppercase tracking-wide text-neutral-400">on-chain commitment</span>
              <span className="font-mono text-xs">{onchainHash === null ? "—" : `0x${onchainHash.toString(16).padStart(48, "0").slice(0, 16)}…`}</span>
            </div>
            <div className="mx-1 h-8 w-px bg-black/10" />
            <div className="flex flex-col items-end leading-tight">
              <span className="text-[10px] uppercase tracking-wide text-neutral-400">transition</span>
              <span className="font-mono text-xs">#{transitionCount.toString()}</span>
            </div>
            {synced ? <Pill tone="pos">witness in sync</Pill> : <Pill tone="neg">out of sync</Pill>}
          </div>

          {!synced && (
            <Button variant="light" size="sm" onClick={resetLocalState} disabled={busy}>
              reset local state
            </Button>
          )}

          {/* acting-account selector */}
          <div className="flex items-center gap-2 rounded-xl border border-black/10 bg-white px-3 py-1.5">
            <span className="text-[10px] uppercase tracking-wide text-neutral-400">acting as</span>
            <select
              className="bg-transparent text-sm font-semibold outline-none"
              value={acting.address}
              onChange={(e) => setActing(DEV_ACCOUNTS.find((a) => a.address === e.target.value)!)}
            >
              {DEV_ACCOUNTS.map((a) => (
                <option key={a.address} value={a.address}>
                  {a.label} · {short(a.address)}
                </option>
              ))}
            </select>
            <Body className="!text-sm text-neutral-500">{fmtWad(usdcBalance)} USDC</Body>
          </div>
        </div>
      </div>
    </header>
  );
}
