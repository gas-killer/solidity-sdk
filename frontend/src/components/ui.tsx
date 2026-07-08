import { ReactNode, InputHTMLAttributes } from "react";
import { cn } from "@breadcoop/ui";
import { Heading3, Caption } from "@breadcoop/ui";

export function Card({ title, subtitle, children, className, right }: { title?: string; subtitle?: string; children: ReactNode; className?: string; right?: ReactNode }) {
  return (
    <section className={cn("rounded-2xl border border-black/10 bg-white/80 backdrop-blur p-5 shadow-sm", className)}>
      {(title || right) && (
        <div className="mb-3 flex items-start justify-between gap-3">
          <div>
            {title && <Heading3 className="!text-lg">{title}</Heading3>}
            {subtitle && <Caption className="text-neutral-500">{subtitle}</Caption>}
          </div>
          {right}
        </div>
      )}
      {children}
    </section>
  );
}

export function Field({ label, children, hint }: { label: string; children: ReactNode; hint?: string }) {
  return (
    <label className="flex flex-col gap-1">
      <span className="text-xs font-medium uppercase tracking-wide text-neutral-500">{label}</span>
      {children}
      {hint && <span className="text-[11px] text-neutral-400">{hint}</span>}
    </label>
  );
}

export function TextInput(props: InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      {...props}
      className={cn(
        "h-10 rounded-lg border border-black/15 bg-white px-3 text-sm outline-none focus:border-black/40 focus:ring-2 focus:ring-orange-200",
        props.className,
      )}
    />
  );
}

export function StatRow({ label, value, mono, tone }: { label: string; value: ReactNode; mono?: boolean; tone?: "pos" | "neg" | "muted" }) {
  return (
    <div className="flex items-center justify-between py-1 text-sm">
      <span className="text-neutral-500">{label}</span>
      <span className={cn(mono && "font-mono tabular-nums", tone === "pos" && "text-emerald-600", tone === "neg" && "text-red-600", tone === "muted" && "text-neutral-400")}>{value}</span>
    </div>
  );
}

export function Pill({ children, tone = "neutral" }: { children: ReactNode; tone?: "neutral" | "pos" | "neg" | "warn" }) {
  const cls = {
    neutral: "bg-neutral-100 text-neutral-600",
    pos: "bg-emerald-100 text-emerald-700",
    neg: "bg-red-100 text-red-700",
    warn: "bg-amber-100 text-amber-700",
  }[tone];
  return <span className={cn("inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-semibold", cls)}>{children}</span>;
}

export function Th({ children, className }: { children?: ReactNode; className?: string }) {
  return <th className={cn("px-2 py-1.5 text-left text-[11px] font-semibold uppercase tracking-wide text-neutral-400", className)}>{children}</th>;
}

export function Td({ children, className }: { children?: ReactNode; className?: string }) {
  return <td className={cn("px-2 py-1.5 text-sm", className)}>{children}</td>;
}
