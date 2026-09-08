"use client";

import { Fragment, useState } from "react";
import { Icon } from "./ui/icons";
import { Coin, Empty, Seg, Subtabs, opts } from "./ui/components";
import { CandleChart } from "./ui/charts";
import { PERP, SWAP_BALANCE, bookLevels, byId, compact, fmtNum, fmtPct, fmtUSD, recentTrades } from "./ui/data";
import type { Toast } from "./ui/nav";

export type PerpOrder = { side: "Long" | "Short"; lev: number; type: "Market" | "Limit"; amount: number; price: number };
const PERIODS = ["1m", "5m", "15m", "1h", "4h", "1D"] as const;
const BOOKS = ["Order book", "Trades"] as const;
const SIDES = ["Long", "Short"] as const;
const PTABS = ["Positions", "Orders", "History"] as const;

export default function PerpsScreen({ toast, onReview }: { toast: Toast; onReview: (o: PerpOrder) => void }) {
  const [side, setSide] = useState<(typeof SIDES)[number]>("Long");
  const [lev, setLev] = useState(10);
  const [type, setType] = useState<"Market" | "Limit">("Market");
  const [amount, setAmount] = useState("100");
  const [price, setPrice] = useState(String(PERP.mid));
  const [book, setBook] = useState<(typeof BOOKS)[number]>("Order book");
  const [tab, setTab] = useState<(typeof PTABS)[number]>("Positions");
  const [period, setPeriod] = useState<(typeof PERIODS)[number]>("1h");
  const a = Math.max(0, Number(amount) || 0);
  const valid = a > 0 && a <= SWAP_BALANCE && (type === "Market" || Number(price) > 0);
  const lv = bookLevels();
  const eth = byId.ETH;
  return (
    <main className="screen" data-screen="trade">
      <div className="pairhd"><Coin sym="ETH" tone="eth" size="lg" /><div><button type="button" className="name" onClick={() => toast("Market picker · sample preview")}>ETH-USD <Icon name="chev-down" /></button><div className={`sub ${eth.chg >= 0 ? "up" : "down"}`}>{fmtUSD(PERP.mid)} · {fmtPct(eth.chg)}</div></div><div className="right"><em className="badge">PERP</em></div></div>
      <div className="pricehd">
        <div><span className="label">Mid price <Icon name="chev-down" /></span><div className="big">{fmtUSD(PERP.mid)}</div><span className="label">Mark {fmtUSD(PERP.mark)}</span></div>
        <div className="stats-mini"><span>24h high</span><b>{fmtUSD(PERP.high)}</b><span>24h low</span><b>{fmtUSD(PERP.low)}</b><span>24h vol (ETH)</span><b>{compact(PERP.volBase)}</b><span>24h vol (USDC)</span><b>${compact(PERP.volQuote)}</b></div>
      </div>
      <Seg options={opts(PERIODS)} value={period} onChange={setPeriod} small />
      <section className="card chart-card" style={{ marginTop: 12 }}><CandleChart period={period} /></section>
      <div style={{ marginTop: 16 }}><Seg options={opts(BOOKS)} value={book} onChange={setBook} /></div>
      {book === "Order book" ? (
        <>
          <div className="ratio"><span className="up">Buys {lv.buyPct}%</span><span className="down">{100 - lv.buyPct}% Sells</span></div>
          <div className="ratio-bar"><i className="b" style={{ width: `${lv.buyPct}%` }} /><i className="a" /></div>
          <div className="book">
            <div className="book-hd"><span>Total (ETH)</span><span>Price</span></div><div className="book-hd"><span>Price</span><span>Total (ETH)</span></div>
            {lv.bids.map((b, i) => { const ask = lv.asks[i]; return (
              <Fragment key={i}>
                <div className="lvl bid"><i style={{ width: `${((b.cum / lv.max) * 100).toFixed(0)}%` }} /><span>{fmtNum(b.sz, 4)}</span><span className="px">{fmtNum(b.px, 2)}</span></div>
                <div className="lvl ask"><i style={{ width: `${((ask.cum / lv.max) * 100).toFixed(0)}%` }} /><span className="px">{fmtNum(ask.px, 2)}</span><span>{fmtNum(ask.sz, 4)}</span></div>
              </Fragment>
            ); })}
          </div>
        </>
      ) : (
        <div className="trades">
          <div className="t" style={{ color: "var(--muted)", fontSize: 12 }}><span>Price</span><span>Size (ETH)</span><span>Time</span></div>
          {recentTrades().map((r, i) => <div className="t" key={i}><span className={r.up ? "up" : "down"}>{fmtNum(r.px, 2)}</span><span>{fmtNum(r.sz, 3)}</span><span>{r.t}</span></div>)}
        </div>
      )}
      <div style={{ marginTop: 18 }}><Seg options={opts(SIDES)} value={side} onChange={setSide} tone="dir" /></div>
      <section className="card order" style={{ marginTop: 12 }}>
        <div className="settings2"><span className="pill-static">Isolated</span><select className="select" aria-label="Leverage" value={lev} onChange={(e) => setLev(Number(e.target.value))}>{[2, 5, 10, 20, 50].map((x) => <option key={x} value={x}>{x}×</option>)}</select></div>
        <div className="between"><span>Available</span><b>{fmtNum(SWAP_BALANCE, 0)} AUSD</b></div>
        <select className="select" aria-label="Order type" value={type} onChange={(e) => setType(e.target.value as "Market" | "Limit")}><option>Market</option><option>Limit</option></select>
        {type === "Limit" && <label className="field">Limit price (USD)<input inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} /></label>}
        <label className="field">Margin (AUSD)<input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></label>
        <div className="presets">{[25, 50, 75, 100].map((x) => <button key={x} type="button" aria-pressed={a === (SWAP_BALANCE * x) / 100} onClick={() => setAmount(String((SWAP_BALANCE * x) / 100))}>{x}%</button>)}</div>
        <div className="between"><span>Position value</span><b>${fmtNum(a * lev)}</b></div>
        <div className="between"><span>Funding / 1h</span><b className="up">{(PERP.funding * 100).toFixed(4)}%</b></div>
        <button type="button" className={`btn big ${side === "Long" ? "tone-up" : "tone-down"}`} disabled={!valid} onClick={() => onReview({ side, lev, type, amount: a, price: Number(price) || 0 })}>{side} ETH · {lev}×</button>
      </section>
      <Subtabs options={PTABS} value={tab} onChange={setTab} />
      {tab === "Positions" ? <Empty icon="layers" title="No open positions" text="Open a position and it will appear here with live PnL." /> : tab === "Orders" ? <Empty icon="file" title="No open orders" text="Resting limit orders show up here." /> : <Empty icon="clock" title="No trade history" text="Closed positions and fills will be listed here." />}
    </main>
  );
}

export function ReviewSheet({ order, onClose, onConfirm }: { order: PerpOrder; onClose: () => void; onConfirm: () => void }) {
  const notional = order.amount * order.lev, size = notional / PERP.mid;
  const liq = order.side === "Long" ? PERP.mid * (1 - 0.95 / order.lev) : PERP.mid * (1 + 0.95 / order.lev);
  return (
    <>
      <div className="grabber" />
      <div className="kvline" style={{ padding: "0 0 8px", alignItems: "center" }}><b style={{ fontSize: 18, letterSpacing: "-.02em" }}>Review order</b><em className="badge">Sample</em></div>
      <div className="review-row"><span>Side</span><b className={order.side === "Long" ? "up" : "down"}>{order.side} ETH-USD</b></div>
      <div className="review-row"><span>Order type</span><b>{order.type}{order.type === "Limit" ? ` · $${fmtNum(order.price)}` : ""}</b></div>
      <div className="review-row"><span>Margin · leverage</span><b>{fmtNum(order.amount)} AUSD · {order.lev}×</b></div>
      <div className="review-row"><span>Size</span><b>{fmtNum(size, 4)} ETH · ${fmtNum(notional)}</b></div>
      <div className="review-row" style={{ border: 0 }}><span>Est. liquidation</span><b>${fmtNum(liq)}</b></div>
      <p className="hint" style={{ margin: "8px 0 14px" }}>This previews the confirmation step. No order is submitted.</p>
      <div className="flow-actions" style={{ margin: 0 }}><button type="button" className="btn secondary" onClick={onClose}>Cancel</button><button type="button" className={`btn ${order.side === "Long" ? "tone-up" : "tone-down"}`} style={{ flex: 1 }} onClick={onConfirm}>Confirm {order.side}</button></div>
    </>
  );
}
