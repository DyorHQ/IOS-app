"use client";

import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { useEffect, useMemo, useState } from "react";
import { isAddress, type Address, type Hex } from "viem";
import { Icon } from "../ui/icons";
import { DEPLOYED, explorerToken } from "../lib/chain";
import { fetchLaunches } from "../lib/launchpad";
import { fetchQuotes, fetchVenueQuote, isWrap, quoteAgeSeconds, rankQuotes, runPlan } from "../lib/swap/engine";
import { CORE_TOKENS, findToken, loadBalances, loadToken, sameToken, type TokenInfo } from "../lib/swap/tokens";
import { VENUE_LABEL, type Venue, type VenueQuote } from "../lib/swap/types";
import { useAsync, useNow } from "../lib/use-async";
import { useDebounced } from "../lib/use-debounced";
import { useTx } from "../lib/use-tx";
import { useWallet } from "../lib/wallet";
import { bpsToPct, fmtNumber, fmtUnits, parseAmount, shortAddress } from "../lib/format";
import { ActionButton, TokenLogo, TxStatus } from "../launchpad/ui";

const PLACEHOLDER: Address = "0x0000000000000000000000000000000000000001";
const SLIPPAGES = [50, 100, 300, 500];
const VENUE_ORDER: Venue[] = ["kuru", "uniswap", "monday"];

function rate(amountIn: bigint, decIn: number, amountOut: bigint, decOut: number) {
  const a = Number(amountIn) / 10 ** decIn;
  const b = Number(amountOut) / 10 ** decOut;
  return a > 0 ? b / a : 0;
}

function VenueMark({ venue }: { venue: Venue }) {
  const letter = { kuru: "K", uniswap: "U", monday: "M", wmon: "W" }[venue];
  return <span className={`vlogo ${venue}`} aria-hidden="true">{letter}</span>;
}

function TokenPicker({ tokens, balances, exclude, onPick, onClose }: { tokens: TokenInfo[]; balances: Record<string, bigint>; exclude: TokenInfo; onPick: (t: TokenInfo) => void; onClose: () => void }) {
  const [query, setQuery] = useState("");
  const custom = useAsync(async () => (isAddress(query.trim()) && !findToken(tokens, query.trim()) ? loadToken(query.trim()) : null), `custom:${query.trim().toLowerCase()}`);
  const q = query.trim().toLowerCase();
  const list = tokens.filter((t) => !sameToken(t.address, exclude.address) && (!q || t.symbol.toLowerCase().includes(q) || t.name.toLowerCase().includes(q) || t.address.toLowerCase() === q));
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  return (
    <div className="picker" role="dialog" aria-modal="true" aria-label="Choose a token" onClick={onClose}>
      <div className="card panel" onClick={(e) => e.stopPropagation()}>
        <div className="hd" style={{ marginBottom: 0 }}><h2>Choose a token</h2><button type="button" className="iconbtn" aria-label="Close" onClick={onClose}><Icon name="x" /></button></div>
        <input className="search-in" placeholder="Search by name, symbol or paste an address" value={query} onChange={(e) => setQuery(e.target.value)} autoFocus />
        <div className="picker-list">
          {custom.data && (
            <button type="button" onClick={() => onPick(custom.data as TokenInfo)}>
              <TokenLogo src="" name={custom.data.symbol} address={custom.data.address} size="sm" />
              <span><b>{custom.data.symbol}</b><small>{custom.data.name} · {shortAddress(custom.data.address)} · unlisted, verify before trading</small></span>
            </button>
          )}
          {list.map((t) => {
            const bal = balances[t.address.toLowerCase()];
            return (
              <button key={t.address} type="button" onClick={() => onPick(t)}>
                <TokenLogo src={t.logo} name={t.symbol} address={t.address} size="sm" />
                <span><b>{t.symbol}{t.launchpad && <em className="badge accent" style={{ marginLeft: 6 }}>Launchpad</em>}</b><small>{t.name}</small></span>
                {bal !== undefined && <span className="bal">{fmtUnits(bal, t.decimals, { compact: true })}<small>{t.symbol}</small></span>}
              </button>
            );
          })}
          {list.length === 0 && !custom.data && <p className="hint" style={{ padding: 12 }}>{isAddress(q) ? (custom.loading ? "Looking up that address…" : "That address is not an ERC-20 on Monad.") : "No matching token. Paste a contract address to add one."}</p>}
        </div>
      </div>
    </div>
  );
}

export default function Swap({ embedded = false, initialIn, initialOut }: { embedded?: boolean; initialIn?: string; initialOut?: string } = {}) {
  const params = useSearchParams();
  const wallet = useWallet();
  const account = wallet.account;
  const now = useNow();
  const launched = useAsync(async () => (DEPLOYED ? (await fetchLaunches(60)).filter((l) => l.phase === 2) : []), "graduated", 60_000);
  const graduated = launched.data;
  const tokens = useMemo<TokenInfo[]>(
    () => [...CORE_TOKENS, ...(graduated ?? []).filter((l) => !findToken(CORE_TOKENS, l.token)).map((l) => ({ address: l.token, symbol: l.symbol, name: l.name, decimals: 18, logo: l.logo, launchpad: true }))],
    [graduated],
  );
  const [tokenIn, setTokenIn] = useState<TokenInfo>(CORE_TOKENS[0]);
  const [tokenOut, setTokenOut] = useState<TokenInfo>(CORE_TOKENS[2]);
  const [seeded, setSeeded] = useState(false);
  const [amount, setAmount] = useState("");
  const [slippageBps, setSlippage] = useState(100);
  const [choice, setChoice] = useState<Venue | null>(null);
  const [picking, setPicking] = useState<"in" | "out" | null>(null);
  const [step, setStep] = useState<{ label: string; hash?: Hex } | null>(null);
  const { tx, run, reset, busy } = useTx();
  const debouncedAmount = useDebounced(amount, 400);
  const amountIn = parseAmount(debouncedAmount, tokenIn.decimals) ?? 0n;

  // Preselect from ?in= and ?out= (symbols or addresses) once the token list, including graduated launches, is known.
  useEffect(() => {
    if (seeded || (DEPLOYED && !launched.data)) return;
    const pick = (raw: string | null): TokenInfo | undefined => raw ? tokens.find((t) => t.symbol.toLowerCase() === raw.toLowerCase() || t.address.toLowerCase() === raw.toLowerCase()) : undefined;
    const wantIn = initialIn ?? params.get("in");
    const wantOut = initialOut ?? params.get("out");
    const inTok = pick(wantIn);
    const outTok = pick(wantOut);
    Promise.all([inTok ?? (wantIn && isAddress(wantIn) ? loadToken(wantIn) : null), outTok ?? (wantOut && isAddress(wantOut) ? loadToken(wantOut) : null)]).then(([i, o]) => {
      if (i) setTokenIn(i);
      if (o) setTokenOut(o);
      setSeeded(true);
    });
  }, [seeded, launched.data, params, tokens, initialIn, initialOut]);

  const balances = useAsync(async (): Promise<Record<string, bigint>> => (account ? loadBalances(tokens, account) : {}), `balances:${account ?? ""}:${tokens.length}`, 15_000);
  const req = { tokenIn, tokenOut, amountIn, slippageBps, account: account ?? PLACEHOLDER };
  const quoteKey = `${tokenIn.address}:${tokenOut.address}:${amountIn}:${slippageBps}:${account ?? ""}`;
  const wrapping = isWrap(req);
  // Each venue streams in on its own; a slow venue never delays the others.
  const kuru = useAsync(async () => (amountIn > 0n && !wrapping ? fetchVenueQuote("kuru", req) : null), `kuru:${quoteKey}`, 12_000);
  const uni = useAsync(async () => (amountIn > 0n && !wrapping ? fetchVenueQuote("uniswap", req) : null), `uniswap:${quoteKey}`, 12_000);
  const monday = useAsync(async () => (amountIn > 0n && !wrapping ? fetchVenueQuote("monday", req) : null), `monday:${quoteKey}`, 12_000);
  const wrap = useAsync(async () => (amountIn > 0n && wrapping ? fetchVenueQuote("wmon", req) : null), `wmon:${quoteKey}`);
  const venueState = { kuru, uniswap: uni, monday, wmon: wrap } as const;
  const quotes = {
    loading: amountIn > 0n && (wrapping ? wrap.loading : kuru.loading || uni.loading || monday.loading),
    error: null as string | null,
    data: { quotes: rankQuotes([kuru.data, uni.data, monday.data, wrap.data]), errors: { kuru: kuru.error ?? undefined, uniswap: uni.error ?? undefined, monday: monday.error ?? undefined } as Partial<Record<Venue, string>> },
    refresh: () => { kuru.refresh(); uni.refresh(); monday.refresh(); wrap.refresh(); },
  };
  const list = quotes.data.quotes;
  const best = list[0] ?? null;
  const selected = (choice && list.find((q) => q.venue === choice)) ?? best;
  const balIn = balances.data?.[tokenIn.address.toLowerCase()];
  const insufficient = balIn !== undefined && amountIn > balIn;
  const impact = selected?.priceImpactBps ?? null;
  const highImpact = impact !== null && impact > 300;

  const flip = () => { setTokenIn(tokenOut); setTokenOut(tokenIn); setAmount(""); setChoice(null); reset(); };
  const pickToken = (t: TokenInfo) => {
    if (picking === "in") { if (sameToken(t.address, tokenOut.address)) setTokenOut(tokenIn); setTokenIn(t); }
    else if (picking === "out") { if (sameToken(t.address, tokenIn.address)) setTokenIn(tokenOut); setTokenOut(t); }
    setPicking(null);
    setChoice(null);
    reset();
  };
  const submit = async () => {
    const client = wallet.client;
    if (!client || !selected || !account) return;
    const quote: VenueQuote = quoteAgeSeconds(selected) > 45 ? (await fetchQuotes({ tokenIn, tokenOut, amountIn, slippageBps, account })).quotes.find((q) => q.venue === selected.venue) ?? selected : selected;
    setStep(null);
    const done = await run(`Swap ${fmtUnits(amountIn, tokenIn.decimals)} ${tokenIn.symbol} → ${tokenOut.symbol}`, async (onSent) => {
      const steps = await quote.build(account);
      return runPlan(client, steps, (label, hash) => { setStep({ label, hash }); if (hash) onSent(hash); });
    });
    if (done) { setAmount(""); balances.refresh(); quotes.refresh(); }
  };

  const outText = selected ? fmtUnits(selected.amountOut, tokenOut.decimals) : amountIn > 0n && quotes.loading ? "…" : "0";
  const buttonLabel = !amountIn ? "Enter an amount" : insufficient ? `Not enough ${tokenIn.symbol}` : quotes.loading && !selected ? "Finding the best price…" : !selected ? "No route found" : highImpact ? `Swap anyway via ${VENUE_LABEL[selected.venue]}` : selected.venue === "wmon" ? selected.route.split(",")[0] : `Swap via ${VENUE_LABEL[selected.venue]}`;

  return (
    <>
      <div className={`swap-layout ${embedded ? "embedded" : ""}`}>
        <section className="card swapcard">
          <div className="swap-head">
            <h1>Swap</h1>
            <div className="slip"><span style={{ marginRight: 0 }}>Slippage</span>{SLIPPAGES.map((s) => <button key={s} type="button" aria-pressed={slippageBps === s} onClick={() => setSlippage(s)}>{bpsToPct(s)}</button>)}</div>
          </div>
          <div className="swap-field">
            <div className="lbl"><span>You pay</span>{balIn !== undefined && <button type="button" onClick={() => setAmount(fmtUnits(balIn, tokenIn.decimals, { dp: 8 }).replace(/,/g, ""))}>Balance {fmtUnits(balIn, tokenIn.decimals, { compact: true })} · Max</button>}</div>
            <div className="rowin">
              <input inputMode="decimal" placeholder="0" aria-label="Amount to pay" value={amount} onChange={(e) => { setAmount(e.target.value); setChoice(null); if (tx.status !== "idle" && !busy) { reset(); setStep(null); } }} />
              <button type="button" className="tokbtn" onClick={() => setPicking("in")}><TokenLogo src={tokenIn.logo} name={tokenIn.symbol} address={tokenIn.address} size="sm" />{tokenIn.symbol}<Icon name="chev-down" /></button>
            </div>
            <div className="sub">{insufficient ? <span className="impact-bad">Insufficient balance</span> : ""}</div>
          </div>
          <button type="button" className="flip" aria-label="Switch tokens" onClick={flip}><Icon name="swap" /></button>
          <div className="swap-field">
            <div className="lbl"><span>You receive</span>{balances.data?.[tokenOut.address.toLowerCase()] !== undefined && <span>Balance {fmtUnits(balances.data[tokenOut.address.toLowerCase()], tokenOut.decimals, { compact: true })}</span>}</div>
            <div className="rowin">
              <input readOnly aria-label="Amount to receive" value={outText} placeholder="0" />
              <button type="button" className="tokbtn" onClick={() => setPicking("out")}><TokenLogo src={tokenOut.logo} name={tokenOut.symbol} address={tokenOut.address} size="sm" />{tokenOut.symbol}<Icon name="chev-down" /></button>
            </div>
            <div className="sub">{selected && amountIn > 0n ? `1 ${tokenIn.symbol} = ${fmtNumber(rate(amountIn, tokenIn.decimals, selected.amountOut, tokenOut.decimals))} ${tokenOut.symbol}` : ""}</div>
          </div>

          {selected && amountIn > 0n && (
            <div className="breakdown">
              <div><span>Route</span><b>{VENUE_LABEL[selected.venue]} · {selected.route}</b></div>
              <div><span>Minimum received</span><b>{fmtUnits(selected.minOut, tokenOut.decimals)} {tokenOut.symbol}</b></div>
              <div><span>Price impact</span><b className={highImpact ? "warn" : ""}>{impact === null ? "—" : `${impact <= 0 ? "" : "−"}${bpsToPct(Math.abs(impact))}`}</b></div>
              {selected.gasEstimate !== null && <div><span>Estimated swap gas</span><b>{Number(selected.gasEstimate).toLocaleString("en-US")}</b></div>}
              <div><span>Quote age</span><b>{now ? `${Math.max(0, now - selected.at)}s` : "—"}</b></div>
            </div>
          )}
          {highImpact && <div className="warnbox"><b>High price impact.</b> This trade moves the market by {bpsToPct(impact)}. Consider a smaller amount or a different venue.</div>}
          {step && busy && <p className="hint">{step.label}{step.hash ? " · sent" : "…"}</p>}
          <TxStatus tx={tx} onDismiss={() => { reset(); setStep(null); }} />
          <ActionButton ready={!!selected && amountIn > 0n && !insufficient} busy={busy} label={buttonLabel} onClick={submit} requireLaunchpad={false} />
          <p className="hint">Quotes are compared live across Kuru Flow, Uniswap (v3 and v4) and Monday Trade. You trade from your own wallet; DyorHQ never holds funds.</p>
        </section>

        <aside className="card">
          <h2 className="panel-title">Routes<small>{amountIn > 0n && quotes.loading ? "refreshing…" : list.length ? `${list.length} venue${list.length === 1 ? "" : "s"}` : ""}</small></h2>
          <div className="routes">
            {amountIn === 0n && <p className="hint">Enter an amount to compare venues.</p>}
            {list.map((q, i) => {
              const delta = best && best.amountOut > 0n ? Number(((q.amountOut - best.amountOut) * 10_000n) / best.amountOut) : 0;
              return (
                <button key={q.venue} type="button" className="route-row" aria-pressed={selected?.venue === q.venue} onClick={() => setChoice(q.venue)}>
                  <div className="top"><span style={{ display: "inline-flex", alignItems: "center", gap: 8 }}><VenueMark venue={q.venue} />{VENUE_LABEL[q.venue]}{i === 0 && <em className="badge accent">Best</em>}</span><b>{fmtUnits(q.amountOut, tokenOut.decimals)} {tokenOut.symbol}</b></div>
                  <div className="bottom"><span>{q.route}</span><span className={`delta ${i === 0 ? "best" : ""}`}>{i === 0 ? "best price" : `${bpsToPct(Math.abs(delta))} less`}</span></div>
                </button>
              );
            })}
            {amountIn > 0n && !wrapping && VENUE_ORDER.filter((v) => !list.some((q) => q.venue === v)).map((v) => {
              const state = venueState[v];
              const text = state.loading ? "Quoting…" : state.error ?? "No route for this pair.";
              return (
                <div key={v} className="route-row err"><div className="top"><span style={{ display: "inline-flex", alignItems: "center", gap: 8 }}><VenueMark venue={v} />{VENUE_LABEL[v]}</span>{state.loading && <span className="spinner" />}</div><div className="bottom"><span>{text}</span></div></div>
              );
            })}
          </div>
          <div className="divider" />
          <p className="hint">Kuru Flow aggregates the order books and pools on Monad. Uniswap quotes cover v3 pools and v4 pools, including graduated launchpad tokens. Monday Trade quotes its hybrid AMM and order book pools.</p>
          {tokenOut.launchpad && <p className="hint" style={{ marginTop: 8 }}><Link href={`/launchpad/${tokenOut.address}`} style={{ color: "var(--accent-ink)", fontWeight: 600, textDecoration: "none" }}>Open {tokenOut.symbol} on the launchpad →</Link></p>}
          {!tokenOut.native && <p className="hint" style={{ marginTop: 8 }}><a href={explorerToken(tokenOut.address)} target="_blank" rel="noreferrer" style={{ color: "var(--muted)", textDecoration: "none" }}>{tokenOut.symbol} contract {shortAddress(tokenOut.address)} ↗</a></p>}
        </aside>
      </div>
      {picking && <TokenPicker tokens={tokens} balances={balances.data ?? {}} exclude={picking === "in" ? tokenOut : tokenIn} onPick={pickToken} onClose={() => setPicking(null)} />}
    </>
  );
}
