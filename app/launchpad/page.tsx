"use client";

import Link from "next/link";
import { useState } from "react";
import { Icon } from "../ui/icons";
import { Seg, type SegOpt } from "../ui/components";
import { DEPLOYED } from "../lib/chain";
import { fetchLaunches, fetchProtocol, type LaunchInfo } from "../lib/launchpad";
import { useAsync, useNow } from "../lib/use-async";
import { bpsToPct, fmtAmount, seconds } from "../lib/format";
import { DeployNotice, LaunchCard, Skeleton, Tile } from "./ui";

type Filter = "all" | "bonding" | "graduated";
type Sort = "newest" | "progress" | "cap";
const FILTERS: SegOpt<Filter>[] = [{ v: "all", l: "All" }, { v: "bonding", l: "Bonding" }, { v: "graduated", l: "Graduated" }];

function sortLaunches(list: LaunchInfo[], sort: Sort) {
  const copy = [...list];
  if (sort === "progress") copy.sort((a, b) => b.progressBps - a.progressBps || b.launchedAt - a.launchedAt);
  if (sort === "cap") copy.sort((a, b) => (b.marketCap > a.marketCap ? 1 : b.marketCap < a.marketCap ? -1 : 0));
  return copy;
}

export default function Explore() {
  const protocol = useAsync(fetchProtocol, "protocol", 60_000);
  const launches = useAsync(() => fetchLaunches(60), "launches", 8_000);
  const [filter, setFilter] = useState<Filter>("all");
  const [sort, setSort] = useState<Sort>("newest");
  const now = useNow();
  const native = protocol.data?.pairs.find((p) => p.native);
  const all = launches.data ?? [];
  const list = sortLaunches(all.filter((l) => (filter === "all" ? true : filter === "graduated" ? l.phase === 2 : l.phase !== 2)), sort);

  return (
    <>
      <section className="page-hero">
        <div>
          <span className="eyebrow">Launchpad · Monad mainnet</span>
          <h1>Launch a meme.<br />Trade it on a fair curve.</h1>
          <p>Every token starts on a bonding curve with no pre-mine and no team allocation. When it raises the threshold, its liquidity moves into a Uniswap v4 pool and locks forever.</p>
          <Link className="btn primary" href="/launchpad/create">Create a token <Icon name="arrow-ur" /></Link>
        </div>
        <div className="stat-strip">
          <Tile label="Launches" value={protocol.data ? protocol.data.launchCount.toLocaleString("en-US") : DEPLOYED ? <Skeleton h={24} w={48} /> : "—"} sub="on this factory" />
          <Tile label="Launch fee" value={protocol.data ? fmtAmount(protocol.data.launchFee, 18, "MON") : DEPLOYED ? <Skeleton h={24} w={80} /> : "—"} sub={protocol.data ? `Trade fee ${bpsToPct(protocol.data.curveFeeBps)}` : "set by the owner"} />
          <Tile label="Graduates at" value={native ? fmtAmount(native.graduationThreshold, 18, "MON", { compact: true }) : DEPLOYED ? <Skeleton h={24} w={90} /> : "—"} sub={protocol.data ? `${seconds(protocol.data.snipeSchedule.length)} anti-snipe window` : "raised on the curve"} />
        </div>
      </section>

      {!DEPLOYED && <DeployNotice />}

      <div className="toolbar">
        <Seg options={FILTERS} value={filter} onChange={setFilter} small />
        <select className="select sm" value={sort} onChange={(e) => setSort(e.target.value as Sort)} aria-label="Sort launches">
          <option value="newest">Newest first</option>
          <option value="progress">Closest to graduation</option>
          <option value="cap">Largest market cap</option>
        </select>
      </div>

      {launches.error && <p className="tx bad" role="alert">{launches.error}</p>}
      <section className="launch-grid" aria-busy={launches.loading}>
        {launches.loading && !launches.data && DEPLOYED && [0, 1, 2].map((i) => (
          <div key={i} className="card launch-card"><div className="launch-top"><Skeleton h={46} w={46} style={{ borderRadius: 14 }} /><div style={{ flex: 1 }}><Skeleton h={16} w="60%" /><Skeleton h={12} w="40%" style={{ marginTop: 8 }} /></div></div><Skeleton h={6} style={{ margin: "26px 0 14px" }} /><Skeleton h={30} /></div>
        ))}
        {list.map((l) => <LaunchCard key={l.token} launch={l} now={now} />)}
      </section>
      {DEPLOYED && !launches.loading && !launches.error && list.length === 0 && (
        <div className="empty"><span className="glyph"><Icon name="rocket" /></span><b>{all.length ? "Nothing in this filter" : "No launches yet"}</b><p>{all.length ? "Try another filter." : "Be the first: create a token and it appears here the moment the transaction confirms."}</p></div>
      )}
    </>
  );
}
