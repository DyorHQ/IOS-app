// Applies every migration to a throwaway in-memory Postgres (PGlite, with supabase_stub.sql standing in for the
// platform), re-applies the security-audit migrations to prove they are idempotent, and checks their grants, RLS,
// triggers and rate limits from each API role's point of view. Uploads are driven the way Storage drives them (a
// permission probe as the caller, rolled back, then the write as the service role). Nothing here touches a real project.
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
const wallet = (n: number) => "0x" + n.toString(16).padStart(40, "0");

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

// ── Storage, as it writes an upload (supabase/storage: src/storage/uploader.ts canUpload / completeUpload, and
// src/storage/database/pg.ts createObject / upsertObject; read 2026-09-27). Before reading any bytes, a permission
// probe as the caller — createObject, or upsertObject with x-upsert: true — with version '1' and the declared type and
// length, always rolled back. Once the bytes are stored, the completion as the service role: a taken path is refused
// unless upserting, then upsertObject with the real size and eTag and a new version. Storage answers SQLSTATE 42501
// as 403 and 23505 as 409 (src/storage/database/errors.ts).
const CREATE = `insert into storage.objects (bucket_id, name, owner_id, metadata, user_metadata, version)
  values ($1, $2, $3, $4, '{}', $5)`;
const UPSERT = CREATE + `
  on conflict (bucket_id, name collate "C") where archived_at is null
  do update set metadata = excluded.metadata, user_metadata = excluded.user_metadata, version = excluded.version,
                owner_id = excluded.owner_id`;

type Upload = { upsert?: boolean; size?: number; etag?: string; mime?: string; role?: Role };
class Rollback extends Error {}

function storageStatus(err: unknown): number {
  const code = (err as { code?: unknown } | null)?.code;
  if (code === "42501") return 403;
  if (code === "23505") return 409;
  throw err;
}

async function probe(db: PGlite, who: string, bucket: string, name: string, u: Upload = {}): Promise<number> {
  const role = u.role ?? "authenticated";
  try {
    await db.transaction(async (tx: Transaction) => {
      await tx.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify({ role, wallet_address: who })]);
      await tx.exec(`set local role ${role}`);
      await tx.query(u.upsert ? UPSERT : CREATE,
        [bucket, name, who, JSON.stringify({ mimetype: u.mime ?? "image/jpeg", contentLength: u.size ?? 1000 }), "1"]);
      throw new Rollback();
    });
  } catch (err) {
    return err instanceof Rollback ? 200 : storageStatus(err);
  }
  return 200;
}

async function complete(db: PGlite, who: string, bucket: string, name: string, u: Upload = {}): Promise<number> {
  try {
    await db.transaction(async (tx: Transaction) => {
      await tx.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify({ role: "service_role" })]);
      await tx.exec("set local role service_role");
      const taken = await tx.query("select version from storage.objects where bucket_id = $1 and name = $2 and archived_at is null for update", [bucket, name]);
      if (!u.upsert && taken.rows.length > 0) throw Object.assign(new Error("The resource already exists"), { code: "23505" });
      const size = u.size ?? 1000;
      await tx.query(UPSERT, [bucket, name, who,
        JSON.stringify({ mimetype: u.mime ?? "image/jpeg", size, contentLength: size, eTag: u.etag ?? `"${name}"` }), crypto.randomUUID()]);
    });
    return 200;
  } catch (err) {
    return storageStatus(err);
  }
}

async function upload(db: PGlite, who: string, bucket: string, name: string, u: Upload = {}): Promise<number> {
  const probed = await probe(db, who, bucket, name, u);
  return probed === 200 ? await complete(db, who, bucket, name, u) : probed;
}

const stored = (db: PGlite, name: string) =>
  one<{ etag: string; size: number; n: number }>(db,
    `select metadata->>'eTag' as etag, (metadata->>'size')::int as size, count(*) over ()::int as n
       from storage.objects where bucket_id = 'launch-media' and name = $1`, [name]);

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
    const count = async () => ({
      policies: (await one<{ n: number }>(db, "select count(*)::int as n from pg_policies")).n,
      triggers: (await one<{ n: number }>(db, "select count(*)::int as n from pg_trigger where tgrelid = 'storage.objects'::regclass and not tgisinternal")).n,
    });
    const before = await count();
    for (const name of files.filter((f) => REAPPLY.some((p) => f.startsWith(p)))) {
      try { await db.exec(await Deno.readTextFile(new URL(name, MIGRATIONS))); }
      catch (err) { throw new Error(`re-applying ${name}: ${(err as Error).message}`); }
    }
    assertEquals(await count(), before);
    assertEquals(before.triggers, 4); // Storage's two, and 26's two
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

  await t.step("SB-6: launch-media is write-once at the database, whatever the concurrency", async () => {
    const lm = "launch-media";
    const moment = `${A}/moment-${hex64(9)}.jpg`;
    // A first upload with x-upsert: true (what every build sends) needs no UPDATE policy.
    assertEquals(await upload(db, A, lm, moment, { upsert: true, etag: '"e1"' }), 200);
    // INTERIM: the same bytes again under a content-addressed name (a retry with the same media) still succeed…
    assertEquals(await upload(db, A, lm, moment, { upsert: true, etag: '"e1"' }), 200);
    // …but different bytes are refused when Storage writes them, and the stored object is untouched.
    assertEquals(await upload(db, A, lm, moment, { upsert: true, etag: '"e2"' }), 409);
    assertEquals(await upload(db, A, lm, moment, { upsert: true, etag: '"e1"', size: 999 }), 409);
    assertEquals(await upload(db, A, lm, moment, { upsert: true, etag: '"e1"', mime: "video/mp4" }), 409);
    assertEquals(await stored(db, moment), { etag: '"e1"', size: 1000, n: 1 });
    // x-upsert: false on a taken path is 409 at the probe (the future app: "already uploaded").
    assertEquals(await probe(db, A, lm, moment), 409);
    // The race the probe cannot see: two uploads to one new path both pass it; the later completion is refused.
    const raced = `${A}/moment-${hex64(12)}.mp4`;
    assertEquals(await probe(db, A, lm, raced, { upsert: true, mime: "video/mp4" }), 200);
    assertEquals(await probe(db, A, lm, raced, { upsert: true, mime: "video/mp4" }), 200);
    assertEquals(await complete(db, A, lm, raced, { upsert: true, mime: "video/mp4", etag: '"benign"' }), 200);
    assertEquals(await complete(db, A, lm, raced, { upsert: true, mime: "video/mp4", etag: '"swap"' }), 409);
    assertEquals((await stored(db, raced)).etag, '"benign"');
    // Launch logos (<uuid>.jpg) and pre-hash Moment names are write-once outright: refused at the probe (no UPDATE
    // policy), and even the same bytes are refused when written.
    const logo = `${A}/${uuid(4)}.jpg`;
    assertEquals(await upload(db, A, lm, logo, { upsert: true, etag: '"logo"' }), 200);
    assertEquals(await upload(db, A, lm, logo, { upsert: true, etag: '"logo"' }), 403);
    assertEquals(await complete(db, A, lm, logo, { upsert: true, etag: '"logo"' }), 409);
    assertEquals(await complete(db, A, lm, logo, { upsert: true, etag: '"other"' }), 409);
    const oldMoment = `${A}/moment-${uuid(5)}.mov`;
    assertEquals(await upload(db, A, lm, oldMoment, { mime: "video/quicktime" }), 200);
    assertEquals(await complete(db, A, lm, oldMoment, { upsert: true, mime: "video/quicktime", etag: '"x"' }), 409);
    // No role may move or rename a launch-media object, into or out of the bucket; takedowns (DELETE) still work.
    await assertRejects(() => as(db, "service_role", null,
      "update storage.objects set name = $1 where bucket_id = 'launch-media' and name = $2", [`${A}/moment-${hex64(99)}.jpg`, moment]), Error, "moved or renamed");
    await assertRejects(() => as(db, "service_role", null,
      "update storage.objects set bucket_id = 'avatars' where bucket_id = 'launch-media' and name = $1", [logo]), Error, "moved or renamed");
    await db.exec(`insert into storage.objects (bucket_id, name, metadata, version) values ('avatars', '${A}/moved.jpg', '{"size": 1}', 'v')`);
    await assertRejects(() => db.exec(`update storage.objects set bucket_id = 'launch-media' where name = '${A}/moved.jpg'`), Error, "moved or renamed");
    await db.exec(`update storage.objects set updated_at = now(), owner_id = 'x' where name = '${logo}'`); // no content change
    await db.exec(`begin; set local storage.allow_delete_query = 'true'; delete from storage.objects where name in ('${logo}', '${A}/moved.jpg'); commit;`);
    assertEquals((await one<{ n: number }>(db, `select count(*)::int as n from storage.objects where name = '${logo}'`)).n, 0);
    // Other buckets are not affected: an avatar can be replaced by its owner.
    assertEquals(await upload(db, A, "avatars", `${A}/avatar.jpg`, { upsert: true, etag: '"a1"' }), 200);
    assertEquals(await upload(db, A, "avatars", `${A}/avatar.jpg`, { upsert: true, etag: '"a2"' }), 200);
  });

  await t.step("SB-6 / OH-6: upload names are pinned; blocklist and budgets hold when Storage writes, not only at the probe", async () => {
    const lm = "launch-media";
    for (const bad of [`${A}/evil.html`, `${A}/moment-${hex64(11)}.gif`, `${A}/x/${uuid(6)}.jpg`, `${A}/${uuid(7)}.png`]) {
      assertEquals(await probe(db, A, lm, bad), 403, bad);
    }
    assertEquals(await probe(db, A, lm, `${B}/${uuid(8)}.jpg`), 403); // another wallet's folder
    assertEquals(await probe(db, A, lm, `${A}/${uuid(9)}.jpg`, { role: "anon" }), 403);
    assertEquals(await probe(db, A, "avatars", `${A}/other.jpg`, { upsert: true }), 403);
    assertEquals(await probe(db, A, "avatars", `${B}/avatar.jpg`, { upsert: true }), 403);

    // Per wallet: 40 objects in 24 hours (older ones do not count). Probes see only committed rows, so they all pass;
    // the writes stop at 40, however many uploads were started together.
    const D = wallet(0xd);
    await db.exec(`insert into storage.objects (bucket_id, name, metadata, version, created_at)
      select 'launch-media', '${D}/old-' || g || '.jpg', '{"size": 1000}', 'v' || g, now() - interval '25 hours' from generate_series(1, 50) g`);
    for (let i = 0; i < 37; i++) assertEquals(await upload(db, D, lm, `${D}/${uuid(100 + i)}.jpg`), 200);
    const late = [0, 1, 2, 3, 4].map((i) => `${D}/${uuid(200 + i)}.jpg`);
    for (const name of late) assertEquals(await probe(db, D, lm, name), 200);
    assertEquals(await Promise.all(late.map((name) => complete(db, D, lm, name))), [200, 200, 200, 403, 403]);
    assertEquals(await probe(db, D, lm, `${D}/${uuid(210)}.jpg`), 403); // and now the probe refuses too
    assertEquals(await upload(db, B, lm, `${B}/${uuid(211)}.jpg`), 200); // another wallet's budget is its own
    // Per wallet: 500 MiB in 24 hours, counting the upload being written.
    const E = wallet(0xe);
    await db.exec(`insert into storage.objects (bucket_id, name, metadata, version)
      select 'launch-media', '${E}/big-' || g || '.mp4', '{"size": 104857600}', 'v' || g from generate_series(1, 4) g`); // 400 MiB
    assertEquals(await probe(db, E, lm, `${E}/moment-${hex64(20)}.mp4`, { mime: "video/mp4", size: 52428800 }), 200);
    assertEquals(await complete(db, E, lm, `${E}/moment-${hex64(20)}.mp4`, { mime: "video/mp4", size: 52428800 }), 200); // 450 MiB
    assertEquals(await probe(db, E, lm, `${E}/moment-${hex64(21)}.mp4`, { mime: "video/mp4", size: 52428800 }), 200); // declared: exactly 500
    assertEquals(await complete(db, E, lm, `${E}/moment-${hex64(21)}.mp4`, { mime: "video/mp4", size: 52428801 }), 403); // actual: over

    // Takedown: a blocklisted wallet can upload to neither bucket — also an upload that passed the probe first — nor
    // replace its avatar; nobody but the owner sees the list.
    const C = "0x" + "c".repeat(40);
    await db.exec(`insert into public.profiles (wallet) values ('${C}')`);
    assertEquals(await upload(db, C, "avatars", `${C}/avatar.jpg`, { upsert: true }), 200);
    assertEquals(await probe(db, C, lm, `${C}/${uuid(300)}.jpg`), 200);
    await db.exec(`insert into public.upload_blocklist (wallet, reason) values ('${C}', 'test')`);
    assertEquals(await complete(db, C, lm, `${C}/${uuid(300)}.jpg`), 403);
    assertEquals(await probe(db, C, lm, `${C}/${uuid(301)}.jpg`), 403);
    assertEquals(await upload(db, C, "avatars", `${C}/avatar.jpg`, { upsert: true, etag: '"new"' }), 403);
    for (const role of ["anon", "authenticated"] as const) {
      await assertRejects(() => as(db, role, C, "select count(*) from public.upload_blocklist"), Error, "permission denied");
    }

    // Overall: 1,000 uploads or 5 GiB in 24 hours across every wallet (a circuit breaker). Probes leave no trace.
    const count = () => one<{ n: number }>(db, "select count(*)::int as n from public.storage_upload_events where bucket_id = 'launch-media'").then((r) => r.n);
    const before = await count();
    assertEquals(await probe(db, B, lm, `${B}/${uuid(400)}.jpg`), 200);
    assertEquals(await count(), before);
    await db.exec(`insert into public.storage_upload_events (bucket_id, bytes)
      select 'launch-media', 1 from generate_series(1, ${999 - before})`);
    const F = wallet(0xf);
    assertEquals(await upload(db, F, lm, `${F}/${uuid(401)}.jpg`), 200); // the 1,000th
    assertEquals(await upload(db, F, lm, `${F}/${uuid(402)}.jpg`), 403);
    assertEquals(await upload(db, A, "avatars", `${A}/avatar.jpg`, { upsert: true, etag: '"a3"' }), 200); // avatars are not counted
    await db.exec(`update public.storage_upload_events set created_at = now() - interval '25 hours'`);
    assertEquals(await upload(db, F, lm, `${F}/${uuid(403)}.jpg`), 200);
    await db.exec(`insert into public.storage_upload_events (bucket_id, bytes) values ('launch-media', 5368709120 - 52428800)`);
    assertEquals(await upload(db, F, lm, `${F}/moment-${hex64(30)}.mp4`, { mime: "video/mp4", size: 52428800 }), 403); // 5 GiB + 1,000 bytes
    // Rows older than two days are purged by the next upload.
    await db.exec(`update public.storage_upload_events set created_at = now() - interval '3 days'`);
    assertEquals(await upload(db, F, lm, `${F}/${uuid(404)}.jpg`), 200);
    assertEquals(await count(), 1);

    const buckets = await db.query<{ id: string; file_size_limit: number; allowed_mime_types: string[] }>(
      "select id, file_size_limit, allowed_mime_types from storage.buckets order by id");
    assertEquals(buckets.rows.map((b) => [b.id, Number(b.file_size_limit), b.allowed_mime_types]), [
      ["avatars", 5242880, ["image/jpeg"]],
      ["launch-media", 52428800, ["image/jpeg", "video/mp4", "video/quicktime"]],
    ]);
    for (const role of ["anon", "authenticated", "service_role"] as const) {
      await assertRejects(() => as(db, role, A, "select count(*) from public.storage_upload_events"), Error, "permission denied");
      await assertRejects(() => as(db, role, A, "select public.storage_wallet_upload_budget($1, 0)", [A]), Error, "permission denied");
    }
    await assertRejects(() => as(db, "anon", null, "select public.storage_upload_allowed('launch-media')"), Error, "permission denied");
  });

  await t.step("OH-6: migration 26 refuses to install budgets whose owner cannot see every object", async () => {
    await db.exec("create role quota_owner nologin noinherit");
    await db.exec("alter function public.storage_wallet_upload_budget(text, bigint) owner to quota_owner");
    const m26 = await Deno.readTextFile(new URL("26_storage_write_once_and_upload_limits.sql", MIGRATIONS));
    await assertRejects(() => db.exec(m26), Error, "must bypass RLS and be able to read storage.objects");
    await db.exec("alter role quota_owner bypassrls");
    await assertRejects(() => db.exec(m26), Error, "must bypass RLS and be able to read storage.objects"); // no SELECT yet
    await db.exec("alter function public.storage_wallet_upload_budget(text, bigint) owner to postgres");
    await db.exec(m26);
  });

  await t.step("SB-6 strict (deferred 31): refuses until ready; then no launch-media object can be uploaded over", async () => {
    const template = await Deno.readTextFile(new URL("31_launch_media_strict_write_once.sql", DEFERRED));
    await assertRejects(() => db.exec(template), Error, "not ready");
    const ready = template.replace("v_ready constant boolean := false;", "v_ready constant boolean := true;");
    assert(ready !== template, "the readiness placeholder moved");
    await db.exec(ready);
    await db.exec(ready); // idempotent
    const moment = `${A}/moment-${hex64(9)}.jpg`;
    assertEquals(await probe(db, A, "launch-media", moment, { upsert: true }), 403); // no UPDATE policy
    assertEquals(await probe(db, A, "launch-media", moment), 409); // x-upsert: false: "already uploaded"
    assertEquals(await complete(db, A, "launch-media", moment, { upsert: true, etag: '"e1"' }), 409); // the same bytes
    assertEquals(await upload(db, A, "launch-media", `${A}/moment-${hex64(40)}.jpg`), 200);
    assertEquals(await upload(db, A, "avatars", `${A}/avatar.jpg`, { upsert: true, etag: '"a4"' }), 200);
    // Reverse: re-running 26 restores the interim exception.
    await db.exec(await Deno.readTextFile(new URL("26_storage_write_once_and_upload_limits.sql", MIGRATIONS)));
    assertEquals(await upload(db, A, "launch-media", moment, { upsert: true, etag: '"e1"' }), 200);
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
