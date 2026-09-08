"use client";

import { useEffect, useMemo, useState } from "react";
import PreviewControls, { type ScreenName } from "./preview-controls";
import PerpsScreen from "./perps-screen";

type Tab = ScreenName;

const markets = [
  { icon: "M", name: "MON", full: "Monad", price: "$1.284", change: "+12.8%", tone: "purple" },
  { icon: "J", name: "JENSEN", full: "paired with aNVDA", price: "$0.0842", change: "+48.2%", tone: "blue" },
  { icon: "B", name: "BTC", full: "Bitcoin", price: "$79,136", change: "-0.86%", tone: "orange" },
  { icon: "E", name: "ETH", full: "Ethereum", price: "$2,493", change: "+0.32%", tone: "ink" },
  { icon: "P", name: "PURPLE", full: "paired with aTSLA", price: "$0.0198", change: "+31.4%", tone: "pink" },
  { icon: "S", name: "SOL", full: "Solana", price: "$103.80", change: "-2.37%", tone: "cyan" },
  { icon: "N", name: "aNVDA", full: "Tokenized NVIDIA", price: "$182.14", change: "+1.72%", tone: "green" },
];

const feed = [
  {
    user: "0xKofi", initials: "KO", time: "2m", action: "BOUGHT", token: "$JENSEN", amount: "$2,480",
    thesis: "Blackwell demand keeps surprising. I’m early to the meme, long the underlying story.",
    pnl: "+38.4%", copies: 42, tone: "blue", badge: "TOP 10",
  },
  {
    user: "monadmaxi", initials: "MM", time: "8m", action: "LAUNCHED", token: "$PURPLE", amount: "aTSLA pair",
    thesis: "The fastest chain deserves the fastest car. Fair launch, no team allocation.",
    pnl: "+21.7%", copies: 19, tone: "pink", badge: "CREATOR",
  },
  {
    user: "ana.chain", initials: "AC", time: "14m", action: "BOUGHT", token: "$CHOG", amount: "$840",
    thesis: "Volume is rotating back into Monad natives. Watching graduation liquidity closely.",
    pnl: "+9.2%", copies: 11, tone: "green", badge: "VERIFIED",
  },
];

function Icon({ children }: { children: React.ReactNode }) {
  return <span className="line-icon" aria-hidden="true">{children}</span>;
}

function StatusBar() {
  return (
    <div className="status-bar" aria-hidden="true">
      <span>9:41</span><span className="island" /><span className="signal">▮▮▮</span><span>⌁</span><span className="battery">100</span>
    </div>
  );
}

function Logo({ small = false }: { small?: boolean }) {
  return <img className={`brand-mark ${small ? "small" : ""}`} src="/brand/dyorhq-mark.png" alt="" />;
}

function GlassButton({ children, className = "", onClick }: { children: React.ReactNode; className?: string; onClick?: () => void }) {
  return <button className={`glass-button ${className}`} onClick={onClick}><span>{children}</span></button>;
}

function AppHeader({ title, subtitle, onMenu }: { title?: string; subtitle?: string; onMenu: () => void }) {
  return (
    <header className="app-header">
      <button className="round-button menu-button" onClick={onMenu} aria-label="Open menu"><i /><i /><i /></button>
      {title ? <div className="header-title"><strong>{title}</strong>{subtitle && <small>{subtitle}</small>}</div> : <div className="search"><Icon>⌕</Icon><span>Search DyorHQ</span></div>}
      <button className="avatar" onClick={onMenu} aria-label="Open profile">JM<span /></button>
    </header>
  );
}

function FeedScreen({ setTab, onMenu }: { setTab: (tab: Tab) => void; onMenu: () => void }) {
  return (
    <main className="screen feed-screen">
      <AppHeader onMenu={onMenu} />
      <section className="hero-card interactive-light">
        <div className="hero-top"><span className="live-pill"><i /> MONAD · PREVIEW</span><span className="muted">24H VOLUME</span></div>
        <h1>The RWA HQ<br /><em>for social trading.</em></h1>
        <p>Launch stock-paired memecoins, follow on-chain traders, and trade on Monad.</p>
        <div className="hero-actions">
          <GlassButton className="primary" onClick={() => setTab("launch")}>Launch a token <b>↗</b></GlassButton>
          <GlassButton onClick={() => setTab("markets")}>Explore</GlassButton>
        </div>
        <div className="orb orb-one" /><div className="orb orb-two" />
      </section>
      <section className="ticker-row" aria-label="Market highlights">
        {markets.slice(0, 3).map((m) => <button key={m.name} onClick={() => setTab("trade")}><span className={`coin ${m.tone}`}>{m.icon}</span><span><b>{m.name}</b><small>{m.price}</small></span><em className={m.change.startsWith("-") ? "loss" : "gain"}>{m.change}</em></button>)}
      </section>
      <div className="section-title"><div><span className="eyebrow">THE STREET</span><h2>Trade feed</h2></div><button>Following⌄</button></div>
      <section className="feed-list">
        {feed.map((item, index) => (
          <article className="trade-card interactive-light" key={item.user}>
            <div className="trade-user"><span className={`user-avatar ${item.tone}`}>{item.initials}</span><div><b>{item.user}</b><small><span className="verified">✓</span> {item.badge}</small></div><time>{item.time}</time><button aria-label="More">•••</button></div>
            <div className="trade-line"><span>{item.action}</span><b>{item.token}</b><strong>{item.amount}</strong></div>
            <p>“{item.thesis}”</p>
            <div className="mini-chart"><i/><i/><i/><i/><i/><i/><i/><i/><span className="chart-glow" /></div>
            <div className="trade-meta"><span>Trade return <b>{item.pnl}</b></span><span>{item.copies} copied</span></div>
            <div className="card-actions"><button>♡ <span>{12 + index * 7}</span></button><button>◌ <span>{4 + index}</span></button><GlassButton className="copy" onClick={() => setTab("trade")}>Copy trade <b>↗</b></GlassButton></div>
          </article>
        ))}
      </section>
    </main>
  );
}

function MarketsScreen({ setTab, onMenu }: { setTab: (tab: Tab) => void; onMenu: () => void }) {
  const [filter, setFilter] = useState("Popular");
  return <main className="screen markets-screen">
    <AppHeader title="Markets" subtitle="Live opportunities" onMenu={onMenu} />
    <div className="big-number"><div><span>TOTAL MARKET VOLUME</span><strong>$842.6M</strong></div><span className="gain">+8.24% today</span></div>
    <div className="segment three"><button className="active">All</button><button>Spot</button><button>Perps</button></div>
    <div className="market-filters">{["Popular", "Hot", "Gainers", "New"].map(x => <button key={x} onClick={() => setFilter(x)} className={filter === x ? "active" : ""}>{x === "Popular" ? "★ " : x === "Hot" ? "◒ " : ""}{x}</button>)}</div>
    <div className="market-count"><span>91 markets</span><span><i /> Sample prices</span></div>
    <section className="market-list">{markets.map((m, index) => <button className="market-row" onClick={() => setTab("trade")} key={m.name}>
      <span className="rank">{index + 1}</span><span className={`coin ${m.tone}`}>{m.icon}</span><span className="market-name"><b>{m.name}{index < 6 && <em>PERP</em>}</b><small>{m.full}</small></span><span className="market-price"><b>{m.price}</b><small className={m.change.startsWith("-") ? "loss" : "gain"}>{m.change}</small></span>
    </button>)}</section>
  </main>;
}

function LaunchScreen({ onMenu }: { onMenu: () => void }) {
  const [mode, setMode] = useState<"discover" | "create">("discover");
  const [pair, setPair] = useState("aNVDA");
  const launches = [
    { name: "JENSEN", pair: "aNVDA", progress: 78, cap: "$184K", tone: "blue", holders: "1,842" },
    { name: "PURPLE", pair: "aTSLA", progress: 51, cap: "$96K", tone: "pink", holders: "824" },
    { name: "APESTREET", pair: "aAAPL", progress: 34, cap: "$42K", tone: "green", holders: "519" },
  ];
  return <main className="screen launch-screen">
    <AppHeader title="Launchpad" subtitle="Memes meet markets" onMenu={onMenu} />
    <div className="segment"><button className={mode === "discover" ? "active" : ""} onClick={() => setMode("discover")}>Discover</button><button className={mode === "create" ? "active" : ""} onClick={() => setMode("create")}>Create</button></div>
    {mode === "discover" ? <>
      <section className="launch-hero interactive-light">
        <span className="eyebrow">THE NEW PRIMITIVE</span><h1>Launch a meme.<br />Pair it with <em>Wall Street.</em></h1>
        <p>Fair-launch tokens paired with real tokenized stocks. Liquidity locks automatically at graduation.</p>
        <GlassButton className="primary" onClick={() => setMode("create")}>Create your token <b>↗</b></GlassButton>
        <div className="stock-stack"><span>N</span><span className="plus">+</span><span>M</span></div>
      </section>
      <div className="section-title"><div><span className="eyebrow">BONDING NOW</span><h2>Trending launches</h2></div><button>View all</button></div>
      <section className="launch-list">{launches.map(x => <article key={x.name} className="launch-card interactive-light">
        <div className="launch-card-top"><span className={`coin large ${x.tone}`}>{x.name[0]}</span><div><h3>${x.name}</h3><p>paired with <b>{x.pair}</b></p></div><span className="gain">↗ {x.progress > 60 ? "48.2" : "21.7"}%</span></div>
        <div className="trust-row"><span>◈ TOKENIZED EXPOSURE</span><span>⌁ LP LOCKS</span></div>
        <div className="progress-label"><span>Graduation progress</span><b>{x.progress}%</b></div><div className="progress"><i style={{width: `${x.progress}%`}} /></div>
        <div className="launch-stats"><span>Market cap <b>{x.cap}</b></span><span>Holders <b>{x.holders}</b></span><GlassButton>View token</GlassButton></div>
      </article>)}</section>
    </> : <CreateLaunch pair={pair} setPair={setPair} />}
  </main>;
}

function CreateLaunch({ pair, setPair }: { pair: string; setPair: (x: string) => void }) {
  const [step, setStep] = useState(1);
  return <section className="create-flow">
    <div className="create-head"><div><span className="eyebrow">STEP {step} OF 3</span><h1>{step === 1 ? "Make it memorable." : step === 2 ? "Choose the market." : "Ready for the street."}</h1></div><span className="step-ring">{step}/3</span></div>
    {step === 1 && <div className="form-card interactive-light"><label>Token artwork<button className="upload"><span>＋</span><b>Add image</b><small>PNG or JPG · Max 5MB</small></button></label><label>Token name<input defaultValue="Jensen's Jacket" /></label><label>Ticker<div className="input-prefix"><span>$</span><input defaultValue="JENSEN" /></div></label><label>Launch thesis<textarea defaultValue="Blackwell demand keeps surprising. A meme for everyone betting on the AI supercycle." /></label></div>}
    {step === 2 && <div className="form-card interactive-light"><h3>Pairing asset</h3><p className="form-hint">Your bonding curve will collect this token. At graduation, both assets move into locked liquidity.</p><div className="pair-grid">{["aNVDA", "aTSLA", "aAAPL", "MON"].map((x, i) => <button key={x} className={pair === x ? "active" : ""} onClick={() => setPair(x)}><span className={`coin ${["green","pink","ink","purple"][i]}`}>{x[1] ?? "M"}</span><b>{x}</b><small>{x === "MON" ? "Monad" : "Tokenized stock"}</small><i>✓</i></button>)}</div><div className="notice"><b>Market-aware launch</b><p>RWA trading follows US market sessions. We’ll show the latest oracle price and clearly mark closed markets.</p></div></div>}
    {step === 3 && <div className="form-card review-card interactive-light"><div className="token-preview"><span className="coin large blue">J</span><div><span>FAIR LAUNCH</span><h2>$JENSEN</h2><p>paired with <b>{pair}</b></p></div></div><div className="review-row"><span>Creator allocation</span><b>0%</b></div><div className="review-row"><span>Graduation threshold</span><b>250 {pair}</b></div><div className="review-row"><span>Curve fee</span><b>1.0%</b></div><div className="review-row"><span>Liquidity lock</span><b className="gain">Permanent</b></div><div className="notice"><b>◈ Transparent by design</b><p>No insider pre-mint. Liquidity migrates and locks automatically when the curve completes.</p></div></div>}
    <div className="flow-actions">{step > 1 && <GlassButton onClick={() => setStep(step - 1)}>Back</GlassButton>}<GlassButton className="primary" onClick={() => setStep(Math.min(3, step + 1))}>{step === 3 ? "Launch on Monad ↗" : "Continue →"}</GlassButton></div>
  </section>;
}

function TradeScreen({ onMenu, onPerps }: { onMenu: () => void; onPerps: () => void }) {
  const [side, setSide] = useState<"Buy" | "Sell">("Buy");
  const [amount, setAmount] = useState("250");
  return <main className="screen trade-screen">
    <div className="segment"><button className="active">Swap</button><button onClick={onPerps}>Perps</button></div>
    <AppHeader title="Trade" subtitle="Best route · Kuru Flow" onMenu={onMenu} />
    <div className="trade-token"><div><span className="coin blue">J</span><span><b>JENSEN / aNVDA</b><small><i /> Curve trading</small></span></div><button>⌄</button></div>
    <section className="price-panel"><div><span>JENSEN PRICE</span><strong>$0.0842</strong><small className="gain">+$0.0276 · 48.2%</small></div><div className="chart-area">{[28,42,34,56,51,68,58,75,70,91,84,96].map((h,i) => <i key={i} style={{height:`${h}%`}} />)}<span /></div></section>
    <div className="stats-strip"><span>Market cap<b>$184.2K</b></span><span>24h volume<b>$92.8K</b></span><span>Holders<b>1,842</b></span></div>
    <div className="segment trade-side"><button className={side === "Buy" ? "active buy" : ""} onClick={() => setSide("Buy")}>Buy</button><button className={side === "Sell" ? "active sell" : ""} onClick={() => setSide("Sell")}>Sell</button></div>
    <section className="order-card interactive-light"><div className="balance"><span>You pay</span><span>Balance 1,840 USDC</span></div><div className="amount-input"><input value={amount} onChange={e => setAmount(e.target.value)} inputMode="decimal"/><button>USDC⌄</button></div><div className="quick-amounts">{["100","250","500","MAX"].map(x => <button key={x} onClick={() => setAmount(x === "MAX" ? "1840" : x)} className={amount === x ? "active" : ""}>{x === "MAX" ? x : `$${x}`}</button>)}</div><div className="swap-direction">↓</div><div className="balance"><span>You receive</span><span>≈ 2,969.12 JENSEN</span></div><div className="receive"><strong>2,969.12</strong><button><span className="coin small blue">J</span>JENSEN</button></div><div className="route"><span>Route</span><b>USDC → aNVDA → JENSEN</b><em>BEST</em></div></section>
    <GlassButton className={`confirm ${side === "Sell" ? "danger" : "primary"}`}>{side} JENSEN <b>↗</b></GlassButton>
    <div className="trade-details"><span>Minimum received <b>2,939.43 JENSEN</b></span><span>Price impact <b className="gain">0.12%</b></span><span>Network <b>Monad · &lt;1 sec</b></span></div>
  </main>;
}

function ProfileScreen({ onMenu }: { onMenu: () => void }) {
  return <main className="screen profile-screen">
    <AppHeader title="Portfolio" subtitle="0x71F4...9A20" onMenu={onMenu} />
    <section className="portfolio-card interactive-light"><div className="portfolio-label"><span>TOTAL BALANCE</span><button>◉</button></div><strong>$12,842.90</strong><div className="portfolio-change"><span className="gain">+$1,284.20 · 11.1%</span><span>THIS MONTH</span></div><div className="portfolio-chart">{[18,22,20,30,27,38,42,35,49,46,62,59,78,70,88,92].map((h,i)=><i key={i} style={{height:`${h}%`}} />)}</div><div className="portfolio-actions"><GlassButton className="primary">Deposit</GlassButton><GlassButton>Withdraw</GlassButton><GlassButton>Send</GlassButton></div></section>
    <div className="section-title"><div><span className="eyebrow">YOUR EDGE</span><h2>Trading stats</h2></div><button>30D⌄</button></div>
    <div className="stats-grid"><div><span>Realized PnL</span><b className="gain">+$2,418</b><small>↑ 18.2%</small></div><div><span>Win rate</span><b>68.4%</b><small>38 trades</small></div><div><span>Copy earnings</span><b>$284.90</b><small>127 copiers</small></div><div><span>Rank</span><b>#142</b><small>Top 4%</small></div></div>
    <div className="section-title"><div><span className="eyebrow">ASSETS</span><h2>Holdings</h2></div><button>Manage</button></div>
    <section className="holdings">{markets.slice(0,4).map((m,i)=><button key={m.name}><span className={`coin ${m.tone}`}>{m.icon}</span><span><b>{m.name}</b><small>{["4,280.00","28,400.18","0.0421","0.8402"][i]} {m.name}</small></span><span><b>{["$5,495.52","$2,391.28","$3,331.60","$2,094.50"][i]}</b><small className={m.change.startsWith("-") ? "loss" : "gain"}>{m.change}</small></span></button>)}</section>
  </main>;
}

function SideMenu({ open, close, setTab }: { open: boolean; close: () => void; setTab: (tab: Tab) => void }) {
  const items: [string, string, Tab][] = [["⌂","Home","feed"],["↗","Markets","markets"],["✦","Launchpad","launch"],["⇅","Trade","trade"],["♙","Leaderboard","feed"],["◎","Portfolio","profile"]];
  return <div className={`menu-overlay ${open ? "open" : ""}`} inert={!open} aria-hidden={!open} onClick={close}><aside onClick={e => e.stopPropagation()}><div className="menu-brand"><Logo/><b>DyorHQ</b><button onClick={close}>×</button></div><div className="menu-user"><span className="avatar large">JM</span><div><b>jerry.main</b><small>0x71F4...9A20</small></div><span>›</span></div><div className="menu-promo"><span>MONAD NATIVE</span><h3>The street moves fast.</h3><p>Preview your wallet and trading preferences.</p><i /></div><nav>{items.map(([icon,label,tab])=><button key={label} onClick={()=>{setTab(tab);close();}}><Icon>{icon}</Icon><span>{label}</span><em>›</em></button>)}</nav><div className="menu-bottom"><button>⚙ Settings</button><button>？ Help & feedback</button></div></aside></div>;
}

function BottomNav({ tab, setTab }: { tab: Tab; setTab: (tab: Tab) => void }) {
  const tabs: [Tab,string,string][] = [["feed","⌂","Home"],["markets","▥","Markets"],["launch","✦","Launch"],["trade","↗","Trade"],["profile","◎","Profile"]];
  return <nav className="bottom-nav">{tabs.map(([id,icon,label])=><button key={id} className={`${tab === id ? "active" : ""} ${id === "launch" ? "launch-tab" : ""}`} onClick={() => setTab(id)}><span>{icon}</span><small>{label}</small></button>)}</nav>;
}

function Particles() {
  const dots = useMemo(() => Array.from({length:18}, (_,i)=>({left:`${(i*37)%100}%`,top:`${(i*53)%100}%`,delay:`${(i%7)*-.8}s`,size: i%4===0 ? 3 : 2})),[]);
  return <div className="particles" aria-hidden="true">{dots.map((d,i)=><i key={i} style={{left:d.left,top:d.top,animationDelay:d.delay,width:d.size,height:d.size}} />)}</div>;
}

export default function Home() {
  const [tab, setTab] = useState<Tab>("feed");
  const [menu, setMenu] = useState(false);
  const [phoneScale, setPhoneScale] = useState(1);
  useEffect(() => {
    const fit = () => setPhoneScale(window.innerWidth >= 760 ? Math.min(1, Math.max(.5, (window.innerHeight - 56) / 956)) : 1);
    fit();
    window.addEventListener("resize", fit);
    return () => window.removeEventListener("resize", fit);
  }, []);
  useEffect(() => {
    const move = (event: PointerEvent) => {
      document.documentElement.style.setProperty("--pointer-x", `${event.clientX}px`);
      document.documentElement.style.setProperty("--pointer-y", `${event.clientY}px`);
      document.documentElement.style.setProperty("--shift-x", `${(event.clientX / innerWidth - .5) * 12}px`);
      document.documentElement.style.setProperty("--shift-y", `${(event.clientY / innerHeight - .5) * 12}px`);
      const target = (event.target as HTMLElement | null)?.closest<HTMLElement>(".interactive-light,.glass-button");
      if (target) {
        const bounds = target.getBoundingClientRect();
        target.style.setProperty("--local-x", `${event.clientX - bounds.left}px`);
        target.style.setProperty("--local-y", `${event.clientY - bounds.top}px`);
      }
    };
    window.addEventListener("pointermove", move, { passive: true });
    return () => window.removeEventListener("pointermove", move);
  }, []);
  return <div className="stage"><PreviewControls screen={tab} onScreen={setTab}/><Particles/><div className="phone-shell" style={{ zoom: phoneScale }}><div className="phone-edge"><StatusBar/><div className="app-scroll" key={tab}>{tab === "feed" && <FeedScreen setTab={setTab} onMenu={()=>setMenu(true)}/>} {tab === "markets" && <MarketsScreen setTab={setTab} onMenu={()=>setMenu(true)}/>} {tab === "launch" && <LaunchScreen onMenu={()=>setMenu(true)}/>} {tab === "trade" && <TradeScreen onMenu={()=>setMenu(true)} onPerps={()=>setTab("perps")}/>} {tab === "perps" && <PerpsScreen onSwap={()=>setTab("trade")}/>} {tab === "profile" && <ProfileScreen onMenu={()=>setMenu(true)}/>}</div><BottomNav tab={tab === "perps" ? "trade" : tab} setTab={setTab}/><SideMenu open={menu} close={()=>setMenu(false)} setTab={setTab}/></div></div></div>;
}
