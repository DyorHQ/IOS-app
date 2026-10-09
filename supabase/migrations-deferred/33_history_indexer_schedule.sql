-- 33_history_indexer_schedule — runs the history-indexer Edge Function every 30 seconds (pg_cron → pg_net), and once a
-- day prunes pg_cron's run log to two days and the indexer's run rows to seven (history_housekeeping()).
--
-- PLATFORM-ONLY and DEFERRED: it needs pg_cron, pg_net and Vault, which the PGlite harness does not have, and it must
-- not run before the function it calls exists. It lives in supabase/migrations-deferred/ until the owner has, in order:
--   (1) applied 32_wallet_history.sql (MCP apply_migration, so supabase_migrations records it);
--   (2) enabled pg_cron and pg_net (Dashboard → Database → Extensions) and checked that `net` is not an exposed API
--       schema (Settings → API);
--   (3) set the Edge secret HISTORY_CRON_SECRET and created, in the SQL editor, the Vault secrets this file reads:
--         select vault.create_secret('<value>', 'history_cron_secret', 'history-indexer cron header');
--           — the SAME value as HISTORY_CRON_SECRET, at least 32 characters, generated on the owner's machine and never
--             written to a file;
--         select vault.create_secret('https://<project ref>.supabase.co/functions/v1/history-indexer', 'history_indexer_url',
--                                    'history-indexer URL');
--           — the project this database belongs to (a branch or staging stack gets its own URL, so this file needs no edit);
--         optionally select vault.create_secret('eu-west-1', 'history_indexer_region', 'history-indexer x-region');
--           — pins the function next to the database; leave it out where the region differs;
--   (4) deployed history-indexer (verify_jwt = false, supabase/config.toml) and seen one manual call answer 202.
-- Then: set v_armed below to true, apply this file with MCP apply_migration (name 33_history_indexer_schedule) as
-- postgres, and move it into supabase/migrations/ (migrations_test.ts lists it in PLATFORM_ONLY: on PGlite it must
-- refuse with "requires pg_cron and pg_net"). A preview branch or rebuild that applies the folder stops at the Vault
-- guard unless that database has its own secrets, and then calls its own function, never production's.
-- Idempotent: re-running replaces both jobs.
--
-- The job sends only the cron secret (read from Vault at each tick; pg_net keeps the queued request, headers included,
-- until its worker sends it, readable by roles that can log in, i.e. postgres) and an empty body; the function answers
-- 202 at once and works in the background under a lease, so ticks never overlap work. A tick that fired is not a run
-- that worked: cron.job_run_details says "succeeded" as soon as net.http_post queued the request. Watch
-- net._http_response (kept 6 h) and history_health() (supabase/README.md "Wallet history cache").
--
-- Reverse: select cron.unschedule('history-indexer'); select cron.unschedule('history-indexer-housekeeping');
--          (to stop indexing without unscheduling: update public.history_indexer_state set paused = true where id;)
-- Verify after apply:
--   select jobname, schedule, active from cron.job where jobname like 'history-indexer%';            -- 2 rows, active
--   select status_code, count(*) from net._http_response where created > now() - interval '10 minutes' group by 1;  -- 202
--   select public.history_health();

do $migration$
declare
  v_armed constant boolean := false;  -- SET TRUE once (1)–(4) in the header all hold
begin
  if not v_armed then
    raise exception 'not armed: apply only after migration 32, pg_cron + pg_net, the Vault secrets and the history-indexer deploy (see the header)';
  end if;
  if not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_net') then
    raise exception 'requires pg_cron and pg_net: enable both (Dashboard → Database → Extensions) first';
  end if;
  if to_regprocedure('public.history_commit(uuid, text, integer, bigint, bigint, bigint, bigint, text[], jsonb)') is null
     or to_regprocedure('public.history_housekeeping()') is null then
    raise exception 'apply migration 32 first';
  end if;
  if not exists (select 1 from vault.decrypted_secrets where name = 'history_cron_secret' and length(decrypted_secret) >= 32) then
    raise exception 'create the Vault secret history_cron_secret (at least 32 characters) first';
  end if;
  if not exists (select 1 from vault.decrypted_secrets where name = 'history_indexer_url'
                    and decrypted_secret ~ '^https://[a-z0-9.-]+(:[0-9]+)?/functions/v1/history-indexer$') then
    raise exception 'create the Vault secret history_indexer_url (https://<host>/functions/v1/history-indexer) first';
  end if;

  perform cron.unschedule(j.jobid) from cron.job j where j.jobname in ('history-indexer', 'history-indexer-housekeeping');

  perform cron.schedule('history-indexer', '30 seconds', $job$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'history_indexer_url'),
      headers := jsonb_strip_nulls(jsonb_build_object(
        'Content-Type', 'application/json',
        'x-region', (select decrypted_secret from vault.decrypted_secrets where name = 'history_indexer_region'),
        'x-history-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'history_cron_secret'))),
      body := '{}'::jsonb,
      timeout_milliseconds := 10000)
  $job$);

  perform cron.schedule('history-indexer-housekeeping', '17 3 * * *', $job$
    delete from cron.job_run_details where start_time < now() - interval '2 days';
    select public.history_housekeeping();
  $job$);
end
$migration$;
