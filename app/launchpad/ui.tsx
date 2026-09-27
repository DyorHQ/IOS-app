"use client";

import Link from "next/link";
import { useId, useRef, useState, type CSSProperties, type KeyboardEvent, type MouseEvent, type ReactNode } from "react";
import { Icon } from "../ui/icons";
import { TONES } from "../ui/data";
import { DEPLOYED, explorerAddress, explorerTx } from "../lib/chain";
import { priceNumber, type LaunchInfo } from "../lib/launchpad";
import { bpsToPct, fmtAmount, fmtNumber, shortAddress, timeAgo } from "../lib/format";
import { checkTx, type TxState } from "../lib/use-tx";
import { useWallet } from "../lib/wallet";
import { COPY_FEEDBACK, useCopy } from "../lib/clipboard";

const TONE_LIST = Object.values(TONES);
export const toneFor = (address: string) => TONE_LIST[parseInt(address.slice(2, 8), 16) % TONE_LIST.length];

/** The token's image, or its first letter on the neutral fallback surface (launchpad.css) when there is no usable image. */
export function TokenLogo({ src, name, size = "" }: { src: string; name: string; size?: "" | "lg" | "sm" }) {
  const [brokenSrc, setBrokenSrc] = useState<string | null>(null);
  const usable = /^https?:\/\//i.test(src) && brokenSrc !== src;
  if (usable) return <img className={`tokenlogo ${size}`} src={src} alt="" onError={() => setBrokenSrc(src)} />;
  const letter = (name.trim()[0] ?? "?").toUpperCase();
  return <span className={`tokenlogo fallback ${size}`} aria-hidden="true">{letter}</span>;
}

export function PhaseBadge({ launch }: { launch: Pick<LaunchInfo, "phase" | "completed" | "rescued"> }) {
  if (launch.phase === 2) return <em className="badge accent">Graduated</em>;
  if (launch.phase === 3 || launch.rescued) return <em className="badge down">Refund mode</em>;
  if (launch.phase === 1 || launch.completed) return <em className="badge">Graduation pending</em>;
  return <em className="badge up">Bonding</em>;
}

/** Launches on a factory the owner has since retired keep trading, claiming and graduating through their own contracts. */
export function RetiredBadge({ launch }: { launch: Pick<LaunchInfo, "stack"> }) {
  if (!launch.stack.retired) return null;
  return <em className="badge" title="Launched on a retired launchpad factory. Trading, claims and graduation still run through its own contracts.">Retired launchpad</em>;
}

export function Progress({ bps, label = "Graduation progress" }: { bps: number; label?: string }) {
  const pct = Math.min(100, bps / 100);
  return <div className="progress" role="progressbar" aria-label={label} aria-valuenow={Math.round(pct)} aria-valuemin={0} aria-valuemax={100} aria-valuetext={`${pct.toFixed(1)}%`}><i style={{ width: `${pct}%` }} /></div>;
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
  const [checking, setChecking] = useState(false);
  // The live region stays mounted while idle (empty, out of the layout): a region that appears together with its first
  // message is often not announced. Both branches render the same <div>, so React keeps the one node.
  if (tx.status === "idle") return <div className="sr-only" role="status" />;
  const busy = tx.status === "signing" || tx.status === "pending";
  const text = tx.status === "signing" ? "Confirm in your wallet…" : tx.status === "pending" ? "Waiting for confirmation on Monad…" : tx.status === "success" ? "Confirmed." : tx.message;
  const hash = tx.hash;
  // "unconfirmed" is neither success nor failure: the transaction is out and may still land. Its receipt is read again
  // in the background (lib/use-tx.ts); "Check again" reads it now.
  const recheck = () => {
    if (!hash || checking) return;
    setChecking(true);
    void checkTx(hash).finally(() => setChecking(false));
  };
  return (
    <div className={`tx ${tx.status === "success" ? "ok" : tx.status === "error" ? "bad" : ""}`} role="status">
      {busy ? <span className="spinner" /> : <Icon name={tx.status === "success" ? "check" : tx.status === "unconfirmed" ? "clock" : "x"} />}
      <div><b>{tx.label}</b>{text}{hash && <><br /><a href={explorerTx(hash)} target="_blank" rel="noreferrer">View transaction <Icon name="arrow-ur" /></a></>}{tx.status === "unconfirmed" && hash && <button type="button" className="tx-check" disabled={checking} onClick={recheck}>{checking ? "Checking…" : "Check again"}</button>}</div>
      {onDismiss && !busy && <button type="button" className="tx-x" aria-label={tx.status === "unconfirmed" ? "I have checked the transaction" : "Dismiss"} onClick={() => onDismiss()}><Icon name="x" /></button>}
    </div>
  );
}

/** A message that appears while the user fills a form (why an action is unavailable), in a polite live region that is
    mounted before it has anything to say, so it is announced when it appears. Empty, it takes no space. */
export function LiveHint({ text, error = true, style }: { text: string | null | false | undefined; error?: boolean; style?: CSSProperties }) {
  return text ? <p className={`hint ${error ? "err" : ""}`} role="status" style={style}>{text}</p> : <p className="sr-only" role="status" />;
}

export function AddressChip({ address, label, token = false }: { address: string; label?: string; token?: boolean }) {
  // The tick shows, and the status is announced, only once the clipboard has taken the address.
  const [copied, copy] = useCopy(1200);
  return (
    <span className="addr">
      <a href={`${explorerAddress(address)}${token ? "" : ""}`} target="_blank" rel="noreferrer" style={{ textDecoration: "none", color: "inherit" }}>{label ? `${label} ` : ""}{shortAddress(address)}</a>
      <button type="button" onClick={() => void copy(address)} aria-label={`Copy ${label ? `${label.toLowerCase()} ` : ""}address`} title="Copy" style={{ display: "inline-flex" }}><Icon name={copied === "copied" ? "check" : copied === "failed" ? "x" : "copy"} /></button>
      <span className="sr-only" role="status">{copied === "idle" ? "" : COPY_FEEDBACK[copied]}</span>
    </span>
  );
}

/** A launch's card, a link to its token page. With `onSelect` (the in-app launchpad) a plain click opens the launch in
    place instead of leaving the app; a modified click (new tab or window) still follows the link. */
export function LaunchCard({ launch, now, onSelect }: { launch: LaunchInfo; now: number; onSelect?: () => void }) {
  const { pair } = launch;
  const select = (event: MouseEvent<HTMLAnchorElement>) => {
    if (!onSelect || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    onSelect();
  };
  return (
    <Link href={`/launchpad/${launch.token}`} className="card launch-card link" onClick={select}>
      <div className="launch-top">
        <TokenLogo src={launch.logo} name={launch.name} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <h3><span>{launch.name}</span><span className="ticker">${launch.symbol}</span></h3>
          <p>paired with <b>{pair.symbol}</b>{now > 0 && ` · ${timeAgo(launch.launchedAt, now)}`}</p>
        </div>
        <PhaseBadge launch={launch} />
      </div>
      <div className="trust">
        <RetiredBadge launch={launch} />
        {launch.holderFeeSharing && <em className="badge accent">Holder rewards</em>}
        {launch.creatorTaxBps > 0 && <em className="badge">Creator tax {bpsToPct(launch.creatorTaxBps)}</em>}
        <em className="badge">LP locks at graduation</em>
      </div>
      <div className="progress-label"><span>{launch.phase === 2 ? `Graduated to ${launch.graduationVenue === 1 ? "Monday Trade" : "Uniswap v4"}` : "Graduation progress"}</span><b>{(launch.progressBps / 100).toFixed(1)}%</b></div>
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
  const [copied, copy] = useCopy();
  const trigger = useRef<HTMLButtonElement>(null);
  const popover = useId();
  const account = wallet.account;
  // A disclosure, not an ARIA menu: Tab walks its items, and Escape closes it and returns focus to its button.
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key !== "Escape" || !open) return;
    setOpen(false);
    trigger.current?.focus();
  };
  if (account) {
    const icon = wallet.active?.info.icon;
    return (
      <div className="menu-anchor" onKeyDown={onKeyDown}>
        <button ref={trigger} type="button" className="iconbtn" aria-expanded={open} aria-controls={open ? popover : undefined} onClick={() => setOpen((o) => !o)}>
          {icon ? <img className="wicon" src={icon} alt="" /> : <Icon name="wallet" />}{shortAddress(account)}<Icon name="chev-down" />
        </button>
        {open && (
          <div className="popover card" id={popover}>
            <small>{wallet.active?.info.name ?? "Wallet"}</small>
            <a href={explorerAddress(account)} target="_blank" rel="noreferrer"><Icon name="arrow-ur" />View on Monadscan</a>
            <button type="button" onClick={() => void copy(account)}><Icon name={copied === "copied" ? "check" : "copy"} />{copied === "idle" ? "Copy address" : COPY_FEEDBACK[copied]}</button>
            <button type="button" onClick={() => { wallet.disconnect(); setOpen(false); }}><Icon name="logout" />Disconnect</button>
            <span className="sr-only" role="status">{copied === "idle" ? "" : COPY_FEEDBACK[copied]}</span>
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
    <div className="menu-anchor" onKeyDown={onKeyDown}>
      <button ref={trigger} type="button" className={className} aria-expanded={open} aria-controls={open ? popover : undefined} disabled={wallet.connecting} onClick={() => setOpen((o) => !o)}>{wallet.connecting ? "Connecting…" : "Connect wallet"}</button>
      {open && (
        <div className="popover card" id={popover}>
          <small>Choose a wallet</small>
          {wallet.wallets.map((w) => (
            <button key={w.info.rdns} type="button" onClick={() => { setOpen(false); wallet.connect(w.info.rdns); }}>
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
