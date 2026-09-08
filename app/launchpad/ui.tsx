"use client";

import Link from "next/link";
import { useState, type ReactNode } from "react";
import { Icon } from "../ui/icons";
import { TONES } from "../ui/data";
import { DEPLOYED, explorerAddress, explorerTx } from "../lib/chain";
import { priceNumber, type LaunchInfo } from "../lib/launchpad";
import { bpsToPct, fmtAmount, fmtNumber, shortAddress, timeAgo } from "../lib/format";
import type { TxState } from "../lib/use-tx";
import { useWallet } from "../lib/wallet";

const TONE_LIST = Object.values(TONES);
export const toneFor = (address: string) => TONE_LIST[parseInt(address.slice(2, 8), 16) % TONE_LIST.length];

export function TokenLogo({ src, name, address, size = "" }: { src: string; name: string; address: string; size?: "" | "lg" | "sm" }) {
  const [brokenSrc, setBrokenSrc] = useState<string | null>(null);
  const usable = /^https?:\/\//i.test(src) && brokenSrc !== src;
  if (usable) return <img className={`tokenlogo ${size}`} src={src} alt="" onError={() => setBrokenSrc(src)} />;
  const letter = (name.trim()[0] ?? "?").toUpperCase();
  return <span className={`tokenlogo fallback ${size}`} style={{ background: toneFor(address) }} aria-hidden="true">{letter}</span>;
}

export function PhaseBadge({ launch }: { launch: Pick<LaunchInfo, "phase" | "completed" | "rescued"> }) {
  if (launch.phase === 2) return <em className="badge accent">Graduated</em>;
  if (launch.phase === 3 || launch.rescued) return <em className="badge down">Refund mode</em>;
  if (launch.phase === 1 || launch.completed) return <em className="badge">Graduation pending</em>;
  return <em className="badge up">Bonding</em>;
}

export function Progress({ bps }: { bps: number }) {
  const pct = Math.min(100, bps / 100);
  return <div className="progress" role="progressbar" aria-valuenow={Math.round(pct)} aria-valuemin={0} aria-valuemax={100}><i style={{ width: `${pct}%` }} /></div>;
}

export function Tile({ label, value, sub }: { label: string; value: ReactNode; sub?: ReactNode }) {
  return <div className="tile"><span>{label}</span><b className="num">{value}</b>{sub && <small>{sub}</small>}</div>;
}

export const Skeleton = ({ h = 16, w = "100%", style }: { h?: number; w?: string | number; style?: React.CSSProperties }) => <span className="skeleton" style={{ display: "block", height: h, width: w, ...style }} aria-hidden="true" />;

export function DeployNotice() {
  return (
    <div className="card state-card" style={{ margin: "18px 0" }}>
      <h3>Contracts are not configured yet</h3>
      <p>The launchpad reads from Monad mainnet, but no factory address is set. Deploy from the <code>contracts/</code> folder with the owner wallet, run <code>npm run sync:deployment</code>, and rebuild. Until then this page shows an empty launchpad.</p>
    </div>
  );
}

export function TxStatus({ tx, onDismiss }: { tx: TxState; onDismiss?: () => void }) {
  if (tx.status === "idle") return null;
  const busy = tx.status === "signing" || tx.status === "pending";
  const text = tx.status === "signing" ? "Confirm in your wallet…" : tx.status === "pending" ? "Waiting for confirmation on Monad…" : tx.status === "success" ? "Confirmed." : tx.message;
  return (
    <div className={`tx ${tx.status === "success" ? "ok" : tx.status === "error" ? "bad" : ""}`} role="status">
      {busy ? <span className="spinner" /> : <Icon name={tx.status === "success" ? "check" : "x"} />}
      <div><b>{tx.label}</b>{text}{tx.hash && <><br /><a href={explorerTx(tx.hash)} target="_blank" rel="noreferrer">View transaction <Icon name="arrow-ur" /></a></>}</div>
      {onDismiss && !busy && <button type="button" className="tx-x" aria-label="Dismiss" onClick={onDismiss}><Icon name="x" /></button>}
    </div>
  );
}

export function AddressChip({ address, label, token = false }: { address: string; label?: string; token?: boolean }) {
  const [copied, setCopied] = useState(false);
  const copy = () => {
    navigator.clipboard?.writeText(address).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1200); });
  };
  return (
    <span className="addr">
      <a href={`${explorerAddress(address)}${token ? "" : ""}`} target="_blank" rel="noreferrer" style={{ textDecoration: "none", color: "inherit" }}>{label ? `${label} ` : ""}{shortAddress(address)}</a>
      <button type="button" onClick={copy} aria-label="Copy address" title="Copy" style={{ display: "inline-flex" }}><Icon name={copied ? "check" : "copy"} /></button>
    </span>
  );
}

export function LaunchCard({ launch, now }: { launch: LaunchInfo; now: number }) {
  const { pair } = launch;
  return (
    <Link href={`/launchpad/${launch.token}`} className="card launch-card link">
      <div className="launch-top">
        <TokenLogo src={launch.logo} name={launch.name} address={launch.token} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <h3><span>{launch.name}</span><span className="ticker">${launch.symbol}</span></h3>
          <p>paired with <b>{pair.symbol}</b>{now > 0 && ` · ${timeAgo(launch.launchedAt, now)}`}</p>
        </div>
        <PhaseBadge launch={launch} />
      </div>
      <div className="trust">
        {launch.holderFeeSharing && <em className="badge accent">Holder rewards</em>}
        {launch.creatorTaxBps > 0 && <em className="badge">Creator tax {bpsToPct(launch.creatorTaxBps)}</em>}
        <em className="badge">LP locks at graduation</em>
      </div>
      <div className="progress-label"><span>{launch.phase === 2 ? "Graduated to Uniswap v4" : "Graduation progress"}</span><b>{(launch.progressBps / 100).toFixed(1)}%</b></div>
      <Progress bps={launch.progressBps} />
      <div className="launch-stats">
        <span>Market cap<b>{fmtAmount(launch.marketCap, pair.decimals, pair.symbol, { compact: true })}</b></span>
        <span>Price<b>{fmtNumber(priceNumber(launch))} {pair.symbol}</b></span>
        <span>Raised<b>{fmtAmount(launch.realQuoteReserve > launch.graduationThreshold ? launch.graduationThreshold : launch.realQuoteReserve, pair.decimals, pair.symbol, { compact: true })}</b></span>
      </div>
    </Link>
  );
}

export function NetworkPill() {
  const wallet = useWallet();
  if (wallet.account && !wallet.onMonad) {
    return <button type="button" className="netpill warn" onClick={() => wallet.switchToMonad().catch(() => undefined)}><i />Switch to Monad</button>;
  }
  return <span className="netpill"><i />Monad</span>;
}

export function WalletButton({ className = "btn primary sm" }: { className?: string }) {
  const wallet = useWallet();
  const [open, setOpen] = useState(false);
  const account = wallet.account;
  if (account) {
    const icon = wallet.active?.info.icon;
    return (
      <div className="menu-anchor">
        <button type="button" className="iconbtn" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen((o) => !o)}>
          {icon ? <img className="wicon" src={icon} alt="" /> : <Icon name="wallet" />}{shortAddress(account)}<Icon name="chev-down" />
        </button>
        {open && (
          <div className="popover card" role="menu">
            <small>{wallet.active?.info.name ?? "Wallet"}</small>
            <a href={explorerAddress(account)} target="_blank" rel="noreferrer" role="menuitem"><Icon name="arrow-ur" />View on Monadscan</a>
            <button type="button" role="menuitem" onClick={() => { navigator.clipboard?.writeText(account); setOpen(false); }}><Icon name="copy" />Copy address</button>
            <button type="button" role="menuitem" onClick={() => { wallet.disconnect(); setOpen(false); }}><Icon name="logout" />Disconnect</button>
          </div>
        )}
      </div>
    );
  }
  if (!wallet.ready) return <button type="button" className={className} disabled>Connect wallet</button>;
  if (wallet.wallets.length === 0) return <button type="button" className={className} disabled title="Install a browser wallet such as MetaMask, Rabby or Phantom">No wallet detected</button>;
  if (wallet.wallets.length === 1) {
    const only = wallet.wallets[0];
    return <button type="button" className={className} disabled={wallet.connecting} onClick={() => wallet.connect(only.info.rdns)}>{wallet.connecting ? "Connecting…" : "Connect wallet"}</button>;
  }
  return (
    <div className="menu-anchor">
      <button type="button" className={className} aria-haspopup="menu" aria-expanded={open} disabled={wallet.connecting} onClick={() => setOpen((o) => !o)}>{wallet.connecting ? "Connecting…" : "Connect wallet"}</button>
      {open && (
        <div className="popover card" role="menu">
          <small>Choose a wallet</small>
          {wallet.wallets.map((w) => (
            <button key={w.info.rdns} type="button" role="menuitem" onClick={() => { setOpen(false); wallet.connect(w.info.rdns); }}>
              {w.info.icon ? <img className="wicon" src={w.info.icon} alt="" /> : <Icon name="wallet" />}{w.info.name}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/** The primary call to action for anything that writes: it walks the user through connecting and switching to
    Monad before it ever shows the real label. */
export function ActionButton({ ready, busy, label, onClick, className = "btn primary big", type = "button", requireLaunchpad = true }: { ready: boolean; busy: boolean; label: ReactNode; onClick: () => void; className?: string; type?: "button" | "submit"; requireLaunchpad?: boolean }) {
  const wallet = useWallet();
  if (requireLaunchpad && !DEPLOYED) return <button type="button" className={className} disabled>Contracts not deployed</button>;
  if (!wallet.account) return <WalletButton className={className} />;
  if (!wallet.onMonad) return <button type="button" className={className} onClick={() => wallet.switchToMonad().catch(() => undefined)}>Switch to Monad</button>;
  return <button type={type} className={className} disabled={!ready || busy} onClick={type === "button" ? onClick : undefined}>{busy && <span className="spinner" />}{label}</button>;
}
