-- 20_email_pepper — the server key that stops offline password guessing against email+password wallets (security
-- audit 2026-09-22: the wallet was computed from email + password alone, so anyone could test guesses offline).
--
-- v2 email wallets mix a server "pepper" p into the key: p = HMAC-SHA256(K, "dyorhq/email-pepper/v1" || 0x00 || e || t),
-- where e = SHA256(email label) and t = SHA256(label || S) come from the app (S = the existing PBKDF2 output; the server
-- never sees the password or S). Without K a guess cannot be checked offline, and every online check goes through
-- email_pepper_hmac(), which rate-limits per email hash (10 / 15 min, 50 / 24 h) and per client network (60 / 15 min;
-- the edge function passes an IPv4 address or an IPv6 /64).
--
--   * K = 32 bytes from pgcrypto's CSPRNG (extensions.gen_random_bytes — pgcrypto lives in schema `extensions` on this
--     project, confirmed read-only 2026-09-23, as are extensions.hmac(bytea, bytea, text) and
--     vault.create_secret(new_secret, new_name, new_description, new_key_id)). It is generated INSIDE the database and
--     stored hex-encoded in Supabase Vault as 'email_pepper_key' (encrypted at rest). No migration text, log line or
--     API response ever contains it: only this SECURITY DEFINER function reads it, and it returns only the HMAC.
--   * K must NEVER rotate, be updated or be deleted: every v2 email wallet's private key depends on it, so changing or
--     losing it (e.g. deleting the project) strands those wallets and any funds in them. It is created only if absent,
--     so re-running this migration is a no-op. It is covered by this project's Supabase backups / PITR.
--   * email_pepper_key_check holds HMAC-SHA256(K, "dyorhq/email-pepper/kcv"), recorded when K is created (it reveals
--     nothing about K or any pepper). With it, a re-run after K was deleted REFUSES instead of quietly minting a new
--     key (which would move every v2 wallet), and email_pepper_hmac() refuses to serve peppers from a key that does
--     not match it (replaced, or restored from the wrong backup) instead of handing out wrong ones.
--   * email_pepper_attempts records one row (email hash, client network, time) per ANSWERED request — refused requests are
--     not recorded, so hammering does not extend a lockout. Rows older than a day are purged by the function. It never
--     stores t or p. RLS on, no policies, and no grants to anon, authenticated OR service_role: only the SECURITY
--     DEFINER function (running as the table owner) touches it, so even the service-role key cannot reset or pre-fill
--     a limit through the API. Same for email_pepper_key_check.
--   * email_pepper_hmac() is executable by service_role only (the email-pepper edge function). search_path is empty and
--     every object is schema-qualified.
--
-- Known limitation (accepted by contract; owner decision before v2 ships): e needs no secret, so anyone who knows a
-- user's email can spend that email's budget (about 50 answered requests a day) and keep the user from deriving the v2
-- key on a device that does not already hold it, for as long as they keep it up. Nothing can be stolen or moved. The
-- server cannot tell the owner's t from a guess (answering "known" t values past the limit would be a guessing
-- oracle), so lifting it needs an out-of-band proof, e.g. a separate bucket for callers presenting a fresh Privy
-- email-OTP token whose attested email hashes to e.
--
-- Reverse (DANGER — only before any v2 wallet exists; afterwards it strands them):
--   drop function public.email_pepper_hmac(text, text, text); drop table public.email_pepper_attempts;
--   and leave the vault secret and email_pepper_key_check in place (never delete either once a v2 wallet exists; before
--   then, remove both together or the next apply refuses).
-- Verify after apply (booleans only, never select decrypted_secret):
--   select has_function_privilege('anon', 'public.email_pepper_hmac(text,text,text)', 'execute'),          -- false
--          has_function_privilege('authenticated', 'public.email_pepper_hmac(text,text,text)', 'execute'), -- false
--          has_function_privilege('service_role', 'public.email_pepper_hmac(text,text,text)', 'execute'),  -- true
--          (select count(*) from vault.secrets where name = 'email_pepper_key'),                           -- 1
--          (select count(*) from public.email_pepper_key_check),                                           -- 1
--          has_table_privilege('service_role', 'public.email_pepper_attempts', 'select,insert,update,delete'); -- false

-- 1. The key check value (see header). Owner-only: no grants to any API role.
create table if not exists public.email_pepper_key_check (
  id         boolean primary key default true check (id),
  kcv        text not null check (kcv ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()
);
alter table public.email_pepper_key_check enable row level security;
revoke all on public.email_pepper_key_check from public, anon, authenticated, service_role;
comment on table public.email_pepper_key_check is
  'HMAC-SHA256(email_pepper_key, "dyorhq/email-pepper/kcv"), recorded when the key was created. Guards against a deleted/replaced key being silently regenerated or used. Never delete. No API role has access.';

-- 2. The key: created in-database on first install only. If a check value exists but the key does not, the key was
--    deleted: refuse (it must be restored from backup, never regenerated).
do $$
declare
  v_key text;
begin
  if not exists (select 1 from vault.secrets where name = 'email_pepper_key') then
    if exists (select 1 from public.email_pepper_key_check) then
      raise exception 'email_pepper_key is missing but was created before (email_pepper_key_check is set): restore the original key from backup; a new key would change every v2 email wallet';
    end if;
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'email_pepper_key',
      'DyorHQ email-pepper HMAC key for v2 email+password wallets. NEVER rotate, update or delete: every v2 email wallet key depends on it; changing or losing it strands those wallets and their funds. Read only by public.email_pepper_hmac().'
    );
  end if;
  if not exists (select 1 from public.email_pepper_key_check) then
    select s.decrypted_secret into v_key from vault.decrypted_secrets s where s.name = 'email_pepper_key';
    if v_key is null or v_key !~ '^[0-9a-f]{64}$' then
      raise exception 'email_pepper_key is malformed';
    end if;
    insert into public.email_pepper_key_check (kcv)
      values (encode(extensions.hmac(convert_to('dyorhq/email-pepper/kcv', 'UTF8'), decode(v_key, 'hex'), 'sha256'), 'hex'));
  end if;
end
$$;

-- 3. Rate-limit ledger (owner-only: read and written solely by the SECURITY DEFINER function below).
create table if not exists public.email_pepper_attempts (
  id         uuid primary key default gen_random_uuid(),
  e          text not null check (e ~ '^[0-9a-f]{64}$'),
  ip         text,
  created_at timestamptz not null default now()
);
alter table public.email_pepper_attempts enable row level security;
revoke all on public.email_pepper_attempts from public, anon, authenticated, service_role;
create index if not exists email_pepper_attempts_e_idx on public.email_pepper_attempts (e, created_at desc);
create index if not exists email_pepper_attempts_ip_idx on public.email_pepper_attempts (ip, created_at desc) where ip is not null;
create index if not exists email_pepper_attempts_created_at_idx on public.email_pepper_attempts (created_at);
comment on table public.email_pepper_attempts is
  'One row per answered email-pepper request (email hash e, client network, time) for its rate limits; purged after a day. Never holds t or p. RLS on, no policies, no grants to anon/authenticated/service_role: only email_pepper_hmac() (as owner) touches it.';

-- 4. The pepper: enforce + record the rate limit, then HMAC with the vault key. Returns {"p": hex} or {"retryAfter": s}.
create or replace function public.email_pepper_hmac(p_e text, p_t text, p_ip text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_ip    text := nullif(left(btrim(coalesce(p_ip, '')), 64), '');
  v_until timestamptz;
  v_key   text;
begin
  if p_e is null or p_e !~ '^[0-9a-f]{64}$' or p_t is null or p_t !~ '^[0-9a-f]{64}$' then
    raise exception 'e and t must each be 64 lowercase hex characters' using errcode = '22023';
  end if;

  -- Serialise attempts for the same email hash, then the same IP (always in that order, so no lock cycle): the counts
  -- below are exact under concurrency. Transaction-scoped, released at commit.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('dyorhq/email-pepper/e'), pg_catalog.hashtext(p_e));
  if v_ip is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('dyorhq/email-pepper/ip'), pg_catalog.hashtext(v_ip));
  end if;

  delete from public.email_pepper_attempts where created_at < now() - interval '1 day';

  -- Over a limit of L per window W when the L-th most recent attempt is still inside W; it is also the attempt that
  -- has to age out before the next one is allowed, so it gives retryAfter.
  select max(w.until) into v_until from (
    (select a.created_at + interval '15 minutes' as until from public.email_pepper_attempts a
      where a.e = p_e and a.created_at > now() - interval '15 minutes'
      order by a.created_at desc offset 9 limit 1)
    union all
    (select a.created_at + interval '1 day' from public.email_pepper_attempts a
      where a.e = p_e and a.created_at > now() - interval '1 day'
      order by a.created_at desc offset 49 limit 1)
    union all
    (select a.created_at + interval '15 minutes' from public.email_pepper_attempts a
      where v_ip is not null and a.ip = v_ip and a.created_at > now() - interval '15 minutes'
      order by a.created_at desc offset 59 limit 1)
  ) w;
  if v_until is not null then
    return jsonb_build_object('retryAfter', greatest(1, ceil(extract(epoch from v_until - now()))::int));
  end if;

  select s.decrypted_secret into v_key from vault.decrypted_secrets s where s.name = 'email_pepper_key';
  if v_key is null or v_key !~ '^[0-9a-f]{64}$' then
    raise exception 'email_pepper_key is missing or malformed' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.email_pepper_key_check c where c.kcv = encode(extensions.hmac(
      convert_to('dyorhq/email-pepper/kcv', 'UTF8'), decode(v_key, 'hex'), 'sha256'), 'hex')) then
    raise exception 'email_pepper_key does not match its recorded check value: refusing to serve peppers' using errcode = 'P0001';
  end if;

  insert into public.email_pepper_attempts (e, ip) values (p_e, v_ip);

  return jsonb_build_object('p', encode(extensions.hmac(
    convert_to('dyorhq/email-pepper/v1', 'UTF8') || decode('00', 'hex') || decode(p_e, 'hex') || decode(p_t, 'hex'),
    decode(v_key, 'hex'),
    'sha256'), 'hex'));
end;
$function$;

-- Default privileges on this schema grant EXECUTE to anon/authenticated explicitly (and PostgreSQL to PUBLIC): revoke
-- all three, then allow only the service role.
revoke all on function public.email_pepper_hmac(text, text, text) from public, anon, authenticated;
grant execute on function public.email_pepper_hmac(text, text, text) to service_role;

comment on function public.email_pepper_hmac(text, text, text) is
  'email-pepper: rate-limits (per email hash 10/15 min + 50/24 h, per client network 60/15 min), records the attempt, and returns {"p": HMAC-SHA256(vault email_pepper_key, "dyorhq/email-pepper/v1" || 0x00 || e || t)} or {"retryAfter": seconds}. Refuses if the key does not match email_pepper_key_check. Never returns the key. service_role only.';

-- 5. Verify the revokes above: fail the migration if any API role can still touch either table.
do $$
declare
  r     text;
  privs constant text := 'select, insert, update, delete, truncate, references, trigger';
begin
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_table_privilege(r, 'public.email_pepper_attempts', privs)
       or has_table_privilege(r, 'public.email_pepper_key_check', privs) then
      raise exception '% still has privileges on email_pepper_attempts / email_pepper_key_check', r;
    end if;
  end loop;
end
$$;
