"use client";
// Shared building blocks: segmented control, chips, coins, rows, empty states, switches, ranges.
import type { ButtonHTMLAttributes, CSSProperties, ReactNode } from "react";
import { Icon, type IconName } from "./icons";
import { TONES, fmtPct, fmtUSD, type Token, type Tone } from "./data";

export const cssVars = (o: Record<string, string | number>) => o as CSSProperties;

export function Button({ variant = "primary", size = "regular", busy = false, className = "", children, disabled, ...props }: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: "primary" | "secondary" | "ghost" | "tone-up" | "tone-down"; size?: "regular" | "sm" | "big"; busy?: boolean }) {
  return <button type="button" {...props} className={`btn ${variant} ${size === "regular" ? "" : size} ${className}`} disabled={disabled || busy} aria-busy={busy || undefined}>{children}</button>;
}

export type SegOpt<T extends string> = { v: T; l: string; i?: IconName };
export const opts = <T extends string>(vals: readonly T[]): SegOpt<T>[] => vals.map((v) => ({ v, l: v }));
export function Seg<T extends string>({ options, value, onChange, tone = "", small = false, className = "", label = "Options" }: { options: SegOpt<T>[]; value: T; onChange: (v: T) => void; tone?: "" | "dir"; small?: boolean; className?: string; label?: string }) {
  const i = Math.max(0, options.findIndex((o) => o.v === value));
  const toneCls = tone === "dir" ? (i === 0 ? "tone-up" : "tone-down") : "";
  return (
    <div className={`seg ${toneCls} ${small ? "small" : ""} ${className}`} role="group" aria-label={label} style={cssVars({ "--n": options.length })}>
      <span className="seg-thumb" style={cssVars({ "--i": i })} />
      {options.map((o) => <button key={o.v} type="button" aria-pressed={o.v === value} onClick={() => onChange(o.v)}>{o.i && <Icon name={o.i} />}{o.l}</button>)}
    </div>
  );
}

export const Chip = ({ chg }: { chg: number }) => <span className={`chip ${chg >= 0 ? "up" : "down"}`}>{fmtPct(chg)}</span>;

export function Coin({ sym, tone, size = "" }: { sym: string; tone: Tone; size?: "" | "lg" | "sm" }) {
  return <span className={`coin ${size}`} style={{ background: TONES[tone] }} aria-hidden="true">{sym.replace(/^a/, "")[0].toUpperCase()}</span>;
}

export function TokenRow({ t, i, badge = false, onClick }: { t: Token; i: number; badge?: boolean; onClick: () => void }) {
  return (
    <button type="button" className="row" onClick={onClick}>
      <span className="rank">{i + 1}</span><Coin sym={t.sym} tone={t.tone} />
      <span className="row-main"><b>{t.sym}{badge && t.perp && <em className="badge">PERP</em>}{t.rwa && <em className="badge accent">RWA</em>}</b><small>{t.name}</small></span>
      <span className="row-end"><span className="price">{fmtUSD(t.price)}</span><Chip chg={t.chg} /></span>
    </button>
  );
}

export const Empty = ({ icon, title, text }: { icon: IconName; title: string; text: string }) => (
  <div className="empty"><span className="glyph"><Icon name={icon} /></span><b>{title}</b><p>{text}</p></div>
);

export function Subtabs<T extends string>({ options, value, onChange }: { options: readonly T[]; value: T; onChange: (v: T) => void }) {
  return <div className="subtabs" role="tablist">{options.map((o) => <button key={o} type="button" role="tab" aria-selected={o === value} onClick={() => onChange(o)}>{o}</button>)}</div>;
}

export const Switch = ({ checked, onChange, label }: { checked: boolean; onChange: (v: boolean) => void; label: string }) => (
  <button type="button" className="switch" role="switch" aria-checked={checked} aria-label={label} onClick={() => onChange(!checked)} />
);

export function Range({ value, min, max, step = 1, onChange, label, id }: { value: number; min: number; max: number; step?: number; onChange: (v: number) => void; label: string; id?: string }) {
  const pct = ((value - min) / (max - min)) * 100;
  return <input type="range" className="range" id={id} min={min} max={max} step={step} value={value} style={cssVars({ "--pct": `${pct}%` })} aria-label={label} onChange={(e) => onChange(Number(e.target.value))} />;
}

export const Section = ({ title, action, children }: { title: string; action?: ReactNode; children?: ReactNode }) => (
  <div className="sec"><h2>{title}</h2>{action}{children}</div>
);
export const Link = ({ onClick, children }: { onClick: () => void; children: ReactNode }) => (
  <button type="button" className="link" onClick={onClick}>{children}</button>
);
