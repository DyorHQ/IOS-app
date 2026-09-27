"use client";

import { useRouter } from "next/navigation";
import { useEffect, useId, useMemo, useRef, useState } from "react";
import { keccak256, stringToHex, type Hex } from "viem";
import { Icon } from "../../ui/icons";
import { ActionButton, TxStatus } from "../../launchpad/ui";
import { BPS, MAX_COLLECT_WINDOW_SECONDS, MIN_COLLECT_WINDOW_SECONDS, MOMENTS_DEPLOYED, SUPPLY, USDC } from "../../lib/moments/config";
import { publish, type PublishInput } from "../../lib/moments/actions";
import { fetchPolicy, type Policy } from "../../lib/moments/reads";
import { useAsync, useNow } from "../../lib/use-async";
import { useTx } from "../../lib/use-tx";
import { useWallet } from "../../lib/wallet";
import { bpsToPct, fmtDate, fmtUnits, parseAmount } from "../../lib/format";
import { EarlyLabel, KV, MomentMedia, MomentsDeployNotice, usd } from "../ui";

type Form = { name: string; symbol: string; place: string; date: string; mediaURI: string; animationURI: string; price: string; allocPct: string; windowDays: string };
const nowLocal = () => { const d = new Date(); d.setSeconds(0, 0); return new Date(d.getTime() - d.getTimezoneOffset() * 60_000).toISOString().slice(0, 16); };
const EMPTY: Form = { name: "", symbol: "", place: "", date: nowLocal(), mediaURI: "", animationURI: "", price: "1", allocPct: "10", windowDays: "30" };

type Validation = { errors: Partial<Record<keyof Form | "media", string>>; input: PublishInput | null };
function validate(form: Form, policy: Policy | null, mediaHash: Hex | null, fileState: "none" | "hashing" | "failed" | "hashed"): Validation {
  const errors: Validation["errors"] = {};
  const name = form.name.trim();
  const symbol = form.symbol.trim();
  if (!name) errors.name = "Give the Moment a name.";
  else if (name.length > 48) errors.name = "Keep the name under 48 characters.";
  if (!symbol) errors.symbol = "Pick a ticker for the coin.";
  else if (!/^[A-Z0-9]{1,10}$/.test(symbol)) errors.symbol = "Tickers use 1–10 letters or digits.";
  if (!form.place.trim()) errors.place = "Where was this moment?";
  if (fileState === "hashing") errors.media = "Fingerprinting the file… Publish waits for its hash.";
  else if (fileState === "failed") errors.media = "That file couldn't be read. Pick it again.";
  const mediaURI = form.mediaURI.trim();
  if (!mediaURI) errors.mediaURI = "Link the media (ipfs:// or https://).";
  else if (!/^(ipfs:\/\/|https:\/\/)\S+$/i.test(mediaURI)) errors.mediaURI = "Use an ipfs:// or https:// link.";
  const animationURI = form.animationURI.trim();
  if (animationURI && !/^(ipfs:\/\/|https:\/\/)\S+$/i.test(animationURI)) errors.animationURI = "Use an ipfs:// or https:// link.";
  const price = parseAmount(form.price, USDC.decimals);
  // The gross that completes the reserve: the first collect at or above it graduates the Moment and is charged only
  // that, so a higher listed price would never be paid (the v2 factory refuses it: PriceTooHigh).
  const maxPrice = policy && policy.reserveBps > 0 ? (policy.threshold * BPS + BigInt(policy.reserveBps) - 1n) / BigInt(policy.reserveBps) : null;
  if (price === null) errors.price = "Enter a plain amount, like 1 or 0.10.";
  else if (policy && price < policy.minPrice) errors.price = `The minimum collect price is ${usd(policy.minPrice)}.`;
  else if (maxPrice !== null && price > maxPrice) errors.price = `The maximum collect price is ${usd(maxPrice)}: the first collect at that price completes the reserve, so a higher price would never be charged.`;
  const allocPct = Number(form.allocPct || "0");
  const creatorAllocBps = Math.round(allocPct * 100);
  if (!Number.isFinite(allocPct) || allocPct < 0 || !/^\d*\.?\d{0,2}$/.test(form.allocPct.trim() || "0")) errors.allocPct = "Enter a percentage with up to two decimals.";
  else if (policy && creatorAllocBps > policy.maxCreatorAllocBps) errors.allocPct = `The maximum creator allocation is ${bpsToPct(policy.maxCreatorAllocBps)}.`;
  const days = Number(form.windowDays);
  const collectWindow = Math.round(days * 86400);
  if (!Number.isFinite(days) || collectWindow < MIN_COLLECT_WINDOW_SECONDS || collectWindow > MAX_COLLECT_WINDOW_SECONDS) errors.windowDays = "The window must be between 1 hour and 30 days.";
  const date = Math.floor(new Date(form.date).getTime() / 1000);
  if (!Number.isFinite(date) || date <= 0) errors.date = "Enter the date of the moment.";
  if (Object.keys(errors).length || !policy || price === null || !mediaHash) return { errors, input: null };
  return { errors, input: { name, symbol, mediaURI, mediaHash, animationURI, place: form.place.trim(), date, price, creatorAllocBps, collectWindow } };
}

export default function Create() {
  const router = useRouter();
  const wallet = useWallet();
  const [form, setForm] = useState<Form>(EMPTY);
  const [file, setFile] = useState<File | null>(null);
  const [fileHash, setFileHash] = useState<Hex | null>(null);
  const [fileFailed, setFileFailed] = useState(false);
  // Only the latest pick may set the hash: an earlier, larger file that finishes hashing later must not overwrite it.
  const pickId = useRef(0);
  const [touched, setTouched] = useState(false);
  const ids = useId();
  const { tx, run, dismiss, busy, locked } = useTx();
  const policy = useAsync(fetchPolicy, "moments-policy", 60_000);
  const preview = useMemo(() => (file ? URL.createObjectURL(file) : ""), [file]);
  useEffect(() => () => { if (preview) URL.revokeObjectURL(preview); }, [preview]);
  const pickFile = (f: File | null) => {
    const id = ++pickId.current;
    setFile(f);
    setFileHash(null);
    setFileFailed(false);
    if (f) {
      f.arrayBuffer().then(
        (buf) => { if (pickId.current === id) setFileHash(keccak256(new Uint8Array(buf))); },
        () => { if (pickId.current === id) setFileFailed(true); },
      );
    }
  };
  // Provenance hash: the media bytes when a file is chosen (hashed locally, never uploaded here), else the link. While a
  // chosen file is still hashing there is no hash at all, so the link's hash can never stand in for the file's.
  const fileState = !file ? "none" : fileFailed ? "failed" : fileHash ? "hashed" : "hashing";
  const mediaHash: Hex | null = file ? fileHash : form.mediaURI.trim() ? keccak256(stringToHex(form.mediaURI.trim())) : null;
  const set = (patch: Partial<Form>) => setForm((f) => ({ ...f, ...patch }));
  const { errors, input } = validate(form, policy.data, mediaHash, fileState);
  // A field's error shows once the field has been left (or after a submit), marked aria-invalid and read with the field.
  // Waiting for a submit alone showed nothing: Publish stays disabled while the form is invalid, so it never submits.
  const [left, setLeft] = useState<Partial<Record<keyof Form, true>>>({});
  const errorOf = (k: keyof Form) => (touched || left[k] ? errors[k] : undefined);
  const wire = (k: keyof Form, help = false) => ({
    onBlur: () => setLeft((s) => (s[k] ? s : { ...s, [k]: true })),
    "aria-invalid": errorOf(k) ? true : undefined,
    "aria-describedby": [help && `${ids}-${k}-help`, errorOf(k) && `${ids}-${k}-err`].filter(Boolean).join(" ") || undefined,
  });
  const errorText = (k: keyof Form) => { const e = errorOf(k); return e ? <span className="hint err" id={`${ids}-${k}-err`}>{e}</span> : null; };
  const p = policy.data;
  // Why Publish is unavailable: the Moments settings first, then (once the form has been touched) its first problem.
  const reason = !MOMENTS_DEPLOYED ? null
    : !p ? (policy.error ? "Couldn't read the Moments settings. Retrying…" : "Reading the Moments settings…")
    : touched || form !== EMPTY || file !== null || Object.keys(left).length > 0 ? (Object.values(errors)[0] ?? null) : null;
  const allocBps = input?.creatorAllocBps ?? (Math.round(Number(form.allocPct || "0") * 100) || 0);
  const creatorCoins = (SUPPLY * BigInt(Math.min(1000, Math.max(0, allocBps)))) / BPS;
  const price = parseAmount(form.price, USDC.decimals);
  const collectsToGraduate = p && price && price > 0n ? Number(((p.threshold * BPS) / BigInt(p.reserveBps) + price - 1n) / price) : null;
  const now = useNow();
  const closesAt = now + Math.round(Number(form.windowDays || "0") * 86400);

  const submit = async () => {
    setTouched(true);
    const client = wallet.client;
    if (!client || !input) return;
    const result = await run(`Publish ${input.name}`, (onSent) => publish(client, input, onSent));
    if (result?.id) router.push(`/moments/${result.id}`);
  };

  return (
    <>
      <MomentsDeployNotice />
      <div className="create-layout">
        <form className="card form" onSubmit={(e) => { e.preventDefault(); void submit(); }} noValidate>
          <div className="step-head"><div><span className="eyebrow">New Moment · Monad</span><h1>Publish a Moment</h1></div></div>

          <div className="field"><label htmlFor={`${ids}-media`}>Media</label>
            <div className="file-pick">
              {preview ? <img className="thumb" src={preview} alt="" /> : <span className="thumb" aria-hidden="true" />}
              <div style={{ flex: 1 }}>
                <input id={`${ids}-media`} type="file" accept="image/*,video/*" aria-describedby={`${ids}-media-help`} onChange={(e) => pickFile(e.target.files?.[0] ?? null)} />
                <span className="help" id={`${ids}-media-help`}>Pick the original file to fingerprint it: its keccak-256 hash goes on-chain as the provenance record. Nothing is uploaded from here.</span>
                {fileHash && <span className="help mono-sm">hash {fileHash}</span>}
                {file && !fileHash && <span className={fileFailed ? "hint err" : "help"}>{fileFailed ? "Couldn't read that file." : "Fingerprinting…"}</span>}
              </div>
            </div>
          </div>
          <label className="field">Media link<input type="url" placeholder="ipfs://… or https://… (the hosted copy shown on the NFT)" value={form.mediaURI} onChange={(e) => set({ mediaURI: e.target.value })} {...wire("mediaURI", true)} /><span className="help" id={`${ids}-mediaURI-help`}>Stored on-chain as the NFT image. Content-addressed (IPFS) links are best; without a file above, the link itself is hashed.</span>{errorText("mediaURI")}</label>
          <label className="field">Video link (optional)<input type="url" placeholder="ipfs://… .mp4 — shown as the NFT animation" value={form.animationURI} onChange={(e) => set({ animationURI: e.target.value })} {...wire("animationURI")} />{errorText("animationURI")}</label>
          <div className="field-row">
            <label className="field">Name<input placeholder="Sunrise over Labadi" maxLength={48} value={form.name} onChange={(e) => set({ name: e.target.value })} {...wire("name")} />{errorText("name")}</label>
            <label className="field">Coin ticker<div className="prefix"><span>$</span><input placeholder="LABADI" maxLength={10} value={form.symbol} onChange={(e) => set({ symbol: e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, "") })} {...wire("symbol")} /></div>{errorText("symbol")}</label>
          </div>
          <div className="field-row">
            <label className="field">Place<input placeholder="Labadi Beach, Accra" maxLength={64} value={form.place} onChange={(e) => set({ place: e.target.value })} {...wire("place")} />{errorText("place")}</label>
            <label className="field">Date<input type="datetime-local" value={form.date} onChange={(e) => set({ date: e.target.value })} {...wire("date")} />{errorText("date")}</label>
          </div>
          <div className="field-row">
            <label className="field">Collect price (USDC)<div className="prefix suffix"><span>$</span><input inputMode="decimal" value={form.price} onChange={(e) => set({ price: e.target.value })} {...wire("price", true)} /><span className="unit">USDC</span></div><span className="help" id={`${ids}-price-help`}>Minimum {p ? usd(p.minPrice) : "—"}. {collectsToGraduate !== null ? `About ${collectsToGraduate} collects at this price reach the ${usd(p!.threshold)} reserve.` : ""}</span>{errorText("price")}</label>
            <label className="field">Your coin allocation (%)<input inputMode="decimal" value={form.allocPct} onChange={(e) => set({ allocPct: e.target.value })} {...wire("allocPct", true)} /><span className="help" id={`${ids}-allocPct-help`}>Up to {p ? bpsToPct(p.maxCreatorAllocBps) : "10%"} of the {fmtUnits(SUPPLY, 18, { compact: true })} coins; vests 20% at graduation, then 16% a month. Anything you leave deepens the pool.</span>{errorText("allocPct")}</label>
          </div>
          <label className="field">Collect window (days)<input inputMode="decimal" value={form.windowDays} onChange={(e) => set({ windowDays: e.target.value })} {...wire("windowDays", true)} /><span className="help" id={`${ids}-windowDays-help`}>1 hour to 30 days. Collecting ends at graduation or when the window closes, whichever comes first. {now > 0 ? `Closes ${fmtDate(closesAt)}.` : ""}</span>{errorText("windowDays")}</label>

          <div className="note"><b>What you are publishing</b><p>A numbered, transferable edition (ERC-721, marketplace-ready with a {p ? bpsToPct(p.royaltyBps) : "5%"} creator royalty) and a promise of coins that only exist if the reserve reaches {p ? usd(p.threshold) : "$10"}. You receive {p ? bpsToPct(p.creatorBps) : "20%"} of every collect in USDC, 0.2% of every trade after graduation, and the {p ? bpsToPct(p.royaltyBps) : "5%"} royalty on secondary sales of the editions. Nothing about a published Moment can be changed afterwards.</p></div>
          <TxStatus tx={tx} onDismiss={dismiss} />
          {reason && <p className="hint">{reason}</p>}
          {p?.publishingPaused && <div className="warnbox"><b>Publishing is paused.</b> Governance has paused new Moments for now.</div>}
          <ActionButton requireLaunchpad={false} type="submit" ready={MOMENTS_DEPLOYED && !!input && !p?.publishingPaused && !locked} busy={busy} label={<>Publish <Icon name="arrow-ur" /></>} onClick={submit} />
          <p className="hint">Publishing costs gas only. The coin and the NFT contracts deploy in the same transaction; their addresses are fixed by your wallet, so nobody can front-run them.</p>
        </form>

        <aside className="sticky">
          <div className="card preview-card">
            <span className="eyebrow">Your Moment</span>
            <div style={{ margin: "10px 0" }}><MomentMedia provenance={{ mediaURI: preview || form.mediaURI.trim(), animationURI: "" }} name={form.name || "Moment"} /></div>
            <h3 style={{ margin: 0 }}>{form.name.trim() || "Moment name"} <span className="ticker">${form.symbol || "TICKER"}</span></h3>
            <p className="desc">{form.place.trim() || "Place"} · {form.date ? fmtDate(Math.floor(new Date(form.date).getTime() / 1000)) : "date"}</p>
            <div className="trust"><EarlyLabel /></div>
            <div className="review">
              <KV label="Collect price" value={price ? usd(price) : "—"} />
              <KV label="Graduates at" value={p ? `${usd(p.threshold)} reserve` : "—"} />
              <KV label="Each collect" value={p ? `${bpsToPct(p.reserveBps)} reserve · ${bpsToPct(p.creatorBps)} you · ${bpsToPct(p.platformBps)} DyorHQ` : "—"} />
              <KV label="Your coins" value={`${fmtUnits(creatorCoins, 18, { compact: true })} (${bpsToPct(allocBps)})`} />
              <KV label="Collectors + pool" value={`${fmtUnits(SUPPLY - creatorCoins, 18, { compact: true })} at one price`} />
              <KV label="NFT royalty" value={p ? bpsToPct(p.royaltyBps) : "—"} />
              <KV label="Trading fee after graduation" value="1.5% (0.2% to you)" />
              <KV label="Window closes" value={now > 0 ? fmtDate(closesAt) : "—"} />
              <KV label="Liquidity" value={<span className="up">Locked forever</span>} />
            </div>
          </div>
        </aside>
      </div>
    </>
  );
}
