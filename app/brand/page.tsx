import type { Metadata } from "next";
import "./brand.css";

export const metadata: Metadata = { title: "DyorHQ — Brand identity" };
const palette = [
  { name: "Signal", value: "#B9F26B", role: "Primary brand & actions", dark: true },
  { name: "Ink", value: "#0C100D", role: "Main background", dark: false },
  { name: "Graphite", value: "#1B211D", role: "Cards & glass", dark: false },
  { name: "Paper", value: "#F2F5EE", role: "Text & light surfaces", dark: true },
];
function Mark({ className = "" }: { className?: string }) { return <img className={className} src="/brand/dyorhq-mark.png" alt="DyorHQ open D symbol" />; }
function Wordmark({ inverse = false }: { inverse?: boolean }) { return <div className={`identity-lockup ${inverse ? "inverse" : ""}`}><Mark/><span>Dyor<span className="wordmark-hq">HQ</span></span></div>; }

export default function Brand() {
  return <main className="brand-page">
    <nav className="brand-nav"><Wordmark/><div><a href="/">Open app preview ↗</a><a href="/brand/dyorhq-mark.png" download>Download logo ↓</a></div></nav>
    <section className="identity-hero"><div><p className="brand-kicker">DYORHQ / VISUAL IDENTITY / 01</p><h1>Conviction starts<br />with a closer look.</h1><p className="identity-tagline">The RWA HQ for social trading</p><p className="identity-description">DyorHQ is a self-custodial mobile app on Monad for launching stock-backed memecoins, copying on-chain traders, and trading perps and swaps.</p><a href="/brand/dyorhq-brand-guide.md" download className="identity-download">Download brand guide <span>↓</span></a></div><div className="master-mark"><Mark/><small>01 — The signal D</small></div></section>
    <section className="identity-system"><div className="identity-section-heading"><span>01 / THE MARK</span><h2>A clear signal.<br />An open perspective.</h2><p>The open D brings together a research lens and a signal moving outward. The strong, simple silhouette gives DyorHQ its own identity on a crowded home screen.</p></div><div className="identity-tiles"><div className="identity-tile primary-tile"><Wordmark/><span>The primary lockup</span></div><div className="identity-tile paper-tile"><Wordmark inverse/><span>One-color use on light</span></div><div className="identity-tile icon-tile"><div className="home-icon"><Mark/></div><span>DyorHQ</span></div><div className="identity-tile scale-tile"><div>{[24,40,64,96].map(size => <Mark key={size} className={`mark-${size}`}/>)}</div><span>Built to stay recognizable at small sizes</span></div></div></section>
    <section className="palette-section"><div className="identity-section-heading"><span>02 / COLOR</span><h2>Quiet foundation.<br />Visible conviction.</h2><p>Signal chartreuse makes key actions easy to find. Deep neutral surfaces keep prices and content readable. Green and red remain reserved for trading direction and returns.</p></div><div className="palette-grid">{palette.map(color => <article key={color.name} style={{background:color.value,color:color.dark?"#0c100d":"#f2f5ee"}}><span>{color.role}</span><div><h3>{color.name}</h3><code>{color.value}</code></div></article>)}</div></section>
    <section className="type-section"><div className="identity-section-heading"><span>03 / TYPOGRAPHY</span><h2>Direct. Precise.<br />Human.</h2><p>Geist for interfaces and the wordmark. Geist Mono for addresses, order IDs, and precise data. Use sentence case and generous spacing.</p></div><div className="type-specimen"><span>GEIST / MEDIUM & SEMIBOLD</span><h3>Do your own research.<br /><em>Find your people.</em></h3><p>Aa Bb Cc Dd Ee Ff Gg Hh Ii Jj Kk Ll Mm</p><code>0123456789 · $2,493.35 · 0x71F4…9A20</code></div></section>
    <section className="brand-application"><div><span className="brand-kicker">04 / IN THE PRODUCT</span><h2>Your research.<br />Your wallet.<br /><em>Your next move.</em></h2><p>The flat logo remains clear while the surrounding interface adds subtle glass, light, and depth.</p><a href="/">Explore the six app screens ↗</a></div><div className="identity-product"><Wordmark/><span className="product-network">MONAD</span><p>Portfolio balance</p><h3>$12,842.90</h3><span className="product-return">+$1,284.20 · 11.1%</span><div className="identity-product-actions"><button>Swap ↗</button><button>Launch a token +</button></div><div className="product-sample"><span>J</span><div><b>JENSEN</b><small>paired with aNVDA</small></div><strong>+48.2%</strong></div><small className="product-caption">Illustrative UI · sample data</small></div></section>
    <footer className="brand-footer"><Wordmark/><p>The RWA HQ for social trading</p><a href="https://iconly.design/" target="_blank" rel="noreferrer">Reference research: Iconly ↗</a></footer>
  </main>;
}
