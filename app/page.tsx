"use client";

import { useEffect, useState, type ReactNode } from "react";
import { Icon, Sprite, type IconName } from "./ui/icons";
import { Seg, cssVars, type SegOpt } from "./ui/components";
import type { Tab, TradeMode } from "./ui/nav";
import { HomeScreen, LaunchScreen, MarketsScreen, ProfileScreen, SwapScreen } from "./ui/screens";
import PerpsScreen, { ReviewSheet, type PerpOrder } from "./perps-screen";
import PreviewControls, { THEME_OPTS, setPrefs, useApplyPrefs, type ScreenName } from "./preview-controls";
import * as Glass from "./ui/liquid-glass";

const TABS: [Tab, IconName, string][] = [["home", "home", "Home"], ["markets", "markets", "Markets"], ["launch", "rocket", "Launch"], ["trade", "trade", "Trade"], ["profile", "profile", "Profile"]];
const MODE_OPTS: SegOpt<TradeMode>[] = [{ v: "swap", l: "Swap" }, { v: "perps", l: "Perps" }];
const MENU_ITEMS: [IconName, string, Tab][] = [["home", "Home", "home"], ["markets", "Markets", "markets"], ["rocket", "Launchpad", "launch"], ["trade", "Trade", "trade"], ["trophy", "Leaderboard", "home"], ["profile", "Portfolio", "profile"]];
const isPhone = () => matchMedia("(max-width:759px)").matches;

export default function Home() {
  const [tab, setTab] = useState<Tab>("home");
  const [mode, setMode] = useState<TradeMode>("swap");
  const [menu, setMenu] = useState(false);
  const [studioOpen, setStudioOpen] = useState(false);
  const [order, setOrder] = useState<PerpOrder | null>(null);
  const [toastMsg, setToastMsg] = useState<{ text: ReactNode; show: boolean; n: number } | null>(null);
  const { prefs } = useApplyPrefs();

  const go = (t: Tab, m?: TradeMode) => { if (m) setMode(m); setTab(t); setMenu(false); setStudioOpen(false); };
  const toast = (text: ReactNode) => setToastMsg((m) => ({ text, show: true, n: (m?.n ?? 0) + 1 }));
  const openStudio = () => { setMenu(false); if (isPhone()) setStudioOpen(true); else toast("Appearance controls are in the studio panel"); };

  useEffect(() => {
    if (!toastMsg?.show) return;
    const id = setTimeout(() => setToastMsg((m) => (m ? { ...m, show: false } : m)), 2400);
    return () => clearTimeout(id);
  }, [toastMsg]);
  useEffect(() => { Glass.cleanup(); Glass.scan(document); }, [tab, mode]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key !== "Escape") return; if (order) setOrder(null); else if (menu) setMenu(false); else if (studioOpen) setStudioOpen(false); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [order, menu, studioOpen]);

  const studioScreen: ScreenName = tab === "trade" ? (mode === "perps" ? "perps" : "trade") : tab;
  const onStudioScreen = (s: ScreenName) => { if (s === "perps") go("trade", "perps"); else if (s === "trade") go("trade", "swap"); else go(s); };
  const tabIndex = TABS.findIndex((t) => t[0] === tab);
  const screenKey = tab === "trade" ? `trade-${mode}` : tab;

  const menuBtn = <button type="button" className="circ glass" data-glass="circ" onClick={() => setMenu(true)} aria-label="Open menu"><Icon name="menu" /></button>;
  const avatar = <button type="button" className="avatar" onClick={() => go("profile")} aria-label="Open portfolio">JM</button>;
  const circ = (icon: IconName, label: string, onClick: () => void) => <button type="button" className="circ glass" data-glass="circ" onClick={onClick} aria-label={label}><Icon name={icon} /></button>;
  const topbar = tab === "markets" ? <>{menuBtn}<h1 className="bar-title">Markets</h1>{circ("search", "Search markets", () => toast("Search · sample preview"))}</>
    : tab === "launch" ? <>{menuBtn}<h1 className="bar-title">Launchpad</h1>{circ("bell", "Notifications", () => toast("Notifications · sample preview"))}</>
    : tab === "trade" ? <>{menuBtn}<div className="bar-seg glass" data-glass="pill"><Seg options={MODE_OPTS} value={mode} onChange={setMode} /></div>{avatar}</>
    : tab === "profile" ? <>{menuBtn}<h1 className="bar-title">Portfolio</h1>{circ("sliders", "Preview studio", openStudio)}</>
    : <>{menuBtn}<button type="button" className="search glass" data-glass="pill" onClick={() => toast("Search · sample preview")}><Icon name="search" /><span>Search tokens, traders</span></button>{avatar}</>;

  return (
    <>
      <Sprite />
      <div className="stage">
        <PreviewControls screen={studioScreen} onScreen={onStudioScreen} open={studioOpen} onClose={() => setStudioOpen(false)} />
        <div className="device">
          <div className="edge">
            <div className="status" aria-hidden="true"><span className="num">9:41</span><span className="island" /><span className="sys"><Icon name="signal" /><Icon name="wifi" /><span className="battery" /></span></div>
            <div className="app-scroll" key={screenKey}>
              {tab === "home" && <HomeScreen go={go} toast={toast} />}
              {tab === "markets" && <MarketsScreen go={go} />}
              {tab === "launch" && <LaunchScreen go={go} toast={toast} />}
              {tab === "trade" && mode === "swap" && <SwapScreen go={go} toast={toast} />}
              {tab === "trade" && mode === "perps" && <PerpsScreen toast={toast} onReview={setOrder} />}
              {tab === "profile" && <ProfileScreen go={go} toast={toast} />}
            </div>
            <div className="scrim" aria-hidden="true" />
            <div className="topbar">{topbar}</div>
            <nav className="tabbar glass" aria-label="Primary" data-glass="bar">
              <span className={`tab-thumb ${tab === "launch" ? "hide" : ""}`} style={cssVars({ "--i": tabIndex })} aria-hidden="true" />
              {TABS.map(([id, icon, label]) => <button key={id} type="button" className={`tab${id === tab ? " active" : ""}${id === "launch" ? " launch" : ""}`} aria-current={id === tab ? "page" : undefined} onClick={() => go(id)}>{id === "launch" ? <span className="launch-btn"><Icon name={icon} /></span> : <Icon name={icon} />}<small>{label}</small></button>)}
            </nav>
            <div className={`menu ${menu ? "open" : ""}`} inert={!menu}>
              <div className="backdrop" onClick={() => setMenu(false)} />
              <aside aria-label="Menu">
                <div className="brandrow"><img className="markimg" src="/brand/dyorhq-mark-small.png" alt="" /><div className="wordmark"><b>Dyor<span className="hq">HQ</span></b><small>The RWA HQ for social trading</small></div><button type="button" className="circ" onClick={() => setMenu(false)} aria-label="Close menu"><Icon name="x" /></button></div>
                <div className="usercard"><span className="avatar">JM</span><div style={{ flex: 1, minWidth: 0 }}><b>jerry.main</b><small>0x71F4…9A20</small></div><Icon name="chev-right" className="chev" /></div>
                <nav>{MENU_ITEMS.map(([icon, label, t]) => <button key={label} type="button" onClick={() => go(t)}><Icon name={icon} /><span>{label}</span><Icon name="chev-right" className="chev" /></button>)}</nav>
                <div className="menu-sec"><span className="label">Appearance</span><Seg options={THEME_OPTS} value={prefs.theme} onChange={(v) => setPrefs({ ...prefs, theme: v })} small /></div>
                <div className="menu-sec"><nav>
                  <button type="button" onClick={openStudio}><Icon name="sliders" /><span>Preview studio</span><Icon name="chev-right" className="chev" /></button>
                  <button type="button" onClick={() => toast("Settings · sample preview")}><Icon name="settings" /><span>Settings</span><Icon name="chev-right" className="chev" /></button>
                  <button type="button" onClick={() => toast("Help · sample preview")}><Icon name="help" /><span>Help &amp; feedback</span><Icon name="chev-right" className="chev" /></button>
                  <button type="button" onClick={() => toast("Signed out · sample preview")}><Icon name="logout" /><span>Sign out</span></button>
                </nav></div>
              </aside>
            </div>
            <div className={`sheet ${order ? "open" : ""}`} inert={!order}>
              <div className="backdrop" onClick={() => setOrder(null)} />
              <div className="panel" role="dialog" aria-modal="true" aria-label="Review order">{order && <ReviewSheet order={order} onClose={() => setOrder(null)} onConfirm={() => { toast(`${order.side} ETH · sample order placed`); setOrder(null); }} />}</div>
            </div>
            <div className={`toast glass ${toastMsg?.show ? "show" : ""}`} role="status" aria-live="polite" data-glass="pill">{toastMsg?.text}</div>
          </div>
        </div>
      </div>
    </>
  );
}
