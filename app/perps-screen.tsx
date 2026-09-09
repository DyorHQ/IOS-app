"use client";

import { Fragment, useState } from "react";
import { Empty, Seg, Subtabs, opts } from "./ui/components";
import { compact, fmtNum, fmtPct, fmtUSD } from "./ui/data";
import type { Go, Preset, Toast } from "./ui/nav";
import { TradingViewChart } from "./ui/tradingview";
import { usePerpsAccount } from "./lib/app-data";
import { cancelOrder, closePosition, collateralBalances, deposit, fetchOpenOrders, fetchPerplContext, fromCNS, PERP_MARKETS, placeOrder, withdraw, type PerpInfo } from "./lib/perps/perpl";
import { usePerplFeed } from "./lib/perps/ws";
import { useAsync, useNow } from "./lib/use-async";
import { useTx } from "./lib/use-tx";
import { useWallet } from "./lib/wallet";
import { fmtUnits, parseAmount, timeAgo } from "./lib/format";
import { ActionButton, TxStatus } from "./launchpad/ui";

/* Perps on Perpl: TradingView chart, live order book and tape from Perpl's feed, and orders, positions and
   collateral straight from the Exchange contract. */

const PERIODS: [string, string][] = [["1", "1m"], ["5", "5m"], ["15", "15m"], ["60", "1h"], ["240", "4h"], ["D", "1D"]];
const BOOKS = ["Order book", "Trades"] as const;
const SIDES = ["Long", "Short"] as const;
const PTABS = ["Positions", "Orders", "Collateral"] as const;
const px = (v: number, perp: PerpInfo) => v / 10 ** perp.priceDecimals;
const sz = (v: number, perp: PerpInfo) => v / 10 ** perp.lotDecimals;

export default function PerpsScreen({ toast, preset }: { toast: Toast; go: Go; preset?: Preset }) {
  const wallet = useWallet();
  const account = wallet.account;
  const { perps, account: acct, positions, refresh } = usePerpsAccount(account);
  const ctx = useAsync(fetchPerplContext, "perpl-context", 15_000);
  const [marketId, setMarketId] = useState<number>(preset?.token ? Number(preset.token) : 10);
  const market = PERP_MARKETS.find((m) => m.id === marketId) ?? PERP_MARKETS[1];
  const perp = perps.find((p) => p.id === marketId) ?? null;
  const mctx = ctx.data?.find((m) => m.id === marketId) ?? null;
  const feed = usePerplFeed(marketId);
  const now = useNow();
  const [side, setSide] = useState<(typeof SIDES)[number]>("Long");
  const [lev, setLev] = useState(5);
  const [type, setType] = useState<"Market" | "Limit">("Market");
  const [size, setSize] = useState("");
  const [price, setPrice] = useState("");
  const [book, setBook] = useState<(typeof BOOKS)[number]>("Order book");
  const [tab, setTab] = useState<(typeof PTABS)[number]>("Positions");
  const [period, setPeriod] = useState("60");
  const [collatAmount, setCollatAmount] = useState("");
  const { tx, run, reset, busy } = useTx();
  const orders = useAsync(async () => (acct && perps.length ? fetchOpenOrders(acct, perps) : []), `orders:${acct?.accountId ?? 0}:${perps.length}`, 10_000);
  const collat = useAsync(async () => (account ? collateralBalances(account) : null), `collat:${account ?? ""}`, 10_000);

  const mark = feed.state ? px(feed.state.mrk, perp ?? { priceDecimals: mctx?.priceDecimals ?? 6 } as PerpInfo) : perp?.mark ?? mctx?.mark ?? 0;
  const last = feed.state && perp ? px(feed.state.lst, perp) : perp?.last ?? mctx?.last ?? 0;
  const prev = mctx?.prev24h ?? 0;
  const chg = prev ? ((last - prev) / prev) * 100 : null;
  const maxLev = perp ? Math.max(1, Math.floor(1 / perp.initMarginFrac)) : 10;
  const levOptions = [1, 2, 3, 5, 10, 15, 20, 25, 50].filter((x) => x <= maxLev);
  const available = acct ? fromCNS(acct.balance - acct.locked) : 0;
  const sizeNum = Number(size) || 0;
  const limitPrice = Number(price) || 0;
  const refPrice = type === "Limit" && limitPrice > 0 ? limitPrice : mark;
  const notional = sizeNum * refPrice;
  const marginNeeded = lev > 0 ? notional / lev : 0;
  const minSize = perp ? 1 / 10 ** perp.lotDecimals : 0;
  const valid = !!perp && sizeNum >= minSize && marginNeeded > 0 && marginNeeded <= available * 1.0001 && (type === "Market" || limitPrice > 0);
  const setPct = (pct: number) => { if (!perp || mark <= 0) return; const s = ((available * pct) / 100) * lev / refPrice; setSize((Math.floor(s * 10 ** perp.lotDecimals) / 10 ** perp.lotDecimals).toString()); };
  const refreshAll = () => { refresh(); orders.refresh(); collat.refresh(); };

  const submit = async () => {
    const client = wallet.client;
    if (!client || !perp) return;
    const done = await run(`${side} ${sizeNum} ${perp.symbol} · ${lev}×`, (onSent) => placeOrder(client, { perp, side: side === "Long" ? "long" : "short", kind: type === "Market" ? "market" : "limit", size: sizeNum, price: limitPrice || undefined, leverage: lev, slippageBps: 100 }, onSent));
    if (done) { setSize(""); toast(`${type} order sent to Perpl`); refreshAll(); }
  };
  const doDeposit = async () => {
    const client = wallet.client; const amt = parseAmount(collatAmount, 6);
    if (!client || !amt) return;
    const done = await run(`Deposit ${collatAmount} AUSD`, (onSent) => deposit(client, amt, !!acct, onSent));
    if (done) { setCollatAmount(""); refreshAll(); }
  };
  const doWithdraw = async () => {
    const client = wallet.client; const amt = parseAmount(collatAmount, 6);
    if (!client || !amt) return;
    const done = await run(`Withdraw ${collatAmount} AUSD`, (onSent) => withdraw(client, amt, onSent));
    if (done) { setCollatAmount(""); refreshAll(); }
  };

  const bids = feed.book.bids.slice(0, 8);
  const asks = feed.book.asks.slice(0, 8);
  const maxDepth = Math.max(1, ...bids.map((l) => l.s), ...asks.map((l) => l.s));
  const bidVol = bids.reduce((s, l) => s + l.s, 0), askVol = asks.reduce((s, l) => s + l.s, 0);
  const buyPct = bidVol + askVol > 0 ? Math.round((bidVol / (bidVol + askVol)) * 100) : 50;
  const pf = perp ?? ({ priceDecimals: mctx?.priceDecimals ?? 6, lotDecimals: mctx?.sizeDecimals ?? 0 } as PerpInfo);

  return (
    <main className="screen" data-screen="trade">
      <div className="pairhd">
        <span className="coin lg" style={{ background: "var(--asset-violet, #7C5CFF)" }}>{market.symbol[0]}</span>
        <div>
          <select className="select" aria-label="Market" value={marketId} onChange={(e) => { setMarketId(Number(e.target.value)); setSize(""); setPrice(""); reset(); }} style={{ padding: "6px 34px 6px 10px", fontSize: 16, fontWeight: 600, width: "auto" }}>
            {PERP_MARKETS.map((m) => <option key={m.id} value={m.id}>{m.symbol}-PERP</option>)}
          </select>
          <div className={`sub ${chg === null ? "" : chg >= 0 ? "up" : "down"}`}>{chg === null ? "—" : fmtPct(chg)} · 24h</div>
        </div>
        <div className="right"><span className={`pill-live ${feed.connected ? "" : "off"}`}><i />{feed.connected ? "Perpl live" : "reconnecting"}</span></div>
      </div>
      <div className="pricehd">
        <div><span className="label">Mark price</span><div className="big">{mark ? fmtUSD(mark) : "—"}</div><span className="label">Last {last ? fmtUSD(last) : "—"} · Oracle {perp ? fmtUSD(perp.oracle) : "—"}</span></div>
        <div className="stats-mini"><span>Open interest</span><b>{mctx ? compact(Math.round(mctx.openInterest)) : "—"} {market.symbol}</b><span>24h volume</span><b>{mctx ? compact(Math.round(mctx.volume24h)) : "—"} {market.symbol}</b><span>Funding</span><b>{mctx ? `${(mctx.fundingRate * 100).toFixed(4)}%` : "—"}</b><span>Max leverage</span><b>{maxLev}×</b></div>
      </div>
      <Seg options={PERIODS.map(([v, l]) => ({ v, l }))} value={period} onChange={setPeriod} small />
      <div style={{ marginTop: 12 }}><TradingViewChart symbol={market.tv} interval={period} height={300} compact /></div>
      <div style={{ marginTop: 16 }}><Seg options={opts(BOOKS)} value={book} onChange={setBook} /></div>
      {book === "Order book" ? (
        <>
          <div className="ratio"><span className="up">Bids {buyPct}%</span><span className="down">{100 - buyPct}% Asks</span></div>
          <div className="ratio-bar"><i className="b" style={{ width: `${buyPct}%` }} /><i className="a" /></div>
          <div className="book">
            <div className="book-hd"><span>Size ({market.symbol})</span><span>Bid</span></div><div className="book-hd"><span>Ask</span><span>Size ({market.symbol})</span></div>
            {Array.from({ length: Math.max(bids.length, asks.length) }).map((_, i) => { const b = bids[i], a = asks[i]; return (
              <Fragment key={i}>
                <div className="lvl bid">{b && <><i style={{ width: `${Math.round((b.s / maxDepth) * 100)}%` }} /><span>{fmtNum(sz(b.s, pf), pf.lotDecimals)}</span><span className="px">{fmtNum(px(b.p, pf), pf.priceDecimals)}</span></>}</div>
                <div className="lvl ask">{a && <><i style={{ width: `${Math.round((a.s / maxDepth) * 100)}%` }} /><span className="px">{fmtNum(px(a.p, pf), pf.priceDecimals)}</span><span>{fmtNum(sz(a.s, pf), pf.lotDecimals)}</span></>}</div>
              </Fragment>
            ); })}
            {bids.length === 0 && asks.length === 0 && <p className="hint" style={{ gridColumn: "1 / -1" }}>{feed.error ?? "Waiting for the book…"}</p>}
          </div>
        </>
      ) : (
        <div className="tape">
          <div className="t" style={{ color: "var(--muted)", fontSize: 12 }}><span>Price</span><span>Size ({market.symbol})</span><span>Time</span></div>
          {feed.trades.slice(0, 14).map((t, i) => <div className="t" key={i}><span className={t.side === "buy" ? "up" : "down"}>{fmtNum(px(t.p, pf), pf.priceDecimals)}</span><span>{fmtNum(sz(t.s, pf), pf.lotDecimals)}</span><span>{now ? timeAgo(Math.floor(t.t / 1000), now) : ""}</span></div>)}
          {feed.trades.length === 0 && <p className="hint">Waiting for trades…</p>}
        </div>
      )}

      <div style={{ marginTop: 18 }}><Seg options={opts(SIDES)} value={side} onChange={setSide} tone="dir" /></div>
      <section className="card order" style={{ marginTop: 12 }}>
        <div className="settings2"><span className="pill-static">Isolated</span><select className="select" aria-label="Leverage" value={lev} onChange={(e) => setLev(Number(e.target.value))}>{levOptions.map((x) => <option key={x} value={x}>{x}×</option>)}</select></div>
        <div className="between"><span>Available margin</span><b>{acct ? `$${fmtNum(available)}` : account ? "No Perpl account yet" : "—"}</b></div>
        <select className="select" aria-label="Order type" value={type} onChange={(e) => setType(e.target.value as "Market" | "Limit")}><option>Market</option><option>Limit</option></select>
        {type === "Limit" && <label className="field">Limit price (USD)<input inputMode="decimal" value={price} placeholder={mark ? fmtNum(mark, pf.priceDecimals) : "0"} onChange={(e) => setPrice(e.target.value)} /></label>}
        <label className="field">Size ({market.symbol})<input inputMode="decimal" value={size} placeholder={minSize ? String(minSize) : "0"} onChange={(e) => setSize(e.target.value)} /></label>
        <div className="presets">{[25, 50, 75, 100].map((x) => <button key={x} type="button" onClick={() => setPct(x)} disabled={!acct}>{x}%</button>)}</div>
        <div className="between"><span>Notional</span><b>${fmtNum(notional)}</b></div>
        <div className="between"><span>Margin required</span><b>${fmtNum(marginNeeded)}</b></div>
        <div className="between"><span>Est. liquidation</span><b>{perp && sizeNum > 0 && marginNeeded > 0 ? fmtUSD(Math.max(0, side === "Long" ? refPrice * (1 - (1 / lev - perp.maintMarginFrac)) : refPrice * (1 + (1 / lev - perp.maintMarginFrac)))) : "—"}</b></div>
        <TxStatus tx={tx} onDismiss={reset} />
        {acct ? <ActionButton ready={valid} busy={busy} label={`${side} ${market.symbol} · ${lev}×`} onClick={submit} className={`btn big ${side === "Long" ? "tone-up" : "tone-down"}`} requireLaunchpad={false} />
          : <ActionButton ready={true} busy={false} label="Deposit AUSD to start" onClick={() => setTab("Collateral")} className="btn big primary" requireLaunchpad={false} />}
        <p className="hint">Orders are placed on Perpl&apos;s on-chain order book by your wallet. Market orders are immediate-or-cancel at 1% slippage.</p>
      </section>

      <Subtabs options={PTABS} value={tab} onChange={setTab} />
      {tab === "Positions" && (
        <section className="stack-cards" style={{ marginTop: 12 }}>
          {positions.map((p) => (
            <div key={p.perpId} className="pos-card">
              <div className="top"><span>{p.symbol}-PERP · <span className={p.side === "long" ? "up" : "down"}>{p.side.toUpperCase()} {p.leverage.toFixed(1)}×</span></span><b className={p.unrealized >= 0 ? "up" : "down"}>{p.unrealized >= 0 ? "+" : "−"}${fmtNum(Math.abs(p.unrealized))}</b></div>
              <div className="grid"><span>Size<b>{fmtNum(p.size, p.size < 1 ? 5 : 2)} {p.symbol}</b></span><span>Entry<b>{fmtUSD(p.entry)}</b></span><span>Mark<b>{fmtUSD(p.mark)}</b></span><span>Margin<b>${fmtNum(p.margin)}</b></span><span>Liq. price<b>{p.liquidation ? fmtUSD(p.liquidation) : "—"}</b></span><span>Notional<b>${fmtNum(p.notional)}</b></span></div>
              <button type="button" className="btn secondary sm" disabled={busy} onClick={() => { const client = wallet.client; const pi = perps.find((x) => x.id === p.perpId); if (client && pi) void run(`Close ${p.symbol} ${p.side}`, (onSent) => closePosition(client, pi, p, 100, onSent), refreshAll); }}>Close at market</button>
            </div>
          ))}
          {positions.length === 0 && <Empty icon="layers" title="No open positions" text={account ? "Open a position and it appears here with live PnL from the Exchange contract." : "Connect a wallet to see positions."} />}
        </section>
      )}
      {tab === "Orders" && (
        <section className="stack-cards" style={{ marginTop: 12 }}>
          {(orders.data ?? []).map((o) => (
            <div key={`${o.perpId}-${o.orderId}`} className="pos-card">
              <div className="top"><span>{o.symbol}-PERP · <span className={o.side === "buy" ? "up" : "down"}>{o.side === "buy" ? "BUY" : "SELL"}</span>{o.reduceOnly && <em className="badge" style={{ marginLeft: 6 }}>reduce-only</em>}</span><b>#{o.orderId}</b></div>
              <div className="grid"><span>Price<b>{fmtUSD(o.price)}</b></span><span>Size<b>{fmtNum(o.size, o.size < 1 ? 5 : 2)}</b></span><span>Leverage<b>{o.leverage}×</b></span></div>
              <button type="button" className="btn secondary sm" disabled={busy} onClick={() => { const client = wallet.client; if (client) void run(`Cancel order #${o.orderId}`, (onSent) => cancelOrder(client, o.perpId, o.orderId, onSent), refreshAll); }}>Cancel</button>
            </div>
          ))}
          {(orders.data ?? []).length === 0 && <Empty icon="file" title={orders.loading ? "Reading the book…" : "No open orders"} text="Resting limit orders on Perpl appear here." />}
        </section>
      )}
      {tab === "Collateral" && (
        <section style={{ marginTop: 12 }}>
          <div className="collat"><div><span>Perpl account</span><b>{acct ? `$${fmtNum(fromCNS(acct.balance))}` : "Not opened"}</b>{acct && <span>locked ${fmtNum(fromCNS(acct.locked))}</span>}</div><div style={{ textAlign: "right" }}><span>AUSD in wallet</span><b>{collat.data ? fmtUnits(collat.data.wallet, 6) : "—"}</b></div></div>
          {!account ? <Empty icon="wallet" title="Connect a wallet" text="Deposits go to the Perpl Exchange contract from your wallet." /> : (
            <>
              <div className="inline-form"><input inputMode="decimal" placeholder="AUSD amount" value={collatAmount} onChange={(e) => setCollatAmount(e.target.value)} /><button type="button" className="btn primary sm" disabled={busy || !parseAmount(collatAmount, 6)} onClick={doDeposit}>{acct ? "Deposit" : "Open account"}</button><button type="button" className="btn secondary sm" disabled={busy || !acct || !parseAmount(collatAmount, 6)} onClick={doWithdraw}>Withdraw</button></div>
              <p className="hint" style={{ marginTop: 8 }}>Collateral is AUSD. First deposit opens your account (minimum 10 AUSD). Need AUSD? <button type="button" className="link" style={{ color: "var(--accent-ink)", fontWeight: 600 }} onClick={() => toast("Swap MON to AUSD on the Swap tab")}>Swap for it</button>.</p>
              <div style={{ marginTop: 10 }}><TxStatus tx={tx} onDismiss={reset} /></div>
            </>
          )}
        </section>
      )}
    </main>
  );
}
