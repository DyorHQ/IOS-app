"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { erc20Abi, getAddress, isAddress, type Address } from "viem";
import { Icon } from "../../ui/icons";
import { Switch } from "../../ui/components";
import { DEPLOYED, ZERO_ADDRESS, publicClient } from "../../lib/chain";
import { factoryContract, fetchProtocol, type PairEconomics, type ProtocolInfo } from "../../lib/launchpad";
import { launch as launchAction, type LaunchInput } from "../../lib/actions";
import { useAsync } from "../../lib/use-async";
import { useTx } from "../../lib/use-tx";
import { useWallet } from "../../lib/wallet";
import { bpsToPct, fmtAmount, fmtUnits, parseAmount, seconds } from "../../lib/format";
import { ActionButton, DeployNotice, TokenLogo, TxStatus, toneFor } from "../ui";

type Form = { name: string; symbol: string; description: string; logo: string; twitter: string; telegram: string; website: string; pair: Address; devBuy: string; holderFeeSharing: boolean; creatorWallet: string; creatorTax: string; exemptions: string };
const EMPTY: Form = { name: "", symbol: "", description: "", logo: "", twitter: "", telegram: "", website: "", pair: ZERO_ADDRESS, devBuy: "", holderFeeSharing: true, creatorWallet: "", creatorTax: "0", exemptions: "" };
const MAX_EXEMPTIONS = 32;

const socialUrl = (value: string, base: string) => {
  const v = value.trim();
  if (!v) return "";
  return /^https?:\/\//i.test(v) ? v : `${base}/${v.replace(/^@/, "")}`;
};
const feeOf = (amount: bigint, bps: number) => (amount * BigInt(bps)) / 10_000n;
const grossForNet = (net: bigint, totalBps: number) => (net * 10_000n + BigInt(10_000 - totalBps) - 1n) / BigInt(10_000 - totalBps);

/** Mirrors BondingCurve.quoteBuy for the deployer (who is snipe-tax exempt) before the curve exists. */
function estimateDevBuy(amount: bigint, pair: PairEconomics, protocol: ProtocolInfo, creatorTaxBps: number) {
  const totalBps = protocol.curveFeeBps + creatorTaxBps;
  let used = amount;
  let net = used - feeOf(used, protocol.curveFeeBps) - feeOf(used, creatorTaxBps);
  if (net > pair.graduationThreshold) {
    used = grossForNet(pair.graduationThreshold, totalBps);
    net = used - feeOf(used, protocol.curveFeeBps) - feeOf(used, creatorTaxBps);
  }
  const tokens = (net * protocol.supply) / (pair.phantomQuote + net);
  return { tokens, used, refund: amount - used, share: protocol.supply === 0n ? 0 : Number((tokens * 10_000n) / protocol.supply) / 100 };
}

type Validation = { errors: Partial<Record<keyof Form, string>>; input: LaunchInput | null };
function validate(form: Form, protocol: ProtocolInfo | null, pair: PairEconomics | undefined, account: Address | null, balance: bigint | null): Validation {
  const errors: Validation["errors"] = {};
  const name = form.name.trim();
  const symbol = form.symbol.trim();
  if (!name) errors.name = "Give the token a name.";
  else if (name.length > 32) errors.name = "Keep the name under 32 characters.";
  if (!symbol) errors.symbol = "Pick a ticker.";
  else if (!/^[A-Z0-9]{1,10}$/.test(symbol)) errors.symbol = "Tickers use 1–10 letters or digits.";
  if (form.description.length > 500) errors.description = "Keep the description under 500 characters.";
  if (form.logo.trim() && !/^https?:\/\/\S+$/i.test(form.logo.trim())) errors.logo = "Use a full image link starting with https://.";
  if (form.website.trim() && !/^https?:\/\/\S+$/i.test(form.website.trim())) errors.website = "Use a full link starting with https://.";
  const creatorWallet = form.creatorWallet.trim() || account || "";
  if (!isAddress(creatorWallet)) errors.creatorWallet = "Enter a valid wallet address.";
  const taxPct = Number(form.creatorTax || "0");
  const creatorTaxBps = Math.round(taxPct * 100);
  if (!Number.isFinite(taxPct) || taxPct < 0 || !/^\d*\.?\d{0,2}$/.test(form.creatorTax.trim() || "0")) errors.creatorTax = "Enter a percentage with up to two decimals.";
  else if (protocol && creatorTaxBps > protocol.maxCreatorTaxBps) errors.creatorTax = `The maximum creator tax is ${bpsToPct(protocol.maxCreatorTaxBps)}.`;
  const exemptionList = form.exemptions.split(/[\s,;]+/).map((s) => s.trim()).filter(Boolean);
  const bad = exemptionList.find((a) => !isAddress(a));
  if (bad) errors.exemptions = `${bad.slice(0, 12)}… is not a valid address.`;
  else if (exemptionList.length > MAX_EXEMPTIONS) errors.exemptions = `Up to ${MAX_EXEMPTIONS} exemptions are allowed.`;
  let devBuy = 0n;
  if (form.devBuy.trim()) {
    const parsed = pair ? parseAmount(form.devBuy, pair.decimals) : null;
    if (parsed === null) errors.devBuy = "Enter a plain amount, like 2.5.";
    else devBuy = parsed;
  }
  if (!pair) errors.pair = "Choose a paired asset.";
  else if (!pair.approved) errors.pair = "That asset is not approved for launches.";
  if (protocol && pair && balance !== null) {
    const need = pair.native ? protocol.launchFee + devBuy : devBuy;
    if (need > balance) errors.devBuy = pair.native ? `You need ${fmtAmount(need, 18, "MON")} plus gas.` : `You only hold ${fmtAmount(balance, pair.decimals, pair.symbol)}.`;
  }
  if (Object.keys(errors).length || !protocol || !pair || !account) return { errors, input: null };
  const estimate = devBuy > 0n ? estimateDevBuy(devBuy, pair, protocol, creatorTaxBps) : null;
  return {
    errors,
    input: {
      name,
      symbol,
      logo: form.logo.trim(),
      description: form.description.trim(),
      socials: { twitter: socialUrl(form.twitter, "https://x.com"), telegram: socialUrl(form.telegram, "https://t.me"), discord: "", website: form.website.trim(), farcaster: "" },
      creatorFeeRecipient: getAddress(creatorWallet),
      creatorTaxBps,
      holderFeeSharing: form.holderFeeSharing,
      pairToken: pair.address,
      pairNative: pair.native,
      configId: protocol.configId,
      exemptions: Array.from(new Set(exemptionList.map((a) => getAddress(a)))),
      launchFee: protocol.launchFee,
      devBuy,
      minTokensOut: estimate ? (estimate.tokens * 99n) / 100n : 0n,
    },
  };
}

function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return <div className="review-row"><span>{label}</span><b>{value}</b></div>;
}

export default function Create({ embedded = false, onLaunched }: { embedded?: boolean; onLaunched?: (token: Address) => void } = {}) {
  const router = useRouter();
  const wallet = useWallet();
  const account = wallet.account;
  const [form, setForm] = useState<Form>(EMPTY);
  const [advanced, setAdvanced] = useState(false);
  const [touched, setTouched] = useState(false);
  const { tx, run, reset, busy } = useTx();
  const protocol = useAsync(fetchProtocol, "protocol", 60_000);
  const pairs = protocol.data?.pairs.filter((p) => p.approved) ?? [];
  const pair = pairs.find((p) => p.address === form.pair) ?? pairs[0];
  const balance = useAsync(
    async () => {
      if (!account || !pair) return null;
      return pair.native ? publicClient.getBalance({ address: account }) : publicClient.readContract({ address: pair.address, abi: erc20Abi, functionName: "balanceOf", args: [account] });
    },
    `balance:${account ?? ""}:${pair?.address ?? ""}`,
    15_000,
  );
  const allowed = useAsync(
    async () => (account && protocol.data?.whitelistEnabled ? publicClient.readContract({ ...factoryContract, functionName: "canLaunch", args: [account] }) : true),
    `canLaunch:${account ?? ""}:${protocol.data?.whitelistEnabled ? "wl" : "open"}`,
  );
  const set = (patch: Partial<Form>) => setForm((f) => ({ ...f, ...patch }));
  const { errors, input } = validate(form, protocol.data, pair, account, balance.data ?? null);
  const firstError = touched ? Object.values(errors)[0] : undefined;
  const creatorTaxBps = input?.creatorTaxBps ?? (Math.round(Number(form.creatorTax || "0") * 100) || 0);
  const estimate = input && pair && protocol.data && input.devBuy > 0n ? estimateDevBuy(input.devBuy, pair, protocol.data, input.creatorTaxBps) : null;
  const fee = protocol.data ? fmtAmount(protocol.data.launchFee, 18, "MON") : "—";

  const submit = async () => {
    setTouched(true);
    const client = wallet.client;
    if (!client || !input) return;
    const result = await run(`Launch $${input.symbol}`, (onSent) => launchAction(client, input, onSent));
    if (result?.token) {
      if (onLaunched) onLaunched(result.token);
      else router.push(`/launchpad/${result.token}`);
    }
  };

  return (
    <>
      {!DEPLOYED && <DeployNotice />}
      <div className={`create-layout ${embedded ? "embedded" : ""}`}>
        <form className="card form" onSubmit={(e) => { e.preventDefault(); void submit(); }} noValidate>
          <div className="step-head"><div><span className="eyebrow">New launch · Monad</span><h1>Create a token</h1></div></div>

          <div className="logo-field">
            <TokenLogo src={form.logo.trim()} name={form.name || form.symbol} address={account ?? ZERO_ADDRESS} size="lg" />
            <label className="field">Token image<input type="url" placeholder="https://… square PNG, JPG or SVG" value={form.logo} onChange={(e) => set({ logo: e.target.value })} /><span className="help">A hosted image link. It is stored on-chain with the token and shown everywhere the token appears.</span>{touched && errors.logo && <span className="hint err">{errors.logo}</span>}</label>
          </div>
          <div className="field-row">
            <label className="field">Name<input placeholder="Jensen's Jacket" maxLength={32} value={form.name} onChange={(e) => set({ name: e.target.value })} />{touched && errors.name && <span className="hint err">{errors.name}</span>}</label>
            <label className="field">Ticker<div className="prefix"><span>$</span><input placeholder="JENSEN" maxLength={10} value={form.symbol} onChange={(e) => set({ symbol: e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, "") })} /></div>{touched && errors.symbol && <span className="hint err">{errors.symbol}</span>}</label>
          </div>
          <label className="field">Description<textarea placeholder="What is this token about? Keep it honest; it lives on-chain." maxLength={500} value={form.description} onChange={(e) => set({ description: e.target.value })} /><span className="help">{form.description.length}/500</span></label>
          <div className="field-row">
            <label className="field">X profile<input placeholder="@handle or link" value={form.twitter} onChange={(e) => set({ twitter: e.target.value })} /></label>
            <label className="field">Telegram<input placeholder="@group or link" value={form.telegram} onChange={(e) => set({ telegram: e.target.value })} /></label>
          </div>
          <label className="field">Website (optional)<input type="url" placeholder="https://" value={form.website} onChange={(e) => set({ website: e.target.value })} />{touched && errors.website && <span className="hint err">{errors.website}</span>}</label>

          <div className="field"><span>Paired asset</span>
            <div className="pair-pick">
              {pairs.map((p) => (
                <button key={p.address} type="button" aria-pressed={pair?.address === p.address} onClick={() => set({ pair: p.address })}>
                  <span className="coin sm" style={{ background: p.native ? "var(--asset-violet)" : toneFor(p.address) }} aria-hidden="true">{p.symbol[0]}</span>
                  <span><b>{p.symbol}</b><small>graduates at {fmtAmount(p.graduationThreshold, p.decimals, p.symbol, { compact: true })}</small></span>
                </button>
              ))}
              {pairs.length === 0 && <span className="hint">{DEPLOYED ? "Loading approved pair assets…" : "Pair assets appear once the contracts are deployed."}</span>}
            </div>
            <span className="help">The curve collects this asset. At graduation it becomes the other side of the Uniswap v4 pool.</span>
          </div>

          <label className="field">Developer buy (optional)
            <div className="prefix suffix"><input inputMode="decimal" placeholder="0" value={form.devBuy} onChange={(e) => set({ devBuy: e.target.value })} /><span className="unit">{pair?.symbol ?? "MON"}</span></div>
            <span className="help">Bought in the same transaction as the launch, before anyone else, with no snipe tax.{account && balance.data !== null && pair ? ` Balance: ${fmtAmount(balance.data ?? 0n, pair.decimals, pair.symbol)}.` : ""}</span>
            {touched && errors.devBuy && <span className="hint err">{errors.devBuy}</span>}
          </label>

          <button type="button" className="disclosure" aria-expanded={advanced} onClick={() => setAdvanced((a) => !a)}>Advanced options <Icon name="chev-down" /></button>
          {advanced && (
            <div className="advanced">
              <div className="toggle-row"><div><b>Holder fee sharing</b><small>Route the creator share of every trade fee to token holders, pro rata, instead of one wallet. Cannot be changed later.</small></div><Switch checked={form.holderFeeSharing} onChange={(v) => set({ holderFeeSharing: v })} label="Holder fee sharing" /></div>
              <label className="field">Creator wallet<input placeholder={account ?? "0x…"} value={form.creatorWallet} onChange={(e) => set({ creatorWallet: e.target.value })} /><span className="help">Receives creator fees and any creator tax, and is exempt from the snipe tax. Defaults to your connected wallet.</span>{touched && errors.creatorWallet && <span className="hint err">{errors.creatorWallet}</span>}</label>
              <label className="field">Creator tax (%)<input inputMode="decimal" value={form.creatorTax} onChange={(e) => set({ creatorTax: e.target.value })} /><span className="help">An extra tax on every trade, paid to the creator wallet on top of the {protocol.data ? bpsToPct(protocol.data.curveFeeBps) : "—"} trade fee. Maximum {protocol.data ? bpsToPct(protocol.data.maxCreatorTaxBps) : "—"}.</span>{touched && errors.creatorTax && <span className="hint err">{errors.creatorTax}</span>}</label>
              <label className="field">Snipe-tax exemptions<textarea placeholder="One address per line" value={form.exemptions} onChange={(e) => set({ exemptions: e.target.value })} /><span className="help">Wallets allowed to buy during the first {protocol.data ? seconds(protocol.data.snipeSchedule.length) : "seconds"} without the snipe tax. You and the creator wallet are always exempt. Up to {MAX_EXEMPTIONS}.</span>{touched && errors.exemptions && <span className="hint err">{errors.exemptions}</span>}</label>
            </div>
          )}

          {allowed.data === false && <div className="warnbox"><b>Whitelist only.</b> Launching is currently limited to whitelisted wallets and yours is not on the list.</div>}
          <TxStatus tx={tx} onDismiss={reset} />
          {firstError && <p className="hint err" role="alert">{firstError}</p>}
          <ActionButton type="submit" ready={!!input && allowed.data !== false && !!protocol.data?.configEnabled} busy={busy} label={<>Launch for {fee}{estimate ? ` + ${fmtAmount(estimate.used, pair?.decimals ?? 18, pair?.symbol ?? "MON")}` : ""} <Icon name="arrow-ur" /></>} onClick={submit} />
          <p className="hint">You pay the launch fee plus your developer buy. Supply mints to the curve only: no team allocation, and nobody can withdraw the liquidity after graduation.</p>
        </form>

        <aside className="sticky">
          <div className="card preview-card">
            <span className="eyebrow">Your token</span>
            <div className="launch-top" style={{ marginTop: 10 }}>
              <TokenLogo src={form.logo.trim()} name={form.name || form.symbol} address={account ?? ZERO_ADDRESS} />
              <div style={{ minWidth: 0 }}><h3>{form.name.trim() || "Token name"}</h3><p>${form.symbol || "TICKER"} · paired with {pair?.symbol ?? "MON"}</p></div>
            </div>
            <p className="desc">{form.description.trim() || "Your description shows up here, on the token page and in the app."}</p>
            <div className="review">
              <Row label="Launch fee" value={fee} />
              <Row label="Trade fee" value={protocol.data ? bpsToPct(protocol.data.curveFeeBps) : "—"} />
              <Row label="Creator tax" value={bpsToPct(creatorTaxBps)} />
              <Row label="Fees go to" value={form.holderFeeSharing ? "Holders" : "Creator wallet"} />
              <Row label="Launch window" value={protocol.data ? `${seconds(protocol.data.snipeSchedule.length)} snipe tax` : "—"} />
              <Row label="Graduation" value={pair ? fmtAmount(pair.graduationThreshold, pair.decimals, pair.symbol, { compact: true }) : "—"} />
              <Row label="Liquidity" value={<span className="up">Locked forever</span>} />
              {estimate && pair && <Row label="Your buy" value={`≈ ${fmtUnits(estimate.tokens, 18, { compact: true })} $${form.symbol || "TOKEN"} · ${estimate.share.toFixed(2)}%`} />}
            </div>
            <div className="note"><b>Fair by construction</b><p>{protocol.data ? `${fmtUnits(protocol.data.supply, 18, { compact: true })} supply mints to the bonding curve.` : "The whole supply mints to the bonding curve."} When the threshold is raised, the pool opens on Uniswap v4 at the curve price and the position is locked for good.</p></div>
          </div>
        </aside>
      </div>
    </>
  );
}
