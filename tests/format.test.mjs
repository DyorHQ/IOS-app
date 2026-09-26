import assert from "node:assert/strict";
import test from "node:test";
import { tsImport } from "tsx/esm/api";

/* app/lib/format.ts: dates built from half-typed form input render as "—", never "Invalid Date". */

const { fmtDate } = await tsImport("../app/lib/format.ts", import.meta.url);

test("a time that isn't one renders as a dash", () => {
  for (const ts of [Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY, 1e20]) assert.equal(fmtDate(ts), "—", String(ts));
});

test("a real time renders as a date", () => {
  const shown = fmtDate(Date.UTC(2026, 8, 26, 12) / 1000);
  assert.match(shown, /^Sep 2[5-7], \d\d:\d\d [AP]M$/);
});
