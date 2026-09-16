"use client";

import Link from "next/link";
import { useDeferredValue, useState } from "react";
import { Icon } from "../ui/icons";
import { Seg, type SegOpt } from "../ui/components";
import { quoteBuy, quoteSell, type AccountView, type LaunchDetail } from "../lib/launchpad";
import { buy, claimEscrow, claimHolderRewards, retryGraduation, sell, sweepPoolFees } from "../lib/actions";
import { useAsync, useNow } from "../lib/use-async";
import { useTx } from "../lib/use-tx";
import { useWallet } from "../lib/wallet";
import { bpsToPct, fmtAmount, fmtUnits, parseAmount, seconds, shortAddress } from "../lib/format";
import { ActionButton, TxStatus } from "./ui";

/* Panels shared by the web token page and the in-app launch screen: curve trading, graduation state, position. */

type Side = "buy" | "sell";
const SIDES: SegOpt<Side>[] = [{ v: "buy", l: "Buy" }, { v: "sell", l: "Sell" }];
const SLIPPAGES = [50, 100, 300, 500];
const BUY_PRESETS = ["0.5", "1", "5", "10"];
const SELL_PRESETS = [25, 50, 75, 100];

export function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return <div className="review-row"><span>{label}</span><b>{value}</b></div>;
}

export function TradePanel({ launch, view, onDone }: { launch: LaunchDetail; view: AccountView | null; onDone: () => void }) {
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

export function StatePanel({ launch, onDone }: { launch: LaunchDetail; onDone: () => void }) {
  const wallet = useWallet();
  const { tx, run, reset, busy } = useTx();
  const pending = launch.hookPendingFees + launch.hookPendingTax;
  const venue = launch.graduationVenue === 1 ? "Monday Trade" : "Uniswap v4";
  if (launch.phase === 2) {
    return (
      <div className="card state-card">
        <h3>Graduated to {venue}</h3>
        <p>The curve raised its threshold. Its {launch.pair.symbol} and the remaining supply now sit in a full-range {venue} position on Monad that nobody can withdraw. Swaps pay the same {bpsToPct(launch.poolFeeBps)} fee through the launchpad hook.</p>
        <div className="kvlist">
          <Row label="Pool id" value={<span className="mono">{shortAddress(launch.poolId, 6)}</span>} />
          <Row label="Swept into the pool" value={fmtAmount(launch.sweptQuote, launch.pair.decimals, launch.pair.symbol, { compact: true })} />
          <Row label="Undistributed pool fees" value={fmtAmount(pending, launch.pair.decimals, launch.pair.symbol)} />
        </div>
        <TxStatus tx={tx} onDismiss={reset} />
        <div className="flow-actions" style={{ marginTop: 4 }}>
          <Link className="btn primary" href={`/swap?in=${launch.pair.native ? "MON" : launch.pairToken}&out=${launch.token}`}>Trade ${launch.symbol} <Icon name="arrow-ur" /></Link>
          {pending > 0n && wallet.client && (
            <button type="button" className="btn secondary" disabled={busy} onClick={() => { const client = wallet.client; if (client) void run("Distribute pool fees", (onSent) => sweepPoolFees(client, launch.poolId, launch.pairToken, onSent), onDone); }}>Distribute pool fees</button>
          )}
        </div>
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
      <p>The curve is complete but the {venue} pool has not opened yet. Anyone can retry the migration; if it keeps failing, the owner can enable refunds after seven days.</p>
      <TxStatus tx={tx} onDismiss={reset} />
      <ActionButton ready={!busy} busy={busy} label="Retry graduation" className="btn secondary" onClick={() => { const client = wallet.client; if (client) void run("Graduate", (onSent) => retryGraduation(client, launch.token, onSent), onDone); }} />
    </div>
  );
}

export function Position({ launch, view, onDone }: { launch: LaunchDetail; view: AccountView; onDone: () => void }) {
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

