"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useDeferredValue, useState } from "react";
import { getAddress, isAddress, type Address } from "viem";
import { Icon } from "../../ui/icons";
import { Seg, type SegOpt } from "../../ui/components";
import { DEPLOYED, explorerAddress } from "../../lib/chain";
import { fetchAccountView, fetchLaunch, priceNumber, quoteBuy, quoteSell, type AccountView, type LaunchDetail } from "../../lib/launchpad";
import { buy, claimEscrow, claimHolderRewards, retryGraduation, sell, sweepPoolFees } from "../../lib/actions";
import { useAsync, useNow } from "../../lib/use-async";
import { useTx } from "../../lib/use-tx";
import { useWallet } from "../../lib/wallet";
import { bpsToPct, fmtAmount, fmtDate, fmtNumber, fmtUnits, parseAmount, seconds, shortAddress, timeAgo } from "../../lib/format";
import { ActionButton, AddressChip, DeployNotice, PhaseBadge, Progress, Skeleton, Tile, TokenLogo, TxStatus } from "../ui";

type Side = "buy" | "sell";
const SIDES: SegOpt<Side>[] = [{ v: "buy", l: "Buy" }, { v: "sell", l: "Sell" }];
const SLIPPAGES = [50, 100, 300, 500];
const BUY_PRESETS = ["0.5", "1", "5", "10"];
const SELL_PRESETS = [25, 50, 75, 100];

function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return <div className="review-row"><span>{label}</span><b>{value}</b></div>;
}

function TradePanel({ launch, view, onDone }: { launch: LaunchDetail; view: AccountView | null; onDone: () => void }) {
  const wallet = useWallet();
  const { pair } = launch;
  const [side, setSide] = useState<Side>("buy");
  const [amount, setAmount] = useState("");
  const [slippageBps, setSlippage] = useState(100);
  const { tx, run, reset, busy } = useTx();
  const now = useNow();
  const deferredAmount = useDeferredValue(amount);
  const decimals = side === "buy" ? pair.decimals : 18;
  const parsed = parseAmount(deferredAmount, decimals);
  const recipient = wallet.account ?? launch.curve;
  const quote = useAsync(
    async () => {
      if (!parsed || parsed === 0n) return null;
      return side === "buy" ? { kind: "buy" as const, ...(await quoteBuy(launch.curve, parsed, recipient)) } : { kind: "sell" as const, ...(await quoteSell(launch.curve, parsed)) };
    },
    `quote:${side}:${parsed ?? ""}:${recipient}`,
    5_000,
  );
  const q = quote.data;
  const out = q ? (q.kind === "buy" ? q.tokensOut : q.quoteOut) : 0n;
  const minOut = (out * BigInt(10_000 - slippageBps)) / 10_000n;
  // Clamped to the schedule length so a chain clock ahead of the browser never shows a longer window.
  const windowLeft = now === 0 ? 0 : Math.min(launch.snipeSchedule.length, Math.max(0, launch.launchedAt + launch.snipeSchedule.length - now));
  const snipeBps = view?.snipeTaxBps ?? (windowLeft > 0 ? launch.snipeSchedule[Math.max(0, Math.min(launch.snipeSchedule.length - 1, now - launch.launchedAt))] ?? 0 : 0);
  const balance = side === "buy" ? view?.pairBalance : view?.tokenBalance;
  const submit = async () => {
    const client = wallet.client;
    if (!client || !parsed || parsed === 0n || !q) return;
    const done = await run(
      side === "buy" ? `Buy $${launch.symbol}` : `Sell $${launch.symbol}`,
      (onSent) => (side === "buy" ? buy(client, launch.curve, launch.pairToken, pair.native, parsed, minOut, onSent) : sell(client, launch.token, launch.curve, parsed, minOut, onSent)),
    );
    if (done) {
      setAmount("");
      onDone();
    }
  };
  const setPreset = (v: string | number) => {
    if (side === "buy") setAmount(String(v));
    else if (view) setAmount(fmtUnits((view.tokenBalance * BigInt(v)) / 100n, 18, { dp: 6 }).replace(/,/g, ""));
  };
  const insufficient = balance !== undefined && parsed !== null && parsed > balance + (side === "buy" ? 0n : 0n);
  return (
    <div className="card trade">
      <Seg options={SIDES} value={side} onChange={(s) => { setSide(s); setAmount(""); reset(); }} tone="dir" />
      <label className="amount">
        <input inputMode="decimal" placeholder="0" aria-label={side === "buy" ? `Amount in ${pair.symbol}` : `Amount in ${launch.symbol}`} value={amount} onChange={(e) => setAmount(e.target.value)} />
        <span className="tok">{side === "buy" ? pair.symbol : `$${launch.symbol}`}</span>
      </label>
      <div className="presets">
        {side === "buy" ? BUY_PRESETS.map((p) => <button key={p} type="button" aria-pressed={amount === p} onClick={() => setPreset(p)}>{p} {pair.symbol}</button>) : SELL_PRESETS.map((p) => <button key={p} type="button" onClick={() => setPreset(p)} disabled={!view}>{p}%</button>)}
      </div>
      {balance !== undefined && <p className="hint">Balance: {fmtAmount(balance, decimals, side === "buy" ? pair.symbol : launch.symbol)}</p>}
      {windowLeft > 0 && side === "buy" && (
        <div className="warnbox"><b>Launch window.</b> {snipeBps === 0 ? `Other buyers pay a snipe tax for ${seconds(windowLeft)} more; your wallet is exempt.` : `A ${bpsToPct(snipeBps)} snipe tax applies to buys for ${seconds(windowLeft)} more. It funds the protocol and the creator, just like the trade fee.`}</div>
      )}
      <div className="breakdown">
        <div><span>You receive</span><b>{q ? `${fmtUnits(out, side === "buy" ? 18 : pair.decimals)} ${side === "buy" ? `$${launch.symbol}` : pair.symbol}` : "—"}</b></div>
        {q && q.kind === "buy" && <div><span>Trade fee {bpsToPct(launch.feeBps)}{launch.creatorTaxBps ? ` + creator tax ${bpsToPct(launch.creatorTaxBps)}` : ""}</span><b>{fmtAmount(q.fee + q.tax, pair.decimals, pair.symbol)}</b></div>}
        {q && q.kind === "buy" && q.snipe > 0n && <div><span>Snipe tax</span><b className="warn">{fmtAmount(q.snipe, pair.decimals, pair.symbol)}</b></div>}
        {q && q.kind === "buy" && q.refund > 0n && <div><span>Refunded (curve completes)</span><b>{fmtAmount(q.refund, pair.decimals, pair.symbol)}</b></div>}
        {q && q.kind === "sell" && <div><span>Trade fee {bpsToPct(launch.feeBps)}{launch.creatorTaxBps ? ` + creator tax ${bpsToPct(launch.creatorTaxBps)}` : ""}</span><b>{fmtAmount(q.fee + q.tax, pair.decimals, pair.symbol)}</b></div>}
        <div><span>Minimum after slippage</span><b>{q ? fmtUnits(minOut, side === "buy" ? 18 : pair.decimals) : "—"}</b></div>
      </div>
      <div className="slip"><span>Slippage</span>{SLIPPAGES.map((s) => <button key={s} type="button" aria-pressed={slippageBps === s} onClick={() => setSlippage(s)}>{bpsToPct(s)}</button>)}</div>
      <TxStatus tx={tx} onDismiss={reset} />
      {quote.error && <p className="hint err">{quote.error}</p>}
      {insufficient && <p className="hint err">Insufficient balance.</p>}
      <ActionButton ready={!!q && out > 0n && !insufficient} busy={busy || (quote.loading && !!parsed)} label={side === "buy" ? `Buy $${launch.symbol}` : `Sell $${launch.symbol}`} onClick={submit} className={`btn big ${side === "buy" ? "tone-up" : "tone-down"}`} />
    </div>
  );
}

function StatePanel({ launch, onDone }: { launch: LaunchDetail; onDone: () => void }) {
  const wallet = useWallet();
  const { tx, run, reset, busy } = useTx();
  const pending = launch.hookPendingFees + launch.hookPendingTax;
  if (launch.phase === 2) {
    return (
      <div className="card state-card">
        <h3>Graduated to Uniswap v4</h3>
        <p>The curve raised its threshold. Its {launch.pair.symbol} and the remaining supply now sit in a full-range Uniswap v4 position on Monad that nobody can withdraw. Swaps pay the same {bpsToPct(launch.poolFeeBps)} fee through the launchpad hook.</p>
        <div className="kvlist">
          <Row label="Pool id" value={<span className="mono">{shortAddress(launch.poolId, 6)}</span>} />
          <Row label="Swept into the pool" value={fmtAmount(launch.sweptQuote, launch.pair.decimals, launch.pair.symbol, { compact: true })} />
          <Row label="Undistributed pool fees" value={fmtAmount(pending, launch.pair.decimals, launch.pair.symbol)} />
        </div>
        <TxStatus tx={tx} onDismiss={reset} />
        {pending > 0n && wallet.client && (
          <button type="button" className="btn secondary" disabled={busy} onClick={() => { const client = wallet.client; if (client) void run("Distribute pool fees", (onSent) => sweepPoolFees(client, launch.poolId, launch.pairToken, onSent), onDone); }}>Distribute pool fees</button>
        )}
      </div>
    );
  }
  if (launch.phase === 3 || launch.rescued) {
    return (
      <div className="card state-card">
        <h3>Refund mode</h3>
        <p>Graduation could not complete and the owner opened the rescue valve: holders can sell back to the curve with no fees, at the curve price. Buying is closed.</p>
      </div>
    );
  }
  return (
    <div className="card state-card">
      <h3>Graduation pending</h3>
      <p>The curve is complete but the Uniswap v4 pool has not opened yet. Anyone can retry the migration; if it keeps failing, the owner can enable refunds after seven days.</p>
      <TxStatus tx={tx} onDismiss={reset} />
      <ActionButton ready={!busy} busy={busy} label="Retry graduation" className="btn secondary" onClick={() => { const client = wallet.client; if (client) void run("Graduate", (onSent) => retryGraduation(client, launch.token, onSent), onDone); }} />
    </div>
  );
}

function Position({ launch, view, onDone }: { launch: LaunchDetail; view: AccountView; onDone: () => void }) {
  const wallet = useWallet();
  const { tx, run, reset, busy } = useTx();
  const { pair } = launch;
  const value = (view.tokenBalance * launch.price) / 10n ** 18n;
  return (
    <div className="card">
      <h2 className="panel-title">Your position<small>{wallet.account ? shortAddress(wallet.account) : ""}</small></h2>
      <div className="stats-grid">
        <div className="stat"><span>Balance</span><b>{fmtUnits(view.tokenBalance, 18, { compact: true })} ${launch.symbol}</b></div>
        <div className="stat"><span>Value on curve</span><b>{fmtAmount(value, pair.decimals, pair.symbol)}</b></div>
      </div>
      {(launch.holderFeeSharing || view.pendingRewards > 0n) && (
        <div className="claim" style={{ marginTop: 10 }}>
          <div><span>Holder rewards</span><b>{fmtAmount(view.pendingRewards, pair.decimals, pair.symbol)}</b></div>
          <button type="button" className="btn secondary sm" disabled={busy || view.pendingRewards === 0n} onClick={() => { const client = wallet.client; if (client) void run("Claim holder rewards", (onSent) => claimHolderRewards(client, launch.token, onSent), onDone); }}>Claim</button>
        </div>
      )}
      {view.escrowBalance > 0n && (
        <div className="claim" style={{ marginTop: 10 }}>
          <div><span>Creator fees in escrow</span><b>{fmtAmount(view.escrowBalance, pair.decimals, pair.symbol)}</b></div>
          <button type="button" className="btn secondary sm" disabled={busy} onClick={() => { const client = wallet.client; if (client) void run("Claim creator fees", (onSent) => claimEscrow(client, launch.pairToken, pair.native, onSent), onDone); }}>Claim</button>
        </div>
      )}
      <div style={{ marginTop: 10 }}><TxStatus tx={tx} onDismiss={reset} /></div>
    </div>
  );
}

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
