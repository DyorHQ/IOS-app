// deno test --no-config --node-modules-dir=none -A supabase/functions/_shared/
import { assertEquals } from "jsr:@std/assert@1";
import { clientNet } from "./net.ts";

const req = (headers: Record<string, string>) => new Request("https://x.test/", { headers });

Deno.test("clientNet: IPv4 per address, IPv6 per /64, mapped IPv4 as IPv4, never X-Forwarded-For", () => {
  assertEquals(clientNet(req({ "cf-connecting-ip": "203.0.113.9" })), "203.0.113.9");
  assertEquals(clientNet(req({ "cf-connecting-ip": " 203.0.113.9 " })), "203.0.113.9");
  assertEquals(clientNet(req({ "cf-connecting-ip": "256.1.1.1" })), null);
  assertEquals(clientNet(req({ "cf-connecting-ip": "2001:DB8:1:2:3:4:5:6" })), "2001:db8:1:2::/64");
  assertEquals(clientNet(req({ "cf-connecting-ip": "2001:db8:1:2::9" })), "2001:db8:1:2::/64");
  assertEquals(clientNet(req({ "cf-connecting-ip": "::ffff:198.51.100.4" })), "198.51.100.4");
  assertEquals(clientNet(req({ "cf-connecting-ip": "not-an-ip" })), null);
  assertEquals(clientNet(req({ "x-forwarded-for": "198.51.100.1" })), null);
  assertEquals(clientNet(req({ "x-real-ip": "198.51.100.1" })), null);
  assertEquals(clientNet(req({})), null);
});
