"use client";

import { useEffect, useState, type ReactNode } from "react";
import { encodeFunctionData, erc20Abi, formatUnits, getAddress, isAddress, type Address } from "viem";
import { Icon, Sprite, type IconName } from "./ui/icons";
import { Seg, cssVars, type SegOpt } from "./ui/components";
import type { Preset, SheetName, Tab, TradeMode } from "./ui/nav";
import { HomeScreen, LaunchScreen, MarketsScreen, ProfileScreen, SwapScreen } from "./ui/screens";
import PerpsScreen from "./perps-screen";
import PreviewControls, { THEME_OPTS, setPrefs, useApplyPrefs, type ScreenName } from "./preview-controls";
import * as Glass from "./ui/liquid-glass";
import { Wordmark } from "./ui/wordmark";
import { useWallet } from "./lib/wallet";
import { useMarkets } from "./lib/app-data";
import { DEPLOYED, EXPLORER, explorerAddress, publicClient } from "./lib/chain";
import { fetchLaunchpadActivity } from "./lib/launchpad/events";
import { useAsync, useNow } from "./lib/use-async";
import { useTx } from "./lib/use-tx";
import { waitFor } from "./lib/use-tx";
import { fmtUnits, parseAmount, shortAddress, timeAgo } from "./lib/format";
import { checkRecipient } from "./lib/send-checks";
import { TxStatus } from "./launchpad/ui";
import "./launchpad/launchpad.css";

const TABS: [Tab, IconName, string][] = [["home", "home", "Home"], ["markets", "markets", "Markets"], ["launch", "rocket", "Launch"], ["trade", "trade", "Trade"], ["profile", "profile", "Profile"]];
const MODE_OPTS: SegOpt<TradeMode>[] = [{ v: "swap", l: "Swap" }, { v: "perps", l: "Perps" }];
const MENU_ITEMS: [IconName, string, Tab, TradeMode | undefined][] = [["home", "Home", "home", undefined], ["markets", "Markets", "markets", undefined], ["rocket", "Launchpad", "launch", undefined], ["swap", "Swap", "trade", "swap"], ["trend-up", "Perps", "trade", "perps"], ["profile", "Portfolio", "profile", undefined]];
const isPhone = () => matchMedia("(max-width:759px)").matches;

export default function Home() {
  const [tab, setTab] = useState<Tab>("home");
  const [mode, setMode] = useState<TradeMode>("swap");
  const [preset, setPreset] = useState<Preset | undefined>(undefined);
  const [nav, setNav] = useState(0);
  const [menu, setMenu] = useState(false);
  const [studioOpen, setStudioOpen] = useState(false);
  const [sheet, setSheet] = useState<SheetName | null>(null);
  const [searchFocus, setSearchFocus] = useState(false);
  const [toastMsg, setToastMsg] = useState<{ text: ReactNode; show: boolean; n: number } | null>(null);
  const { prefs } = useApplyPrefs();
  const wallet = useWallet();
  const account = wallet.account;

  const go = (t: Tab, m?: TradeMode, p?: Preset) => { if (m) setMode(m); setTab(t); setPreset(p); setNav((n) => n + 1); setMenu(false); setStudioOpen(false); setSheet(null); setSearchFocus(false); };
  const toast = (text: ReactNode) => setToastMsg((m) => ({ text, show: true, n: (m?.n ?? 0) + 1 }));
  const openStudio = () => { setMenu(false); if (isPhone()) setStudioOpen(true); else toast("Appearance controls are in the studio panel"); };
  const openSheet = (s: SheetName) => { setMenu(false); setSheet(s); };
  const onAvatar = () => {
    if (account) { setMenu(true); return; }
    if (wallet.wallets.length === 1) void wallet.connect(wallet.wallets[0].info.rdns);
    else openSheet("wallets");
  };

  useEffect(() => {
    if (!toastMsg?.show) return;
    const id = setTimeout(() => setToastMsg((m) => (m ? { ...m, show: false } : m)), 2400);
    return () => clearTimeout(id);
  }, [toastMsg]);
  useEffect(() => { Glass.cleanup(); Glass.scan(document); }, [tab, mode]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key !== "Escape") return; if (sheet) setSheet(null); else if (menu) setMenu(false); else if (studioOpen) setStudioOpen(false); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [sheet, menu, studioOpen]);

  const studioScreen: ScreenName = tab === "trade" ? (mode === "perps" ? "perps" : "trade") : tab;
  const onStudioScreen = (s: ScreenName) => { if (s === "perps") go("trade", "perps"); else if (s === "trade") go("trade", "swap"); else go(s); };
  const tabIndex = TABS.findIndex((t) => t[0] === tab);
  const screenKey = `${tab === "trade" ? `trade-${mode}` : tab}-${nav}`;
  const initials = account ? account.slice(2, 4).toUpperCase() : null;

  const menuBtn = <button type="button" className="circ glass" data-glass="circ" onClick={() => setMenu(true)} aria-label="Open menu"><Icon name="menu" /></button>;
  const avatar = <button type="button" className={`avatar ${account ? "" : "empty"}`} onClick={onAvatar} aria-label={account ? "Wallet menu" : "Connect wallet"} title={account ? shortAddress(account) : "Connect wallet"}>{initials ?? <Icon name="wallet" />}</button>;
  const circ = (icon: IconName, label: string, onClick: () => void) => <button type="button" className="circ glass" data-glass="circ" onClick={onClick} aria-label={label}><Icon name={icon} /></button>;
  const topbar = tab === "markets" ? <>{menuBtn}<h1 className="bar-title">Markets</h1>{avatar}</>
    : tab === "launch" ? <>{menuBtn}<h1 className="bar-title">Launchpad</h1>{circ("bell", "Activity", () => openSheet("activity"))}</>
    : tab === "trade" ? <>{menuBtn}<div className="bar-seg glass" data-glass="pill"><Seg label="Trade mode" options={MODE_OPTS} value={mode} onChange={(m) => { setMode(m); setNav((n) => n + 1); }} /></div>{avatar}</>
    : tab === "profile" ? <>{menuBtn}<h1 className="bar-title">Portfolio</h1>{circ("sliders", "Preview studio", openStudio)}</>
    : <>{menuBtn}<button type="button" className="search glass" data-glass="pill" onClick={() => { setSearchFocus(true); setTab("markets"); setNav((n) => n + 1); }}><Icon name="search" /><span>Search tokens</span></button>{avatar}</>;

  return (
    <>
      <Sprite />
      <div className="stage">
        <PreviewControls screen={studioScreen} onScreen={onStudioScreen} open={studioOpen} onClose={() => setStudioOpen(false)} />
        <div className="device">
          <div className="edge">
            <div className="status" aria-hidden="true"><span className="num">9:41</span><span className="island" /><span className="sys"><Icon name="signal" /><Icon name="wifi" /><span className="battery" /></span></div>
            <div className="app-scroll" key={screenKey}>
              {tab === "home" && <HomeScreen go={go} toast={toast} openSheet={openSheet} />}
              {tab === "markets" && <MarketsScreen go={go} preset={preset} autoFocus={searchFocus} />}
              {tab === "launch" && <LaunchScreen go={go} toast={toast} preset={preset} />}
              {tab === "trade" && mode === "swap" && <SwapScreen preset={preset} />}
              {tab === "trade" && mode === "perps" && <PerpsScreen toast={toast} go={go} preset={preset} />}
              {tab === "profile" && <ProfileScreen go={go} toast={toast} openSheet={openSheet} />}
            </div>
            <div className="scrim" aria-hidden="true" />
            <div className="topbar">{topbar}</div>
            <nav className="tabbar glass" aria-label="Primary" data-glass="bar">
              <span className="tab-thumb" style={cssVars({ "--i": tabIndex })} aria-hidden="true" />
              {TABS.map(([id, icon, label]) => <button key={id} type="button" className={`tab${id === tab ? " active" : ""}`} aria-current={id === tab ? "page" : undefined} onClick={() => go(id)}><Icon name={icon} /><small>{label}</small></button>)}
            </nav>
            <div className={`menu ${menu ? "open" : ""}`} inert={!menu}>
              <div className="backdrop" onClick={() => setMenu(false)} />
              <aside aria-label="Menu">
                <div className="brandrow"><div className="wordmark"><Wordmark /><small>The RWA HQ for social trading</small></div><button type="button" className="circ" onClick={() => setMenu(false)} aria-label="Close menu"><Icon name="x" /></button></div>
                {account ? (
                  <button type="button" className="usercard" onClick={() => go("profile")}><span className="avatar">{initials}</span><div style={{ flex: 1, minWidth: 0 }}><b>{wallet.active?.info.name ?? "Wallet"}</b><small>{shortAddress(account, 6)}{wallet.onMonad ? " · Monad" : " · wrong network"}</small></div><Icon name="chev-right" className="chev" /></button>
                ) : (
                  <button type="button" className="usercard" onClick={() => { setMenu(false); onAvatar(); }}><span className="avatar"><Icon name="wallet" /></span><div style={{ flex: 1, minWidth: 0 }}><b>Connect wallet</b><small>{wallet.wallets.length ? `${wallet.wallets.length} wallet${wallet.wallets.length === 1 ? "" : "s"} detected` : "No wallet detected"}</small></div><Icon name="chev-right" className="chev" /></button>
                )}
                <nav>{MENU_ITEMS.map(([icon, label, t, m]) => <button key={label} type="button" onClick={() => go(t, m)}><Icon name={icon} /><span>{label}</span><Icon name="chev-right" className="chev" /></button>)}</nav>
                <div className="menu-sec"><span className="label">Appearance</span><Seg label="Appearance" options={THEME_OPTS} value={prefs.theme} onChange={(v) => setPrefs({ ...prefs, theme: v })} small /></div>
                <div className="menu-sec"><nav>
                  <button type="button" onClick={openStudio}><Icon name="sliders" /><span>Preview studio</span><Icon name="chev-right" className="chev" /></button>
                  <button type="button" onClick={() => openSheet("help")}><Icon name="help" /><span>Help &amp; links</span><Icon name="chev-right" className="chev" /></button>
                  {account && <button type="button" onClick={() => { wallet.disconnect(); setMenu(false); toast("Wallet disconnected"); }}><Icon name="logout" /><span>Disconnect</span></button>}
                </nav></div>
              </aside>
            </div>
            <div className={`sheet ${sheet ? "open" : ""}`} inert={!sheet}>
              <div className="backdrop" onClick={() => setSheet(null)} />
              <div className="panel" role="dialog" aria-modal="true" aria-label={sheet ?? "Sheet"}>
                {sheet === "receive" && <ReceiveSheet onClose={() => setSheet(null)} />}
                {sheet === "send" && <SendSheet onClose={() => setSheet(null)} toast={toast} />}
                {sheet === "activity" && <ActivitySheet onClose={() => setSheet(null)} />}
                {sheet === "wallets" && <WalletsSheet onClose={() => setSheet(null)} />}
                {sheet === "help" && <HelpSheet onClose={() => setSheet(null)} />}
              </div>
            </div>
            <div className={`toast glass ${toastMsg?.show ? "show" : ""}`} role="status" aria-live="polite" data-glass="pill">{toastMsg?.text}</div>
          </div>
        </div>
      </div>
    </>
  );
}

function SheetHead({ title, onClose }: { title: string; onClose: () => void }) {
  return <div className="hd"><h2 style={{ margin: 0 }}>{title}</h2><button type="button" className="circ" onClick={onClose} aria-label="Close"><Icon name="x" /></button></div>;
}

function ReceiveSheet({ onClose }: { onClose: () => void }) {
  const wallet = useWallet();
  const [copied, setCopied] = useState(false);
  if (!wallet.account) return <><SheetHead title="Receive" onClose={onClose} /><p className="hint">Connect a wallet first.</p></>;
  const address = wallet.account;
  return (
    <>
      <SheetHead title="Receive on Monad" onClose={onClose} />
      <p className="hint" style={{ marginBottom: 10 }}>Send MON or any Monad token to this address. Only use the Monad network (chain id 143).</p>
      <div className="addr-box">{address}</div>
      <div className="flow-actions"><button type="button" className="btn primary" onClick={() => { navigator.clipboard?.writeText(address).then(() => setCopied(true)); }}>{copied ? "Copied" : "Copy address"}</button><a className="btn secondary" href={explorerAddress(address)} target="_blank" rel="noreferrer">Monadscan <Icon name="arrow-ur" /></a></div>
    </>
  );
}

function SendSheet({ onClose, toast }: { onClose: () => void; toast: (t: ReactNode) => void }) {
  const wallet = useWallet();
  const markets = useMarkets(wallet.account);
  const owned = markets.rows.filter((r) => r.balance > 0n);
  const [token, setToken] = useState<string>("0x0000000000000000000000000000000000000000");
  const [to, setTo] = useState("");
  const [amount, setAmount] = useState("");
  const [confirmedContract, setConfirmedContract] = useState<string | null>(null);
  const { tx, run, dismiss, busy } = useTx();
  const row = markets.rows.find((r) => r.address.toLowerCase() === token.toLowerCase()) ?? owned[0];
  const parsed = row ? parseAmount(amount, row.decimals) : null;
  const recipient = to.trim();
  // The recipient's bytecode: a contract recipient must be confirmed (app/lib/send-checks.ts).
  const code = useAsync(async () => (isAddress(recipient) ? (await publicClient.getCode({ address: recipient })) ?? "0x" : null), `code:${recipient}`);
  const check = row ? checkRecipient(recipient, row, wallet.account, code.loading ? null : code.data ?? undefined) : null;
  const unconfirmed = !!check?.contract && confirmedContract !== recipient;
  // Why Send is disabled, in the order the user fills the form.
  const reason = !markets.balancesReady ? (markets.balancesError ? "Couldn't read your balances. Retrying…" : "Reading your balances…")
    : !row ? "This wallet holds nothing to send yet."
    : !recipient ? "Enter the recipient's address."
    : check?.block ? null // shown under the address
    : !amount.trim() ? "Enter an amount."
    : parsed === null ? "Enter the amount as a plain number, like 2.5."
    : parsed === 0n ? "Enter an amount above zero."
    : parsed > row.balance ? `That is more than your ${row.symbol} balance.`
    : code.loading ? "Checking the address…"
    : unconfirmed ? "Confirm the contract recipient first."
    : null;
  const valid = !!row && !!parsed && !check?.block && reason === null;
  const send = async () => {
    const client = wallet.client;
    if (!client || !row || !parsed || !valid || !isAddress(recipient)) return;
    const shown = formatUnits(parsed, row.decimals); // what is signed, not what was typed
    const done = await run(`Send ${shown} ${row.symbol}`, async (onSent) => {
      const hash = row.native
        ? await client.sendTransaction({ account: client.account, chain: client.chain, to: getAddress(recipient), value: parsed })
        : await client.sendTransaction({ account: client.account, chain: client.chain, to: row.address, data: encodeFunctionData({ abi: erc20Abi, functionName: "transfer", args: [getAddress(recipient), parsed] }) });
      onSent(hash);
      await waitFor(hash);
      return hash;
    });
    if (done) { toast(`Sent ${shown} ${row.symbol}`); markets.refresh(); setAmount(""); }
  };
  if (!wallet.account) return <><SheetHead title="Send" onClose={onClose} /><p className="hint">Connect a wallet first.</p></>;
  return (
    <>
      <SheetHead title="Send" onClose={onClose} />
      <label className="field">Asset<select className="select" value={row?.address ?? token} onChange={(e) => setToken(e.target.value)}>{owned.map((r) => <option key={r.address} value={r.address}>{r.symbol} · {fmtUnits(r.balance, r.decimals, { compact: true })}</option>)}{owned.length === 0 && <option value="">{markets.balancesReady ? "No balances" : markets.balancesError ? "Couldn't read balances" : "Reading balances…"}</option>}</select></label>
      <label className="field">To address<input placeholder="0x…" value={to} onChange={(e) => setTo(e.target.value)} />{recipient && check?.block && <span className="hint err">{check.block}</span>}{code.error && <span className="help">Couldn&apos;t check whether this address is a contract.</span>}</label>
      {check?.warn && (
        <div className="warnbox">
          {check.warn}
          {check.contract && row && <label style={{ display: "flex", gap: 8, alignItems: "center", marginTop: 8 }}><input type="checkbox" checked={confirmedContract === recipient} onChange={(e) => setConfirmedContract(e.target.checked ? recipient : null)} />I know this contract can receive {row.symbol}.</label>}
        </div>
      )}
      <label className="field">Amount<input inputMode="decimal" placeholder="0" value={amount} onChange={(e) => setAmount(e.target.value)} />{row && <span className="help">{markets.balancesReady ? `Balance ${fmtUnits(row.balance, row.decimals)} ${row.symbol}` : markets.balancesError ? "Couldn't read your balance" : "Reading balance…"}</span>}</label>
      <TxStatus tx={tx} onDismiss={dismiss} />
      {wallet.onMonad && reason && <p className="hint">{reason}</p>}
      <button type="button" className="btn primary big" disabled={!valid || busy || !wallet.onMonad} onClick={send}>{wallet.onMonad ? `Send ${row?.symbol ?? ""}` : "Switch to Monad first"}</button>
    </>
  );
}

function ActivitySheet({ onClose }: { onClose: () => void }) {
  const wallet = useWallet();
  const markets = useMarkets(wallet.account);
  const now = useNow();
  const curves = new Map(markets.launches.map((l) => [l.curve.toLowerCase(), l.token as Address]));
  const activity = useAsync(async () => (DEPLOYED ? fetchLaunchpadActivity(curves, 18_000n) : []), `activity-sheet:${markets.launches.length}`, 30_000);
  const launchOf = (token: Address | null) => markets.launches.find((l) => token && l.token.toLowerCase() === token.toLowerCase());
  const symbol = (token: Address | null) => launchOf(token)?.symbol ?? (token ? shortAddress(token) : "token");
  // A curve trade's amount is in the launch's pair asset, with that asset's decimals.
  const tradeAmount = (token: Address | null, quote: bigint) => { const pair = launchOf(token)?.pair; return pair ? `${fmtUnits(quote, pair.decimals, { compact: true })} ${pair.symbol}` : ""; };
  return (
    <>
      <SheetHead title="On-chain activity" onClose={onClose} />
      {!DEPLOYED && <p className="hint">The launchpad contracts are not deployed on this network yet; activity appears once they are.</p>}
      {activity.loading && !activity.data && <p className="hint">Reading the last two hours of blocks…</p>}
      <div style={{ maxHeight: 360, overflow: "auto" }}>
        {(activity.data ?? []).slice(0, 60).map((a) => (
          <a key={a.tx + a.kind + a.block} className="act-row" href={`${EXPLORER}/tx/${a.tx}`} target="_blank" rel="noreferrer" style={{ textDecoration: "none", color: "inherit" }}>
            <Icon name={a.kind === "launch" ? "rocket" : a.kind === "graduated" ? "graduate" : a.side === "buy" ? "trend-up" : "trend-down"} />
            <span className="row-main"><b>{a.kind === "launch" ? `Launched $${symbol(a.token)}` : a.kind === "graduated" ? `$${symbol(a.token)} graduated` : `${a.side === "buy" ? "Bought" : "Sold"} $${symbol(a.token)}`}</b><small>{now ? timeAgo(a.time, now) : ""}</small></span>
            {a.kind === "trade" && <span className="amt">{tradeAmount(a.token, a.quote)}</span>}
          </a>
        ))}
        {activity.error && <p className="hint err">Couldn&apos;t read recent activity ({activity.error}). Retrying.</p>}
        {activity.data && activity.data.length === 0 && DEPLOYED && !activity.error && <p className="hint">Nothing in the last two hours.</p>}
      </div>
    </>
  );
}

function WalletsSheet({ onClose }: { onClose: () => void }) {
  const wallet = useWallet();
  return (
    <>
      <SheetHead title="Connect a wallet" onClose={onClose} />
      {wallet.wallets.length === 0 && <p className="hint">{wallet.ready ? "No browser wallet found. Install MetaMask, Rabby or Phantom and reload this page." : "Looking for wallets…"}</p>}
      <div className="wallet-list">{wallet.wallets.map((w) => <button key={w.info.rdns} type="button" onClick={() => { onClose(); void wallet.connect(w.info.rdns); }}>{w.info.icon ? <img src={w.info.icon} alt="" /> : <Icon name="wallet" />}{w.info.name}</button>)}</div>
      {wallet.error && <p className="hint err" style={{ marginTop: 8 }}>{wallet.error}</p>}
    </>
  );
}

function HelpSheet({ onClose }: { onClose: () => void }) {
  const links: [string, string, string][] = [
    ["Monadscan", "Explorer for every transaction the app sends", EXPLORER],
    ["Perpl", "The on-chain perps exchange behind the Perps tab", "https://perpl.xyz"],
    ["Kuru Flow", "Aggregated liquidity used by the swap", "https://kuru.io"],
    ["Uniswap on Monad", "v3 and v4 pools used by the swap and launchpad", "https://app.uniswap.org"],
    ["Monday Trade", "Spot pools used by the swap", "https://monday.trade"],
    ["Monad docs", "Network information and RPC endpoints", "https://docs.monad.xyz"],
  ];
  return (
    <>
      <SheetHead title="Help & links" onClose={onClose} />
      <div className="help-links">{links.map(([t, d, href]) => <a key={t} href={href} target="_blank" rel="noreferrer"><span>{t}<br /><small>{d}</small></span><Icon name="arrow-ur" /></a>)}</div>
      <p className="hint" style={{ marginTop: 10 }}>DyorHQ never holds funds. Every action is a transaction from your own wallet on Monad.</p>
    </>
  );
}
