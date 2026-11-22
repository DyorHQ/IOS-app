-- 34_oneinch_rate_scopes — edge_rate_gate budgets for oneinch-proxy, the app's route to the 1inch Swap API for
-- xStocks (tokenized stocks) against USDC on Monad.
--
-- oneinch-proxy spends DyorHQ's 1inch API key, and a wallet-auth session costs nothing but a fresh key, so every call
-- passes edge_rate_gate (migration 27) under one of two new scopes:
--
--   scope          subject (the function passes)    per subject       per client network    overall
--   oneinch        the session's wallet (status,    120 / 15 min      360 / 15 min          20 / 10 s
--                  and indicative quotes: the
--                  Swap screen refreshes every
--                  15 s)
--   oneinch-firm   the session's wallet (firm       10 / day          60 / day              5 / 10 s
--                  swaps, one per Review)
--
-- oneinch-firm's 10 a day per wallet, with the function's $250 per-trade cap, bounds what one wallet can trade through
-- 1inch in a day. The client network is an IPv4 address or an IPv6 /48 (oneinch-proxy asks for /48). The overall limits
-- keep every caller together under the 1inch key's own request rate, and take the scope lock 27 takes for pin-media,
-- so their counts are exact under concurrency. UNVERIFIED (research R2): the key's quota is not known yet; 20 and 5
-- per 10 s (3 requests a second in all) are cautious. A change to any limit is a new migration.
--
-- This migration changes only what the new scopes need, in 27's own objects: it re-asserts the scope CHECK on
-- edge_rate_events with the two scopes added, and replaces edge_rate_gate with 27's function, copied as it is in 27
-- (supabase/tests/migrations_test.ts checks the copy), with these changes and no other:
--   * the unknown-scope guard accepts 'oneinch' and 'oneinch-firm';
--   * the scope lock is taken for 'pin-media', 'oneinch' and 'oneinch-firm';
--   * the limits above are added to the inline VALUES list; every existing scope's limits are unchanged;
--   * the COMMENT ON FUNCTION lists the two scopes.
-- 27's grants are re-applied and re-checked as 27 checks them.
--
-- Re-running 27 requires re-running 34 immediately after. 27 re-asserts its own CHECK and function: while
-- edge_rate_events holds any oneinch row (rows are purged a day after they were written), 27's CHECK refuses it and
-- the run fails (run as one transaction, as one multi-statement script is, it then changes nothing); once none is
-- left, 27 succeeds and narrows the gate back to its own scopes, and every oneinch-proxy call then fails closed (503
-- busy) until 34 runs again. Re-running 34 itself is safe at any time.
--
-- Reverse: redeploy or delete oneinch-proxy first (it fails closed without these scopes), then
--          delete from public.edge_rate_events where scope in ('oneinch', 'oneinch-firm'); and re-run 27.
-- Verify after apply:
--   select pg_get_constraintdef(oid) from pg_constraint where conname = 'edge_rate_events_scope_check'; -- names both
--   select pg_get_functiondef('public.edge_rate_gate(text,text,text)'::regprocedure) like '%oneinch-firm%';  -- true
--   select has_function_privilege('anon', 'public.edge_rate_gate(text,text,text)', 'execute'),          -- false
--          has_function_privilege('authenticated', 'public.edge_rate_gate(text,text,text)', 'execute'), -- false
--          has_function_privilege('service_role', 'public.edge_rate_gate(text,text,text)', 'execute');  -- true

alter table public.edge_rate_events drop constraint if exists edge_rate_events_scope_check;
alter table public.edge_rate_events add constraint edge_rate_events_scope_check
  check (scope in ('pin-media', 'aurora', 'aurora-status', 'waitlist', 'wallet-auth', 'oneinch', 'oneinch-firm'));

create or replace function public.edge_rate_gate(p_scope text, p_subject text, p_ip text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_subject       text := nullif(btrim(coalesce(p_subject, '')), '');
  v_ip            text := nullif(left(btrim(coalesce(p_ip, '')), 64), '');
  v_net           text;
  v_subject_until timestamptz;
  v_net_until     timestamptz;
  v_global_until  timestamptz;
begin
  if p_scope is null or p_scope not in ('pin-media', 'aurora', 'aurora-status', 'waitlist', 'wallet-auth', 'oneinch', 'oneinch-firm') then
    raise exception 'unknown rate-limit scope' using errcode = '22023';
  end if;
  if v_subject is not null and char_length(v_subject) > 64 then
    raise exception 'subject must be at most 64 characters' using errcode = '22023';
  end if;
  if v_ip is not null then
    select encode(extensions.hmac(convert_to('dyorhq/edge-rate/v1/net:' || v_ip, 'UTF8'), s.salt, 'sha256'), 'hex')
      into v_net from public.edge_rate_salt s;
    if v_net is null then
      raise exception 'edge_rate_salt is missing' using errcode = 'P0001';
    end if;
  end if;

  -- Subject lock, then network lock, then — for the scopes with an overall ('global') limit below — the scope lock
  -- (always in that order, so no lock cycle). Released at commit.
  if v_subject is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('dyorhq/edge-rate/subject'), pg_catalog.hashtext(p_scope || '/' || v_subject));
  end if;
  if v_net is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('dyorhq/edge-rate/net'), pg_catalog.hashtext(p_scope || '/' || v_net));
  end if;
  if p_scope in ('pin-media', 'oneinch', 'oneinch-firm') then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('dyorhq/edge-rate/scope'), pg_catalog.hashtext(p_scope));
  end if;

  delete from public.edge_rate_events where created_at < now() - interval '1 day';

  -- Over a limit of L per window W when the L-th most recent allowed call is still inside W; it is also the call that
  -- has to age out before the next one is allowed, so it gives retryAfter. A null subject or network skips its limits;
  -- a 'global' limit counts every call in the scope.
  select max(x.until) filter (where l.kind = 'subject'), max(x.until) filter (where l.kind = 'network'),
         max(x.until) filter (where l.kind = 'global')
    into v_subject_until, v_net_until, v_global_until
  from (values
      ('pin-media',     'subject', interval '15 minutes',   20),
      ('pin-media',     'subject', interval '1 day',       100),
      ('pin-media',     'network', interval '15 minutes',   60),
      ('pin-media',     'global',  interval '1 day',      1000),
      ('aurora',        'subject', interval '15 minutes',  120),
      ('aurora',        'network', interval '15 minutes',  360),
      ('aurora-status', 'subject', interval '15 minutes',  900),
      ('aurora-status', 'network', interval '15 minutes', 2700),
      ('waitlist',      'subject', interval '1 hour',      500),
      ('waitlist',      'network', interval '15 minutes',    5),
      ('waitlist',      'network', interval '1 day',        20),
      ('wallet-auth',   'network', interval '15 minutes',   30),
      ('wallet-auth',   'network', interval '1 day',       200),
      ('oneinch',       'subject', interval '15 minutes',  120),
      ('oneinch',       'network', interval '15 minutes',  360),
      ('oneinch',       'global',  interval '10 seconds',   20),
      ('oneinch-firm',  'subject', interval '1 day',        10),
      ('oneinch-firm',  'network', interval '1 day',        60),
      ('oneinch-firm',  'global',  interval '10 seconds',    5)
    ) as l(scope, kind, win, lim)
  cross join lateral (
    select e.created_at + l.win as until
      from public.edge_rate_events e
     where e.scope = p_scope
       and ((l.kind = 'subject' and v_subject is not null and e.subject = v_subject)
         or (l.kind = 'network' and v_net is not null and e.net = v_net)
         or l.kind = 'global')
       and e.created_at > now() - l.win
     order by e.created_at desc
     offset l.lim - 1 limit 1
  ) x
  where l.scope = p_scope;

  if v_subject_until is not null or v_net_until is not null or v_global_until is not null then
    return jsonb_build_object(
      'retryAfter', greatest(1, ceil(extract(epoch from greatest(v_subject_until, v_net_until, v_global_until) - now()))::int),
      'limit', case when v_net_until is not null then 'network' when v_global_until is not null then 'global' else 'subject' end);
  end if;

  insert into public.edge_rate_events (scope, subject, net) values (p_scope, v_subject, v_net);
  return jsonb_build_object('ok', true);
end;
$function$;

revoke all on function public.edge_rate_gate(text, text, text) from public, anon, authenticated;
grant execute on function public.edge_rate_gate(text, text, text) to service_role;
comment on function public.edge_rate_gate(text, text, text) is
  'Edge Function budgets (pin-media, aurora, aurora-status, waitlist, wallet-auth, oneinch, oneinch-firm) per subject, per client network (stored only as a salted HMAC) and overall. Records the allowed call and returns {"ok": true}, or {"retryAfter": seconds, "limit": "subject"|"network"|"global"}. service_role only.';

-- Fail the migration if any API role can touch the ledger or the salt, or anyone but the service role can call the gate.
do $$
declare
  r     text;
  privs constant text := 'select, insert, update, delete, truncate, references, trigger';
begin
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_table_privilege(r, 'public.edge_rate_events', privs) or has_table_privilege(r, 'public.edge_rate_salt', privs) then
      raise exception '% still has privileges on edge_rate_events / edge_rate_salt', r;
    end if;
  end loop;
  foreach r in array array['anon', 'authenticated'] loop
    if has_function_privilege(r, 'public.edge_rate_gate(text, text, text)', 'execute') then
      raise exception '% can still execute edge_rate_gate', r;
    end if;
  end loop;
  if not has_function_privilege('service_role', 'public.edge_rate_gate(text, text, text)', 'execute') then
    raise exception 'service_role cannot execute edge_rate_gate';
  end if;
  if (select count(*) from public.edge_rate_salt) <> 1 then
    raise exception 'edge_rate_salt must hold exactly one salt';
  end if;
end
$$;
