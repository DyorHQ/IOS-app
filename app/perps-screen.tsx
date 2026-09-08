"use client";

import { useState } from "react";

export default function PerpsScreen({ onSwap }: { onSwap: () => void }) {
  const [view, setView] = useState("Order");
  const [leverage, setLeverage] = useState(10);
  const [amount, setAmount] = useState("100");
  const [side, setSide] = useState("Long");
  const [review, setReview] = useState(false);
  const [tab, setTab] = useState("Positions");
  const [period, setPeriod] = useState("1h");
  const [orderType, setOrderType] = useState("Market");
  const [price, setPrice] = useState("2493.35");
  const validAmount = Number(amount) > 0 && Number(amount) <= 1840 && (orderType === "Market" || Number(price) > 0);
  const heights = [29, 36, 31, 50, 63, 46, 60, 80, 69, 57, 63, 47, 55, 76, 91, 82, 63, 73, 59, 67, 45, 36, 47, 58];
  return <main className="screen perps-screen">
    <div className="segment"><button onClick={onSwap}>Swap</button><button className="active">Perps</button></div>
    <div className="perps-heading"><div><span className="coin ink">E</span><strong>ETH / USD</strong></div><span className="gain">+0.32%</span></div>
    <div className="perps-price"><div><small>Mid price</small><h1>$2,493.35</h1></div><div><small>24h volume</small><b>$34.21M</b></div></div>
    <div className="segment"><button className={view === "Chart" ? "active" : ""} onClick={() => setView("Chart")}>Chart</button><button className={view === "Order" ? "active" : ""} onClick={() => setView("Order")}>Order</button></div>
    {view === "Chart" && <section className="perps-chart-panel"><div className="chart-periods">{["1m", "5m", "15m", "1h", "4h", "1D"].map(x => <button key={x} className={period === x ? "active" : ""} onClick={() => setPeriod(x)}>{x}</button>)}</div><div className="candles" aria-label={`Illustrative ETH ${period} candlestick chart`}>{heights.map((h, i) => <i key={i} className={i % 3 === 0 ? "down" : ""} style={{ bottom: `${h * .55}%`, height: `${12 + ((i * 7) % 17)}%` }} />)}<span className="chart-price">2,493.35</span></div><p className="chart-caption">Illustrative chart · {period} interval</p></section>}
    <div className="perps-layout"><section className="perps-order"><div className="perps-settings"><span>Isolated</span><label><select aria-label="Leverage" value={leverage} onChange={e => setLeverage(Number(e.target.value))}>{[2,5,10,20,50].map(x => <option key={x} value={x}>{x}×</option>)}</select></label></div><div className="perps-available"><span>Available</span><b>1,840 AUSD</b></div><select aria-label="Order type" className="order-select" value={orderType} onChange={e => setOrderType(e.target.value)}><option>Market</option><option>Limit</option></select>
      {orderType === "Limit" && <label className="perps-field">Limit price (USD)<input aria-label="Limit price" type="number" min="0" value={price} onChange={e => setPrice(e.target.value)} /></label>}
      <label className="perps-field">Margin (AUSD)<input aria-label="Margin amount" type="number" min="0" max="1840" value={amount} onChange={e => { setAmount(e.target.value); setReview(false); }} /></label><div className="perps-presets">{[25,50,100].map(x => <button key={x} onClick={() => setAmount(String(1840 * x / 100))}>{x}%</button>)}</div><div className="perps-estimate"><span>Position value</span><b>${(Math.max(0, Number(amount) || 0) * leverage).toLocaleString("en-US", { maximumFractionDigits: 2 })}</b></div>
      <button className="perp-action long" disabled={!validAmount} onClick={() => { setSide("Long"); setReview(true); }}>Long ETH</button><button className="perp-action short" disabled={!validAmount} onClick={() => { setSide("Short"); setReview(true); }}>Short ETH</button>
    </section><section className="order-book" aria-label="Illustrative order book"><div className="book-funding"><span>Funding / 1h</span><b className="gain">0.00036%</b></div><div className="book-label"><span>Price</span><span>ETH</span></div>{[2501,2500,2499,2498,2497,2496].map((p,i) => <div className="book-level ask" key={p}><i style={{width:`${25+i*11}%`}}/><b>{p.toLocaleString()}</b><span>{(1093.13 / (i + 1)).toFixed(2)}</span></div>)}<strong className="book-mid">2,493.35</strong>{[2493,2492,2491,2490,2489,2488].map((p,i) => <div className="book-level bid" key={p}><i style={{width:`${20+i*12}%`}}/><b>{p.toLocaleString()}</b><span>{(165.03 * (i+1)).toFixed(2)}</span></div>)}</section></div>
    <div className="perps-bottom-tabs">{["Positions", "Orders", "History"].map(x => <button className={tab === x ? "active" : ""} key={x} onClick={() => setTab(x)}>{x}</button>)}</div><div className="perps-empty">No {tab === "History" ? "trade history" : `open ${tab.toLowerCase()}`}</div>
    {review && <div className="perps-review" role="dialog" aria-modal="true" aria-label="Review sample order"><div><button aria-label="Close order review" className="review-close" onClick={() => setReview(false)}>×</button><span className="eyebrow">SAMPLE ORDER</span><h2>{side} ETH · {leverage}×</h2><p>{amount} AUSD margin · {orderType} order</p><p>This previews the confirmation screen. No order will be submitted.</p><button className="glass-button primary" onClick={() => setReview(false)}>Back to trading</button></div></div>}
  </main>;
}
