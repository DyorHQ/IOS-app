"use client";
// Home, Markets, Launchpad, Swap, and Portfolio screens. Each keeps its own UI state; navigation goes through `go`.
import { useState } from "react";
import { Icon, type IconName } from "./icons";
import { Chip, Coin, Empty, Range, Seg, Subtabs, Switch, TokenRow, opts, type SegOpt } from "./components";
import { LineChart } from "./charts";
import { ACTIVITY, CASH, FEED, FILTERS, HOLDINGS, JENSEN_PRICE, LAUNCHES, SWAP_BALANCE, TOKENS, TONES, byId, capitalize, compact, filterTokens, fmtNum, fmtPct, holdingsValue, totalBalance, walk, type FeedItem, type Filter, type Launch } from "./data";
import type { Go, Toast } from "./nav";

type ScreenProps = { go: Go; toast: Toast };

function Post({ p, go, toast }: { p: FeedItem } & ScreenProps) {
  return (
    <article className="card post">
      <div className="post-head"><span className="who" style={{ background: TONES[p.tone] }}>{p.initials}</span><span className="row-main"><b>{p.user}</b><small><span className="verified"><Icon name="check" /></span> {p.badge}</small></span><time className="num">{p.time}</time><button type="button" className="circ" style={{ width: 36, height: 36 }} onClick={() => toast("More · sample preview")} aria-label="More options"><Icon name="more" /></button></div>
      <div className="post-line"><span className="verb">{p.verb}</span><span>{p.token}</span><span className="amt">{p.amount}</span></div>
      <p>“{p.thesis}”</p>
      <div className="spark"><LineChart values={walk(p.seed, 22, 0.15)} color="var(--up)" w={300} h={56} /></div>
      <div className="post-meta"><span>Trade return <b className="up">{fmtPct(p.ret)}</b></span><span>{p.copies} copied</span></div>
      <div className="post-actions"><button type="button" className="iconbtn" onClick={() => toast("Liked · sample preview")}><Icon name="heart" /><span className="num">{p.likes}</span></button><button type="button" className="iconbtn" onClick={() => toast("Replies · sample preview")}><Icon name="comment" /><span className="num">{p.replies}</span></button><button type="button" className="btn primary sm" onClick={() => go("trade", "swap")}>Copy trade <Icon name="arrow-ur" /></button></div>
    </article>
  );
}

const ACTIONS: [IconName, string][] = [["deposit", "Deposit"], ["withdraw", "Withdraw"], ["send", "Send"]];
export function HomeScreen({ go, toast }: ScreenProps) {
  const [filter, setFilter] = useState<Filter>("Popular");
  const total = totalBalance(), inUse = holdingsValue();
  const list = filterTokens(TOKENS, filter).slice(0, 7);
  return (
    <main className="screen" data-screen="home">
      <section className="balance">
        <div><span className="label">Portfolio</span><div className="hero-num">${fmtNum(total)}</div><div className="delta up"><span>+$1,284.20</span><span className="chip up"><Icon name="trend-up" />11.1%</span></div></div>
        <div className="balance-side"><div><span className="label">24h volume</span><div className="val">$842.6M</div></div><button type="button" className="net" onClick={() => toast("Network · Monad mainnet")}><i>M</i>Monad <Icon name="chev-down" /></button></div>
      </section>
      <section className="kv"><div><span className="label">Available</span><b>${fmtNum(CASH)}</b></div><div><span className="label">In use</span><b className="up">${fmtNum(inUse)}</b></div></section>
      <section className="actions">{ACTIONS.map(([icon, label]) => <button key={label} type="button" className="action" onClick={() => toast(`${label} · sample preview`)}><Icon name={icon} />{label}</button>)}</section>
      <div className="sec"><h2>Top tokens</h2><button type="button" className="link" onClick={() => go("markets")}>See all <Icon name="chev-right" /></button></div>
      <Seg options={FILTERS} value={filter} onChange={setFilter} small />
      <section className="list" style={{ marginTop: 4 }}>{list.map((t, i) => <TokenRow key={t.sym} t={t} i={i} onClick={() => go("trade", "swap")} />)}</section>
      <div className="sec"><h2>Feed</h2><button type="button" className="link" onClick={() => toast("Following · sample preview")}>Following <Icon name="chev-down" /></button></div>
      <section className="feed">{FEED.map((p) => <Post key={p.user} p={p} go={go} toast={toast} />)}</section>
    </main>
  );
}

const SEGS = ["All", "Spot", "Perps"] as const;
export function MarketsScreen({ go }: { go: Go }) {
  const [seg, setSeg] = useState<(typeof SEGS)[number]>("All");
  const [filter, setFilter] = useState<Filter>("Popular");
  const list = filterTokens(TOKENS.filter((t) => seg !== "Perps" || t.perp), filter);
  return (
    <main className="screen" data-screen="markets">
      <Seg options={opts(SEGS)} value={seg} onChange={setSeg} />
      <div style={{ marginTop: 10 }}><Seg options={FILTERS} value={filter} onChange={setFilter} small /></div>
      <div className="meta-row"><span>{list.length} markets</span><span className="live"><i />Live</span></div>
      <section className="list">{list.map((t, i) => <TokenRow key={t.sym} t={t} i={i} badge={seg !== "Spot"} onClick={() => go("trade", "swap")} />)}</section>
    </main>
  );
}

function LaunchCard({ x, go }: { x: Launch; go: Go }) {
  return (
    <article className="card launch-card">
      <div className="launch-top"><Coin sym={x.name} tone={x.tone} size="lg" /><div style={{ flex: 1, minWidth: 0 }}><h3>${x.name}</h3><p>paired with <b>{x.pair}</b></p></div><Chip chg={x.chg} /></div>
      <div className="trust"><em className="badge accent">Stock-backed</em><em className="badge">LP locks</em></div>
      <div className="progress-label"><span>Graduation progress</span><b>{x.progress}%</b></div>
      <div className="progress"><i style={{ width: `${x.progress}%` }} /></div>
      <div className="launch-stats"><span>Market cap<b>${compact(x.cap)}</b></span><span>Holders<b>{fmtNum(x.holders, 0)}</b></span><button type="button" className="btn secondary sm" onClick={() => go("trade", "swap")}>View</button></div>
    </article>
  );
}

const PAIRS = ["aNVDA", "aTSLA", "aAAPL", "MON"];
const TITLES = ["Make it memorable.", "Choose the market.", "Ready to launch."];
function CreateFlow({ step, setStep, pair, setPair, toast }: { step: number; setStep: (n: number) => void; pair: string; setPair: (p: string) => void; toast: Toast }) {
  return (
    <>
      <div className="step-head"><div><span className="eyebrow">Step {step} of 3</span><h1>{TITLES[step - 1]}</h1></div><span className="ring num">{step}/3</span></div>
      {step === 1 && (
        <div className="card form">
          <div className="field"><span>Token artwork</span><button type="button" className="upload" onClick={() => toast("Image picker · sample preview")}><Icon name="plus" /><b>Add image</b><small>PNG or JPG · up to 5 MB</small></button></div>
          <label className="field">Token name<input defaultValue="Jensen's Jacket" /></label>
          <label className="field">Ticker<div className="prefix"><span>$</span><input defaultValue="JENSEN" /></div></label>
          <label className="field">Launch thesis<textarea defaultValue="Blackwell demand keeps surprising. A meme for everyone betting on the AI supercycle." /></label>
        </div>
      )}
      {step === 2 && (
        <div className="card form">
          <div><b style={{ fontSize: 16 }}>Pairing asset</b><p className="hint" style={{ marginTop: 4 }}>Your bonding curve collects this asset. At graduation both move into locked liquidity.</p></div>
          <div className="pair-grid">{PAIRS.map((x) => { const t = byId[x]; return <button key={x} type="button" aria-pressed={pair === x} onClick={() => setPair(x)}><Coin sym={x} tone={t ? t.tone : "eth"} /><span><b>{x}</b><small>{x === "MON" ? "Monad" : "Tokenized stock"}</small></span><span className="tick"><Icon name="check" /></span></button>; })}</div>
          <div className="note"><b>Market-aware launch</b><p>Stock-backed trading follows US market sessions. The latest oracle price is shown and closed markets are marked.</p></div>
        </div>
      )}
      {step === 3 && (
        <div className="card form review">
          <div className="launch-top" style={{ paddingBottom: 14, borderBottom: "1px solid var(--track)" }}><Coin sym="JENSEN" tone="blue" size="lg" /><div><span className="eyebrow">Fair launch</span><h3 style={{ margin: "2px 0 0", fontSize: 20 }}>$JENSEN</h3><p style={{ margin: "2px 0 0", fontSize: 13, color: "var(--muted)" }}>paired with {pair}</p></div></div>
          <div className="review-row"><span>Creator allocation</span><b>0%</b></div>
          <div className="review-row"><span>Graduation threshold</span><b>250 {pair}</b></div>
          <div className="review-row"><span>Curve fee</span><b>1.0%</b></div>
          <div className="review-row" style={{ border: 0 }}><span>Liquidity lock</span><b className="up">Permanent</b></div>
          <div className="note"><b>Transparent by design</b><p>No insider pre-mint. Liquidity migrates and locks automatically when the curve completes.</p></div>
        </div>
      )}
      <div className="flow-actions">
        {step > 1 && <button type="button" className="btn secondary" onClick={() => setStep(Math.max(1, step - 1))}>Back</button>}
        <button type="button" className="btn primary" onClick={() => { if (step === 3) toast("$JENSEN is ready to launch on Monad · sample"); else setStep(step + 1); }}>{step === 3 ? "Launch on Monad" : "Continue"} <Icon name={step === 3 ? "arrow-ur" : "chev-right"} /></button>
      </div>
    </>
  );
}

const MODE_OPTS: SegOpt<"discover" | "create">[] = [{ v: "discover", l: "Discover" }, { v: "create", l: "Create" }];
export function LaunchScreen({ go, toast }: ScreenProps) {
  const [mode, setMode] = useState<"discover" | "create">("discover");
  const [step, setStep] = useState(1);
  const [pair, setPair] = useState("aNVDA");
  const switchMode = (m: "discover" | "create") => { setMode(m); setStep(1); };
  return (
    <main className="screen" data-screen="launch">
      <Seg options={MODE_OPTS} value={mode} onChange={switchMode} />
      {mode === "create" ? <CreateFlow step={step} setStep={setStep} pair={pair} setPair={setPair} toast={toast} /> : (
        <>
          <section className="card launch-hero" style={{ marginTop: 16 }}>
            <span className="eyebrow">The new primitive</span>
            <h1>Launch a meme.<br />Pair it with Wall Street.</h1>
            <p>Fair-launch tokens paired with real tokenized stocks. Liquidity locks automatically at graduation.</p>
            <button type="button" className="btn primary" onClick={() => switchMode("create")}>Create your token <Icon name="arrow-ur" /></button>
            <div className="stack-art" aria-hidden="true"><span>N</span><i>+</i><span>M</span></div>
          </section>
          <div className="sec"><h2>Trending launches</h2><button type="button" className="link" onClick={() => toast("All launches · sample preview")}>View all <Icon name="chev-right" /></button></div>
          <section className="feed">{LAUNCHES.map((x) => <LaunchCard key={x.name} x={x} go={go} />)}</section>
        </>
      )}
    </main>
  );
}

function HoldingRow({ sym, qty, onClick }: { sym: string; qty: number; onClick: () => void }) {
  const t = byId[sym], v = qty * t.price;
  return <button type="button" className="row" onClick={onClick}><Coin sym={t.sym} tone={t.tone} /><span className="row-main"><b>{t.sym}</b><small className="num">{fmtNum(qty, qty < 1 ? 4 : 2)} {t.sym}</small></span><span className="stack"><span className="price">${fmtNum(v)}</span><small className={`${t.chg >= 0 ? "up" : "down"} num`}>{fmtPct(t.chg)}</small></span></button>;
}

const SIDES = ["Buy", "Sell"] as const;
const STABS = ["Holdings", "Orders", "History"] as const;
export function SwapScreen({ toast }: ScreenProps) {
  const [side, setSide] = useState<(typeof SIDES)[number]>("Buy");
  const [amount, setAmount] = useState("250");
  const [slippage, setSlippage] = useState(false);
  const [tab, setTab] = useState<(typeof STABS)[number]>("Holdings");
  const amt = Math.max(0, Number(amount) || 0), recv = amt / JENSEN_PRICE;
  const pct = Math.min(100, Math.round((amt / SWAP_BALANCE) * 100));
  const stepAmt = (d: number) => setAmount(String(Math.max(0, Math.min(SWAP_BALANCE, amt + d))));
  return (
    <main className="screen" data-screen="trade">
      <div className="pairhd"><Coin sym="JENSEN" tone="blue" size="lg" /><div><button type="button" className="name" onClick={() => toast("Pair picker · sample preview")}>JENSEN / aNVDA <Icon name="chev-down" /></button><div className="sub up">$0.0842 · +48.2%</div></div><div className="right"><em className="badge">Curve</em></div></div>
      <section className="card chart-card" style={{ padding: "14px 16px 10px" }}>
        <div className="pricehd"><div><span className="label">JENSEN price</span><div className="big">$0.0842</div><span className="chip up"><Icon name="trend-up" />+$0.0276 · 48.2%</span></div><div className="stats-mini"><span>Market cap</span><b>$184.2K</b><span>24h volume</span><b>$92.8K</b><span>Holders</span><b>1,842</b></div></div>
        <div className="area"><LineChart values={walk(21, 28, 0.16)} w={340} h={120} grid areaOpacity={0.18} /></div>
      </section>
      <div style={{ marginTop: 16 }}><Seg options={opts(SIDES)} value={side} onChange={setSide} tone="dir" /></div>
      <section className="card order" style={{ marginTop: 12 }}>
        <div className="between"><span>You pay</span><b>Balance {fmtNum(SWAP_BALANCE, 0)} USDC</b></div>
        <div className="amount"><button type="button" className="circ" onClick={() => stepAmt(-25)} aria-label="Decrease amount"><Icon name="minus" /></button><input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} aria-label="Amount in USDC" /><button type="button" className="circ" onClick={() => stepAmt(25)} aria-label="Increase amount"><Icon name="plus" /></button><button type="button" className="tok" onClick={() => toast("Token picker · sample preview")}><Coin sym="USDC" tone="usdc" size="sm" />USDC <Icon name="chev-down" /></button></div>
        <Range value={Math.round(pct / 25) * 25} min={0} max={100} step={25} onChange={(v) => setAmount(String(Math.round((SWAP_BALANCE * v) / 100)))} label="Percent of balance" />
        <div className="ticks"><span>0%</span><span>25%</span><span>50%</span><span>75%</span><span>Max</span></div>
        <span className="swapdir" aria-hidden="true"><Icon name="swap" /></span>
        <div className="between"><span>You receive</span><b>≈ {fmtNum(recv)} JENSEN</b></div>
        <div className="receive"><strong>{fmtNum(recv)}</strong><span className="tokpill"><Coin sym="JENSEN" tone="blue" size="sm" />JENSEN</span></div>
        <div className="route"><span>Route</span><b>USDC → aNVDA → JENSEN</b><em className="badge">Best</em></div>
        <div className="between" style={{ paddingTop: 2 }}><span>Max slippage</span><span style={{ display: "flex", alignItems: "center", gap: 10 }}><b>{slippage ? "1.0%" : "0.5%"}</b><Switch checked={slippage} onChange={setSlippage} label="Custom slippage" /></span></div>
      </section>
      <div className="kvline" style={{ marginTop: 10 }}><span>Minimum received</span><b>{fmtNum(recv * 0.995)} JENSEN</b></div>
      <div className="kvline" style={{ marginBottom: 12 }}><span>Fee</span><b>{fmtNum(amt * 0.003)} USDC</b></div>
      <button type="button" className={`btn big ${side === "Buy" ? "tone-up" : "tone-down"}`} onClick={() => toast(`${side === "Buy" ? "Bought" : "Sold"} JENSEN · sample order`)}>{side} JENSEN</button>
      <Subtabs options={STABS} value={tab} onChange={setTab} />
      {tab === "Holdings" ? <section className="list holdings">{HOLDINGS.map((h) => <HoldingRow key={h.sym} sym={h.sym} qty={h.qty} onClick={() => toast(`${h.sym} · sample preview`)} />)}</section> : tab === "Orders" ? <Empty icon="file" title="No open orders" text="Limit orders you place will appear here." /> : <Empty icon="clock" title="No trade history" text="Your fills will show up here after your first trade." />}
    </main>
  );
}

const PROFILE_ACTIONS = ["deposit", "withdraw", "send"] as const;
export function ProfileScreen({ go, toast }: ScreenProps) {
  const total = totalBalance();
  return (
    <main className="screen" data-screen="profile">
      <section className="card portfolio">
        <div className="kvline" style={{ padding: 0, alignItems: "center" }}><span className="label">Total balance</span><button type="button" className="circ" style={{ width: 32, height: 32, background: "var(--inner)" }} onClick={() => toast("Balance hidden · sample preview")} aria-label="Hide balance"><Icon name="eye" /></button></div>
        <div className="hero-num">${fmtNum(total)}</div>
        <div className="delta"><span className="chip up"><Icon name="trend-up" />+$1,284.20 · 11.1%</span><span className="label">this month</span></div>
        <div className="area" style={{ height: 96 }}><LineChart values={walk(77, 30, 0.14)} w={340} h={96} areaOpacity={0.18} /></div>
        <div className="actions" style={{ margin: "8px 0 0" }}>{PROFILE_ACTIONS.map((a) => <button key={a} type="button" className="action" style={{ height: 64 }} onClick={() => toast(`${capitalize(a)} · sample preview`)}><Icon name={a} />{capitalize(a)}</button>)}</div>
      </section>
      <div className="sec"><h2>Trading stats</h2><button type="button" className="link" onClick={() => toast("Range · sample preview")}>30D <Icon name="chev-down" /></button></div>
      <section className="stats-grid">
        <div className="tile"><span>Realized PnL</span><b className="up">+$2,418</b><small>+18.2% vs last month</small></div>
        <div className="tile"><span>Win rate</span><b>68.4%</b><small>38 trades</small></div>
        <div className="tile"><span>Copy earnings</span><b>$284.90</b><small>127 copiers</small></div>
        <div className="tile"><span>Rank</span><b>#142</b><small>Top 4% on Monad</small></div>
      </section>
      <div className="sec"><h2>Holdings</h2><button type="button" className="link" onClick={() => toast("Manage · sample preview")}>Manage <Icon name="chev-right" /></button></div>
      <section className="list holdings">{HOLDINGS.map((h) => <HoldingRow key={h.sym} sym={h.sym} qty={h.qty} onClick={() => go("trade", "swap")} />)}</section>
      <div className="sec"><h2>Recent activity</h2><button type="button" className="link" onClick={() => toast("Activity · sample preview")}>See all <Icon name="chev-right" /></button></div>
      <section className="list">{ACTIVITY.map((a) => <div className="row" key={a.title}><span className="act-icon"><Icon name={a.icon} /></span><span className="row-main"><b>{a.title}</b><small>{a.sub}</small></span><span className="stack"><span className="price" style={{ fontSize: 14 }}>{a.amt}</span><small>{a.usd}</small></span></div>)}</section>
    </main>
  );
}
