"use client";

import Link from "next/link";
import { useState, type ReactNode } from "react";
import type { Address } from "viem";
import { Icon } from "../ui/icons";
import { Progress, Skeleton, toneFor } from "../launchpad/ui";
import { MOMENTS_DEPLOYED, USDC } from "../lib/moments/config";
import { fetchHolderStats } from "../lib/moments/holders";
import { STATES, fdvUsd, fetchNftHolders, type MomentInfo, type Provenance } from "../lib/moments/reads";
import { useAsync } from "../lib/use-async";
import { bpsToPct, fmtNumber, fmtUnits, shortAddress, timeAgo } from "../lib/format";

/* Shared Moments pieces. Containment (spec §12): every coin shows holder count + top-holder share, every Moment is
   labelled early / low-cap / validation, and there is no "proven demand" badge anywhere. */

export const usd = (units: bigint, opts?: { compact?: boolean; dp?: number }) => `$${fmtUnits(units, USDC.decimals, opts)}`;
export const coinsOf = (wei: bigint, symbol: string, compact = true) => `${fmtUnits(wei, 18, { compact })} $${symbol}`;

export function ipfsToHttp(uri: string): string {
  if (/^ipfs:\/\//i.test(uri)) return `https://ipfs.io/ipfs/${uri.slice(7).replace(/^ipfs\//, "")}`;
  return uri;
}
const isVideo = (uri: string) => /\.(mp4|webm|mov|m4v)(\?|$)/i.test(uri);

export function MomentMedia({ provenance, name, hero = false }: { provenance: Pick<Provenance, "mediaURI" | "animationURI">; name: string; hero?: boolean }) {
  const [broken, setBroken] = useState(false);
  const image = ipfsToHttp(provenance.mediaURI);
  const animation = provenance.animationURI ? ipfsToHttp(provenance.animationURI) : "";
  const usable = /^https?:\/\//i.test(image) && !broken;
  return (
    <div className={`moment-media ${hero ? "hero" : ""}`}>
      {animation && isVideo(animation) ? (
        <video src={animation} poster={usable ? image : undefined} controls muted playsInline preload="metadata" aria-label={name} />
      ) : usable ? (
        <img src={image} alt={name} loading="lazy" onError={() => setBroken(true)} />
      ) : (
        <span className="placeholder" aria-hidden="true"><Icon name="rocket" /></span>
      )}
    </div>
  );
}

export function StateBadge({ moment, now }: { moment: Pick<MomentInfo, "ledger" | "graduated" | "deadline">; now?: number }) {
  const state = moment.ledger.state;
  if (moment.graduated || state === 2) return <em className="badge accent">Graduated</em>;
  if (state === 3) return <em className="badge down">Expired</em>;
  if (state === 1) return <em className="badge">Graduation pending</em>;
  if (now && now >= moment.deadline) return <em className="badge">Window closed</em>;
  return <em className="badge up">Collecting</em>;
}

export const EarlyLabel = () => <span className="label-early" title="Validation-stage asset: small pool, few holders, price can move a lot">Early · low-cap · validation</span>;

export function Countdown({ until, now }: { until: number; now: number }) {
  if (now === 0) return <span>…</span>;
  const left = until - now;
  if (left <= 0) return <span>closed</span>;
  const d = Math.floor(left / 86400);
  const h = Math.floor((left % 86400) / 3600);
  const m = Math.floor((left % 3600) / 60);
  return <span>{d > 0 ? `${d}d ${h}h` : h > 0 ? `${h}h ${m}m` : `${m}m`} left</span>;
}

export function MomentCard({ moment, now }: { moment: MomentInfo; now: number }) {
  const price = moment.pool ? moment.pool.usdcPerCoin : null;
  return (
    <Link href={`/moments/${moment.id}`} className="card moment-card link">
      <div className="media"><MomentMedia provenance={moment.provenance} name={moment.name} /></div>
      <div className="body">
        <div className="launch-top" style={{ marginBottom: 6 }}>
          <div style={{ flex: 1, minWidth: 0 }}>
            <h3><span>{moment.name}</span><span className="ticker">${moment.symbol}</span></h3>
            <p className="place">{moment.provenance.place}{now > 0 && ` · ${timeAgo(moment.publishedAt, now)}`}</p>
          </div>
          <StateBadge moment={moment} now={now} />
        </div>
        <div className="trust"><EarlyLabel /><em className="badge">{moment.editions} edition{moment.editions === 1 ? "" : "s"}</em></div>
        <div className="progress-label"><span>{moment.graduated ? "Pool locked on Uniswap v4" : moment.ledger.state === 3 ? "Wound down" : "Reserve to graduation"}</span><b>{(moment.progressBps / 100).toFixed(1)}%</b></div>
        <Progress bps={moment.progressBps} />
        <div className="launch-stats">
          <span>{moment.graduated ? "Coin price" : "Collect price"}<b>{moment.graduated && price !== null ? `$${fmtNumber(price)}` : usd(moment.price)}</b></span>
          <span>{moment.graduated && price !== null ? "FDV" : "Raised"}<b>{moment.graduated && price !== null ? `$${fmtNumber(fdvUsd(price), { compact: true })}` : usd(moment.ledger.totalGross)}</b></span>
          <span>{moment.ledger.state === 0 ? "Window" : "Collectors' coins"}<b>{moment.ledger.state === 0 ? <Countdown until={moment.deadline} now={now} /> : fmtUnits(moment.entitlements, 18, { compact: true })}</b></span>
        </div>
      </div>
    </Link>
  );
}

export function MomentsDeployNotice() {
  if (MOMENTS_DEPLOYED) return null;
  return (
    <div className="card state-card" style={{ margin: "18px 0" }}>
      <h3>Moments contracts are not configured</h3>
      <p>No factory address is set. Run <code>npm run sync:moments</code> after deploying and rebuild.</p>
    </div>
  );
}

/** Plain-language pre-collect disclosure (spec §12). Must be acknowledged before the collect button enables. */
export function DisclosureBox({ checked, onChange, moment }: { checked: boolean; onChange: (v: boolean) => void; moment: MomentInfo }) {
  return (
    <div className="disclosure-box" role="note">
      <b>Before you collect</b>
      This is a validation-stage asset, not an investment product. Plainly:
      <ul>
        <li>You pay <b>{usd(moment.price)}</b> per edition in USDC. {bpsToPct(moment.creatorBps)} goes to the creator, {bpsToPct(moment.platformBps)} to DyorHQ and {bpsToPct(moment.reserveBps)} seeds a pool that only opens if the reserve reaches <b>{usd(moment.threshold)}</b> before the window closes.</li>
        <li>Your coins exist only if the Moment graduates. They vest 60% at graduation and 20% after each of the next two months. If it never graduates you keep the NFT; the reserve is wound down 70% to the creator and 30% to the DyorHQ treasury.</li>
        <li>The pool is tiny (about {usd(moment.threshold)} of USDC). Selling even a small share of the coins moves the price a lot, and every trade pays a 1.5% fee. Anyone, including the creator, can hold most of the supply.</li>
        <li>Coins can lose all of their value. Selling may be taxable where you live. Nothing here is advice.</li>
      </ul>
      <label><input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} />I understand what I am paying for and that the coins may be worth nothing.</label>
    </div>
  );
}

/** Holder count + top-holder share, on every graduated coin, plus the NFT edition holders. */
export function HoldersPanel({ moment }: { moment: MomentInfo }) {
  const stats = useAsync(() => (moment.graduated ? fetchHolderStats(moment.coin, moment.publishedAt) : Promise.resolve(null)), `holders:${moment.coin}:${moment.graduated ? 1 : 0}`, 30_000);
  const nft = useAsync(() => fetchNftHolders(moment.nft, moment.editions), `nft-holders:${moment.nft}:${moment.editions}`, 30_000);
  const s = stats.data;
  const n = nft.data;
  return (
    <div className="card">
      <h2 className="panel-title">Who holds it<small>read straight from the chain</small></h2>
      <div className="holders">
        <div className="stat"><b>{s ? s.holders.toLocaleString("en-US") : moment.graduated ? <Skeleton h={22} w={40} /> : "—"}</b><span>coin holders</span></div>
        <div className="stat"><b>{s ? (s.holders === 0 ? "—" : bpsToPct(s.topHolderBps, 1)) : moment.graduated ? <Skeleton h={22} w={48} /> : "—"}</b><span>largest wallet, of circulating</span></div>
        <div className="stat"><b>{s ? bpsToPct(s.poolBps, 1) : moment.graduated ? <Skeleton h={22} w={48} /> : "—"}</b><span>of minted coins in the locked pool</span></div>
        <div className="stat"><b>{n ? n.holders.toLocaleString("en-US") : <Skeleton h={22} w={40} />}</b><span>edition holders</span></div>
        <div className="stat"><b>{n && moment.editions > 0 ? `${n.topCount} / ${moment.editions}` : "—"}</b><span>editions held by the largest collector</span></div>
        <div className="stat"><b>{moment.graduated ? `${fmtUnits(moment.entitlements, 18, { compact: true })}` : "—"}</b><span>coins promised to collectors</span></div>
      </div>
      {s?.topHolder && <p className="hint" style={{ marginTop: 10 }}>Largest wallet: <a href={`https://monadscan.com/address/${s.topHolder}`} target="_blank" rel="noreferrer" className="mono">{shortAddress(s.topHolder)}</a>{s.topHolder.toLowerCase() === moment.creator.toLowerCase() ? " (the creator)" : ""}. A single large holder can sell into the pool at any time.</p>}
      {stats.error && <p className="hint err">{stats.error}</p>}
      {!moment.graduated && <p className="hint" style={{ marginTop: 10 }}>No coin exists before graduation. Holder statistics appear once the pool opens.</p>}
    </div>
  );
}

export function KV({ label, value }: { label: string; value: ReactNode }) {
  return <div className="review-row"><span>{label}</span><b>{value}</b></div>;
}

export const stateName = (moment: Pick<MomentInfo, "ledger" | "graduated">) => (moment.graduated ? STATES[2] : STATES[moment.ledger.state]);
export const addressTone = (address: Address) => toneFor(address);
