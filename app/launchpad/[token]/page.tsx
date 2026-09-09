"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { getAddress, isAddress, type Address } from "viem";
import { Icon } from "../../ui/icons";
import { DEPLOYED, explorerAddress } from "../../lib/chain";
import { fetchAccountView, fetchLaunch, priceNumber } from "../../lib/launchpad";
import { useAsync, useNow } from "../../lib/use-async";
import { useWallet } from "../../lib/wallet";
import { bpsToPct, fmtAmount, fmtDate, fmtNumber, fmtUnits, seconds, shortAddress, timeAgo } from "../../lib/format";
import { AddressChip, DeployNotice, PhaseBadge, Progress, Skeleton, Tile, TokenLogo } from "../ui";
import { Position, Row, StatePanel, TradePanel } from "../token-panels";

export default function TokenPage() {
  const params = useParams<{ token: string }>();
  const raw = params?.token ?? "";
  const address: Address | null = isAddress(raw) ? getAddress(raw) : null;
  const wallet = useWallet();
  const now = useNow();
  const launch = useAsync(() => (address ? fetchLaunch(address) : Promise.resolve(null)), `launch:${address ?? ""}`, 6_000);
  const data = launch.data;
  const view = useAsync(
    () => (wallet.account && data ? fetchAccountView(data, wallet.account) : Promise.resolve(null)),
    `view:${address ?? ""}:${wallet.account ?? ""}:${data ? data.phase : "loading"}`,
    8_000,
  );
  const refreshAll = () => { launch.refresh(); view.refresh(); };

  if (!address) return <div className="empty"><span className="glyph"><Icon name="search" /></span><b>Not a token address</b><p>Open a token from the launchpad list.</p></div>;
  if (!DEPLOYED) return <DeployNotice />;
  if (launch.error) return <p className="tx bad" role="alert">{launch.error}</p>;
  if (!data) {
    if (!launch.loading) return <div className="empty"><span className="glyph"><Icon name="rocket" /></span><b>Unknown token</b><p>This address was not launched on the DyorHQ launchpad.</p><Link className="btn secondary sm" href="/launchpad">Back to launches</Link></div>;
    return <div className="token-hero"><Skeleton h={76} w={76} style={{ borderRadius: 22 }} /><div className="token-who"><Skeleton h={28} w="50%" /><Skeleton h={14} w="30%" style={{ marginTop: 10 }} /></div></div>;
  }

  const { pair } = data;
  const socials = [
    ["twitter", "X", data.socials.twitter],
    ["telegram", "Telegram", data.socials.telegram],
    ["website", "Website", data.socials.website],
    ["discord", "Discord", data.socials.discord],
    ["farcaster", "Farcaster", data.socials.farcaster],
  ].filter(([, , url]) => /^https?:\/\//i.test(url));
  const trading = data.phase === 0 && !data.completed && !data.rescued;
  const raised = data.realQuoteReserve > data.graduationThreshold ? data.graduationThreshold : data.realQuoteReserve;

  return (
    <>
      <p style={{ margin: "6px 0 0" }}><Link href="/launchpad" className="sec link" style={{ display: "inline-flex", alignItems: "center", gap: 4, fontSize: 13, fontWeight: 600, color: "var(--accent-ink)", textDecoration: "none" }}><Icon name="chev-left" /> All launches</Link></p>
      <section className="token-hero">
        <TokenLogo src={data.logo} name={data.name} address={data.token} size="lg" />
        <div className="token-who">
          <h1>{data.name} <span className="ticker">${data.symbol}</span> <PhaseBadge launch={data} /></h1>
          <div className="meta">
            <AddressChip address={data.token} label="Token" />
            <AddressChip address={data.deployer} label="Creator" />
            <span className="hint">Launched {fmtDate(data.launchedAt)}{now > 0 ? ` · ${timeAgo(data.launchedAt, now)}` : ""}</span>
          </div>
          {data.description && <p className="desc" style={{ marginTop: 12 }}>{data.description}</p>}
          {socials.length > 0 && (
            <div className="socials" style={{ marginTop: 12 }}>
              {socials.map(([key, label, url]) => <a key={key} href={url} target="_blank" rel="noreferrer">{label} <Icon name="arrow-ur" /></a>)}
            </div>
          )}
        </div>
      </section>

      <div className="stats-4">
        <Tile label="Price" value={`${fmtNumber(priceNumber(data))} ${pair.symbol}`} sub="on the curve" />
        <Tile label="Market cap" value={fmtAmount(data.marketCap, pair.decimals, pair.symbol, { compact: true })} sub={`${fmtUnits(data.supply, 18, { compact: true })} supply`} />
        <Tile label="Raised" value={fmtAmount(raised, pair.decimals, pair.symbol, { compact: true })} sub={`of ${fmtAmount(data.graduationThreshold, pair.decimals, pair.symbol, { compact: true })} to graduate`} />
        <Tile label="Progress" value={`${(data.progressBps / 100).toFixed(1)}%`} sub={<Progress bps={data.progressBps} />} />
      </div>

      <div className="token-layout">
        <div className="stack-cards">
          <div className="card">
            <h2 className="panel-title">About this launch<small>fair launch · no pre-mine</small></h2>
            <div className="kvlist">
              <Row label="Paired asset" value={pair.symbol} />
              <Row label="Trade fee" value={bpsToPct(data.feeBps)} />
              <Row label="Creator tax" value={bpsToPct(data.creatorTaxBps)} />
              <Row label="Fees go to" value={data.holderFeeSharing ? "Token holders (pro rata)" : "Creator wallet"} />
              <Row label="Creator wallet" value={<a href={explorerAddress(data.creatorFeeRecipient)} target="_blank" rel="noreferrer" className="mono" style={{ textDecoration: "none" }}>{shortAddress(data.creatorFeeRecipient)}</a>} />
              <Row label="Launch window" value={`${seconds(data.snipeSchedule.length)} · ${data.snipeSchedule.map((b) => bpsToPct(b)).join(" → ")} → 0%`} />
              <Row label="Bonding curve" value={<a href={explorerAddress(data.curve)} target="_blank" rel="noreferrer" className="mono" style={{ textDecoration: "none" }}>{shortAddress(data.curve)}</a>} />
              <Row label="Still on the curve" value={data.phase === 0 && !data.completed ? `${fmtUnits(data.sellableTokens, 18, { compact: true })} $${data.symbol}` : "Moved to the pool"} />
              <Row label="Reserved for the pool" value={`${fmtUnits(data.reservedTokens, 18, { compact: true })} $${data.symbol}`} />
              <Row label="Liquidity after graduation" value={<span className="up">Locked forever</span>} />
            </div>
          </div>
          <div className="note"><b>How graduation works</b><p>Buys push {pair.symbol} into the curve. Once {fmtAmount(data.graduationThreshold, pair.decimals, pair.symbol, { compact: true })} is raised, the launchpad opens a Uniswap v4 pool at the exact curve price with the raised {pair.symbol} and the reserved supply, and locks the position permanently. Trading fees keep flowing to {data.holderFeeSharing ? "holders" : "the creator"} and the protocol through the pool hook.</p></div>
        </div>
        <div className="stack-cards">
          {trading ? <TradePanel launch={data} view={view.data ?? null} onDone={refreshAll} /> : data.rescued || data.phase === 3 ? <><StatePanel launch={data} onDone={refreshAll} /><TradePanel launch={data} view={view.data ?? null} onDone={refreshAll} /></> : <StatePanel launch={data} onDone={refreshAll} />}
          {view.data && <Position launch={data} view={view.data} onDone={refreshAll} />}
        </div>
      </div>
    </>
  );
}
