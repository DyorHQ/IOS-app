"use client";

import { useState } from "react";
import Link from "next/link";
import { Wordmark } from "../ui/wordmark";
import { Button, Chip, Empty, Range, Seg, Switch } from "../ui/components";
import { Icon, Sprite } from "../ui/icons";
import { THEME_OPTS, setPrefs, useApplyPrefs } from "../preview-controls";

const sections = [["identity", "Identity"], ["palette", "Color"], ["typography", "Typography"], ["components", "Components"], ["structure", "Spacing & motion"]];
const colors = [
  ["Canvas", "--bg", "Page backgrounds"], ["Surface", "--card", "Cards and sheets"],
  ["Inset", "--inner", "Fields and controls"], ["Primary", "--text", "Text and primary actions"],
  ["Secondary", "--muted", "Labels and supporting text"],
];

export default function BrandSystem() {
  const { prefs } = useApplyPrefs();
  const [side, setSide] = useState("Buy");
  const [notifications, setNotifications] = useState(true);
  const [amount, setAmount] = useState(25);
  const [ticker, setTicker] = useState("");
  const [submitted, setSubmitted] = useState(false);
  const [notice, setNotice] = useState("");
  const error = submitted && !/^[A-Z]{2,10}$/.test(ticker);
  return <div className="system-page">
    <Sprite />
    <header className="system-header"><Link href="/" aria-label="DyorHQ app preview"><Wordmark /></Link><span>Design system</span><Link href="/">Open app <Icon name="chev-right" /></Link></header>
    <div className="system-layout">
      <aside className="system-index"><nav aria-label="Design system sections">{sections.map(([id, label]) => <a key={id} href={`#${id}`}>{label}</a>)}</nav><div className="system-theme"><label id="theme-label">Appearance</label><Seg label="Theme" options={THEME_OPTS} value={prefs.theme} onChange={theme => setPrefs({ ...prefs, theme })} small /><p>One identity in both themes.</p></div><a href="/brand/dyorhq-design-system.md" download>Download guidelines</a><a href="/design-tokens.css" download>Download CSS tokens</a></aside>
      <main className="system-content">
        <section id="identity" className="system-intro">
          <h1>DyorHQ design system</h1><p className="system-lead">An editorial identity for a precise trading experience. Shared typography, surfaces, and controls across every screen.</p>
          <div className="logo-specimen"><Wordmark /><p>The RWA HQ for social trading</p></div>
          <div className="system-note"><p>The wordmark is artwork, not a font setting. Use the supplied file; do not reconstruct it with live text.</p><a href="/brand/dyorhq-serif-v2-transparent.png" download>Download wordmark <Icon name="deposit" /></a></div>
        </section>
        <section id="palette"><h2>Color has a job.</h2><p className="section-intro">Neutral surfaces carry the interface. Green and red communicate financial direction, never decoration. Switch themes to inspect the same tokens.</p>
          <div className="system-palette">{colors.map(([name, token, role]) => <article key={token}><div className="color-sample" style={{ background: `var(${token})` }} /><h3>{name}</h3><code>{token}</code><p>{role}</p></article>)}</div>
          <div className="semantic-specimen"><div><Chip chg={12.8} /><h3>Positive</h3><p>Gains, buys, confirmed success.</p></div><div><Chip chg={-2.06} /><h3>Negative</h3><p>Losses, sells, errors.</p></div><div><span className="system-warning">Review slippage</span><h3>Attention</h3><p>Warnings requiring a decision.</p></div></div>
          <p className="system-caption">Token and avatar colors are identifiers. They must never become page accents or transaction-state colors.</p>
        </section>
        <section id="typography"><h2>Three roles. No substitutions.</h2>
          <article className="type-row"><div><h3>Bodoni Moda</h3><p>Editorial headings</p><code>400 / 500 · optical sizing</code></div><div className="display-specimen">Your research.<br />Your next move.</div></article>
          <article className="type-row"><div><h3>Manrope</h3><p>Interface and body</p><code>400 / 500 / 600</code></div><div className="body-specimen"><h4>Keep control of your assets.</h4><p>Explore markets, follow traders, and review every order from your own wallet.</p><span>Aa Bb Cc Dd Ee Ff Gg Hh Ii Jj</span></div></article>
          <article className="type-row"><div><h3>IBM Plex Mono</h3><p>Financial data</p><code>400 / 500 · tabular figures</code></div><div className="number-specimen"><strong>$12,842.90</strong><span>+11.10%<br />0x71F4…9A20</span></div></article>
          <div className="type-scale"><span><b>12</b>Metadata</span><span><b>14</b>Label</span><span><b>16</b>Body</span><span><b>24</b>Section</span><span><b>40-72</b>Display</span></div>
          <p className="system-caption">Serifs stay out of prices, buttons, and forms. All fonts are self-hosted with their open-source licenses.</p>
        </section>
        <section id="components"><h2>Components you can test.</h2><p className="section-intro">These are the same shared styles and controls used in the app. Tab through them to inspect keyboard focus.</p>
          <div className="component-block"><div><h3>Actions</h3><p>One primary action per decision. Directional buttons state the trade in text.</p></div><div className="component-demo"><Button onClick={() => setNotice("Primary action selected. This specimen does not submit a transaction.")}>Review order</Button><Button variant="secondary" onClick={() => setNotice("Secondary action selected.")}>Cancel</Button><Button variant="ghost" onClick={() => setNotice("Order details would open here in the product.")}>View details</Button><Button disabled>Unavailable</Button><Button busy>Submitting…</Button><Button variant="tone-up" onClick={() => setNotice("Buy selected. No transaction submitted.")}>Buy MON</Button><Button variant="tone-down" onClick={() => setNotice("Sell selected. No transaction submitted.")}>Sell MON</Button></div></div>
          <p className="specimen-status" role="status" aria-live="polite">{notice || "Select an action to see its feedback."}</p>
          <div className="component-block"><div><h3>Selection</h3><p>Selected states use a solid fill. Switches announce their state to assistive technology.</p></div><div className="selection-demo"><Seg label="Trade side" options={[{ v: "Buy", l: "Buy" }, { v: "Sell", l: "Sell" }]} value={side} onChange={setSide} /><div className="opt"><span>Price notifications</span><Switch checked={notifications} onChange={setNotifications} label="Price notifications" /></div><div><div className="opt"><label htmlFor="allocation-demo">Allocation</label><output>{amount}%</output></div><Range id="allocation-demo" value={amount} min={0} max={100} onChange={setAmount} label="Allocation" /></div></div></div>
          <div className="component-block"><div><h3>Forms & feedback</h3><p>Labels remain visible. Errors explain how to fix the input and do not rely on red alone.</p></div><form className="form-demo" onSubmit={e => { e.preventDefault(); setSubmitted(true); }} noValidate><label className="field" htmlFor="ticker-demo">Token ticker<input id="ticker-demo" value={ticker} onChange={e => setTicker(e.target.value.toUpperCase())} placeholder="e.g. JENSEN" aria-invalid={error} aria-describedby="ticker-help" /></label><p id="ticker-help" className={error ? "down" : "muted"}>{error ? "Enter 2 to 10 letters, with no spaces or numbers." : submitted ? "Ticker format is valid. No token has been created." : "Use 2 to 10 letters. This is a component example."}</p><Button type="submit" variant="secondary">Validate ticker</Button></form></div>
          <div className="component-block"><div><h3>Empty & loading</h3><p>Explain what happens next. Keep layout dimensions stable while data loads.</p></div><div><Empty icon="wallet" title="No holdings yet" text="Your assets will appear here after your first deposit." /><div className="system-skeleton" role="status" aria-label="Loading token balances"><span /><span /><span /><span className="sr-only">Loading token balances</span></div></div></div>
        </section>
        <section id="structure"><h2>Measured, not ornamental.</h2><div className="system-rules"><article><h3>Spacing</h3><p>A 4px base, with 8, 12, 16, 20, 24, 32, and 48px steps. Dense data rows use consistent alignment, not extra containers.</p><div className="space-specimen">{[4,8,12,16,24,32].map(n => <span key={n}><i style={{width:n}} /><code>{n}</code></span>)}</div></article><article><h3>Shape</h3><p>8px for compact controls, 12px for fields and buttons, 16px for cards, 24px for sheets. Pills are reserved for floating navigation.</p><div className="radius-specimen"><span>8</span><span>12</span><span>16</span><span>24</span></div></article><article><h3>Motion</h3><p>140ms feedback, 220ms selection, 320ms panels. No decorative loops. Reduced motion removes transitions and shimmer.</p></article><article><h3>Glass</h3><p>Reserved for floating navigation. Content, forms, and prices use solid surfaces. Web glass is an approximation, not a native Apple material.</p></article></div></section>
        <footer className="system-footer"><p>DyorHQ · The RWA HQ for social trading</p><Link href="/">Open app preview <Icon name="chev-right" /></Link></footer>
      </main>
    </div>
  </div>;
}
