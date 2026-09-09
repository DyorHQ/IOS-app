"use client";

import { useEffect, useSyncExternalStore } from "react";
import { Wordmark } from "./ui/wordmark";
import { Icon } from "./ui/icons";
import { Range, Seg, Switch, type SegOpt } from "./ui/components";
import * as Glass from "./ui/liquid-glass";

export type ScreenName = "home" | "markets" | "launch" | "trade" | "perps" | "profile";
export const screenOptions: { id: ScreenName; title: string; note: string }[] = [
  { id: "home", title: "Home", note: "Balance, top tokens & feed" },
  { id: "markets", title: "Markets", note: "Tokens & prices" },
  { id: "launch", title: "Launchpad", note: "Discover & create a token" },
  { id: "trade", title: "Swap", note: "Curve quote & review" },
  { id: "perps", title: "Perps", note: "Chart, book & order entry" },
  { id: "profile", title: "Portfolio", note: "Balance, stats & activity" },
];

export type Theme = "system" | "light" | "dark";
export type Preferences = { theme: Theme; textScale: number; glass: number; motion: boolean };
export const DEFAULT_PREFS: Preferences = { theme: "system", textScale: 1, glass: 30, motion: true };
export const THEME_OPTS: SegOpt<Theme>[] = [{ v: "system", l: "System" }, { v: "light", l: "Light", i: "sun" }, { v: "dark", l: "Dark", i: "moon" }];
const storageKey = "dyorhq-preview-preferences-v3";

/* Preferences live in a tiny external store read through useSyncExternalStore: the server and the hydration
   render see the defaults, the first client read hydrates from localStorage, and edits notify subscribers. */
type Snapshot = { prefs: Preferences; ready: boolean };
const serverSnapshot: Snapshot = { prefs: DEFAULT_PREFS, ready: false };
const listeners = new Set<() => void>();
let snapshot: Snapshot | null = null;

function sanitize(s: Partial<Record<keyof Preferences, unknown>>): Preferences {
  return {
    theme: s.theme === "light" || s.theme === "dark" ? s.theme : "system",
    textScale: Math.max(1, Math.min(1.2, Number(s.textScale) || 1)),
    glass: typeof s.glass === "number" && Number.isFinite(s.glass) ? Math.max(0, Math.min(100, s.glass)) : 30,
    motion: typeof s.motion === "boolean" ? s.motion : true,
  };
}
function readStored(): Preferences {
  try {
    const stored = JSON.parse(localStorage.getItem(storageKey) ?? localStorage.getItem("dyorhq-preview-preferences-v2") ?? "null");
    return stored ? sanitize(stored) : DEFAULT_PREFS;
  } catch { return DEFAULT_PREFS; /* Invalid or unavailable local preferences use the defaults. */ }
}
function getSnapshot(): Snapshot { if (!snapshot) snapshot = { prefs: readStored(), ready: true }; return snapshot; }
function getServerSnapshot(): Snapshot { return serverSnapshot; }
function subscribe(listener: () => void) { listeners.add(listener); return () => { listeners.delete(listener); }; }
export function setPrefs(prefs: Preferences) { snapshot = { prefs, ready: true }; listeners.forEach((l) => l()); }
export function usePrefs() { return useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot); }

/* Writes the preferences to the document: theme attribute, CSS variables, motion flag, glass strength. */
export function useApplyPrefs() {
  const { prefs, ready } = usePrefs();
  useEffect(() => {
    if (!ready) return;
    const root = document.documentElement;
    if (prefs.theme === "system") root.removeAttribute("data-theme"); else root.setAttribute("data-theme", prefs.theme);
    // The identity is fixed; only theme and accessibility preferences vary.
    ["--accent", "--accent-ink-light", "--accent-ink-dark", "--accent-fill-js", "--on-accent-js", "--font", "--r-card", "--r-row", "--r-input"].forEach(key => root.style.removeProperty(key));
    root.style.setProperty("--text-scale", String(prefs.textScale));
    root.dataset.motion = prefs.motion ? "on" : "off";
    Glass.setIntensity(prefs.glass);
    try { localStorage.setItem(storageKey, JSON.stringify(prefs)); } catch { /* Preview still works without storage. */ }
  }, [prefs, ready]);
  return { prefs, ready };
}

const noop = () => () => {};
export default function PreviewControls({ screen, onScreen, open, onClose }: { screen: ScreenName; onScreen: (s: ScreenName) => void; open: boolean; onClose: () => void }) {
  const { prefs } = usePrefs();
  const refract = useSyncExternalStore(noop, () => Glass.supported(), () => null);
  const set = (patch: Partial<Preferences>) => setPrefs({ ...prefs, ...patch });
  return (
    <aside className={`studio ${open ? "open" : ""}`} id="preview-studio" aria-label="Preview studio">
      <button type="button" className="studio-close" onClick={onClose} aria-label="Close studio"><Icon name="x" /></button>
      <div className="studio-brand"><Wordmark /><small>The RWA HQ for social trading</small></div>
      <p className="studio-intro">Explore the app in light or dark. Typography and colors follow the DyorHQ design system.</p>
      <a className="studio-system-link" href="/brand">Design system <Icon name="chev-right" /></a>
      <nav aria-label="Preview screens" className="studio-screens">
        {screenOptions.map((item, i) => <button key={item.id} type="button" aria-current={screen === item.id ? "page" : undefined} onClick={() => onScreen(item.id)}><span>0{i + 1}</span><div><b>{item.title}</b><small>{item.note}</small></div><Icon name="chev-right" className="chev" /></button>)}
      </nav>
      <div className="studio-sec"><h2>Appearance</h2>
        <div><span className="lbl">Theme</span><div style={{ marginTop: 8 }}><Seg options={THEME_OPTS} value={prefs.theme} onChange={(v) => set({ theme: v })} small /></div></div>
        <dl className="studio-fonts"><div><dt>Headings</dt><dd>Bodoni Moda</dd></div><div><dt>Interface</dt><dd>Manrope</dd></div><div><dt>Numbers</dt><dd>IBM Plex Mono</dd></div></dl>
        <div><div className="opt"><span className="lbl">Text size</span><output>{Math.round(prefs.textScale * 100)}%</output></div><Range value={prefs.textScale} min={1} max={1.2} step={0.05} onChange={(v) => set({ textScale: v })} label="Text size" /></div>
        <div><div className="opt"><span className="lbl">Liquid glass</span><output>{prefs.glass}%</output></div><Range value={prefs.glass} min={0} max={100} onChange={(v) => set({ glass: v })} label="Glass refraction strength" />
          <p className="studio-note" style={{ marginTop: 6 }}>{refract === null ? "Refraction bends what scrolls under the bars in Chromium browsers." : refract ? "Refraction bends what scrolls under the bars. Other browsers get frosted blur." : "This browser can't refract backdrops, so the glass falls back to frosted blur."}</p></div>
        <div className="opt"><span className="lbl">Motion</span><Switch checked={prefs.motion} onChange={(v) => set({ motion: v })} label="Motion" /></div>
        <button type="button" className="btn secondary sm" style={{ alignSelf: "flex-start" }} onClick={() => setPrefs({ ...DEFAULT_PREFS })}>Reset appearance</button>
      </div>
      <p className="studio-foot">Live on Monad. Every action is a transaction from your wallet. Appearance is saved in this browser.</p>
    </aside>
  );
}
