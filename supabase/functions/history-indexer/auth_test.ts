// deno test --no-config --node-modules-dir=none -A supabase/functions/history-indexer/
import { assertEquals } from "jsr:@std/assert@1";
import { cronAuthorized } from "./auth.ts";

const SECRET = "s".repeat(20) + "-cron-header-value-48"; // 41 characters, a test value

Deno.test("cronAuthorized: only the exact header, and only with a configured secret of 32+ characters", async () => {
  assertEquals(await cronAuthorized(SECRET, SECRET), true);
  assertEquals(await cronAuthorized(SECRET + " ", SECRET), false);
  assertEquals(await cronAuthorized(SECRET.toUpperCase(), SECRET), false);
  assertEquals(await cronAuthorized("", SECRET), false);
  assertEquals(await cronAuthorized(null, SECRET), false);
  // A prefix of the secret (what an attacker learning it byte by byte would send) is refused like anything else.
  assertEquals(await cronAuthorized(SECRET.slice(0, 32), SECRET), false);
  assertEquals(await cronAuthorized(SECRET.slice(0, -1), SECRET), false);
  // No secret, or a short one, refuses everything — even a header equal to it.
  assertEquals(await cronAuthorized("", undefined), false);
  assertEquals(await cronAuthorized("x", ""), false);
  const short = "a".repeat(31);
  assertEquals(await cronAuthorized(short, short), false);
  assertEquals(await cronAuthorized("a".repeat(32), "a".repeat(32)), true);
});
