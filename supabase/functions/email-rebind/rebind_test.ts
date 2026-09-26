// deno test --no-config --node-modules-dir=none -A supabase/functions/email-rebind/
import { assertEquals } from "jsr:@std/assert@1";
import { decideRebind, field, parseReplace } from "./rebind.ts";

const NEW = "0x" + "a".repeat(40);
const OLD = "0x" + "b".repeat(40);
const OLD_MIXED = "0x" + "B".repeat(40);

Deno.test("GE-1: a first sign-up inserts, a same-wallet re-bind refreshes (both unchanged)", () => {
  assertEquals(decideRebind(null, NEW, undefined), { action: "insert" });
  assertEquals(decideRebind(null, NEW, OLD), { action: "insert" });
  assertEquals(decideRebind(NEW, NEW, undefined), { action: "refresh", from: NEW });
  assertEquals(decideRebind(NEW.toUpperCase().replace("0X", "0x"), NEW, undefined), { action: "refresh", from: NEW.toUpperCase().replace("0X", "0x") });
});

Deno.test("GE-1: another wallet's binding moves only with replace naming exactly that wallet", () => {
  assertEquals(decideRebind(OLD, NEW, undefined), { action: "conflict", current: OLD });
  assertEquals(decideRebind(OLD, NEW, NEW), { action: "conflict", current: OLD });
  assertEquals(decideRebind(OLD, NEW, "0x" + "c".repeat(40)), { action: "conflict", current: OLD });
  assertEquals(decideRebind(OLD, NEW, OLD), { action: "replace", from: OLD });
  assertEquals(decideRebind(OLD, NEW, OLD_MIXED), { action: "replace", from: OLD });
  assertEquals(decideRebind(OLD_MIXED, NEW, OLD), { action: "replace", from: OLD_MIXED });
});

Deno.test("replace: absent or null is no replace; anything but an address is invalid", () => {
  assertEquals(parseReplace(undefined), undefined);
  assertEquals(parseReplace(null), undefined);
  assertEquals(parseReplace(OLD), OLD);
  for (const bad of ["", "0x123", OLD + "0", 42, true, [OLD], { address: OLD }, "0x" + "g".repeat(40)]) {
    assertEquals(parseReplace(bad), "invalid", JSON.stringify(bad));
  }
});

Deno.test("challenge fields are read by name, case-insensitively, first line wins", () => {
  const challenge = `DyorHQ Email Rebind\n\nEmail: Me@X.io\nAddress: ${NEW}\nIssued At: 2026-09-26T12:00:00.000Z`;
  assertEquals(field(challenge, "Email"), "Me@X.io");
  assertEquals(field(challenge, "address"), NEW);
  assertEquals(field(challenge, "Issued At"), "2026-09-26T12:00:00.000Z");
  assertEquals(field(challenge, "Replace"), null);
  assertEquals(field(challenge + "\nEmail: evil@x.io", "Email"), "Me@X.io");
});
