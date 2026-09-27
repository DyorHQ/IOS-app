import assert from "node:assert/strict";
import test from "node:test";
import { tsImport } from "tsx/esm/api";

/* app/lib/clipboard.ts: a copy is confirmed only when the clipboard write resolves; a missing clipboard or a refused
   write reports failure instead of a false "Copied". */

const { copyText, COPY_FEEDBACK } = await tsImport("../app/lib/clipboard.ts", import.meta.url);

test("resolves true only once the clipboard has taken the text", async () => {
  const written = [];
  assert.equal(await copyText("0xabc", { writeText: async (t) => { written.push(t); } }), true);
  assert.deepEqual(written, ["0xabc"]);
});

test("a refused write or a missing clipboard is a failure, never a throw", async () => {
  assert.equal(await copyText("0xabc", { writeText: async () => { throw new DOMException("Document is not focused.", "NotAllowedError"); } }), false);
  assert.equal(await copyText("0xabc", { writeText: () => { throw new TypeError("sync failure"); } }), false);
  assert.equal(await copyText("0xabc", undefined), false);
});

test("every copy control uses the same words", () => {
  assert.deepEqual(COPY_FEEDBACK, { copied: "Address copied", failed: "Couldn't copy the address" });
});
