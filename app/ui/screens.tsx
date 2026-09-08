"use client";
// Home, Markets, Launchpad, Swap and Portfolio screens, wired to on-chain data. Navigation goes through `go`.
import { useState } from "react";
import type { Address } from "viem";
import { Icon, type IconName } from "./icons";
import { Empty, Seg, Subtabs, opts, type SegOpt } from "./components";
import { compact, fmtNum, fmtPct, fmtUSD } from "./data";
import type { Go, OpenSheet, Preset, Toast } from "./nav";
import { LightweightChart, TradingViewChart, TV_SYMBOLS } from "./tradingview";
import { useMarkets, usePerpsAccount, type MarketRow } from "../lib/app-data";
import { DEPLOYED, EXPLORER, explorerAddress, explorerTx } from "../lib/chain";
import { fetchAccountView, fetchLaunch, fetchLaunches, priceNumber, type LaunchInfo } from "../lib/launchpad";
import { candlesFromTrades, fetchCurveTrades, fetchLaunchpadActivity, type ActivityItem } from "../lib/launchpad/events";
import { fetchPerplContext } from "../lib/perps/perpl";
import { usePerplFeed } from "../lib/perps/ws";
import { useAsync, useNow } from "../lib/use-async";
import { useWallet } from "../lib/wallet";
import { fmtAmount, fmtUnits, shortAddress, timeAgo } from "../lib/format";
import { LaunchCard as WebLaunchCard, PhaseBadge, Progress, Skeleton, TokenLogo } from "../launchpad/ui";
import { Position, StatePanel, TradePanel } from "../launchpad/token-panels";
import Create from "../launchpad/create/page";
import Swap from "../swap/page";

type ScreenProps = { go: Go; toast: Toast; openSheet: OpenSheet };

/* ------------------------------------------------------------------------------------------------ shared */

function ConnectCard({ text = "Connect a wallet to see balances, positions and activity from Monad." }: { text?: string }) {
  const wallet = useWallet();
  const primary = wallet.wallets[0];
  return (
    <div className="wallet-cta">
      <b>Your wallet, your keys</b>
      <p>{text}</p>
      {wallet.wallets.length === 0 ? <span className="hint">{wallet.ready ? "No browser wallet detected. Install MetaMask, Rabby or Phantom and reload." : "Looking for wallets…"}</span>
        : <button type="button" className="btn primary" disabled={wallet.connecting} onClick={() => wallet.connect(primary.info.rdns)}>{wallet.connecting ? "Connecting…" : `Connect ${wallet.wallets.length === 1 ? primary.info.name : "wallet"}`}</button>}
    </div>
  );
}

function TokenRowLive({ row, i, onClick }: { row: MarketRow; i: number; onClick: () => void }) {
  return (
    <button type="button" className="tok-row" onClick={onClick}>
      <span className="rank">{i + 1}</span>
      <TokenLogo src={row.logo} name={row.symbol} address={row.address} />
      <span className="row-main"><b>{row.symbol}{row.launchpad && <em className="badge accent">Launch</em>}</b><small>{row.name}</small></span>
      <span className="row-end">
        <span className="price">{row.usd === null ? "—" : fmtUSD(row.usd)}</span>
        {row.change24h !== null ? <span className={`chip ${row.change24h >= 0 ? "up" : "down"}`}>{fmtPct(row.change24h)}</span> : <span className="chip neutral">{row.launch ? "on curve" : row.usd === null ? "no pool" : "new"}</span>}
      </span>
    </button>
  );
}

function ActivityRow({ item, launches, now }: { item: ActivityItem; launches: LaunchInfo[]; now: number }) {
  const sym = (token: Address | null) => launches.find((l) => token && l.token.toLowerCase() === token.toLowerCase())?.symbol ?? (token ? shortAddress(token) : "token");
  const icon: IconName = item.kind === "launch" ? "rocket" : item.kind === "graduated" ? "graduate" : item.side === "buy" ? "trend-up" : "trend-down";
  const title = item.kind === "launch" ? `Launched $${sym(item.token)}` : item.kind === "graduated" ? `$${sym(item.token)} graduated to Uniswap v4` : `${item.side === "buy" ? "Bought" : "Sold"} $${sym(item.token)}`;
  const who = item.kind === "launch" ? shortAddress(item.deployer) : item.kind === "trade" ? shortAddress(item.trader) : "";
  return (
    <a className="act-row" href={explorerTx(item.tx)} target="_blank" rel="noreferrer" style={{ textDecoration: "none", color: "inherit" }}>
      <Icon name={icon} />
      <span className="row-main"><b>{title}</b><small>{who}{who ? " · " : ""}{now ? timeAgo(item.time, now) : ""}</small></span>
      {item.kind === "trade" && <span className="amt">{fmtAmount(item.quote, 18, "MON", { compact: true })}<small>{fmtUnits(item.tokens, 18, { compact: true })} tokens</small></span>}
    </a>
  );
}

/* -------------------------------------------------------------------------------------------------- home */

export function HomeScreen({ go, openSheet }: ScreenProps) {
  const wallet = useWallet();
  const account = wallet.account;
  const markets = useMarkets(account);
  const perps = usePerpsAccount(account);
  const now = useNow();
  const tokenValue = markets.rows.reduce((s, r) => s + (r.value ?? 0), 0);
  const perpEquity = perps.account ? Number(perps.account.balance) / 1e6 + perps.positions.reduce((s, p) => s + p.unrealized, 0) : 0;
  const total = tokenValue + perpEquity;
  const dayDelta = markets.rows.reduce((s, r) => s + (r.value !== null && r.change24h !== null ? (r.value * r.change24h) / (100 + r.change24h) : 0), 0);
  const movers = [...markets.rows].filter((r) => r.usd !== null).sort((a, b) => Math.abs(b.change24h ?? 0) - Math.abs(a.change24h ?? 0)).slice(0, 6);
  const curves = new Map(markets.launches.map((l) => [l.curve.toLowerCase(), l.token as Address]));
  const activity = useAsync(async () => (DEPLOYED ? fetchLaunchpadActivity(curves, 9_000n) : []), `activity:${markets.launches.length}`, 20_000);
  const feed = usePerplFeed(10);
  return (
    <main className="screen" data-screen="home">
      {account ? (
        <>
          <section className="balance">
            <div><span className="label">Portfolio</span><div className="hero-num">${fmtNum(total)}</div><div className={`delta ${dayDelta >= 0 ? "up" : "down"}`}><span>{dayDelta >= 0 ? "+" : "−"}${fmtNum(Math.abs(dayDelta))} today</span></div></div>
            <div className="balance-side"><div><span className="label">Perps equity</span><div className="val">${fmtNum(perpEquity)}</div></div><a className="net" href={explorerAddress(account)} target="_blank" rel="noreferrer" style={{ textDecoration: "none" }}>Monad · {shortAddress(account)}</a></div>
          </section>
          <section className="kv"><div><span className="label">Tokens</span><b>${fmtNum(tokenValue)}</b></div><div><span className="label">MON</span><b>{fmtUnits(markets.rows.find((r) => r.native)?.balance ?? 0n, 18, { compact: true })}</b></div></section>
        </>
      ) : <ConnectCard />}
      <section className="actions">
        <button type="button" className="action" onClick={() => openSheet("receive")}><Icon name="deposit" />Receive</button>
        <button type="button" className="action" onClick={() => openSheet("send")}><Icon name="send" />Send</button>
        <button type="button" className="action" onClick={() => go("trade", "swap")}><Icon name="swap" />Swap</button>
      </section>
      <div className="sec"><h2>Top movers</h2><button type="button" className="link" onClick={() => go("markets")}>All markets <Icon name="chev-right" /></button></div>
      <section className="list" style={{ marginTop: 4 }}>
        {markets.loading && movers.length === 0 && [0, 1, 2].map((i) => <div key={i} className="tok-row"><Skeleton h={38} w={38} style={{ borderRadius: 19 }} /><div style={{ flex: 1 }}><Skeleton h={14} w="40%" /></div></div>)}
        {movers.map((r, i) => <TokenRowLive key={r.address} row={r} i={i} onClick={() => go("markets", undefined, { token: r.address })} />)}
        {markets.error && <p className="hint err">{markets.error}</p>}
      </section>
      <div className="sec"><h2>Live on Monad</h2><button type="button" className="link" onClick={() => openSheet("activity")}>Everything <Icon name="chev-right" /></button></div>
      {DEPLOYED ? (
        <section className="card" style={{ padding: "4px 16px" }}>
          {activity.loading && !activity.data && <p className="hint" style={{ padding: "12px 0" }}>Reading the last hour of launchpad blocks…</p>}
          {(activity.data ?? []).slice(0, 6).map((a) => <ActivityRow key={a.tx + a.kind + a.block} item={a} launches={markets.launches} now={now} />)}
          {activity.data && activity.data.length === 0 && <p className="hint" style={{ padding: "12px 0" }}>No launchpad activity in the last hour.</p>}
        </section>
      ) : (
        <section className="card" style={{ padding: "12px 16px" }}>
          <div className="hd" style={{ marginBottom: 6 }}><b>Perps tape · MON</b><span className={`pill-live ${feed.connected ? "" : "off"}`}><i />{feed.connected ? "Perpl live" : "connecting"}</span></div>
          <div className="tape">{feed.trades.slice(0, 6).map((t, i) => <div className="t" key={i}><span className={t.side === "buy" ? "up" : "down"}>{fmtUSD(t.p / 1e6)}</span><span>{fmtNum(t.s, 0)} MON</span><span>{now ? timeAgo(Math.floor(t.t / 1000), now) : ""}</span></div>)}{feed.trades.length === 0 && <p className="hint">Waiting for trades…</p>}</div>
        </section>
      )}
    </main>
  );
}

/* ----------------------------------------------------------------------------------------------- markets */

const MSEGS = ["All", "Spot", "Perps", "Stocks"] as const;
type MFilter = "Popular" | "Gainers" | "Losers";
const MFILTERS: SegOpt<MFilter>[] = [{ v: "Popular", l: "Popular", i: "star" }, { v: "Gainers", l: "Gainers", i: "trend-up" }, { v: "Losers", l: "Losers", i: "trend-down" }];
const STOCKS = [["NVDA", "NVIDIA"], ["TSLA", "Tesla"], ["AAPL", "Apple"], ["MSFT", "Microsoft"], ["GOOGL", "Alphabet"], ["AMZN", "Amazon"]] as const;

function TokenDetail({ row, go, onBack }: { row: MarketRow; go: Go; onBack: () => void }) {
  const tv = TV_SYMBOLS[row.symbol];
  const launch = row.launch;
  const trades = useAsync(async () => (launch ? fetchCurveTrades(launch.curve as Address) : []), `curve:${launch?.curve ?? ""}`, 30_000);
  const candles = launch && trades.data ? candlesFromTrades(trades.data, 300, 1) : [];
  return (
    <>
      <button type="button" className="back-btn" onClick={onBack}><Icon name="chev-left" />Markets</button>
      <div className="detail-head"><TokenLogo src={row.logo} name={row.symbol} address={row.address} size="lg" /><div><h1>{row.symbol}<small>{row.name}</small></h1><div className="detail-price">{row.usd === null ? "—" : fmtUSD(row.usd)}</div>{row.change24h !== null && <span className={`chip ${row.change24h >= 0 ? "up" : "down"}`} style={{ marginTop: 6 }}>{fmtPct(row.change24h)} · 24h</span>}</div></div>
      {tv ? <TradingViewChart symbol={tv} height={300} /> : launch ? (candles.length > 1 ? <div className="card" style={{ padding: 8 }}><LightweightChart candles={candles} height={240} precision={8} /><p className="hint" style={{ padding: "6px 8px 4px" }}>Price in MON per token from curve trades in the last two hours.</p></div> : <div className="card"><p className="hint">{trades.loading ? "Reading curve trades…" : "No curve trades in the last two hours."}</p></div>) : <div className="card"><p className="hint">No TradingView symbol for {row.symbol}. Prices come from its Monad pool.</p></div>}
      <div className="mini-stats">
        <div className="stat"><span>Your balance</span><b>{fmtUnits(row.balance, row.decimals, { compact: true })} {row.symbol}</b></div>
        <div className="stat"><span>Value</span><b>{row.value === null ? "—" : fmtUSD(row.value)}</b></div>
        {launch && <div className="stat"><span>Launch phase</span><b><PhaseBadge launch={launch} /></b></div>}
        {launch && <div className="stat"><span>Curve price</span><b>{fmtNum(priceNumber(launch), 6)} MON</b></div>}
      </div>
      <div className="flow-actions" style={{ marginTop: 0 }}>
        <button type="button" className="btn tone-up" style={{ flex: 1 }} onClick={() => go("trade", "swap", { in: "MON", out: row.native ? "USDC" : row.address })}>Buy {row.symbol}</button>
        <button type="button" className="btn tone-down" style={{ flex: 1 }} onClick={() => go("trade", "swap", { in: row.native ? "USDC" : row.address, out: "MON" })}>Sell {row.symbol}</button>
      </div>
      {launch && <button type="button" className="btn secondary" style={{ width: "100%", marginTop: 8 }} onClick={() => go("launch", undefined, { token: row.address })}>Open on the launchpad</button>}
      <p className="hint" style={{ marginTop: 10 }}>{tv ? `Chart: TradingView ${tv}. ` : ""}Price source: {row.launch && row.change24h === null ? "bonding curve" : "Uniswap pool on Monad"}. <a href={explorerAddress(row.address === "0x0000000000000000000000000000000000000000" ? "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A" : row.address)} target="_blank" rel="noreferrer">Explorer ↗</a></p>
    </>
  );
}

function StockDetail({ symbol, name, onBack }: { symbol: string; name: string; onBack: () => void }) {
  return (
    <>
      <button type="button" className="back-btn" onClick={onBack}><Icon name="chev-left" />Markets</button>
      <div className="detail-head"><span className="coin lg" style={{ background: "var(--asset-blue, #3B82F6)" }}>{symbol[0]}</span><div><h1>{symbol}<small>{name}</small></h1></div></div>
      <TradingViewChart symbol={TV_SYMBOLS[symbol]} height={300} />
      <div className="stock-note">TradingView market data. Tokenised {symbol} is not tradable on Monad yet; when Monday Trade opens its RWA markets, launches can pair with it.</div>
    </>
  );
}

export function MarketsScreen({ go, preset, autoFocus = false }: { go: Go; preset?: Preset; autoFocus?: boolean }) {
  const wallet = useWallet();
  const markets = useMarkets(wallet.account);
  const [seg, setSeg] = useState<(typeof MSEGS)[number]>("All");
  const [filter, setFilter] = useState<MFilter>("Popular");
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<string | null>(preset?.token ?? null);
  const [stock, setStock] = useState<string | null>(null);
  const perpsCtx = useAsync(fetchPerplContext, "perpl-context", 15_000);
  const q = query.trim().toLowerCase();
  const rows = markets.rows.filter((r) => !q || r.symbol.toLowerCase().includes(q) || r.name.toLowerCase().includes(q) || r.address.toLowerCase() === q);
  const sorted = filter === "Gainers" ? [...rows].sort((a, b) => (b.change24h ?? -1e9) - (a.change24h ?? -1e9)) : filter === "Losers" ? [...rows].sort((a, b) => (a.change24h ?? 1e9) - (b.change24h ?? 1e9)) : rows;
  const detail = selected ? markets.rows.find((r) => r.address.toLowerCase() === selected.toLowerCase()) : null;
  if (stock) { const s = STOCKS.find((x) => x[0] === stock)!; return <main className="screen" data-screen="markets"><StockDetail symbol={s[0]} name={s[1]} onBack={() => setStock(null)} /></main>; }
  if (detail) return <main className="screen" data-screen="markets"><TokenDetail row={detail} go={go} onBack={() => setSelected(null)} /></main>;
  return (
    <main className="screen" data-screen="markets">
      <label className="mkt-search"><Icon name="search" /><input placeholder="Search tokens or paste an address" value={query} onChange={(e) => setQuery(e.target.value)} autoFocus={autoFocus} /></label>
      <Seg options={opts(MSEGS)} value={seg} onChange={setSeg} />
      {seg !== "Perps" && seg !== "Stocks" && <div style={{ marginTop: 10 }}><Seg options={MFILTERS} value={filter} onChange={setFilter} small /></div>}
      {seg === "Perps" ? (
        <>
          <div className="meta-row"><span>{perpsCtx.data?.length ?? 0} perpetual markets on Perpl</span><span className="live"><i />On-chain</span></div>
          <section className="list">
            {(perpsCtx.data ?? []).map((m, i) => { const chg = m.prev24h ? ((m.last - m.prev24h) / m.prev24h) * 100 : null; return (
              <button key={m.id} type="button" className="tok-row" onClick={() => go("trade", "perps", { token: String(m.id) })}>
                <span className="rank">{i + 1}</span><span className="coin" style={{ background: "var(--asset-violet, #7C5CFF)" }}>{m.name[0]}</span>
                <span className="row-main"><b>{m.name}-PERP<em className="badge">{m.isOpen ? "OPEN" : "PAUSED"}</em></b><small>OI {compact(Math.round(m.openInterest))} · 24h vol {compact(Math.round(m.volume24h))}</small></span>
                <span className="row-end"><span className="price">{fmtUSD(m.mark)}</span>{chg !== null && <span className={`chip ${chg >= 0 ? "up" : "down"}`}>{fmtPct(chg)}</span>}</span>
              </button>
            ); })}
            {perpsCtx.error && <p className="hint err">{perpsCtx.error}</p>}
          </section>
        </>
      ) : seg === "Stocks" ? (
        <>
          <div className="meta-row"><span>US equities · TradingView data</span><span className="live"><i />Market hours</span></div>
          <section className="list">{STOCKS.map(([s, n], i) => <button key={s} type="button" className="tok-row" onClick={() => setStock(s)}><span className="rank">{i + 1}</span><span className="coin" style={{ background: "var(--asset-blue, #3B82F6)" }}>{s[0]}</span><span className="row-main"><b>{s}<em className="badge">RWA soon</em></b><small>{n}</small></span><span className="row-end"><Icon name="chev-right" /></span></button>)}</section>
        </>
      ) : (
        <>
          <div className="meta-row"><span>{sorted.filter((r) => seg !== "Spot" || !r.launchpad).length} markets · prices from Monad pools</span><span className="live"><i />Live</span></div>
          <section className="list">
            {markets.loading && sorted.length === 0 && [0, 1, 2, 3].map((i) => <div key={i} className="tok-row"><Skeleton h={38} w={38} style={{ borderRadius: 19 }} /><div style={{ flex: 1 }}><Skeleton h={14} w="40%" /></div></div>)}
            {sorted.filter((r) => seg !== "Spot" || !r.launchpad).map((r, i) => <TokenRowLive key={r.address} row={r} i={i} onClick={() => setSelected(r.address)} />)}
            {markets.error && <p className="hint err">{markets.error}</p>}
          </section>
        </>
      )}
    </main>
  );
}

/* ---------------------------------------------------------------------------------------------- launchpad */

function LaunchDetail({ token, onBack }: { token: Address; onBack: () => void }) {
  const wallet = useWallet();
  const launch = useAsync(() => fetchLaunch(token), `launch:${token}`, 6_000);
  const data = launch.data;
  const view = useAsync(() => (wallet.account && data ? fetchAccountView(data, wallet.account) : Promise.resolve(null)), `view:${token}:${wallet.account ?? ""}:${data ? data.phase : "l"}`, 8_000);
  const trades = useAsync(async () => (data ? fetchCurveTrades(data.curve) : []), `trades:${data?.curve ?? ""}`, 30_000);
  const candles = trades.data ? candlesFromTrades(trades.data, 300, 1) : [];
  const refresh = () => { launch.refresh(); view.refresh(); trades.refresh(); };
  if (!data) return <><button type="button" className="back-btn" onClick={onBack}><Icon name="chev-left" />Launchpad</button>{launch.loading ? <Skeleton h={120} /> : <Empty icon="rocket" title="Unknown launch" text={launch.error ?? "This token was not launched here."} />}</>;
  const trading = data.phase === 0 && !data.completed && !data.rescued;
  return (
    <>
      <button type="button" className="back-btn" onClick={onBack}><Icon name="chev-left" />Launchpad</button>
      <div className="detail-head"><TokenLogo src={data.logo} name={data.name} address={data.token} size="lg" /><div><h1>{data.name}<small>${data.symbol}</small></h1><div className="detail-price">{fmtNum(priceNumber(data), 6)} MON</div><PhaseBadge launch={data} /></div></div>
      {candles.length > 1 ? <div className="card" style={{ padding: 8 }}><LightweightChart candles={candles} height={220} precision={8} /></div> : <div className="card"><p className="hint">{trades.loading ? "Reading curve trades…" : "No trades in the last two hours yet."}</p></div>}
      <div className="progress-label" style={{ marginTop: 12 }}><span>{data.phase === 2 ? "Graduated to Uniswap v4" : "Graduation progress"}</span><b>{(data.progressBps / 100).toFixed(1)}%</b></div>
      <Progress bps={data.progressBps} />
      <div className="stack-cards">
        {trading ? <TradePanel launch={data} view={view.data ?? null} onDone={refresh} /> : data.rescued || data.phase === 3 ? <><StatePanel launch={data} onDone={refresh} /><TradePanel launch={data} view={view.data ?? null} onDone={refresh} /></> : <StatePanel launch={data} onDone={refresh} />}
        {view.data && <Position launch={data} view={view.data} onDone={refresh} />}
        <p className="desc">{data.description}</p>
      </div>
    </>
  );
}

const LMODES: SegOpt<"discover" | "create">[] = [{ v: "discover", l: "Discover" }, { v: "create", l: "Create" }];
export function LaunchScreen({ preset }: { go: Go; toast: Toast; preset?: Preset }) {
  const [mode, setMode] = useState<"discover" | "create">("discover");
  const [selected, setSelected] = useState<Address | null>((preset?.token as Address) ?? null);
  const launches = useAsync(async () => (DEPLOYED ? fetchLaunches(60) : []), "launches", 8_000);
  const now = useNow();
  if (selected) return <main className="screen" data-screen="launch"><LaunchDetail token={selected} onBack={() => setSelected(null)} /></main>;
  return (
    <main className="screen" data-screen="launch">
      <Seg options={LMODES} value={mode} onChange={setMode} />
      {mode === "create" ? (
        <div style={{ marginTop: 14 }}>
          {DEPLOYED ? <Create embedded onLaunched={(t) => { setSelected(t); setMode("discover"); }} /> : <Empty icon="rocket" title="Launchpad not deployed" text="Deploy the contracts from the owner wallet and sync the addresses to launch tokens." />}
        </div>
      ) : (
        <>
          <section className="card launch-hero" style={{ marginTop: 16 }}>
            <span className="eyebrow">Fair launches on Monad</span>
            <h1>Launch a meme.<br />Graduate to Uniswap v4.</h1>
            <p>No pre-mine, locked liquidity, fees to holders. Every number below is read from the chain.</p>
            <button type="button" className="btn primary" onClick={() => setMode("create")} disabled={!DEPLOYED}>Create your token <Icon name="arrow-ur" /></button>
            <div className="stack-art" aria-hidden="true"><span>M</span><i>+</i><span>D</span></div>
          </section>
          <div className="sec"><h2>Launches</h2><span className="hint">{launches.data ? `${launches.data.length} on-chain` : ""}</span></div>
          {!DEPLOYED && <Empty icon="rocket" title="Contracts not deployed" text="The launchpad reads from Monad mainnet once the owner deploys and syncs the addresses." />}
          <section className="feed">
            {launches.loading && !launches.data && DEPLOYED && <Skeleton h={160} />}
            {(launches.data ?? []).map((l) => <div key={l.token} onClick={() => setSelected(l.token)} style={{ cursor: "pointer" }}><WebLaunchCard launch={l} now={now} /></div>)}
            {launches.error && <p className="hint err">{launches.error}</p>}
          </section>
        </>
      )}
    </main>
  );
}

/* --------------------------------------------------------------------------------------------------- swap */

export function SwapScreen({ preset }: { preset?: Preset }) {
  return (
    <main className="screen" data-screen="trade">
      <Swap key={`${preset?.in ?? ""}-${preset?.out ?? ""}`} embedded initialIn={preset?.in ?? "MON"} initialOut={preset?.out ?? "USDC"} />
    </main>
  );
}

/* ------------------------------------------------------------------------------------------------ profile */

const PTABS = ["Holdings", "Perps", "Activity"] as const;
export function ProfileScreen({ go, toast, openSheet }: ScreenProps) {
  const wallet = useWallet();
  const account = wallet.account;
  const markets = useMarkets(account);
  const perps = usePerpsAccount(account);
  const [tab, setTab] = useState<(typeof PTABS)[number]>("Holdings");
  const now = useNow();
  const curves = new Map(markets.launches.map((l) => [l.curve.toLowerCase(), l.token as Address]));
  const activity = useAsync(async () => (DEPLOYED && account ? (await fetchLaunchpadActivity(curves, 18_000n)).filter((a) => (a.kind === "trade" && a.trader.toLowerCase() === account.toLowerCase()) || (a.kind === "launch" && a.deployer.toLowerCase() === account.toLowerCase())) : []), `my-activity:${account ?? ""}:${markets.launches.length}`, 30_000);
  const holdings = markets.rows.filter((r) => r.balance > 0n).sort((a, b) => (b.value ?? 0) - (a.value ?? 0));
  const tokenValue = holdings.reduce((s, r) => s + (r.value ?? 0), 0);
  const perpEquity = perps.account ? Number(perps.account.balance) / 1e6 + perps.positions.reduce((s, p) => s + p.unrealized, 0) : 0;
  if (!account) return <main className="screen" data-screen="profile"><ConnectCard text="Your portfolio is read straight from Monad: token balances, launchpad positions and Perpl perps." /></main>;
  return (
    <main className="screen" data-screen="profile">
      <section className="usercard" style={{ marginBottom: 14 }}>
        <span className="avatar">{account.slice(2, 4).toUpperCase()}</span>
        <div style={{ flex: 1, minWidth: 0 }}><b>{wallet.active?.info.name ?? "Wallet"}</b><small>{shortAddress(account, 6)}</small></div>
        <button type="button" className="iconbtn" onClick={() => { navigator.clipboard?.writeText(account); toast("Address copied"); }}><Icon name="copy" />Copy</button>
      </section>
      <section className="balance"><div><span className="label">Total value</span><div className="hero-num">${fmtNum(tokenValue + perpEquity)}</div></div><div className="balance-side"><div><span className="label">Perps equity</span><div className="val">${fmtNum(perpEquity)}</div></div></div></section>
      <section className="actions">
        <button type="button" className="action" onClick={() => openSheet("receive")}><Icon name="deposit" />Receive</button>
        <button type="button" className="action" onClick={() => openSheet("send")}><Icon name="send" />Send</button>
        <button type="button" className="action" onClick={() => go("trade", "swap")}><Icon name="swap" />Swap</button>
      </section>
      <Subtabs options={PTABS} value={tab} onChange={setTab} />
      {tab === "Holdings" && (
        <section className="list" style={{ marginTop: 6 }}>
          {holdings.map((r, i) => <TokenRowLive key={r.address} row={r} i={i} onClick={() => go("markets", undefined, { token: r.address })} />)}
          {holdings.length === 0 && <Empty icon="wallet" title={markets.loading ? "Reading balances…" : "No tokens yet"} text="Receive MON or swap into any Monad asset to get started." />}
        </section>
      )}
      {tab === "Perps" && (
        <section style={{ marginTop: 12 }}>
          <div className="collat"><div><span>Perpl balance</span><b>{perps.account ? `$${fmtNum(Number(perps.account.balance) / 1e6)}` : "No account"}</b></div><button type="button" className="btn secondary sm" onClick={() => go("trade", "perps")}>Open perps</button></div>
          <div className="stack-cards">{perps.positions.map((p) => <div key={p.perpId} className="pos-card"><div className="top"><span>{p.symbol} · <span className={p.side === "long" ? "up" : "down"}>{p.side.toUpperCase()} {p.leverage.toFixed(1)}×</span></span><b className={p.unrealized >= 0 ? "up" : "down"}>{p.unrealized >= 0 ? "+" : "−"}${fmtNum(Math.abs(p.unrealized))}</b></div><div className="grid"><span>Size<b>{fmtNum(p.size, p.size < 1 ? 5 : 2)} {p.symbol}</b></span><span>Entry<b>{fmtUSD(p.entry)}</b></span><span>Mark<b>{fmtUSD(p.mark)}</b></span></div></div>)}</div>
          {perps.positions.length === 0 && <Empty icon="layers" title="No open positions" text="Positions on Perpl show here with live PnL." />}
        </section>
      )}
      {tab === "Activity" && (
        <section className="card" style={{ marginTop: 12, padding: "4px 16px" }}>
          {activity.loading && !activity.data && <p className="hint" style={{ padding: "12px 0" }}>Reading the last two hours of blocks…</p>}
          {(activity.data ?? []).map((a) => <ActivityRow key={a.tx + a.kind} item={a} launches={markets.launches} now={now} />)}
          {activity.data && activity.data.length === 0 && <p className="hint" style={{ padding: "12px 0" }}>{DEPLOYED ? "No launchpad activity from this wallet in the last two hours." : "Launchpad activity appears once the contracts are deployed."} <a href={`${EXPLORER}/address/${account}`} target="_blank" rel="noreferrer">Full history on Monadscan ↗</a></p>}
        </section>
      )}
      <div className="divider" />
      <button type="button" className="btn secondary" style={{ width: "100%" }} onClick={() => { wallet.disconnect(); toast("Wallet disconnected"); }}><Icon name="logout" />Disconnect wallet</button>
    </main>
  );
}
