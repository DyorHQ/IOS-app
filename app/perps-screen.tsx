"use client";

import { Fragment, useId, useState } from "react";
import { formatUnits } from "viem";
import { Empty, Seg, SideMark, Subtabs, opts, tabPanel } from "./ui/components";
import type { Go, Preset, Toast } from "./ui/nav";
import { PerplChart } from "./ui/tradingview";
import { usePerpsAccount } from "./lib/app-data";
import { cancelOrder, closePosition, collateralBalances, deposit, fetchOpenOrders, fetchPerplContext, fromCNS, PERP_MARKETS, PERPL, placeOrder, withdraw, type PerpInfo } from "./lib/perps/perpl";
import { usePerplFeed } from "./lib/perps/ws";
import { useAsync, useNow } from "./lib/use-async";
import { useTx } from "./lib/use-tx";
import { useWallet } from "./lib/wallet";
import { fmtFixed, fmtNumber, fmtPct, fmtUnits, fmtUsd, parseAmount, timeAgo } from "./lib/format";
import { ActionButton, TxStatus } from "./launchpad/ui";

/* Perps on Perpl: Perpl's own candles, live order book and tape from Perpl's feed, and orders, positions and
   collateral straight from the Exchange contract. */

const PERIODS: [string, string][] = [["60", "1m"], ["300", "5m"], ["900", "15m"], ["3600", "1h"], ["14400", "4h"], ["86400", "1D"]];
const BOOKS = ["Order book", "Trades"] as const;
const SIDES = ["Long", "Short"] as const;
const PTABS = ["Positions", "Orders", "Collateral"] as const;
const px = (v: number, perp: PerpInfo) => v / 10 ** perp.priceDecimals;
const sz = (v: number, perp: PerpInfo) => v / 10 ** perp.lotDecimals;

export default function PerpsScreen({ toast, preset }: { toast: Toast; go: Go; preset?: Preset }) {
  const wallet = useWallet();
  const account = wallet.account;
  const { perps, account: acct, accountKnown, positionsKnown, positions, error: accountError, refresh } = usePerpsAccount(account);
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
  const [period, setPeriod] = useState("3600");
  const [collatAmount, setCollatAmount] = useState("");
  const collatId = useId();
  const { tx, run, reset, dismiss, busy } = useTx();
  const orders = useAsync(async () => (acct && perps.length ? fetchOpenOrders(acct, perps) : []), `orders:${acct?.accountId ?? 0}:${perps.length}`, 10_000);
  const collat = useAsync(async () => (account ? collateralBalances(account) : null), `collat:${account ?? ""}`, 10_000);

  const mark = feed.state ? px(feed.state.mrk, perp ?? { priceDecimals: mctx?.priceDecimals ?? 6 } as PerpInfo) : perp?.mark ?? mctx?.mark ?? 0;
  const last = feed.state && perp ? px(feed.state.lst, perp) : perp?.last ?? mctx?.last ?? 0;
  const prev = mctx?.prev24h ?? 0;
  const chg = prev ? ((last - prev) / prev) * 100 : null;
  const maxLev = perp ? Math.max(1, Math.floor(1 / perp.initMarginFrac)) : 10;
  const levOptions = [1, 2, 3, 5, 10, 15, 20, 25, 50].filter((x) => x <= maxLev);
  const available = acct ? fromCNS(acct.balance - acct.locked) : 0;
  // What the order carries, not what was typed: the size cut down to the market's lot and the limit price to its
  // price decimals (parseAmount truncates, never rounds up, and reads a decimal comma). Every figure below uses them.
  const lots = perp ? parseAmount(size, perp.lotDecimals) : null;
  const limitPNS = perp && type === "Limit" ? parseAmount(price, perp.priceDecimals) : null;
  const sizeNum = perp && lots !== null ? Number(lots) / 10 ** perp.lotDecimals : 0;
  const limitPrice = perp && limitPNS !== null ? Number(limitPNS) / 10 ** perp.priceDecimals : 0;
  const sizeText = perp && lots !== null ? formatUnits(lots, perp.lotDecimals) : "";
  const limitText = perp && limitPNS !== null ? formatUnits(limitPNS, perp.priceDecimals) : "";
  const cut = (typed: string, kept: bigint | null, decimals: number) => kept !== null && parseAmount(typed, 18) !== kept * 10n ** BigInt(Math.max(0, 18 - decimals));
  const sizeCut = !!perp && cut(size, lots, perp.lotDecimals);
  const priceCut = !!perp && type === "Limit" && cut(price, limitPNS, perp.priceDecimals);
  const refPrice = type === "Limit" && limitPrice > 0 ? limitPrice : mark;
  const notional = sizeNum * refPrice;
  const marginNeeded = lev > 0 ? notional / lev : 0;
  const minSize = perp ? 1 / 10 ** perp.lotDecimals : 0;
  const valid = !!perp && lots !== null && lots > 0n && marginNeeded > 0 && marginNeeded <= available * 1.0001 && (type === "Market" || (limitPNS !== null && limitPNS > 0n));
  // Why the order button is disabled, once there is something to explain.
  const orderIssue = !acct || !size.trim() ? null
    : !perp ? (accountError ? "Couldn't read this market from Perpl." : "Reading this market from Perpl…")
    : lots === null ? "Enter the size as a plain number, like 0.5."
    : lots === 0n ? `The smallest size is ${formatUnits(1n, perp.lotDecimals)} ${perp.symbol}.`
    : type === "Limit" && (limitPNS === null || limitPNS === 0n) ? "Enter a limit price."
    : refPrice <= 0 ? "Waiting for Perpl's mark price…"
    : marginNeeded > available * 1.0001 ? `This needs $${fmtFixed(marginNeeded)} of margin; $${fmtFixed(available)} is available.`
    : null;
  const setPct = (pct: number) => { if (!perp || refPrice <= 0) return; const s = ((available * pct) / 100) * lev / refPrice; setSize(formatUnits(BigInt(Math.floor(s * 10 ** perp.lotDecimals)), perp.lotDecimals)); };
  const refreshAll = () => { refresh(); orders.refresh(); collat.refresh(); };

  const submit = async () => {
    const client = wallet.client;
    if (!client || !perp || lots === null || lots === 0n) return;
    const limit = type === "Limit" && limitPNS !== null ? { price: limitPrice, pricePNS: limitPNS } : {};
    const done = await run(`${side} ${sizeText} ${perp.symbol}${type === "Limit" ? ` at $${limitText}` : ""} · ${lev}×`, (onSent) => placeOrder(client, { perp, side: side === "Long" ? "long" : "short", kind: type === "Market" ? "market" : "limit", size: sizeNum, lotLNS: lots, ...limit, leverage: lev, slippageBps: 100 }, onSent));
    if (done) { setSize(""); toast(`${type} order sent to Perpl`); refreshAll(); }
  };
  const doDeposit = async () => {
    const client = wallet.client; const amt = parseAmount(collatAmount, 6);
    if (!client || !amt) return;
    const done = await run(`${acct ? "Deposit" : "Open account with"} ${formatUnits(amt, 6)} AUSD`, (onSent) => deposit(client, amt, onSent));
    if (done) { setCollatAmount(""); refreshAll(); }
  };
  const doWithdraw = async () => {
    const client = wallet.client; const amt = parseAmount(collatAmount, 6);
    if (!client || !amt) return;
    const done = await run(`Withdraw ${formatUnits(amt, 6)} AUSD`, (onSent) => withdraw(client, amt, onSent));
    if (done) { setCollatAmount(""); refreshAll(); }
  };

  // Deposit and withdraw checks, shown before anything is signed. Opening an account waits until the account read has
  // answered: during an RPC failure an existing account must not be offered "Open account".
  const collatAmt = parseAmount(collatAmount, PERPL.collateralDecimals);
  const walletAusd = collat.data?.wallet ?? null;
  const freeCNS = acct ? acct.balance - acct.locked : 0n;
  const depositIssue = !collatAmount.trim() ? null
    : collatAmt === null || collatAmt === 0n ? "Enter an AUSD amount, like 25."
    : !accountKnown ? (accountError ? "Couldn't read your Perpl account; deposits wait until it loads." : "Reading your Perpl account…")
    : !acct && collatAmt < PERPL.minDeposit ? `The first deposit opens your account and must be at least ${formatUnits(PERPL.minDeposit, 6)} AUSD.`
    : walletAusd !== null && collatAmt > walletAusd ? `Your wallet holds ${fmtUnits(walletAusd, 6)} AUSD, less than this deposit.`
    : null;
  const withdrawIssue = !!acct && collatAmt !== null && collatAmt > freeCNS;
  const accountText = acct ? null : !account ? "—" : accountKnown ? null : accountError ? "Couldn't read" : "Reading…";

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
        <div><span className="label">Mark price</span><div className="big">{mark ? fmtUsd(mark) : "—"}</div><span className="label">Last {last ? fmtUsd(last) : "—"} · Oracle {perp ? fmtUsd(perp.oracle) : "—"}</span></div>
        <div className="stats-mini"><span>Open interest</span><b>{mctx ? fmtNumber(Math.round(mctx.openInterest), { compact: true }) : "—"} {market.symbol}</b><span>24h volume</span><b>{mctx ? fmtNumber(Math.round(mctx.volume24h), { compact: true }) : "—"} {market.symbol}</b><span>Funding</span><b>{mctx ? fmtPct(mctx.fundingRate * 100, 4) : "—"}</b><span>Max leverage</span><b>{maxLev}×</b></div>
      </div>
      <Seg label="Chart interval" options={PERIODS.map(([v, l]) => ({ v, l }))} value={period} onChange={setPeriod} small />
      <div style={{ marginTop: 12 }}><PerplChart marketId={market.id} resolution={Number(period)} height={300} /></div>
      <div style={{ marginTop: 16 }}><Seg label="Order book or trades" options={opts(BOOKS)} value={book} onChange={setBook} /></div>
      {book === "Order book" ? (
        <>
          <div className="ratio"><span className="up">Bids {buyPct}%</span><span className="down">{100 - buyPct}% Asks</span></div>
          <div className="ratio-bar"><i className="b" style={{ width: `${buyPct}%` }} /><i className="a" /></div>
          <div className="book">
            <div className="book-hd"><span>Size ({market.symbol})</span><span>Bid</span></div><div className="book-hd"><span>Ask</span><span>Size ({market.symbol})</span></div>
            {Array.from({ length: Math.max(bids.length, asks.length) }).map((_, i) => { const b = bids[i], a = asks[i]; return (
              <Fragment key={i}>
                <div className="lvl bid">{b && <><i style={{ width: `${Math.round((b.s / maxDepth) * 100)}%` }} /><span>{fmtFixed(sz(b.s, pf), pf.lotDecimals)}</span><span className="px">{fmtFixed(px(b.p, pf), pf.priceDecimals)}</span></>}</div>
                <div className="lvl ask">{a && <><i style={{ width: `${Math.round((a.s / maxDepth) * 100)}%` }} /><span className="px">{fmtFixed(px(a.p, pf), pf.priceDecimals)}</span><span>{fmtFixed(sz(a.s, pf), pf.lotDecimals)}</span></>}</div>
              </Fragment>
            ); })}
            {bids.length === 0 && asks.length === 0 && <p className="hint" style={{ gridColumn: "1 / -1" }}>{feed.error ?? "Waiting for the book…"}</p>}
          </div>
        </>
      ) : (
        <div className="tape">
          <div className="t" style={{ color: "var(--muted)", fontSize: 12 }}><span>Price</span><span>Size ({market.symbol})</span><span>Time</span></div>
          {feed.trades.slice(0, 14).map((t, i) => <div className="t" key={i}><span className={t.side === "buy" ? "up" : "down"}><SideMark side={t.side} />{fmtFixed(px(t.p, pf), pf.priceDecimals)}</span><span>{fmtFixed(sz(t.s, pf), pf.lotDecimals)}</span><span>{now ? timeAgo(Math.floor(t.t / 1000), now) : ""}</span></div>)}
          {feed.trades.length === 0 && <p className="hint">Waiting for trades…</p>}
        </div>
      )}

      <div style={{ marginTop: 18 }}><Seg label="Order side" options={opts(SIDES)} value={side} onChange={setSide} tone="dir" /></div>
      <section className="card order" style={{ marginTop: 12 }}>
        <div className="settings2"><span className="pill-static">Isolated</span><select className="select" aria-label="Leverage" value={lev} onChange={(e) => setLev(Number(e.target.value))}>{levOptions.map((x) => <option key={x} value={x}>{x}×</option>)}</select></div>
        <div className="between"><span>Available margin</span><b>{acct ? `$${fmtFixed(available)}` : accountText ?? "No Perpl account yet"}</b></div>
        <select className="select" aria-label="Order type" value={type} onChange={(e) => setType(e.target.value as "Market" | "Limit")}><option>Market</option><option>Limit</option></select>
        {type === "Limit" && <label className="field">Limit price (USD)<input inputMode="decimal" value={price} placeholder={mark ? fmtFixed(mark, pf.priceDecimals) : "0"} onChange={(e) => setPrice(e.target.value)} /></label>}
        <label className="field">Size ({market.symbol})<input inputMode="decimal" value={size} placeholder={minSize ? String(minSize) : "0"} onChange={(e) => setSize(e.target.value)} /></label>
        <div className="presets">{[25, 50, 75, 100].map((x) => <button key={x} type="button" onClick={() => setPct(x)} disabled={!acct}>{x}%</button>)}</div>
        {perp && lots !== null && lots > 0n && <div className="between"><span>Order size</span><b>{sizeText} {perp.symbol}{type === "Limit" && limitPNS !== null && limitPNS > 0n ? ` at $${limitText}` : ""}</b></div>}
        {(sizeCut || priceCut) && <p className="hint">Cut to what the market accepts: {sizeCut ? `sizes in steps of ${formatUnits(1n, perp!.lotDecimals)}` : ""}{sizeCut && priceCut ? ", " : ""}{priceCut ? `prices to ${perp!.priceDecimals} decimals` : ""}.</p>}
        <div className="between"><span>Notional</span><b>${fmtFixed(notional)}</b></div>
        <div className="between"><span>Margin required</span><b>${fmtFixed(marginNeeded)}</b></div>
        <div className="between"><span>Est. liquidation</span><b>{perp && sizeNum > 0 && marginNeeded > 0 ? fmtUsd(Math.max(0, side === "Long" ? refPrice * (1 - (1 / lev - perp.maintMarginFrac)) : refPrice * (1 + (1 / lev - perp.maintMarginFrac)))) : "—"}</b></div>
        <TxStatus tx={tx} onDismiss={dismiss} />
        {orderIssue && <p className="hint err">{orderIssue}</p>}
        {acct ? <ActionButton ready={valid} busy={busy} label={`${side} ${market.symbol} · ${lev}×`} onClick={submit} className={`btn big ${side === "Long" ? "tone-up" : "tone-down"}`} requireLaunchpad={false} />
          : accountKnown || !account ? <ActionButton ready={true} busy={false} label="Deposit AUSD to start" onClick={() => setTab("Collateral")} className="btn big primary" requireLaunchpad={false} />
          : <ActionButton ready={false} busy={!accountError} label={accountError ? "Couldn't read your Perpl account" : "Reading your Perpl account…"} onClick={() => undefined} className="btn big primary" requireLaunchpad={false} />}
        <p className="hint">Orders are placed on Perpl&apos;s on-chain order book by your wallet. Market orders are immediate-or-cancel at 1% slippage.</p>
      </section>

      <Subtabs id="perps-account" label="Your Perpl account" options={PTABS} value={tab} onChange={setTab} />
      <div {...tabPanel("perps-account", tab)}>
      {tab === "Positions" && (
        <section className="stack-cards" style={{ marginTop: 12 }}>
          {account && accountError && <p className="hint err" role="alert">Couldn&apos;t read your Perpl account or positions ({accountError}). Retrying{positions.length ? "; the positions below may be out of date" : ""}.</p>}
          {positions.map((p) => (
            <div key={p.perpId} className="pos-card">
              <div className="top"><span>{p.symbol}-PERP · <span className={p.side === "long" ? "up" : "down"}>{p.side.toUpperCase()} {p.leverage.toFixed(1)}×</span></span><b className={p.unrealized >= 0 ? "up" : "down"}>{p.unrealized >= 0 ? "+" : "−"}${fmtFixed(Math.abs(p.unrealized))}</b></div>
              <div className="grid"><span>Size<b>{fmtFixed(p.size, p.size < 1 ? 5 : 2)} {p.symbol}</b></span><span>Entry<b>{fmtUsd(p.entry)}</b></span><span>Mark<b>{fmtUsd(p.mark)}</b></span><span>Margin<b>${fmtFixed(p.margin)}</b></span><span>Liq. price<b>{p.liquidation ? fmtUsd(p.liquidation) : "—"}</b></span><span>Notional<b>${fmtFixed(p.notional)}</b></span></div>
              <button type="button" className="btn secondary sm" disabled={busy} onClick={() => { const client = wallet.client; if (client) void run(`Close ${p.symbol} ${p.side}`, (onSent) => closePosition(client, p.perp, p, 100, onSent), refreshAll); }}>Close at market</button>
            </div>
          ))}
          {positions.length === 0 && (!account ? <Empty icon="layers" title="No open positions" text="Connect a wallet to see positions." />
            : positionsKnown && !accountError ? <Empty icon="layers" title="No open positions" text="Open a position and it appears here with live PnL from the Exchange contract." />
            : !accountError && <Empty icon="layers" title="Reading positions…" text="Positions come straight from the Perpl Exchange contract." />)}
        </section>
      )}
      {tab === "Orders" && (
        <section className="stack-cards" style={{ marginTop: 12 }}>
          {(orders.data ?? []).map((o) => (
            <div key={`${o.perpId}-${o.orderId}`} className="pos-card">
              <div className="top"><span>{o.symbol}-PERP · <span className={o.side === "buy" ? "up" : "down"}>{o.side === "buy" ? "BUY" : "SELL"}</span>{o.reduceOnly && <em className="badge" style={{ marginLeft: 6 }}>reduce-only</em>}</span><b>#{o.orderId}</b></div>
              <div className="grid"><span>Price<b>{fmtUsd(o.price)}</b></span><span>Size<b>{fmtFixed(o.size, o.size < 1 ? 5 : 2)}</b></span><span>Leverage<b>{o.leverage}×</b></span></div>
              <button type="button" className="btn secondary sm" disabled={busy} onClick={() => { const client = wallet.client; if (client) void run(`Cancel order #${o.orderId}`, (onSent) => cancelOrder(client, o.perpId, o.orderId, onSent), refreshAll); }}>Cancel</button>
            </div>
          ))}
          {orders.error && <p className="hint err" role="alert">Couldn&apos;t read your open orders ({orders.error}). Retrying.</p>}
          {(orders.data ?? []).length === 0 && !orders.error && <Empty icon="file" title={orders.loading || (account && !accountKnown) ? "Reading the book…" : "No open orders"} text="Resting limit orders on Perpl appear here." />}
        </section>
      )}
      {tab === "Collateral" && (
        <section style={{ marginTop: 12 }}>
          <div className="collat"><div><span>Perpl account</span><b>{acct ? `$${fmtFixed(fromCNS(acct.balance))}` : accountText ?? "Not opened"}</b>{acct && <span>locked ${fmtFixed(fromCNS(acct.locked))}</span>}</div><div style={{ textAlign: "right" }}><span>AUSD in wallet</span><b>{collat.data ? fmtUnits(collat.data.wallet, 6) : collat.error ? "Couldn't read" : "—"}</b></div></div>
          {!account ? <Empty icon="wallet" title="Connect a wallet" text="Deposits go to the Perpl Exchange contract from your wallet." /> : (
            <>
              <label className="label" htmlFor={collatId} style={{ display: "block", marginBottom: 6 }}>Amount (AUSD)</label>
              <div className="inline-form"><input id={collatId} inputMode="decimal" placeholder="0" value={collatAmount} onChange={(e) => setCollatAmount(e.target.value)} /><button type="button" className="btn primary sm" disabled={busy || !accountKnown || !collatAmt || !!depositIssue} onClick={doDeposit}>{acct ? "Deposit" : "Open account"}</button><button type="button" className="btn secondary sm" disabled={busy || !acct || !collatAmt || withdrawIssue} onClick={doWithdraw}>Withdraw</button></div>
              {depositIssue && <p className="hint err" style={{ marginTop: 8 }}>{depositIssue}</p>}
              {acct && <p className={`hint ${withdrawIssue ? "err" : ""}`} style={{ marginTop: 8 }}>${fmtFixed(fromCNS(freeCNS))} is available to withdraw.</p>}
              <p className="hint" style={{ marginTop: 8 }}>Collateral is AUSD. First deposit opens your account (minimum 10 AUSD). Need AUSD? <button type="button" className="link" style={{ color: "var(--accent-ink)", fontWeight: 600 }} onClick={() => toast("Swap MON to AUSD on the Swap tab")}>Swap for it</button>.</p>
              <div style={{ marginTop: 10 }}><TxStatus tx={tx} onDismiss={dismiss} /></div>
            </>
          )}
        </section>
      )}
      </div>
    </main>
  );
}
