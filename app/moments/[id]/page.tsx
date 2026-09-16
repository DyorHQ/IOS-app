"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { Icon } from "../../ui/icons";
import { AddressChip, Progress, Skeleton, Tile } from "../../launchpad/ui";
import { explorerAddress } from "../../lib/chain";
import { MOMENTS_DEPLOYED } from "../../lib/moments/config";
import { fdvUsd, fetchAccountView, fetchMoment } from "../../lib/moments/reads";
import { useAsync, useNow } from "../../lib/use-async";
import { useWallet } from "../../lib/wallet";
import { bpsToPct, fmtDate, fmtNumber, fmtUnits, shortAddress, timeAgo } from "../../lib/format";
import { EarlyLabel, HoldersPanel, KV, MomentMedia, MomentsDeployNotice, StateBadge, ipfsToHttp, usd } from "../ui";
import { CollectPanel, CreatorPanel, PositionPanel, StatePanel } from "../panels";

export default function MomentPage() {
  const params = useParams<{ id: string }>();
  const raw = params?.id ?? "";
  const id = /^\d+$/.test(raw) ? BigInt(raw) : null;
  const wallet = useWallet();
  const now = useNow();
  const moment = useAsync(() => (id ? fetchMoment(id) : Promise.resolve(null)), `moment:${raw}`, 6_000);
  const data = moment.data;
  const view = useAsync(
    () => (wallet.account && data ? fetchAccountView(data, wallet.account) : Promise.resolve(null)),
    `view:${raw}:${wallet.account ?? ""}:${data ? data.ledger.state : "loading"}:${data?.editions ?? 0}`,
    8_000,
  );
  const refreshAll = () => { moment.refresh(); view.refresh(); };

  if (!id) return <div className="empty"><span className="glyph"><Icon name="search" /></span><b>Not a Moment id</b><p>Open a Moment from the list.</p></div>;
  if (!MOMENTS_DEPLOYED) return <MomentsDeployNotice />;
  if (moment.error) return <p className="tx bad" role="alert">{moment.error}</p>;
  if (!data) {
    if (!moment.loading) return <div className="empty"><span className="glyph"><Icon name="rocket" /></span><b>Unknown Moment</b><p>No Moment with this id has been published.</p><Link className="btn secondary sm" href="/moments">Back to Moments</Link></div>;
    return <div className="token-hero"><Skeleton h={220} w="100%" style={{ borderRadius: 22 }} /></div>;
  }

  const collecting = data.ledger.state === 0 && (now === 0 || now < data.deadline);
  const price = data.pool?.usdcPerCoin ?? null;
  const prov = data.provenance;

  return (
    <>
      <p style={{ margin: "6px 0 0" }}><Link href="/moments" className="sec link" style={{ display: "inline-flex", alignItems: "center", gap: 4, fontSize: 13, fontWeight: 600, color: "var(--accent-ink)", textDecoration: "none" }}><Icon name="chev-left" /> All Moments</Link></p>
      <section className="token-hero" style={{ alignItems: "flex-start" }}>
        <div style={{ flex: "0 0 min(46%, 480px)", width: "100%" }}><MomentMedia provenance={prov} name={data.name} hero /></div>
        <div className="token-who">
          <h1>{data.name} <span className="ticker">${data.symbol}</span> <StateBadge moment={data} now={now} /></h1>
          <div className="trust" style={{ marginTop: 6 }}><EarlyLabel /><em className="badge">{data.editions} edition{data.editions === 1 ? "" : "s"}{data.closed ? " · fixed" : " · open"}</em></div>
          <div className="meta" style={{ marginTop: 10 }}>
            <AddressChip address={data.creator} label="Creator" />
            <AddressChip address={data.nft} label="NFT" />
            <AddressChip address={data.coin} label="Coin" />
            <span className="hint">Published {fmtDate(data.publishedAt)}{now > 0 ? ` · ${timeAgo(data.publishedAt, now)}` : ""}</span>
          </div>
          <div className="kvlist" style={{ marginTop: 12 }}>
            <KV label="Place" value={prov.place} />
            <KV label="Date" value={fmtDate(prov.date)} />
            <KV label="Media" value={<a href={ipfsToHttp(prov.mediaURI)} target="_blank" rel="noreferrer" className="mono" style={{ textDecoration: "none" }}>{prov.mediaURI.length > 34 ? `${prov.mediaURI.slice(0, 34)}…` : prov.mediaURI}</a>} />
            <KV label="Media hash" value={<span className="mono-sm">{prov.mediaHash}</span>} />
            {prov.animationURI && <KV label="Video" value={<a href={ipfsToHttp(prov.animationURI)} target="_blank" rel="noreferrer" className="mono" style={{ textDecoration: "none" }}>open</a>} />}
            {data.externalUrl && <KV label="Page" value={<a href={data.externalUrl} target="_blank" rel="noreferrer">{data.externalUrl}</a>} />}
          </div>
        </div>
      </section>

      <div className="stats-4">
        <Tile label={data.graduated && price !== null ? "Coin price" : "Collect price"} value={data.graduated && price !== null ? `$${fmtNumber(price)}` : usd(data.price)} sub={data.graduated && price !== null ? `FDV $${fmtNumber(fdvUsd(price), { compact: true })}` : "per edition, USDC"} />
        <Tile label={data.graduated ? "Seeded" : "Reserve"} value={data.graduated ? usd(data.pool?.reserveSeed ?? data.threshold) : usd(data.ledger.reserve)} sub={data.graduated ? `${usd(data.ledger.totalGross)} collected in total` : `of ${usd(data.threshold)} to graduate`} />
        <Tile label="Editions" value={String(data.editions)} sub={`${data.ledger.collects} collect${data.ledger.collects === 1 ? "" : "s"}`} />
        <Tile label="Progress" value={`${(data.progressBps / 100).toFixed(1)}%`} sub={<Progress bps={data.progressBps} />} />
      </div>

      <div className="token-layout">
        <div className="stack-cards">
          <div className="card">
            <h2 className="panel-title">About this Moment<small>fixed at publish · no admin can change it</small></h2>
            <div className="kvlist">
              <KV label="Settlement" value="USDC (6 decimals) · coin 18 decimals" />
              <KV label="Each collect" value={`${bpsToPct(data.reserveBps)} reserve · ${bpsToPct(data.creatorBps)} creator · ${bpsToPct(data.platformBps)} DyorHQ`} />
              <KV label="Graduates at" value={`${usd(data.threshold)} in the reserve`} />
              <KV label="Coins per USDC collected" value={`${fmtNumber(Number(data.rateNum) / Number(data.rateDen) / 1e12, { compact: true })} $${data.symbol}`} />
              <KV label="Supply" value={`${fmtUnits(data.supply.entitlements + data.supply.remainderPool + data.supply.creatorAlloc, 18, { compact: true })} = collectors ${fmtUnits(data.supply.entitlements, 18, { compact: true })} + pool ${fmtUnits(data.supply.remainderPool, 18, { compact: true })} + creator ${fmtUnits(data.supply.creatorAlloc, 18, { compact: true })}`} />
              <KV label="Creator allocation" value={`${bpsToPct(data.creatorAllocBps)} · 20% at graduation, +16%/month`} />
              <KV label="Collector vesting" value="60% at graduation · +20% month 1 · +20% month 2" />
              <KV label="Window" value={`${fmtDate(data.publishedAt)} → ${fmtDate(data.deadline)}`} />
              <KV label="If it never graduates" value={`editions stay; reserve ${bpsToPct(data.expiryCreatorBps)} creator / ${bpsToPct(10_000 - data.expiryCreatorBps)} treasury`} />
              <KV label="NFT royalty" value={`${bpsToPct(data.royaltyBps)} to the creator (ERC-2981)`} />
              <KV label="Pool" value={data.pool ? <a href={explorerAddress(data.pool.key.hooks)} target="_blank" rel="noreferrer" className="mono" style={{ textDecoration: "none" }}>hooked coin/USDC · {shortAddress(data.pool.poolId, 6)}</a> : "opens at graduation, 0.5% LP fee + 1% hook fee"} />
              <KV label="Liquidity" value={<span className="up">Locked forever · can only grow</span>} />
            </div>
          </div>
          <HoldersPanel moment={data} />
          <div className="note"><b>How this works</b><p>Collectors pay a fixed price for numbered editions; {bpsToPct(data.reserveBps)} of every collect builds a reserve. When the reserve reaches {usd(data.threshold)}, the same transaction opens a Uniswap v4 pool at exactly the price collectors paid and locks it. Collectors then claim their coins over two months; the creator over five. Trades pay 1.5%: 0.5% stays in the pool, 0.2% goes to the creator, 0.3% to DyorHQ and 0.5% buys the coin back into the locked pool. If the window closes first, no coin is ever minted.</p></div>
        </div>
        <div className="stack-cards">
          {collecting ? <CollectPanel moment={data} view={view.data ?? null} onDone={refreshAll} /> : <StatePanel moment={data} onDone={refreshAll} />}
          {collecting && <StatePanel moment={data} onDone={refreshAll} />}
          {view.data && <PositionPanel moment={data} view={view.data} onDone={refreshAll} />}
          {view.data && <CreatorPanel moment={data} view={view.data} onDone={refreshAll} />}
        </div>
      </div>
    </>
  );
}
