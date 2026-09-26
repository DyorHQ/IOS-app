// Applies every migration to a throwaway in-memory Postgres (PGlite, with supabase_stub.sql standing in for the
// platform), re-applies the security-audit migrations to prove they are idempotent, and checks their grants, RLS and
// rate limits from each API role's point of view. Nothing here touches a real project.
//
//   deno test -A --no-config --node-modules-dir=none supabase/tests/migrations_test.ts   (about 2 minutes)
import { PGlite, type Transaction } from "npm:@electric-sql/pglite@0.5.8";
import { pgcrypto } from "npm:@electric-sql/pglite@0.5.8/contrib/pgcrypto";
import { citext } from "npm:@electric-sql/pglite@0.5.8/contrib/citext";
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";

const MIGRATIONS = new URL("../migrations/", import.meta.url);
const DEFERRED = new URL("../migrations-deferred/", import.meta.url);
const STUB = new URL("./supabase_stub.sql", import.meta.url);
// The migrations written for the 2026-09-26 audit, which must be safe to re-run.
const REAPPLY = ["24_", "25_", "26_", "27_", "28_", "29_"];

const A = "0x" + "a".repeat(40);
const B = "0x" + "b".repeat(40);
const hex64 = (n: number) => n.toString(16).padStart(64, "0");
const uuid = (n: number) => `00000000-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;

async function migrationFiles(): Promise<string[]> {
  const names: string[] = [];
  for await (const entry of Deno.readDir(MIGRATIONS)) if (entry.isFile && entry.name.endsWith(".sql")) names.push(entry.name);
  return names.sort();
}

type Role = "anon" | "authenticated" | "service_role";

// Runs `sql` as `role` (with a wallet_address claim when `wallet` is given) in its own transaction, as PostgREST would.
async function as<T = Record<string, unknown>>(db: PGlite, role: Role, wallet: string | null, sql: string, params: unknown[] = []): Promise<T[]> {
  return await db.transaction(async (tx: Transaction) => {
    const claims = wallet ? { role, wallet_address: wallet } : { role };
    await tx.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify(claims)]);
    await tx.exec(`set local role ${role}`);
    return (await tx.query<T>(sql, params)).rows;
  });
}

async function one<T = Record<string, unknown>>(db: PGlite, sql: string, params: unknown[] = []): Promise<T> {
  return (await db.query<T>(sql, params)).rows[0];
}

Deno.test("migrations: apply, re-apply, and behave per role", async (t) => {
  const db = await PGlite.create({ extensions: { pgcrypto, citext } });
  await db.exec(await Deno.readTextFile(STUB));
  const files = await migrationFiles();

  await t.step("01–29 apply in order on a fresh database", async () => {
    assert(files.includes("29_waitlist.sql"), "expected migrations through 29");
    for (const name of files) {
      try { await db.exec(await Deno.readTextFile(new URL(name, MIGRATIONS))); }
      catch (err) { throw new Error(`${name}: ${(err as Error).message}`); }
    }
  });

  await t.step("24–29 re-apply without error or change", async () => {
    const before = await one<{ n: number }>(db, "select count(*)::int as n from pg_policies");
    for (const name of files.filter((f) => REAPPLY.some((p) => f.startsWith(p)))) {
      try { await db.exec(await Deno.readTextFile(new URL(name, MIGRATIONS))); }
      catch (err) { throw new Error(`re-applying ${name}: ${(err as Error).message}`); }
    }
    assertEquals((await one<{ n: number }>(db, "select count(*)::int as n from pg_policies")).n, before.n);
    assertEquals((await one<{ n: number }>(db, "select count(*)::int as n from public.edge_rate_salt")).n, 1);
    assertEquals((await one<{ n: number }>(db, "select count(*)::int as n from public.app_config")).n, 1);
  });

  await db.exec(`insert into public.profiles (wallet) values ('${A}'), ('${B}')`);

  await t.step("SB-4: only anonymous requests count toward and are held to the network limit", async () => {
    const pepper = (e: string, ip: string, verified: boolean) =>
      as<{ r: { p?: string; limit?: string } }>(db, "service_role", null,
        "select public.email_pepper_hmac($1, $2, $3, $4) as r", [e, hex64(7), ip, verified]).then((rows) => rows[0].r);
    // 60 anonymous requests from one network (each for a different email, so no per-email limit fires) spend it…
    for (let i = 0; i < 60; i++) assert((await pepper(hex64(1000 + i), "198.51.100.7", false)).p);
    assertEquals((await pepper(hex64(2000), "198.51.100.7", false)).limit, "network");
    // …but a verified request from that network is not held to it,
    assert((await pepper(hex64(2001), "198.51.100.7", true)).p, "a verified request must pass a spent network limit");
    // and verified requests never spend it: 70 of them leave an anonymous request from their network unaffected.
    for (let i = 0; i < 70; i++) assert((await pepper(hex64(3000 + i), "198.51.100.8", true)).p);
    assert((await pepper(hex64(4000), "198.51.100.8", false)).p, "verified requests must not count toward the network limit");
    // The per-email budgets are unchanged: an 11th anonymous request for one email inside 15 minutes is refused.
    for (let i = 0; i < 10; i++) assert((await pepper(hex64(5000), `203.0.113.${i}`, false)).p);
    assertEquals((await pepper(hex64(5000), "203.0.113.99", false)).limit, "email");
    for (const role of ["anon", "authenticated"] as const) {
      await assertRejects(() => as(db, role, A, "select public.email_pepper_hmac($1, $2, null, false)", [hex64(1), hex64(2)]), Error, "permission denied");
    }
  });

  await t.step("SB-5 A: the app can upsert with on_conflict=wallet,id; a squatted id still blocks until B", async () => {
    const upsert = (wallet: string, id: string, title: string) => as(db, "authenticated", wallet,
      `insert into public.activity (id, wallet, kind, title) values ($1, $2, 'swap', $3)
       on conflict (wallet, id) do update set title = excluded.title`, [id, wallet, title]);
    await upsert(A, uuid(1), "first");
    await upsert(A, uuid(1), "second");
    assertEquals((await one<{ title: string }>(db, `select title from public.activity where id = '${uuid(1)}'`)).title, "second");
    await upsert(B, uuid(2), "squat"); // B takes the id A's next transaction would map to
    await assertRejects(() => upsert(A, uuid(2), "victim"), Error, "duplicate key");
    // on_conflict=id (the builds before the fix) keeps working until B.
    await as(db, "authenticated", A, `insert into public.activity (id, wallet, kind, title) values ($1, $2, 'swap', 'x')
      on conflict (id) do update set title = excluded.title`, [uuid(1), A]);
  });

  await t.step("SB-5 B (deferred): refuses until min_build is raised, then scopes ids to the wallet", async () => {
    const template = await Deno.readTextFile(new URL("30_activity_primary_key_wallet_id.sql", DEFERRED));
    await assertRejects(() => db.exec(template), Error, "set v_required_build");
    const armed = template.replace("v_required_build constant int := 0;", "v_required_build constant int := 15;");
    assert(armed !== template, "the build placeholder moved");
    await assertRejects(() => db.exec(armed), Error, "below build 15");
    await db.exec(`update public.app_config set value = jsonb_set(value, '{min_build}', '15') where key = 'ios'`);
    await db.exec(armed);
    await db.exec(armed); // idempotent
    const keys = await db.query<{ def: string }>(`select pg_get_constraintdef(oid) as def from pg_constraint
      where conrelid = 'public.activity'::regclass and contype in ('p', 'u') order by 1`);
    assertEquals(keys.rows.map((r) => r.def), ["PRIMARY KEY (wallet, id)"]);
    await as(db, "authenticated", A, `insert into public.activity (id, wallet, kind, title) values ($1, $2, 'swap', 'victim')
      on conflict (wallet, id) do update set title = excluded.title`, [uuid(2), A]);
    assertEquals((await one<{ n: number }>(db, `select count(*)::int as n from public.activity where id = '${uuid(2)}'`)).n, 2);
    await assertRejects(() => as(db, "authenticated", A, `insert into public.activity (id, wallet, kind, title)
      values ($1, $2, 'swap', 'x') on conflict (id) do nothing`, [uuid(3), A]), Error, "no unique or exclusion constraint");
    await db.exec(`update public.app_config set value = jsonb_set(value, '{min_build}', '0') where key = 'ios'`);
  });

  await t.step("SB-6 / OH-6: launch-media is write-once, names are pinned, uploads are capped per wallet", async () => {
    const put = (wallet: string, bucket: string, name: string, upsert = false) => as(db, "authenticated", wallet,
      `insert into storage.objects (bucket_id, name, metadata) values ($1, $2, '{"size": 1000}')` +
      (upsert ? " on conflict (bucket_id, name) do update set metadata = excluded.metadata" : ""), [bucket, name]);
    const moment = `${A}/moment-${hex64(9)}.jpg`;
    await put(A, "launch-media", moment, true); // a first upload with x-upsert: true needs no UPDATE policy
    await assertRejects(() => put(A, "launch-media", moment, true), Error, "row-level security"); // no overwrite
    await assertRejects(() => put(A, "launch-media", moment), Error, "duplicate key"); // x-upsert: false → 409
    const updated = await as(db, "authenticated", A,
      "update storage.objects set metadata = '{\"size\": 1}' where bucket_id = 'launch-media' and name = $1 returning id", [moment]);
    assertEquals(updated.length, 0, "an UPDATE must not reach a launch-media object");
    await put(A, "launch-media", `${A}/${uuid(4)}.jpg`);
    await put(A, "launch-media", `${A}/moment-${uuid(5)}.mov`);
    await put(A, "launch-media", `${A}/moment-${hex64(10)}.mp4`);
    for (const bad of [`${A}/evil.html`, `${A}/moment-${hex64(11)}.gif`, `${A}/x/${uuid(6)}.jpg`, `${A}/${uuid(7)}.png`]) {
      await assertRejects(() => put(A, "launch-media", bad), Error, "row-level security", bad);
    }
    await assertRejects(() => put(A, "launch-media", `${B}/${uuid(8)}.jpg`), Error, "row-level security");
    await assertRejects(() => as(db, "anon", null,
      `insert into storage.objects (bucket_id, name) values ('launch-media', $1)`, [`${A}/${uuid(9)}.jpg`]), Error, "row-level security");
    // Quota: 40 objects per wallet per 24 h (A has 4; objects older than a day do not count).
    await db.exec(`insert into storage.objects (bucket_id, name, metadata, created_at)
      select 'launch-media', '${A}/old-' || g || '.jpg', '{"size": 1000}', now() - interval '25 hours' from generate_series(1, 50) g`);
    for (let i = 0; i < 36; i++) await put(A, "launch-media", `${A}/${uuid(100 + i)}.jpg`);
    await assertRejects(() => put(A, "launch-media", `${A}/${uuid(200)}.jpg`), Error, "row-level security");
    await put(B, "launch-media", `${B}/${uuid(201)}.jpg`); // another wallet's quota is its own
    // …and 500 MB per wallet per 24 h.
    await db.exec(`insert into storage.objects (bucket_id, name, metadata)
      select 'launch-media', '${B}/big-' || g || '.mp4', '{"size": 104857600}' from generate_series(1, 4) g`);
    await put(B, "launch-media", `${B}/${uuid(202)}.jpg`); // 400 MB + 2 KB so far
    await db.exec(`insert into storage.objects (bucket_id, name, metadata) values ('launch-media', '${B}/big-5.mp4', '{"size": 104857600}')`);
    await assertRejects(() => put(B, "launch-media", `${B}/${uuid(203)}.jpg`), Error, "row-level security");
    // avatars: only <wallet>/avatar.jpg, which the owner may overwrite.
    await put(A, "avatars", `${A}/avatar.jpg`, true);
    await put(A, "avatars", `${A}/avatar.jpg`, true);
    await assertRejects(() => put(A, "avatars", `${A}/other.jpg`), Error, "row-level security");
    await assertRejects(() => put(A, "avatars", `${B}/avatar.jpg`), Error, "row-level security");
    const buckets = await db.query<{ id: string; file_size_limit: number; allowed_mime_types: string[] }>(
      "select id, file_size_limit, allowed_mime_types from storage.buckets order by id");
    assertEquals(buckets.rows.map((b) => [b.id, Number(b.file_size_limit), b.allowed_mime_types]), [
      ["avatars", 5242880, ["image/jpeg"]],
      ["launch-media", 52428800, ["image/jpeg", "video/mp4", "video/quicktime"]],
    ]);
    await assertRejects(() => as(db, "anon", null, "select public.storage_upload_allowed('launch-media')"), Error, "permission denied");
    // Takedown: a blocklisted wallet can upload to neither bucket, nor overwrite its avatar; nobody but the owner sees the list.
    const C = "0x" + "c".repeat(40);
    await db.exec(`insert into public.profiles (wallet) values ('${C}')`);
    await put(C, "avatars", `${C}/avatar.jpg`, true);
    await db.exec(`insert into public.upload_blocklist (wallet, reason) values ('${C}', 'test')`);
    await assertRejects(() => put(C, "launch-media", `${C}/${uuid(300)}.jpg`), Error, "row-level security");
    await assertRejects(() => put(C, "avatars", `${C}/avatar.jpg`, true), Error, "row-level security");
    for (const role of ["anon", "authenticated"] as const) {
      await assertRejects(() => as(db, role, C, "select count(*) from public.upload_blocklist"), Error, "permission denied");
    }
  });

  await t.step("SB-2 / OH-6 / LR-4: edge_rate_gate budgets per subject and per network, never storing an IP", async () => {
    const gate = (scope: string, subject: string | null, ip: string | null) =>
      as<{ r: { ok?: boolean; retryAfter?: number; limit?: string } }>(db, "service_role", null,
        "select public.edge_rate_gate($1, $2, $3) as r", [scope, subject, ip]).then((rows) => rows[0].r);
    for (let i = 0; i < 10; i++) assertEquals((await gate("pin-media", A, "192.0.2.1")).ok, true);
    const refused = await gate("pin-media", A, "192.0.2.1");
    assertEquals(refused.limit, "subject");
    assert(refused.retryAfter! > 800 && refused.retryAfter! <= 900, `retryAfter ${refused.retryAfter}`);
    // Refusals are not recorded, and scopes are separate budgets.
    assertEquals((await one<{ n: number }>(db, "select count(*)::int as n from public.edge_rate_events where scope = 'pin-media'")).n, 10);
    assertEquals((await gate("aurora", A, "192.0.2.1")).ok, true);
    // Network: 30 pin-media calls per 15 minutes, whichever wallets make them.
    for (let i = 0; i < 20; i++) assertEquals((await gate("pin-media", "0x" + i.toString(16).padStart(40, "c"), "192.0.2.1")).ok, true);
    assertEquals((await gate("pin-media", B, "192.0.2.1")).limit, "network");
    assertEquals((await gate("pin-media", B, "192.0.2.2")).ok, true);
    assertEquals((await gate("pin-media", B, null)).ok, true); // no network known: only the subject's limits apply
    // Waitlist: 5 per network per 15 minutes.
    for (let i = 0; i < 5; i++) assertEquals((await gate("waitlist", "all", "2001:db8:1:2::/64")).ok, true);
    assertEquals((await gate("waitlist", "all", "2001:db8:1:2::/64")).limit, "network");
    // Calls older than a window stop counting.
    await db.exec(`update public.edge_rate_events set created_at = now() - interval '16 minutes' where scope = 'waitlist'`);
    assertEquals((await gate("waitlist", "all", "2001:db8:1:2::/64")).ok, true);
    // No raw address is ever stored.
    const leaked = await one<{ n: number }>(db, `select count(*)::int as n from public.edge_rate_events
      where coalesce(net, '') like '%192.0.2%' or coalesce(net, '') like '%2001:db8%' or net !~ '^[0-9a-f]{64}$'`);
    assertEquals(leaked.n, 0);
    await assertRejects(() => gate("anything", A, null), Error, "unknown rate-limit scope");
    for (const role of ["anon", "authenticated"] as const) {
      await assertRejects(() => as(db, role, A, "select public.edge_rate_gate('aurora', null, null)"), Error, "permission denied");
    }
    for (const role of ["anon", "authenticated", "service_role"] as const) {
      await assertRejects(() => as(db, role, A, "select count(*) from public.edge_rate_events"), Error, "permission denied");
      await assertRejects(() => as(db, role, A, "select count(*) from public.edge_rate_salt"), Error, "permission denied");
    }
  });

  await t.step("GP-2: app_config is readable by anyone and writable by no API role", async () => {
    for (const role of ["anon", "authenticated"] as const) {
      const rows = await as<{ value: { min_build: number; message: string; url: string } }>(db, role, A,
        "select value from public.app_config where key = 'ios'");
      assertEquals(rows[0].value, { min_build: 0, message: "", url: "https://testflight.apple.com" });
      await assertRejects(() => as(db, role, A, "update public.app_config set value = '{}' where key = 'ios'"), Error, "permission denied");
      await assertRejects(() => as(db, role, A, "insert into public.app_config (key, value) values ('x', '{}')"), Error, "permission denied");
      await assertRejects(() => as(db, role, A, "delete from public.app_config"), Error, "permission denied");
    }
    // The ios row keeps the shape the app parses.
    for (const bad of [`'{"min_build": "15", "message": "", "url": "https://x.y"}'`, `'{"min_build": -1, "message": "", "url": "https://x.y"}'`,
                       `'{"min_build": 1.5, "message": "", "url": "https://x.y"}'`, `'{"min_build": 1, "message": "", "url": "http://x.y"}'`,
                       `'{"min_build": 1, "url": "https://x.y"}'`]) {
      await assertRejects(() => db.exec(`update public.app_config set value = ${bad} where key = 'ios'`), Error, "app_config_ios_shape");
    }
    await db.exec(`update public.app_config set value = '{"min_build": 16, "message": "Update DyorHQ", "url": "https://testflight.apple.com/join/x"}' where key = 'ios'`);
    await db.exec(`update public.app_config set value = '{"min_build": 0, "message": "", "url": "https://testflight.apple.com"}' where key = 'ios'`);
  });

  await t.step("LR-4: the waitlist is service-role only, and one row per address whatever its case", async () => {
    for (const role of ["anon", "authenticated"] as const) {
      await assertRejects(() => as(db, role, A, "select count(*) from public.waitlist"), Error, "permission denied");
      await assertRejects(() => as(db, role, A, "insert into public.waitlist (email) values ('x@example.com')"), Error, "permission denied");
    }
    await as(db, "service_role", null, "insert into public.waitlist (email, source) values ('Person@Example.com', 'site') on conflict (email) do nothing");
    await as(db, "service_role", null, "insert into public.waitlist (email, source) values ('person@example.COM', 'hero') on conflict (email) do nothing");
    assertEquals((await one<{ n: number }>(db, "select count(*)::int as n from public.waitlist")).n, 1);
  });

  await db.close();
});
