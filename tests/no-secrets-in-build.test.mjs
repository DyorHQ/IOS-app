import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

/* The production build (dist/, what gets deployed) must carry no secret: scripts/dev/secret-scan.sh --path checks it for
   every secret value in the repo's .env and Secrets.xcconfig and for key patterns, and reports names, never values. */
const root = fileURLToPath(new URL("..", import.meta.url));
const scanner = path.join(root, "scripts/dev/secret-scan.sh");
const scan = (args, env = process.env) => spawnSync("/bin/bash", [scanner, ...args], { cwd: root, encoding: "utf8", env });

test("the production build output carries no secret values", () => {
  const dist = path.join(root, "dist");
  assert.ok(existsSync(path.join(dist, "client")) && existsSync(path.join(dist, "server")), "dist/ is missing: run `npm run build` first");
  const env = { ...process.env };
  delete env.SECRET_SCAN_ENV;
  delete env.SECRET_SCAN_XCCONFIG;
  const result = scan(["--path", dist], env);
  assert.equal(result.status, 0, `secret-scan found secrets in dist/ (locations and names only):\n${result.stdout}${result.stderr}`);
});

test("the scanner catches planted secrets and never prints a value", () => {
  // Fake, freshly generated values only: never test with real secrets.
  const fake = (n) => randomBytes(n).toString("hex");
  const secret = `sk_${fake(16)}`;
  const devKey = `0x${fake(32)}`;
  const publicRpc = `https://rpc-${fake(6)}.example`;
  const address = `0x${fake(20)}`;
  const dir = mkdtempSync(path.join(tmpdir(), "secret-scan-test-"));
  try {
    const envFile = path.join(dir, "fake.env");
    writeFileSync(envFile, [`FAKE_API_KEY=${secret}`, `NEXT_PUBLIC_DEV_WALLET_KEY=${devKey}`, `NEXT_PUBLIC_RPC=${publicRpc}`, `TREASURY=${address}`, ""].join("\n"));
    const out = path.join(dir, "dist");
    mkdirSync(path.join(out, "assets"), { recursive: true });
    writeFileSync(path.join(out, "assets", "app.js"), `const rpc="${publicRpc}",t="${address}";\nconst k="${secret}";\nconst w="${devKey.slice(2).toUpperCase()}";\n`);
    writeFileSync(path.join(out, "clean.js"), "export const ok = 1;\n");

    const result = scan(["--path", out], { ...process.env, SECRET_SCAN_ENV: envFile });
    assert.equal(result.status, 1, "the planted secrets were not detected");
    const report = result.stdout + result.stderr;
    assert.match(result.stdout, /app\.js:2: FAKE_API_KEY \(fake\.env\)/);
    assert.match(result.stdout, /app\.js:3: NEXT_PUBLIC_DEV_WALLET_KEY \(fake\.env\)/);
    assert.doesNotMatch(result.stdout, /NEXT_PUBLIC_RPC|TREASURY|clean\.js/);
    for (const value of [secret, devKey.slice(2), publicRpc, address]) assert.ok(!report.toLowerCase().includes(value.toLowerCase()), "the scanner printed a value");

    rmSync(path.join(out, "assets"), { recursive: true });
    assert.equal(scan(["--path", out], { ...process.env, SECRET_SCAN_ENV: envFile }).status, 0, "a clean directory must pass");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
