"use client";

import { useEffect, useState } from "react";

export type ScreenName = "feed" | "markets" | "launch" | "trade" | "perps" | "profile";
export const screenOptions: { id: ScreenName; title: string; note: string }[] = [
  { id: "feed", title: "Home", note: "Feed, discovery & copy trading" },
  { id: "markets", title: "Markets", note: "Tokens & prices" },
  { id: "launch", title: "Launchpad", note: "Discover & create a token" },
  { id: "trade", title: "Swap", note: "Quote & review" },
  { id: "perps", title: "Perps", note: "Chart & order entry" },
  { id: "profile", title: "Portfolio", note: "Balance & holdings" },
];

type Preferences = { accent: string; radius: number; motion: boolean; textScale: number };
const defaults: Preferences = { accent: "#b9f26b", radius: 24, motion: true, textScale: 1 };
const storageKey = "dyorhq-preview-preferences-v1";

export default function PreviewControls({ screen, onScreen }: { screen: ScreenName; onScreen: (screen: ScreenName) => void }) {
  const [open, setOpen] = useState(false);
  const [prefs, setPrefs] = useState(defaults);
  const [ready, setReady] = useState(false);
  useEffect(() => {
    try {
      const stored = JSON.parse(localStorage.getItem(storageKey) ?? "null");
      if (stored) setPrefs({
        accent: /^#[0-9a-f]{6}$/i.test(stored.accent) ? stored.accent : defaults.accent,
        radius: Math.max(8, Math.min(32, Number(stored.radius) || 24)),
        motion: typeof stored.motion === "boolean" ? stored.motion : true,
        textScale: Math.max(1, Math.min(1.2, Number(stored.textScale) || 1)),
      });
    } catch { /* Invalid or unavailable local preferences use the defaults. */ }
    setReady(true);
  }, []);
  useEffect(() => {
    if (!ready) return;
    const root = document.documentElement;
    root.style.setProperty("--preview-accent", prefs.accent);
    root.style.setProperty("--preview-radius", `${prefs.radius}px`);
    root.style.setProperty("--preview-text-scale", String(prefs.textScale));
    root.dataset.previewMotion = prefs.motion ? "on" : "off";
    try { localStorage.setItem(storageKey, JSON.stringify(prefs)); } catch { /* Preview still works without storage. */ }
  }, [prefs, ready]);
  return <>
    <button className="studio-toggle" aria-expanded={open} aria-controls="preview-studio" onClick={() => setOpen(!open)}>{open ? "Close controls ×" : "Edit preview ☷"}</button>
    <aside id="preview-studio" className={`preview-studio ${open ? "is-open" : ""}`}>
      <div className="studio-brand"><img src="/brand/dyorhq-mark.png" alt="" /><div><strong>DyorHQ</strong><small>UI playground</small></div></div>
      <p className="studio-intro">The RWA HQ for social trading<br /><a href="/brand">Explore the brand ↗</a></p>
      <nav aria-label="Preview screens" className="studio-screens">{screenOptions.map((item, i) => <button key={item.id} aria-current={screen === item.id ? "page" : undefined} onClick={() => { onScreen(item.id); setOpen(false); }}><span>0{i + 1}</span><div><b>{item.title}</b><small>{item.note}</small></div><em>↗</em></button>)}</nav>
      <div className="studio-section"><h2>Appearance</h2><label className="studio-color">Accent color<input aria-label="Accent color" type="color" value={prefs.accent} onChange={e => setPrefs({ ...prefs, accent: e.target.value })} /></label>
        <div className="studio-swatches">{[{ color: "#8b5cf6", label: "Monad violet" }, { color: "#34b4f5", label: "Miracle blue" }, { color: "#28bd89", label: "Emerald" }, { color: "#ef8a56", label: "Copper" }].map(x => <button key={x.color} aria-label={x.label} title={x.label} aria-pressed={prefs.accent === x.color} style={{ background: x.color }} onClick={() => setPrefs({ ...prefs, accent: x.color })} />)}</div>
        <label className="studio-range">Corners <output>{prefs.radius}px</output><input aria-label="Corner roundness" type="range" min="8" max="32" value={prefs.radius} onChange={e => setPrefs({ ...prefs, radius: Number(e.target.value) })} /></label>
        <label className="studio-range">Text size <output>{Math.round(prefs.textScale * 100)}%</output><input aria-label="Text size" type="range" min="1" max="1.2" step="0.05" value={prefs.textScale} onChange={e => setPrefs({ ...prefs, textScale: Number(e.target.value) })} /></label>
        <label className="studio-switch">Motion & particles<input type="checkbox" checked={prefs.motion} onChange={e => setPrefs({ ...prefs, motion: e.target.checked })} /></label>
        <button className="studio-reset" onClick={() => setPrefs(defaults)}>Reset appearance</button>
      </div>
      <p className="studio-footnote"><i /> Interactive UI prototype<br /><span>Sample data. No real transactions.<br />Appearance is saved in this browser.</span></p>
    </aside>
  </>;
}
