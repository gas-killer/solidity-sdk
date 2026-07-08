import { useStore } from "../store";
import { Card } from "./ui";

export function ActivityLog() {
  const { log } = useStore();
  return (
    <Card title="Activity" subtitle="transactions submitted by the operator console">
      {log.length === 0 ? (
        <div className="rounded-lg bg-neutral-50 px-3 py-4 text-center text-sm text-neutral-400">No activity yet</div>
      ) : (
        <ul className="gk-scroll max-h-72 space-y-1 overflow-y-auto">
          {log.map((e, i) => (
            <li key={i} className="flex items-start gap-2 rounded-lg px-2 py-1.5 text-sm hover:bg-neutral-50">
              <span className={e.ok ? "text-emerald-600" : "text-red-600"}>{e.ok ? "✓" : "✗"}</span>
              <div className="min-w-0 flex-1">
                <div className="truncate text-neutral-700">{e.label}</div>
                {e.msg && <div className="truncate text-xs text-red-500">{e.msg}</div>}
                {e.hash && <div className="truncate font-mono text-[11px] text-neutral-400">{e.hash}</div>}
              </div>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}
