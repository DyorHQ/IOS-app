"use client";

import Link from "next/link";
import { useState } from "react";
import { Icon } from "../ui/icons";
import { Seg, type SegOpt } from "../ui/components";
import { Skeleton, Tile } from "../launchpad/ui";
import { MOMENTS_DEPLOYED } from "../lib/moments/config";
import { fetchMoments, fetchPolicy, type MomentInfo } from "../lib/moments/reads";
import { useAsync, useNow } from "../lib/use-async";
import { bpsToPct } from "../lib/format";
import { EarlyLabel, MomentCard, MomentsDeployNotice, usd } from "./ui";

type Filter = "all" | "collecting" | "graduated" | "ended";
type Sort = "newest" | "progress" | "editions";
const FILTERS: SegOpt<Filter>[] = [{ v: "all", l: "All" }, { v: "collecting", l: "Collecting" }, { v: "graduated", l: "Graduated" }, { v: "ended", l: "Ended" }];

function sortMoments(list: MomentInfo[], sort: Sort) {
  const copy = [...list];
  if (sort === "progress") copy.sort((a, b) => b.progressBps - a.progressBps || b.publishedAt - a.publishedAt);
  if (sort === "editions") copy.sort((a, b) => b.editions - a.editions || b.publishedAt - a.publishedAt);
  return copy;
}

export default function Explore() {
  const policy = useAsync(fetchPolicy, "moments-policy", 60_000);
  const moments = useAsync(() => fetchMoments(60), "moments", 8_000);
  const [filter, setFilter] = useState<Filter>("all");
  const [sort, setSort] = useState<Sort>("newest");
  const now = useNow();
  const all = moments.data ?? [];
  const list = sortMoments(
    all.filter((m) => (filter === "all" ? true : filter === "graduated" ? m.graduated : filter === "ended" ? m.ledger.state === 3 : !m.graduated && m.ledger.state !== 3)),
    sort,
  );
  const p = policy.data;

  return (
    <>
      <section className="page-hero">
        <div>
          <span className="eyebrow">Moments · Monad mainnet</span>
          <h1>Collect a moment.<br />Own its edition.</h1>
          <p>A creator publishes a moment; collectors pay a fixed USDC price for numbered editions and are promised a share of the moment&apos;s coin. If enough is collected, a tiny pool opens at the same price and locks forever. Every Moment is an <b>early, low-cap, validation-stage</b> asset: few holders, thin liquidity, no guarantees.</p>
          <div className="trust" style={{ marginTop: 12 }}><EarlyLabel /></div>
          <Link className="btn primary" href="/moments/create" style={{ marginTop: 14 }}>Publish a Moment <Icon name="arrow-ur" /></Link>
        </div>
        <div className="stat-strip">
          <Tile label="Moments" value={p ? p.momentCount.toLocaleString("en-US") : MOMENTS_DEPLOYED ? <Skeleton h={24} w={48} /> : "—"} sub="published on this factory" />
          <Tile label="Graduates at" value={p ? usd(p.threshold) : MOMENTS_DEPLOYED ? <Skeleton h={24} w={80} /> : "—"} sub={p ? `reserve · min collect ${usd(p.minPrice)}` : "policy value"} />
          <Tile label="Each collect" value={p ? `${bpsToPct(p.reserveBps)} reserve` : MOMENTS_DEPLOYED ? <Skeleton h={24} w={90} /> : "—"} sub={p ? `${bpsToPct(p.creatorBps)} creator · ${bpsToPct(p.platformBps)} DyorHQ` : "USDC split"} />
        </div>
      </section>

      <MomentsDeployNotice />

      <div className="toolbar">
        <Seg options={FILTERS} value={filter} onChange={setFilter} small />
        <select className="select sm" value={sort} onChange={(e) => setSort(e.target.value as Sort)} aria-label="Sort Moments">
          <option value="newest">Newest first</option>
          <option value="progress">Closest to graduation</option>
          <option value="editions">Most editions</option>
        </select>
      </div>

      {moments.error && <p className="tx bad" role="alert">{moments.error}</p>}
      <section className="moment-grid" aria-busy={moments.loading}>
        {moments.loading && !moments.data && MOMENTS_DEPLOYED && [0, 1, 2].map((i) => (
          <div key={i} className="card moment-card"><Skeleton h={180} /><div className="body"><Skeleton h={16} w="60%" /><Skeleton h={12} w="40%" style={{ marginTop: 8 }} /><Skeleton h={6} style={{ margin: "26px 0 14px" }} /></div></div>
        ))}
        {list.map((m) => <MomentCard key={String(m.id)} moment={m} now={now} />)}
      </section>
      {MOMENTS_DEPLOYED && !moments.loading && !moments.error && list.length === 0 && (
        <div className="empty"><span className="glyph"><Icon name="rocket" /></span><b>{all.length ? "Nothing in this filter" : "No Moments yet"}</b><p>{all.length ? "Try another filter." : "Be the first: publish a Moment and it appears here the moment the transaction confirms."}</p></div>
      )}
    </>
  );
}
