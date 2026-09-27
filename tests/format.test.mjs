import assert from "node:assert/strict";
import test from "node:test";
import { tsImport } from "tsx/esm/api";

/* app/lib/format.ts: dates built from half-typed form input render as "—", never "Invalid Date". Numbers come from one
   formatter family, so the same kind of value reads the same on every screen. */

const { fmtDate, fmtFixed, fmtNumber, fmtPct, fmtUsd } = await tsImport("../app/lib/format.ts", import.meta.url);

test("a time that isn't one renders as a dash", () => {
  for (const ts of [Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY, 1e20]) assert.equal(fmtDate(ts), "—", String(ts));
});

test("a real time renders as a date", () => {
  const shown = fmtDate(Date.UTC(2026, 8, 26, 12) / 1000);
  assert.match(shown, /^Sep 2[5-7], \d\d:\d\d [AP]M$/);
});

test("dollars: cents from $1 up, more precision below, never exponent notation", () => {
  assert.equal(fmtUsd(1), "$1.00");
  assert.equal(fmtUsd(1.5), "$1.50");
  assert.equal(fmtUsd(1.284), "$1.284");
  assert.equal(fmtUsd(102.725), "$102.725");
  assert.equal(fmtUsd(78391.5), "$78,391.50");
  assert.equal(fmtUsd(0.5), "$0.50");
  assert.equal(fmtUsd(0.0321), "$0.0321");
  assert.equal(fmtUsd(0), "$0.00");
  assert.equal(fmtUsd(9.5e-7), "$0.0₆95");
  for (const n of [9.5e-7, 1e-12, 3.2e-5]) assert.doesNotMatch(fmtUsd(n), /e/i, String(n));
  assert.equal(fmtUsd(-5), "−$5.00");
  assert.equal(fmtUsd(Number.NaN), "—");
});

test("one minus sign (U+2212) everywhere, and no sign on what rounds to zero", () => {
  assert.equal(fmtFixed(-1234.5), "−1,234.50");
  assert.equal(fmtFixed(-0.001), "0.00");
  assert.equal(fmtNumber(-2.5), "−2.5");
  assert.equal(fmtPct(-2.06), "−2.06%");
  assert.equal(fmtPct(12.8), "+12.80%");
  assert.equal(fmtPct(-0.001), "0.00%");
  assert.equal(fmtPct(0.004), "0.00%");
  assert.equal(fmtPct(-0.0012, 4), "−0.0012%");
  for (const s of [fmtFixed(-3), fmtNumber(-3), fmtPct(-3), fmtUsd(-3), fmtNumber(-3000, { compact: true })]) assert.doesNotMatch(s, /-/, s);
});

test("compact numbers roll over to the next unit instead of showing 1000K", () => {
  assert.equal(fmtNumber(512, { compact: true }), "512");
  assert.equal(fmtNumber(12_345, { compact: true }), "12.35K");
  assert.equal(fmtNumber(999_994, { compact: true }), "999.99K");
  assert.equal(fmtNumber(999_999, { compact: true }), "1M");
  assert.equal(fmtNumber(999_999_999, { compact: true }), "1B");
  assert.equal(fmtNumber(-999_999, { compact: true }), "−1M");
});
