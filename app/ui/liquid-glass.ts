// Liquid glass: Chromium can run an SVG displacement filter inside backdrop-filter, so each glass capsule gets a
// per-size map that bends the backdrop inward along its rim (a lens edge). Other engines keep the CSS frosted
// blur. Everything here touches the DOM, so call it from effects only.
const NS = "http://www.w3.org/2000/svg";
type Rec = { id: string; w?: number; h?: number };
const items = new Map<HTMLElement, Rec>();
let n = 0;
let intensity = 60;
let defs: SVGDefsElement | null = null;
let ro: ResizeObserver | null = null;
let supportedCache: boolean | null = null;

export function supported(): boolean {
  if (typeof window === "undefined") return false;
  if (supportedCache === null) {
    const nav = navigator as Navigator & { userAgentData?: unknown };
    supportedCache = !!nav.userAgentData && typeof CSS !== "undefined" && CSS.supports("backdrop-filter", "url(#x)");
  }
  return supportedCache;
}
function ensureDefs() {
  if (defs) return defs;
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("aria-hidden", "true");
  svg.style.cssText = "position:absolute;width:0;height:0;overflow:hidden";
  defs = document.createElementNS(NS, "defs");
  svg.appendChild(defs);
  document.body.appendChild(svg);
  return defs;
}
function mapFor(w: number, h: number, r: number) {
  const c = document.createElement("canvas"); c.width = w; c.height = h;
  const ctx = c.getContext("2d")!; const img = ctx.createImageData(w, h); const d = img.data;
  const rr = Math.min(r, w / 2, h / 2), band = Math.max(6, Math.min(w, h) * 0.42);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const px = x + 0.5 - w / 2, py = y + 0.5 - h / 2, qx = Math.abs(px) - (w / 2 - rr), qy = Math.abs(py) - (h / 2 - rr);
    const dist = Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - rr;
    let t = 1 + dist / band; t = t < 0 ? 0 : t > 1 ? 1 : t; const s = t * t * (3 - 2 * t);
    let nx: number, ny: number;
    if (qx > 0 || qy > 0) { nx = Math.max(qx, 0) * Math.sign(px); ny = Math.max(qy, 0) * Math.sign(py); }
    else if (qx > qy) { nx = Math.sign(px); ny = 0; } else { nx = 0; ny = Math.sign(py); }
    const len = Math.hypot(nx, ny) || 1; nx /= len; ny /= len;
    const i = (y * w + x) * 4; d[i] = Math.round(128 - nx * s * 127); d[i + 1] = Math.round(128 - ny * s * 127); d[i + 2] = 0; d[i + 3] = 255;
  }
  ctx.putImageData(img, 0, 0);
  return c.toDataURL();
}
function apply(el: HTMLElement) {
  const clear = () => { el.style.removeProperty("backdrop-filter"); el.style.removeProperty("-webkit-backdrop-filter"); };
  if (!supported() || intensity === 0 || !el.isConnected) { clear(); return; }
  const w = Math.max(2, Math.round(el.offsetWidth)), h = Math.max(2, Math.round(el.offsetHeight));
  if (w < 3 || h < 3) return;
  const rec = items.get(el); if (!rec) return;
  let f = document.getElementById(rec.id) as SVGFilterElement | null;
  if (!f) { f = document.createElementNS(NS, "filter"); f.id = rec.id; ensureDefs().appendChild(f); }
  if (rec.w !== w || rec.h !== h) {
    rec.w = w; rec.h = h;
    const r = parseFloat(getComputedStyle(el).borderTopLeftRadius) || Math.min(w, h) / 2;
    f.setAttribute("filterUnits", "userSpaceOnUse"); f.setAttribute("x", "0"); f.setAttribute("y", "0");
    f.setAttribute("width", String(w)); f.setAttribute("height", String(h)); f.setAttribute("color-interpolation-filters", "sRGB");
    f.innerHTML = `<feImage href="${mapFor(w, h, r)}" width="${w}" height="${h}" result="m"/><feDisplacementMap in="SourceGraphic" in2="m" scale="0" xChannelSelector="R" yChannelSelector="G"/>`;
  }
  const dm = f.querySelector("feDisplacementMap"); if (dm) dm.setAttribute("scale", ((intensity / 100) * 44).toFixed(1));
  const v = `url(#${rec.id}) blur(${(1.5 + ((100 - intensity) / 100) * 9).toFixed(1)}px) saturate(1.5)`;
  el.style.setProperty("backdrop-filter", v); el.style.setProperty("-webkit-backdrop-filter", v);
}
function observer() {
  if (!ro && typeof ResizeObserver !== "undefined") ro = new ResizeObserver((es) => { for (const e of es) apply(e.target as HTMLElement); });
  return ro;
}
export function scan(scope: ParentNode = document) {
  scope.querySelectorAll<HTMLElement>("[data-glass]").forEach((el) => {
    if (!items.has(el)) { items.set(el, { id: "lg" + n++ }); observer()?.observe(el); }
    apply(el);
  });
}
export function setIntensity(v: number) { intensity = v; items.forEach((_, el) => apply(el)); }
export function cleanup() {
  items.forEach((rec, el) => {
    if (!el.isConnected) { ro?.unobserve(el); document.getElementById(rec.id)?.remove(); items.delete(el); }
  });
}
