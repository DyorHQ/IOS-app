"use client";

import Link from "next/link";
import { Icon } from "../../ui/icons";
import { Skeleton, Tile, TxStatus, WalletButton } from "../../launchpad/ui";
import { MOMENTS_DEPLOYED } from "../../lib/moments/config";
import { claim, claimAll } from "../../lib/moments/actions";
import { fetchPortfolio } from "../../lib/moments/reads";
import { useAsync, useNow } from "../../lib/use-async";
import { useTx } from "../../lib/use-tx";
import { useWallet } from "../../lib/wallet";
import { fmtUnits, shortAddress } from "../../lib/format";
import { MomentMedia, MomentsDeployNotice, StateBadge } from "../ui";

export default function Portfolio() {
  const wallet = useWallet();
  const now = useNow();
  const account = wallet.account;
  const { tx, run, reset, busy } = useTx();
  const portfolio = useAsync(() => (account ? fetchPortfolio(account) : Promise.resolve(null)), `portfolio:${account ?? ""}`, 10_000);
  const p = portfolio.data;
  const claimableIds = p ? p.rows.filter((r) => r.claimableCollector + r.claimableCreator > 0n).map((r) => r.moment.id) : [];
  const coins = (wei: bigint) => fmtUnits(wei, 18, { compact: true });

  return (
    <>
      <section className="page-hero">
        <div>
          <span className="eyebrow">Portfolio · Moments</span>
          <h1>Your editions and coins.</h1>
          <p>Coins are promised when you collect, minted only when you claim after graduation: 60% on graduation day, 20% after each of the next two months. Claiming sends them straight to your wallet.</p>
          {!account && <div style={{ marginTop: 14 }}><WalletButton /></div>}
        </div>
        <div className="portfolio-totals">
          <Tile label="Pending" value={p ? coins(p.pending) : account ? <Skeleton h={24} w={60} /> : "—"} sub="promised, not graduated yet" />
          <Tile label="Claimable now" value={p ? coins(p.claimable) : account ? <Skeleton h={24} w={60} /> : "—"} sub="vested and unclaimed" />
          <Tile label="Still vesting" value={p ? coins(p.vesting) : account ? <Skeleton h={24} w={60} /> : "—"} sub="unlocks at the monthly cliffs" />
          <Tile label="Claimed" value={p ? coins(p.claimed) : account ? <Skeleton h={24} w={60} /> : "—"} sub="already in your wallet" />
        </div>
      </section>
      <MomentsDeployNotice />
      {account && MOMENTS_DEPLOYED && (
        <div className="toolbar">
          <span className="hint">{shortAddress(account)}</span>
          <span className="spacer" />
          <button type="button" className="btn primary sm" disabled={busy || claimableIds.length === 0 || !wallet.client} onClick={() => { const client = wallet.client; if (client) void run(`Claim ${claimableIds.length} Moment${claimableIds.length === 1 ? "" : "s"}`, (onSent) => claimAll(client, claimableIds, onSent), () => portfolio.refresh()); }}>Claim all ({claimableIds.length}) <Icon name="arrow-ur" /></button>
        </div>
      )}
      <TxStatus tx={tx} onDismiss={reset} />
      {portfolio.error && <p className="tx bad" role="alert">{portfolio.error}</p>}
      <section className="stack-cards" style={{ marginTop: 16 }}>
        {p?.rows.map((r) => {
          const m = r.moment;
          const claimable = r.claimableCollector + r.claimableCreator;
          return (
            <div className="card" key={String(m.id)} style={{ display: "grid", gridTemplateColumns: "96px 1fr auto", gap: 14, alignItems: "center" }}>
              <div style={{ width: 96 }}><MomentMedia provenance={m.provenance} name={m.name} /></div>
              <div style={{ minWidth: 0 }}>
                <h3 style={{ margin: 0 }}><Link href={`/moments/${m.id}`} style={{ textDecoration: "none", color: "inherit" }}>{m.name}</Link> <span className="ticker">${m.symbol}</span> <StateBadge moment={m} now={now} /></h3>
                <p className="hint" style={{ margin: "4px 0 0" }}>{r.nftBalance} edition{r.nftBalance === 1 ? "" : "s"} · promised {coins(r.entitlement)} · claimed {coins(r.claimed)} · in wallet {coins(r.coinBalance)}{m.creator.toLowerCase() === account?.toLowerCase() ? " · you are the creator" : ""}</p>
              </div>
              <div style={{ textAlign: "right" }}>
                <b className="num">{m.graduated ? coins(claimable) : coins(r.entitlement)}</b>
                <div className="hint">{m.graduated ? "claimable now" : "at graduation"}</div>
                {m.graduated && <button type="button" className="btn secondary sm" style={{ marginTop: 6 }} disabled={busy || claimable === 0n || !wallet.client} onClick={() => { const client = wallet.client; if (client) void run(`Claim $${m.symbol}`, (onSent) => claim(client, m.id, onSent), () => portfolio.refresh()); }}>Claim</button>}
              </div>
            </div>
          );
        })}
        {p && p.rows.length === 0 && <div className="empty"><span className="glyph"><Icon name="rocket" /></span><b>Nothing here yet</b><p>Collect a Moment and it shows up here with its editions and coin schedule.</p><Link className="btn secondary sm" href="/moments">Browse Moments</Link></div>}
      </section>
    </>
  );
}
