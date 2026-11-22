// deno test --no-config --node-modules-dir=none -A supabase/functions/_shared/
// xstocks.json is the list of xStocks oneinch-proxy may quote against USDC; xstocks.ts is generated from it.
import { assertEquals, assertMatch } from "jsr:@std/assert@1";
import { generatedModule } from "./gen_xstocks.ts";
import { XSTOCKS } from "./xstocks.ts";

const JSON_URL = new URL("./xstocks.json", import.meta.url);
const MONAD_SWIFT = new URL("../../../ios/DyorKit/Sources/DyorKit/Chain/Monad.swift", import.meta.url);

Deno.test("xstocks.ts is generated from xstocks.json", async () => {
  const raw = await Deno.readTextFile(JSON_URL);
  const onDisk = await Deno.readTextFile(new URL("./xstocks.ts", import.meta.url));
  assertEquals(onDisk, generatedModule(raw), "run gen_xstocks.ts after changing xstocks.json");
  assertEquals(XSTOCKS, JSON.parse(raw));
});

Deno.test("xstocks.json: USDC is the app's Monad.usdc, lowercase", async () => {
  const value = JSON.parse(await Deno.readTextFile(JSON_URL));
  const swift = await Deno.readTextFile(MONAD_SWIFT);
  const usdc = swift.match(/static let usdc = Address\(literal: "(0x[0-9a-fA-F]{40})"\)/);
  assertMatch(value.usdc, /^0x[0-9a-f]{40}$/);
  assertEquals(value.usdc, usdc?.[1].toLowerCase());
});

Deno.test("xstocks.json: no xStock is listed until its address and reference feed are verified (R4, R6, R11)", async () => {
  // UNVERIFIED (research R4, R6, R11): the app's XStocks.curated is empty too, so the proxy serves no pair yet.
  const value = JSON.parse(await Deno.readTextFile(JSON_URL));
  assertEquals(value.curated, []);
});
