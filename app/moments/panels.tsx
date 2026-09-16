"use client";

import Link from "next/link";
import { useState, useSyncExternalStore } from "react";
import { Icon } from "../ui/icons";
import { ActionButton, TxStatus } from "../launchpad/ui";
import { BPS, MAX_BATCH, MOMENTS_DEPLOYED, MONTH_SECONDS, STUCK_GRACE_SECONDS, SUPPLY, USDC } from "../lib/moments/config";
import { claim, collect, expire, retryGraduation, runBuyback, withdrawCreatorFees, withdrawCreatorProceeds, withdrawPlatformFees, withdrawPlatformProceeds, withdrawTreasuryProceeds, type CollectMode } from "../lib/moments/actions";
import { fdvUsd, quoteCollect, type AccountView, type MomentDetail } from "../lib/moments/reads";
import { useAsync, useNow } from "../lib/use-async";
import { useTx } from "../lib/use-tx";
import { useWallet } from "../lib/wallet";
import { bpsToPct, fmtDate, fmtNumber, fmtUnits, shortAddress } from "../lib/format";
import { Countdown, DisclosureBox, KV, coinsOf, usd } from "./ui";

const DISCLOSURE_KEY = "dyorhq-moments-disclosure";
const disclosureListeners = new Set<() => void>();
const readDisclosure = () => {
  try {
    return sessionStorage.getItem(DISCLOSURE_KEY) === "1";
  } catch {
    return false;
  }
};
const subscribeDisclosure = (listener: () => void) => {
  disclosureListeners.add(listener);
  return () => {
    disclosureListeners.delete(listener);
  };
};
/** The pre-collect acknowledgement, remembered for the browser session (an external store, so no effect-set-state). */
function useDisclosure(): [boolean, (v: boolean) => void] {
  const ok = useSyncExternalStore(subscribeDisclosure, readDisclosure, () => false);
  return [
    ok,
    (v) => {
      try {
        sessionStorage.setItem(DISCLOSURE_KEY, v ? "1" : "0");
      } catch {
        /* no storage: the box simply does not persist */
      }
      for (const l of disclosureListeners) l();
    },
  ];
}

export function CollectPanel({ moment, view, onDone }: { moment: MomentDetail; view: AccountView | null; onDone: () => void }) {
  const wallet = useWallet();
  const now = useNow();
  const [qty, setQty] = useState(1);
  const [mode, setMode] = useState<CollectMode>("permit2");
  const [agreed, setAgreed] = useDisclosure();
  const { tx, run, reset, busy } = useTx();
  const quote = useAsync(() => quoteCollect(moment.id, qty), `quote:${moment.id}:${qty}`, 6_000);
  const q = quote.data?.quote ?? null;
  const closed = now > 0 && now >= moment.deadline;
  const balance = view?.usdcBalance;
  const insufficient = q !== null && balance !== undefined && q.gross > balance;
  const liquidAtGrad = q ? (q.entitlement * 6_000n) / BPS : 0n;
  const submit = async () => {
    const client = wallet.client;
    if (!client || !q) return;
    const done = await run(`Collect ${q.editions} edition${q.editions === 1n ? "" : "s"}`, (onSent) => collect(client, moment.id, qty, q.gross, mode, onSent));
    if (done) {
      setQty(1);
      onDone();
    }
  };
  return (
    <div className="card trade">
      <h2 className="panel-title">Collect<small>{usd(moment.price)} per edition · USDC</small></h2>
      <div className="qty" role="group" aria-label="Editions">
        <button type="button" aria-label="Fewer" onClick={() => setQty((n) => Math.max(1, n - 1))} disabled={qty <= 1}>−</button>
        <input inputMode="numeric" value={qty} aria-label="Editions to collect" onChange={(e) => { const n = Number(e.target.value.replace(/\D/g, "")); if (Number.isFinite(n)) setQty(Math.min(MAX_BATCH, Math.max(1, n || 1))); }} />
        <button type="button" aria-label="More" onClick={() => setQty((n) => Math.min(MAX_BATCH, n + 1))} disabled={qty >= MAX_BATCH}>+</button>
        <span className="hint">up to {MAX_BATCH} per collect</span>
      </div>
      {balance !== undefined && <p className="hint">Balance: {usd(balance)} USDC</p>}
      <div className="breakdown">
        <div><span>You pay</span><b>{q ? usd(q.gross) : "—"}</b></div>
        <div><span>Editions minted to you</span><b>{q ? `${q.editions} (rank #${moment.editions + 1}${q.editions > 1n ? `–#${moment.editions + Number(q.editions)}` : ""})` : "—"}</b></div>
        <div><span>Coins promised at graduation</span><b>{q ? coinsOf(q.entitlement, moment.symbol) : "—"}</b></div>
        <div><span>Of which liquid on graduation day (60%)</span><b>{q ? coinsOf(liquidAtGrad, moment.symbol) : "—"}</b></div>
        <div><span>To the pool reserve · creator · DyorHQ</span><b>{q ? `${usd(q.reserveIn)} · ${usd(q.creatorIn)} · ${usd(q.platformIn)}` : "—"}</b></div>
        {q?.terminal && <div><span>Completes the Moment</span><b className="warn">Only {usd(q.gross)} is taken{q.excess > 0n ? `; ${usd(q.excess)} of your request is never pulled` : ""}. Graduation runs in the same transaction.</b></div>}
      </div>
      {quote.data?.reason && <p className="hint err">{quote.data.reason}</p>}
      {closed && <p className="hint err">The collect window closed {fmtDate(moment.deadline)}.</p>}
      <DisclosureBox checked={agreed} onChange={setAgreed} moment={moment} />
      <div className="slip" style={{ marginTop: 10 }}>
        <span>Pay with</span>
        <button type="button" aria-pressed={mode === "permit2"} onClick={() => setMode("permit2")} title="Approve Permit2 once, then sign each collect">Permit2 signature</button>
        <button type="button" aria-pressed={mode === "approve"} onClick={() => setMode("approve")} title="An exact USDC approval of the collect contract, then the collect">Plain approval</button>
      </div>
      <TxStatus tx={tx} onDismiss={reset} />
      {insufficient && <p className="hint err">Not enough USDC.</p>}
      <ActionButton requireLaunchpad={false} ready={MOMENTS_DEPLOYED && !!q && agreed && !insufficient && !closed} busy={busy || (quote.loading && !q)} label={<>Collect {q ? `${q.editions} for ${usd(q.gross)}` : ""} <Icon name="arrow-ur" /></>} onClick={submit} className="btn big tone-up" />
      <p className="hint">Window closes {fmtDate(moment.deadline)} (<Countdown until={moment.deadline} now={now} />). Nothing is refunded and nothing is over-pulled: the last collect is clamped so the reserve lands exactly on {usd(moment.threshold)}.</p>
    </div>
  );
}

export function StatePanel({ moment, onDone }: { moment: MomentDetail; onDone: () => void }) {
  const wallet = useWallet();
  const now = useNow();
  const { tx, run, reset, busy } = useTx();
  const l = moment.ledger;
  const expirable = now > 0 && now >= moment.deadline && (l.state === 0 || (l.state === 1 && now >= l.stuckSince + STUCK_GRACE_SECONDS));
  const call = (label: string, action: (onSent: (h: `0x${string}`) => void) => Promise<unknown>) => { const client = wallet.client; if (client) void run(label, action, onDone); };

  if (moment.graduated && moment.pool) {
    const p = moment.pool;
    const price = p.usdcPerCoin;
    const accrued = p.fees.buyback + p.buybackCarry;
    const canBuyback = accrued >= p.buybackMin && (now === 0 || now >= p.lastBuyback + p.buybackInterval);
    const depth = p.seedLiquidity === 0n ? 0 : Number((p.liquidity * 10_000n) / p.seedLiquidity) / 100;
    return (
      <div className="card state-card">
        <h3>Graduated · pool locked on Uniswap v4</h3>
        <p>The reserve reached {usd(p.reserveSeed)} and opened a coin/USDC pool at exactly the collectors&apos; price on {fmtDate(p.graduatedAt)}. The position is owned by a locker with no withdrawal function; it can only grow.</p>
        <div className="kvlist">
          <KV label="Coin price" value={`$${fmtNumber(price)} · FDV $${fmtNumber(fdvUsd(price), { compact: true })}`} />
          <KV label="Seeded" value={`${usd(p.reserveSeed)} + ${coinsOf(p.poolCoins, moment.symbol)}`} />
          <KV label="Locked liquidity vs seed" value={`${depth.toFixed(2)}% (${depth > 100 ? "+" : ""}${(depth - 100).toFixed(2)}% from fees and buybacks)`} />
          <KV label="Trading fee" value="1.5% = 0.5% pool + 0.2% creator + 0.3% DyorHQ + 0.5% buyback" />
          <KV label="Fees accrued" value={`creator ${usd(p.fees.creator)} · DyorHQ ${usd(p.fees.platform)} · buyback ${usd(p.fees.buyback)}`} />
          <KV label="Buyback carry" value={usd(p.buybackCarry)} />
          <KV label="Last buyback" value={p.lastBuyback ? fmtDate(p.lastBuyback) : "never"} />
          <KV label="Pool id" value={<span className="mono">{shortAddress(p.poolId, 6)}</span>} />
        </div>
        <TxStatus tx={tx} onDismiss={reset} />
        <div className="flow-actions" style={{ marginTop: 4 }}>
          <Link className="btn primary" href={`/swap?in=${USDC.address}&out=${moment.coin}`}>Trade ${moment.symbol} <Icon name="arrow-ur" /></Link>
          <button type="button" className="btn secondary" disabled={busy || !canBuyback || !wallet.client} title={canBuyback ? "Buys coin with the accrued 0.5% and adds it to the locked position" : `Needs ${usd(p.buybackMin)} accrued and one hour between rounds`} onClick={() => call("Run buyback", (onSent) => runBuyback(wallet.client!, moment.id, 0n, onSent))}>Run buyback ({usd(accrued)})</button>
        </div>
        <p className="hint">Anyone may run the buyback. It swaps at most a 1% price move per round and can only add liquidity to the locked position.</p>
      </div>
    );
  }
  if (l.state === 3) {
    return (
      <div className="card state-card">
        <h3>Wound down</h3>
        <p>The window closed on {fmtDate(moment.deadline)} without reaching {usd(moment.threshold)}. No coin was ever minted. Editions stay with their collectors; the {usd(l.creatorClaimable + l.treasuryClaimable + l.platformClaimable > 0n ? moment.threshold : 0n)} reserve was booked {bpsToPct(moment.expiryCreatorBps)} to the creator and {bpsToPct(10_000 - moment.expiryCreatorBps)} to the DyorHQ treasury, each to pull at will.</p>
        <div className="kvlist">
          <KV label="Collected in total" value={usd(l.totalGross)} />
          <KV label="Editions" value={String(moment.editions)} />
          <KV label="Ended" value={fmtDate(l.endedAt)} />
        </div>
      </div>
    );
  }
  if (l.state === 1) {
    return (
      <div className="card state-card">
        <h3>Graduation pending</h3>
        <p>The reserve reached {usd(moment.threshold)} but the pool did not open in that transaction. Anyone can retry; every cent is still in the collect contract. {l.stuckSince ? `First failure ${fmtDate(l.stuckSince)}.` : ""} If it keeps failing, the Moment can be wound down {STUCK_GRACE_SECONDS / 86400} days after the first failure and after the window closes.</p>
        <TxStatus tx={tx} onDismiss={reset} />
        <div className="flow-actions">
          <ActionButton requireLaunchpad={false} ready={!busy && !!wallet.client} busy={busy} label="Retry graduation" className="btn secondary" onClick={() => call("Graduate", (onSent) => retryGraduation(wallet.client!, moment.id, onSent))} />
          {expirable && <button type="button" className="btn secondary" disabled={busy} onClick={() => call("Wind down", (onSent) => expire(wallet.client!, moment.id, onSent))}>Wind down</button>}
        </div>
      </div>
    );
  }
  return (
    <div className="card state-card">
      <h3>{expirable ? "Window closed" : "Collecting"}</h3>
      <p>{expirable ? `The window closed on ${fmtDate(moment.deadline)} with ${usd(l.reserve)} of the ${usd(moment.threshold)} reserve. Anyone can wind it down: editions stay, no coin is minted, and the reserve is booked ${bpsToPct(moment.expiryCreatorBps)} to the creator and ${bpsToPct(10_000 - moment.expiryCreatorBps)} to the DyorHQ treasury.` : `Every collect pushes ${bpsToPct(moment.reserveBps)} of its USDC into the reserve. When the reserve reaches ${usd(moment.threshold)} the pool opens in that same transaction at the collectors' price and locks forever. Otherwise the window closes ${fmtDate(moment.deadline)}.`}</p>
      <div className="kvlist">
        <KV label="Reserve" value={`${usd(l.reserve)} of ${usd(moment.threshold)}`} />
        <KV label="Collected in total" value={usd(l.totalGross)} />
        <KV label="Window" value={<Countdown until={moment.deadline} now={now} />} />
      </div>
      <TxStatus tx={tx} onDismiss={reset} />
      {expirable && <ActionButton requireLaunchpad={false} ready={!busy && !!wallet.client} busy={busy} label="Wind down" className="btn secondary" onClick={() => call("Wind down", (onSent) => expire(wallet.client!, moment.id, onSent))} />}
    </div>
  );
}

export function PositionPanel({ moment, view, onDone }: { moment: MomentDetail; view: AccountView; onDone: () => void }) {
  const wallet = useWallet();
  const { tx, run, reset, busy } = useTx();
  const now = useNow();
  const isCreator = wallet.account?.toLowerCase() === moment.creator.toLowerCase();
  const alloc = isCreator ? (SUPPLY * BigInt(moment.creatorAllocBps)) / BPS : 0n;
  const total = view.entitlement + alloc;
  if (total === 0n && view.nftBalance === 0 && view.coinBalance === 0n) return null;
  const claimable = view.claimableCollector + view.claimableCreator;
  const locked = total - view.claimed - claimable;
  const g = moment.pool?.graduatedAt ?? 0;
  const pct = (x: bigint) => (total === 0n ? 0 : Number((x * 10_000n) / total) / 100);
  return (
    <div className="card">
      <h2 className="panel-title">Your position<small>{wallet.account ? shortAddress(wallet.account) : ""}</small></h2>
      <div className="stats-grid">
        <div className="stat"><span>Editions</span><b>{view.nftBalance}</b></div>
        <div className="stat"><span>Coins in wallet</span><b>{coinsOf(view.coinBalance, moment.symbol)}</b></div>
        <div className="stat"><span>{moment.graduated ? "Claimable now" : "Promised at graduation"}</span><b>{coinsOf(moment.graduated ? claimable : total, moment.symbol)}</b></div>
        <div className="stat"><span>Claimed</span><b>{coinsOf(view.claimed, moment.symbol)}</b></div>
      </div>
      {view.nftIds.length > 0 && <div className="nft-strip" aria-label="Your editions">{view.nftIds.map((id) => <span key={String(id)}>#{String(id)}</span>)}{view.nftBalance > view.nftIds.length && <span>+{view.nftBalance - view.nftIds.length}</span>}</div>}
      {total > 0n && (
        <>
          <div className="vest-bar" aria-hidden="true"><i className="claimed" style={{ width: `${pct(view.claimed)}%` }} /><i className="claimable" style={{ width: `${pct(claimable)}%` }} /><i className="locked" style={{ width: `${pct(locked)}%` }} /></div>
          <div className="timeline">
            {moment.graduated ? (
              <>
                <div><span>60% at graduation</span><b>{fmtDate(g)}</b></div>
                <div><span>+20% month 1</span><b>{fmtDate(g + MONTH_SECONDS)}{now > 0 && now < g + MONTH_SECONDS ? " · locked" : ""}</b></div>
                <div><span>+20% month 2</span><b>{fmtDate(g + 2 * MONTH_SECONDS)}{now > 0 && now < g + 2 * MONTH_SECONDS ? " · locked" : ""}</b></div>
                {isCreator && alloc > 0n && <div><span>Creator: 20% at graduation, +16% monthly × 5</span><b>{fmtDate(g + 5 * MONTH_SECONDS)}</b></div>}
              </>
            ) : (
              <div><span>Vesting starts at graduation</span><b>60% → +20% → +20% over two months</b></div>
            )}
          </div>
        </>
      )}
      <div style={{ marginTop: 10 }}><TxStatus tx={tx} onDismiss={reset} /></div>
      {moment.graduated && (
        <div className="claim" style={{ marginTop: 10 }}>
          <div><span>Claimable now</span><b>{coinsOf(claimable, moment.symbol)}</b></div>
          <button type="button" className="btn secondary sm" disabled={busy || claimable === 0n || !wallet.client} onClick={() => { const client = wallet.client; if (client) void run("Claim coins", (onSent) => claim(client, moment.id, onSent), onDone); }}>Claim</button>
        </div>
      )}
      <p className="hint" style={{ marginTop: 10 }}>{fmtUnits(SUPPLY, 18, { compact: true })} coins in total: {bpsToPct(10_000 - moment.creatorAllocBps)} split between collectors and the locked pool by the same rate, {bpsToPct(moment.creatorAllocBps)} to the creator. Claims mint straight to your wallet.</p>
    </div>
  );
}

export function CreatorPanel({ moment, view, onDone }: { moment: MomentDetail; view: AccountView; onDone: () => void }) {
  const wallet = useWallet();
  const { tx, run, reset, busy } = useTx();
  const rows: { label: string; amount: bigint; action: (onSent: (h: `0x${string}`) => void) => Promise<unknown> }[] = [];
  const client = wallet.client;
  if (client) {
    if (view.creatorProceeds > 0n) rows.push({ label: "Creator share of collects", amount: view.creatorProceeds, action: (onSent) => withdrawCreatorProceeds(client, moment.id, onSent) });
    if (view.creatorFees > 0n) rows.push({ label: "Creator share of trading fees", amount: view.creatorFees, action: (onSent) => withdrawCreatorFees(client, moment.id, onSent) });
    if (view.platformProceeds > 0n) rows.push({ label: "DyorHQ share of collects", amount: view.platformProceeds, action: (onSent) => withdrawPlatformProceeds(client, moment.id, onSent) });
    if (view.platformFees > 0n) rows.push({ label: "DyorHQ share of trading fees", amount: view.platformFees, action: (onSent) => withdrawPlatformFees(client, moment.id, onSent) });
    if (view.treasuryProceeds > 0n) rows.push({ label: "Treasury share of the wound-down reserve", amount: view.treasuryProceeds, action: (onSent) => withdrawTreasuryProceeds(client, moment.id, onSent) });
  }
  if (rows.length === 0) return null;
  return (
    <div className="card">
      <h2 className="panel-title">Pull your USDC<small>only the beneficiary wallet can</small></h2>
      {rows.map((r) => (
        <div className="claim" key={r.label} style={{ marginTop: 10 }}>
          <div><span>{r.label}</span><b>{usd(r.amount)}</b></div>
          <button type="button" className="btn secondary sm" disabled={busy} onClick={() => void run(`Withdraw ${usd(r.amount)}`, r.action, onDone)}>Withdraw</button>
        </div>
      ))}
      <div style={{ marginTop: 10 }}><TxStatus tx={tx} onDismiss={reset} /></div>
    </div>
  );
}
