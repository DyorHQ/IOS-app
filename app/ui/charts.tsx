"use client";
// SVG charts drawn to one scale: thin marks, hairline solid grid, text in theme tokens.
import { useId, useRef, useState, type PointerEvent } from "react";
import { candles, fmtNum, ma, PERP } from "./data";

export function smoothPath(pts: number[][]) {
  if (pts.length < 2) return "";
  const t = 0.18, d = [`M${pts[0][0].toFixed(1)},${pts[0][1].toFixed(1)}`];
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[i - 1] || pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2] || p2;
    d.push(`C${(p1[0] + (p2[0] - p0[0]) * t).toFixed(1)},${(p1[1] + (p2[1] - p0[1]) * t).toFixed(1)} ${(p2[0] - (p3[0] - p1[0]) * t).toFixed(1)},${(p2[1] - (p3[1] - p1[1]) * t).toFixed(1)} ${p2[0].toFixed(1)},${p2[1].toFixed(1)}`);
  }
  return d.join(" ");
}

export function LineChart({ values, color = "var(--accent-ink)", w = 320, h = 56, pad = 4, grid = false, dot = true, areaOpacity = 0.14 }: { values: number[]; color?: string; w?: number; h?: number; pad?: number; grid?: boolean; dot?: boolean; areaOpacity?: number }) {
  const gid = "g" + useId().replace(/[^a-zA-Z0-9]/g, "");
  const min = Math.min(...values), max = Math.max(...values), rng = max - min || 1;
  const pts = values.map((v, i) => [pad + (i * (w - 2 * pad)) / (values.length - 1), h - pad - ((v - min) / rng) * (h - 2 * pad - 2)]);
  const line = smoothPath(pts), end = pts[pts.length - 1];
  const area = `${line} L${end[0].toFixed(1)},${h} L${pts[0][0].toFixed(1)},${h} Z`;
  return (
    <svg viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" aria-hidden="true">
      <defs><linearGradient id={gid} x1="0" x2="0" y1="0" y2="1"><stop offset="0" stopColor={color} stopOpacity={areaOpacity} /><stop offset="1" stopColor={color} stopOpacity="0" /></linearGradient></defs>
      {grid && [0.25, 0.5, 0.75].map((f) => <line key={f} x1="0" x2={w} y1={(h * f).toFixed(1)} y2={(h * f).toFixed(1)} stroke="var(--track)" strokeWidth="1" />)}
      <path d={area} fill={`url(#${gid})`} />
      <path d={line} fill="none" stroke={color} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" vectorEffect="non-scaling-stroke" />
      {dot && <circle cx={end[0].toFixed(1)} cy={end[1].toFixed(1)} r="4" fill={color} stroke="var(--card)" strokeWidth="2" vectorEffect="non-scaling-stroke" />}
    </svg>
  );
}

export function CandleChart({ period }: { period: string }) {
  const data = candles();
  const [hover, setHover] = useState<number | null>(null);
  const svgRef = useRef<SVGSVGElement>(null);
  const W = 380, H = 250, axisW = 54, padT = 8, volH = 40, chartB = H - volH - 22, plotW = W - axisW;
  let hi = -Infinity, lo = Infinity; data.forEach((d) => { hi = Math.max(hi, d.h); lo = Math.min(lo, d.l); });
  const rngP = hi - lo || 1;
  const y = (v: number) => padT + ((hi - v) / rngP) * (chartB - padT);
  const step = plotW / data.length, bw = Math.min(9, step * 0.62);
  const maxV = Math.max(...data.map((d) => d.v));
  const series = (s: (number | null)[]) => { const pts: number[][] = []; s.forEach((v, i) => { if (v != null) pts.push([i * step + step / 2, y(v)]); }); return smoothPath(pts); };
  const ly = y(PERP.mid);
  const locate = (e: PointerEvent<SVGSVGElement>) => {
    const r = svgRef.current?.getBoundingClientRect(); if (!r) return;
    const x = ((e.clientX - r.left) / r.width) * W;
    if (x < 0 || x > plotW) { setHover(null); return; }
    setHover(Math.min(data.length - 1, Math.max(0, Math.floor(x / step))));
  };
  const d = hover == null ? null : data[hover];
  return (
    <>
      <div className="chart-cap" style={{ paddingTop: 0 }}>
        <span className="legend"><span><i style={{ background: "var(--accent-ink)" }} />MA 7</span><span><i style={{ background: "var(--muted)" }} />MA 25</span></span>
        <span>{d ? <><b className={d.c >= d.o ? "up" : "down"}>{d.c >= d.o ? "Up" : "Down"}</b> O {fmtNum(d.o, 0)} · H {fmtNum(d.h, 0)} · L {fmtNum(d.l, 0)} · C {fmtNum(d.c, 0)}</> : "Touch the chart for OHLC"}</span>
      </div>
      <div className="chart">
        <svg ref={svgRef} viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" role="img" aria-label={`Illustrative ETH candlestick chart, ${period} interval`} onPointerMove={locate} onPointerDown={locate} onPointerLeave={() => setHover(null)}>
          {[0, 1, 2, 3].map((i) => { const f = i / 3, gy = padT + (chartB - padT) * f; return <g key={i}><line x1="0" x2={plotW} y1={gy.toFixed(1)} y2={gy.toFixed(1)} stroke="var(--track)" strokeWidth="1" /><text x={plotW + 8} y={(gy + 4).toFixed(1)} fontSize="11" fill="var(--muted)">{fmtNum(hi - rngP * f, 0)}</text></g>; })}
          {data.map((c, i) => { const cx = i * step + step / 2, up = c.c >= c.o, col = up ? "var(--up)" : "var(--down)"; const vh = (c.v / maxV) * volH; return <rect key={i} x={(cx - bw / 2).toFixed(1)} y={(H - 22 - vh).toFixed(1)} width={bw.toFixed(1)} height={vh.toFixed(1)} rx="1" fill={col} opacity=".35" />; })}
          {data.map((c, i) => { const cx = i * step + step / 2, up = c.c >= c.o, col = up ? "var(--up)" : "var(--down)"; const top = Math.min(y(c.o), y(c.c)), bh = Math.max(1.5, Math.abs(y(c.c) - y(c.o))); return <g key={i} style={{ opacity: hover == null || hover === i ? 1 : 0.5 }}><line x1={cx.toFixed(1)} x2={cx.toFixed(1)} y1={y(c.h).toFixed(1)} y2={y(c.l).toFixed(1)} stroke={col} strokeWidth="1.2" /><rect x={(cx - bw / 2).toFixed(1)} y={top.toFixed(1)} width={bw.toFixed(1)} height={bh.toFixed(1)} rx="1" fill={col} /></g>; })}
          <path d={series(ma(data, 25))} fill="none" stroke="var(--muted)" strokeWidth="1.6" strokeLinecap="round" vectorEffect="non-scaling-stroke" />
          <path d={series(ma(data, 7))} fill="none" stroke="var(--accent-ink)" strokeWidth="1.6" strokeLinecap="round" vectorEffect="non-scaling-stroke" />
          <line x1="0" x2={plotW} y1={ly.toFixed(1)} y2={ly.toFixed(1)} stroke="var(--up)" strokeWidth="1" strokeDasharray="3 3" />
          <rect x={plotW + 2} y={(ly - 9).toFixed(1)} width={axisW - 2} height="18" rx="4" fill="var(--up-fill)" />
          <text x={plotW + axisW / 2 + 1} y={(ly + 4).toFixed(1)} textAnchor="middle" fontSize="11" fontWeight="600" fill="var(--on-up)">{fmtNum(PERP.mid, 0)}</text>
          {["Sep 6", "Sep 7", "Sep 7", "Sep 8"].map((t, i) => <text key={i} x={((plotW * (i + 0.5)) / 4).toFixed(1)} y={H - 6} textAnchor="middle" fontSize="11" fill="var(--muted)">{t}</text>)}
        </svg>
        <span className="cross" style={{ left: hover == null ? undefined : `${(((hover + 0.5) * step) / W) * 100}%`, opacity: hover == null ? 0 : 1 }} />
      </div>
    </>
  );
}
