import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { randomBytes, randomInt } from "node:crypto";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

/* The leak guard (scripts/dev/secret-scan.sh, scripts/dev/forbidden-paths.sh, scripts/dev/install-hooks.sh and the
   .githooks/ they install) exercised in throwaway repositories. Every secret below is FAKE, generated at run time —
   never test with real values — and no output may contain one. */
const root = fileURLToPath(new URL("..", import.meta.url));
const GUARD = ["scripts/dev/secret-scan.sh", "scripts/dev/forbidden-paths.sh", "scripts/dev/install-hooks.sh",
  "scripts/dev/bip39-english.txt", ".githooks/pre-commit", ".githooks/pre-merge-commit", ".githooks/pre-push", ".leakguard"];

const ALNUM = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
const pick = (chars, n) => Array.from({ length: n }, () => chars[randomInt(chars.length)]).join("");
const alnum = (n) => pick(ALNUM, n);
const upper = (n) => pick("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", n);
const digits = (n) => pick("123456789", 1) + pick("0123456789", n - 1);
const hex = (bytes) => randomBytes(bytes).toString("hex");
const b64url = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const jwt = (payload) => `${b64url({ alg: "HS256", typ: "JWT" })}.${b64url(payload)}.${randomBytes(32).toString("base64url")}`;

const words = readFileSync(path.join(root, "scripts/dev/bip39-english.txt"), "utf8").trim().split("\n");
function seedPhrase(n = 12) {
  for (;;) {
    const p = Array.from({ length: n }, () => words[randomInt(words.length)]);
    if (new Set(p).size >= 10 && p.some((w, i) => i > 0 && w <= p[i - 1])) return p.join(" ");
  }
}
// The public test keys the scanner masks (anvil/hardhat and the fork-only dev keys), read from the scanner itself.
const scannerSource = readFileSync(path.join(root, "scripts/dev/secret-scan.sh"), "utf8");
const publicKeys = scannerSource.slice(scannerSource.indexOf("PUBLIC_TEST_KEYS="), scannerSource.indexOf("| tr ' ' '|'))\"")).match(/[0-9a-f]{64}/g);

let dir, env, fakeEnvValue;
const secretsSeen = []; // every fake value that must never be printed
const fake = (v) => (secretsSeen.push(v), v);
const run = (cmd, args, cwd, input) => {
  const r = spawnSync(cmd, args, { cwd, env, input, encoding: "utf8" });
  const out = `${r.stdout}${r.stderr}`;
  for (const s of secretsSeen) assert.ok(!out.includes(s), `a fake secret value was printed by ${cmd} ${args.join(" ")}`);
  return { status: r.status, out };
};
const git = (cwd, ...args) => run("git", args, cwd);
const write = (repo, file, text) => {
  mkdirSync(path.dirname(path.join(repo, file)), { recursive: true });
  writeFileSync(path.join(repo, file), text);
};
function newRepo(name, withGuard = true) {
  const repo = path.join(dir, name);
  mkdirSync(repo);
  git(repo, "init", "-q", "-b", "main");
  if (withGuard) {
    for (const f of GUARD) {
      mkdirSync(path.dirname(path.join(repo, f)), { recursive: true });
      copyFileSync(path.join(root, f), path.join(repo, f));
      if (!f.endsWith(".txt") && f !== ".leakguard") chmodSync(path.join(repo, f), 0o755);
    }
    git(repo, "add", "--", ...GUARD);
    assert.equal(git(repo, "commit", "-q", "-m", "leak guard").status, 0);
  }
  return repo;
}
const scan = (repo, ...args) => run("/bin/bash", [path.join(repo, "scripts/dev/secret-scan.sh"), ...args], repo);
const paths = (repo, ...args) => run("/bin/bash", [path.join(repo, "scripts/dev/forbidden-paths.sh"), ...args], repo);

before(() => {
  dir = mkdtempSync(path.join(tmpdir(), "leak-guard-test-"));
  const globalConfig = path.join(dir, "gitconfig");
  writeFileSync(globalConfig, "[user]\n\tname = Leak Guard Test\n\temail = test@example.invalid\n[init]\n\tdefaultBranch = main\n");
  fakeEnvValue = fake(`fake_${alnum(28)}`);
  const envFile = path.join(dir, "fake.env");
  writeFileSync(envFile, `FAKE_API_KEY=${fakeEnvValue}\nNEXT_PUBLIC_SITE=https://example.invalid\n`);
  // Only the fake env file is a value source, and neither the user's git config nor a hook manager takes part.
  env = { ...process.env, SECRET_SCAN_ENV: envFile, GIT_CONFIG_GLOBAL: globalConfig, GIT_CONFIG_NOSYSTEM: "1" };
  delete env.SECRET_SCAN_XCCONFIG;
  delete env.BASH_ENV;
});
after(() => rmSync(dir, { recursive: true, force: true }));

test("every secret pattern and heuristic fires, and no value is printed", () => {
  const repo = newRepo("patterns");
  // Each random part is registered with fake(): no output may contain it.
  const cases = [
    ["Alchemy keyed RPC URL", `https://monad-mainnet.g.alchemy.com/v2/${fake(alnum(32))}`],
    ["Infura keyed RPC URL", `https://mainnet.infura.io/v3/${fake(hex(16))}`],
    ["QuickNode keyed RPC URL", `https://x.monad-mainnet.quiknode.pro/${fake(hex(20))}/`],
    ["Pimlico keyed URL (apikey=)", `https://api.pimlico.io/v2/143/rpc?apikey=${fake(alnum(24))}`],
    ["Pimlico API key (pim_)", `const bundler = "pim_${fake(alnum(22))}";`],
    ["API key in a URL query (apikey= / api_key=)", `https://api.example.invalid/v1?api_key=${fake(alnum(24))}`],
    ["PEM private key", `-----BEGIN EC ${"PRIVATE"} KEY-----${fake(alnum(16))}`],
    ["age secret key", `AGE-SECRET-${"KEY"}-1${fake(upper(58))}`],
    ["private key assignment (KEY=0x + 64 hex)", `DEPLOYER_KEY=0x${fake(hex(32))}`],
    ["private key assignment (private_key / --private-key + 64 hex)", `cast send --private-key ${fake(hex(32))} 0x1`],
    ["Supabase secret key (sb_secret_)", `sb_${"secret"}_${fake(alnum(32))}`],
    ["Supabase access token (sbp_)", `token: sbp_${fake(hex(20))}`],
    ["Supabase service_role JWT", fake(jwt({ iss: "supabase", ref: alnum(20).toLowerCase(), role: "service_role" }))],
    ["JSON Web Token", `Authorization: Bearer ${fake(jwt({ sub: alnum(12), iat: 1790000000 }))}`],
    ["Privy app secret (privy_app_secret_)", `privy_app_${"secret"}_${fake(alnum(40))}`],
    ["Privy authorization key (wallet-auth:)", `wallet-auth:${fake(randomBytes(48).toString("base64"))}`],
    ["GitHub token (ghp_/gho_/ghs_/ghu_/ghr_)", `gh${"p"}_${fake(alnum(36))}`],
    ["GitHub fine-grained token (github_pat_)", `github_${"pat"}_${fake(alnum(22))}_${fake(alnum(59))}`],
    ["AWS access key id (AKIA/ASIA)", `aws_access_key_id = AK${"IA"}${fake(upper(16))}`],
    ["AWS secret access key assignment", `aws_secret_access_key = ${fake(alnum(40))}`],
    ["Slack token (xox*)", `xox${"b"}-${digits(12)}-${fake(alnum(24))}`],
    ["Slack webhook URL", `https://hooks.slack.com/services/T${upper(8)}/B${upper(8)}/${fake(alnum(24))}`],
    ["Discord webhook URL", `https://discord.com/api/webhooks/${digits(18)}/${fake(alnum(68))}`],
    ["Stripe live key (sk_live_/rk_live_)", `sk_${"live"}_${fake(alnum(24))}`],
    ["Anthropic API key (sk-ant-)", `sk-${"ant"}-api03-${fake(alnum(80))}`],
    ["OpenAI API key (sk-proj-/sk-svcacct-/sk-admin-)", `sk-${"proj"}-${fake(alnum(48))}`],
    ["OpenAI-style API key (sk-…)", `key: sk-${fake(alnum(48))}`],
    ["Google API key (AIza)", `AI${"za"}${fake(alnum(35))}`],
    ["npm token (npm_)", `//registry.npmjs.org/:_authToken=npm_${fake(alnum(36))}`],
    ["Telegram bot token", `bot ${digits(10)}:AA${fake(alnum(33))}`],
    ["known secret variable with a literal value", `AURORA_API_KEY=${fake(alnum(32))}`],
    ["BIP-39 seed phrase (12+ wordlist words)", `const phrase = "${fake(seedPhrase(12))}";`],
    ["32-byte hex key passed to a key or wallet constructor", `const account = privateKeyToAccount("0x${fake(hex(32))}");`],
    ["FAKE_API_KEY (fake.env)", `const k = "${fakeEnvValue}";`],
  ];
  const lines = cases.map(([, text]) => text);
  const arrayStart = lines.length + 1;
  const arrayKey = fake(hex(32));
  write(repo, "src/leaky.ts", `${lines.join("\n")}\nconst signerKeys = [\n  "0x${arrayKey}",\n];\n`);
  git(repo, "add", "src/leaky.ts");
  const { status, out } = scan(repo, "--staged");
  assert.equal(status, 1, out);
  cases.forEach(([name], i) => assert.ok(out.includes(`src/leaky.ts:${i + 1}: ${name}`), `${name} did not fire:\n${out}`));
  assert.ok(out.includes(`src/leaky.ts:${arrayStart + 1}: 32-byte hex key in a key-named array`), out);

  // --all reads the same file from the working tree, --path from the directory.
  git(repo, "commit", "-q", "--no-verify", "-m", "fake secrets");
  for (const args of [["--all"], ["--path", "src"]]) {
    const r = scan(repo, ...args);
    assert.equal(r.status, 1, r.out);
    for (const [name] of cases) assert.ok(r.out.includes(name), `${args[0]}: ${name} missing:\n${r.out}`);
  }
});

test("public identifiers, test vectors and placeholders do not fire", () => {
  const repo = newRepo("public");
  const [anvil0] = publicKeys;
  const forkKey = publicKeys[publicKeys.length - 1];
  const anonKey = jwt({ iss: "supabase", ref: alnum(20).toLowerCase(), role: "anon", iat: 1700000000, exp: 2000000000 });
  const text = [
    `export const SUPABASE_ANON_KEY = "${anonKey}";`,
    `const publishable = "sb_publishable_${alnum(31)}";`,
    `const factory = "0x${hex(20)}"; const DEPLOYER = "0x${hex(20)}";`,
    `const anvil = privateKeyToAccount("0x${anvil0}");`,
    `const keys = ["0x${anvil0}", "0x${forkKey}"];`,
    `const topics = ["0x${hex(32)}", "0x${hex(32)}"];`,
    `const txHash = "0x${hex(32)}";`,
    "const mnemonic = \"test test test test test test test test test test test junk\";",
    "const vector = \"abandon amount liar amount expire adjust cage candy arch gather drum bullet absurd math era live bid rhythm alien crouch range attend journey unaware\";",
    `const list = "${words.slice(100, 140).join(" ")}";`,
    `const example = "AKIA${"IOSFODNN7EXAMPLE"}";`,
    "AURORA_API_KEY=<your aurora key>",
    "AURORA_API_KEY=${AURORA_API_KEY}",
    'const AURORA_API_KEY = Deno.env.get("AURORA_API_KEY");',
    "Recovery words are shown once: write them down and keep them offline, never in a screenshot.",
  ].join("\n");
  write(repo, "app/public.ts", `${text}\n`);
  // Test vectors under a test directory: derived keys in key-named arrays are expected there.
  write(repo, "tests/vectors.test.mjs", `const attemptKeys = [\n  "0x${hex(32)}",\n];\nconst account = privateKeyToAccount("0x${hex(32)}");\n`);
  write(repo, ".env.example", "PINATA_JWT=\nAURORA_API_KEY=\n");
  git(repo, "add", "app/public.ts", "tests/vectors.test.mjs", ".env.example");
  const staged = scan(repo, "--staged");
  assert.equal(staged.status, 0, staged.out);
  assert.equal(paths(repo, "--staged").status, 0);
  git(repo, "commit", "-q", "--no-verify", "-m", "public values");
  const all = scan(repo, "--all");
  assert.equal(all.status, 0, all.out);
});

test("forbidden-paths: secrets and internal documents are denied, developer files are not", () => {
  const cfg = path.join(root, ".leakguard");
  const denied = [".env", "app/.env.production", "prod.env", ".dev.vars", "ios/DyorHQ/Config/Secrets.xcconfig",
    "AuthKey_ABC.p8", "certs/dist.p12", "key.pem", "id_ed25519", "build/DyorHQ-1.0-14.xcarchive/Info.plist", "DyorHQ.ipa",
    ".claude/settings.local.json", "ios/.claude/settings.local.json", "HANDOFF.md", "notes/owner-RUNBOOK.md",
    "docs/security-audit-2026-09-26/REPORT.md", "Docs/Security-Audit-2027/checklist.md", "docs/moments-spec.md",
    "ios/docs/mera/MERA-PLAN.md", "reviews/moments-security-review.md", "contracts/deployments/relaunch.log",
    "contracts/broadcast/Deploy.s.sol/143/run-latest.json", "contracts/cache/Deploy.s.sol/143/run-latest.json",
    "notes/relaunch-2026-10-01.md", "decisions.md", "CLAUDE.local.md"];
  const allowed = [".env.example", "ios/DyorHQ/Config/Secrets.example.xcconfig", "docs/README.md", "docs/app-wiring.md",
    "docs/swap-spec.md", "contracts/test/audit/Z_LiveDeployment.t.sol", "contracts/script/relaunch/relaunch-new-wallets.sh",
    "contracts/deployments/143.json", ".claude/settings.json", ".claude/launch.json", "CLAUDE.md",
    "supabase/migrations/23_default_privileges_least_privilege.sql", "public/brand/dyorhq-brand-guide.md",
    "tests/web-security.test.mjs", "contracts/keepers/lib/report.mjs", "ios/README.md"];
  const r = run("/bin/bash", [path.join(root, "scripts/dev/forbidden-paths.sh"), "--config", cfg, "--check", ...denied, ...allowed], dir);
  assert.equal(r.status, 1);
  for (const p of denied) assert.ok(r.out.includes(`${p}: forbidden path`), `${p} was not denied:\n${r.out}`);
  for (const p of allowed) assert.ok(!r.out.includes(`${p}: forbidden path`), `${p} was denied:\n${r.out}`);
  const clean = run("/bin/bash", [path.join(root, "scripts/dev/forbidden-paths.sh"), "--config", cfg, "--check", ...allowed], dir);
  assert.equal(clean.status, 0, clean.out);
});

test("the hooks block forbidden paths and secrets in commits and pushes; a clean commit passes", () => {
  const repo = newRepo("hooks");
  const inst = run("/bin/bash", [path.join(repo, "scripts/dev/install-hooks.sh")], repo);
  assert.equal(inst.status, 0, inst.out);
  assert.equal(git(repo, "config", "--get", "core.hooksPath").out.trim(), ".githooks");
  assert.equal(run("/bin/bash", [path.join(repo, "scripts/dev/install-hooks.sh"), "--check"], repo).status, 0);

  // A forbidden path.
  write(repo, "HANDOFF.md", "# where things stand\n");
  git(repo, "add", "HANDOFF.md");
  let c = git(repo, "commit", "-m", "handoff");
  assert.notEqual(c.status, 0, "a HANDOFF.md commit went through");
  assert.match(c.out, /HANDOFF\.md: forbidden path/);
  git(repo, "rm", "-q", "--cached", "HANDOFF.md");

  // An env file with a fake secret: both checkers refuse it.
  write(repo, ".env", `SERVICE_TOKEN=${fake(alnum(40))}\n`);
  git(repo, "add", "-f", ".env");
  c = git(repo, "commit", "-m", "env");
  assert.notEqual(c.status, 0, "a .env commit went through");
  assert.match(c.out, /\.env: forbidden path/);
  assert.match(c.out, /\.env: env file must not be committed/);
  git(repo, "rm", "-q", "--cached", ".env");

  // A fake key in code.
  write(repo, "src/deploy.ts", `export const DEPLOYER_KEY = "0x${fake(hex(32))}";\n`);
  git(repo, "add", "src/deploy.ts");
  c = git(repo, "commit", "-m", "key");
  assert.notEqual(c.status, 0, "a commit with a fake key went through");
  assert.match(c.out, /src\/deploy\.ts:1: private key assignment/);
  git(repo, "rm", "-q", "--cached", "src/deploy.ts");

  // A clean commit.
  write(repo, "src/ok.ts", "export const ok = 1;\n");
  git(repo, "add", "src/ok.ts");
  c = git(repo, "commit", "-m", "clean");
  assert.equal(c.status, 0, c.out);

  // --no-verify skips the commit hooks, so the push is refused instead, and history scans find it.
  const remote = path.join(dir, "remote.git");
  git(dir, "init", "-q", "--bare", remote);
  git(repo, "remote", "add", "origin", remote);
  write(repo, "src/deploy.ts", `export const DEPLOYER_KEY = "0x${fake(hex(32))}";\n`);
  write(repo, "docs/owner-runbook.md", "# steps\n");
  git(repo, "add", "src/deploy.ts", "docs/owner-runbook.md");
  assert.equal(git(repo, "commit", "-q", "--no-verify", "-m", "sneaky").status, 0);
  const p = git(repo, "push", "-q", "origin", "main");
  assert.notEqual(p.status, 0, "a push with a fake key went through");
  assert.match(p.out, /src\/deploy\.ts:1: private key assignment/);
  assert.match(p.out, /docs\/owner-runbook\.md: forbidden path/);
  assert.equal(git(remote, "rev-parse", "-q", "--verify", "refs/heads/main").status, 1, "the remote received the branch");
  const h = scan(repo, "--history", "--all");
  assert.equal(h.status, 1);
  assert.match(h.out, /[0-9a-f]+:src\/deploy\.ts:1: private key assignment/);
  const hp = paths(repo, "--history", "--all");
  assert.equal(hp.status, 1);
  assert.match(hp.out, /[0-9a-f]+:docs\/owner-runbook\.md: forbidden path/);
});

test("worktrees on branches without .githooks keep their secret scan (dispatchers)", () => {
  const repo = newRepo("dispatch");
  // A branch from before the guard existed, checked out in a second worktree.
  git(repo, "checkout", "-q", "--orphan", "old");
  git(repo, "rm", "-rq", "--cached", ".");
  for (const f of GUARD) rmSync(path.join(repo, f), { force: true });
  write(repo, "README.md", "old branch\n");
  git(repo, "add", "README.md");
  git(repo, "commit", "-q", "-m", "old");
  git(repo, "checkout", "-q", "main");
  const old = path.join(dir, "dispatch-old");
  assert.equal(git(repo, "worktree", "add", "-q", old, "old").status, 0);

  // Through the old installer entry point, which now delegates to install-hooks.sh.
  const inst = scan(repo, "--install-hook");
  assert.equal(inst.status, 0, inst.out);
  assert.match(inst.out, /dispatchers/);
  assert.equal(git(repo, "config", "--get", "core.hooksPath").status, 1, "core.hooksPath would disable the old worktree's hooks");
  assert.equal(run("/bin/bash", [path.join(repo, "scripts/dev/install-hooks.sh"), "--check"], repo).status, 0);

  write(old, "keys.txt", `KEY=0x${fake(hex(32))}\n`);
  git(old, "add", "keys.txt");
  let c = git(old, "commit", "-m", "old branch key");
  assert.notEqual(c.status, 0, "the old worktree committed a fake key");
  assert.match(c.out, /keys\.txt:1: private key assignment/);
  git(old, "rm", "-q", "--cached", "keys.txt");
  write(old, "notes.txt", "fine\n");
  git(old, "add", "notes.txt");
  assert.equal(git(old, "commit", "-q", "-m", "old branch clean").status, 0);

  write(repo, "docs/security-review-q3.md", "# review\n");
  git(repo, "add", "docs/security-review-q3.md");
  c = git(repo, "commit", "-m", "review");
  assert.notEqual(c.status, 0, "the guarded worktree committed an internal document");
  assert.match(c.out, /docs\/security-review-q3\.md: forbidden path/);
});
