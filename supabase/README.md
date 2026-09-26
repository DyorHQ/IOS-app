# DyorHQ backend (Supabase)

Backs the *social trading HQ* features only — push & price alerts, social (profiles/follows/feed/comments/
leaderboards/referrals), a launch-discovery index, and cross-device sync. The core app stays
self-custodial and on-chain; **no private keys or the Perpl Ed25519 secret are ever stored here.**

- **Project:** `DyorHQ` · ref `fmnjqrguvopusfufmirs` · region eu-west-1 · Postgres 17
- **URL:** `https://fmnjqrguvopusfufmirs.supabase.co`
- **App keys (safe to embed):** publishable key `sb_publishable_s1G3ns-jmzTfnFs7rTvdbQ_8FJYODhT` (RLS protects data).
  Wired into the iOS app via `AppConfig` (defaults; overridable with `SupabaseURL` / `SupabaseKey` in Secrets.xcconfig).

## Auth (login stays in Privy)

The app has the Privy wallet `personal_sign` a fresh nonce; the **`wallet-auth`** Edge Function (`functions/wallet-auth/`)
recovers the signer, checks freshness, and mints a Supabase HS256 JWT with a `wallet_address` claim. Every RLS policy
keys off `public.app_wallet()` = that claim (lowercased). Public data is world-readable with the publishable key;
writes require the wallet's session.

**Required secret:** set `APP_JWT_SECRET` for the function to the project's **JWT Secret**
(Dashboard → Settings → API → JWT Secret) so PostgREST accepts the minted tokens.

## Schema (applied as migrations 01–07, RLS on every table, security advisor clean)

| Area | Tables |
|---|---|
| Foundation/sync | `profiles`, `follows`, `watchlist`, `user_settings` |
| Social | `posts`, `comments`, `reactions`, `referral_codes`, `referrals`, `leaderboard` |
| Alerts/push | `device_tokens`, `alerts` |
| Launch index | `launches` |
| App sync (mig. 11) | `activity` (every action: kind, section, USD size + fee, tx hash), `notifications` |
| Sessions (mig. 14) | `sessions` (one row per sign-in — `signed_in_at`, `signed_out_at`) |
| Journey (mig. 12–14) | `user_journey` (view — one row per user: handle, wallet, `joined_at`, sign-in/out times, per-domain spot/perps/launchpad/moments/bridge/deposits/withdrawals rollup; **internal analytics only**, not granted to anon/authenticated), `platform_journey()` (platform totals by domain) |

`activity.kind` ∈ swap, buy, sell, launch, perp, moment, **bridge**, **deposit**, **withdraw**, send; `activity.section`
∈ spot, perps, launch(pad), moments, bridge, wallet. The whole user journey — username (`profiles.handle`), wallet,
per-domain volume, deposits/withdrawals, notifications and activities — is stitched by the `user_journey` view.

Every migration applied to the live project is now in `migrations/` (01–22); 23–29 (security audit 2026-09-26) are
written but not yet applied, and `migrations-deferred/30_activity_primary_key_wallet_id.sql` must wait until the first
build that upserts activity with `on_conflict=wallet,id` is the minimum build (see its header). 01–07 and 11 were restored on 2026-09-26
from the project's own migration history (`supabase_migrations.schema_migrations.statements`), byte-for-byte — each
file's md5 equals the recorded statements' md5. Two out-of-band changes are NOT in any migration: the Strategies tables
below were dropped directly (2026-09-18), and 18's revokes supersede 11's `grant execute … platform_volume … to anon`.
Record every future schema change as a numbered migration here, so the backend can be rebuilt and audited from source.

> The Strategies feature (copy-trading, market-making, delta-neutral) was removed from the app on 2026-09-18; its
> tables (`strategies`, `leaders`, `copy_relationships`, `copy_grants`, `copy_events`) were dropped from the project.

| Audit 2026-09-26 (mig. 24–29) | `app_config` (public, read-only: `ios.min_build`), `waitlist`, `upload_blocklist`, `edge_rate_events` / `edge_rate_salt` (owner-only rate ledger) |

## Edge Functions

`config.toml` pins each function's gateway JWT check; deploy with `supabase functions deploy <name>` from the repository
root (the CLI bundles `functions/_shared/`). Never run `supabase config push` from this repository.

| Function | verify_jwt | Caller proves | Limits |
|---|---|---|---|
| `wallet-auth` | false | a wallet signature over a server nonce (EIP-4361 or the legacy template) | single-use nonce |
| `email-pepper` | false | nothing, or a Privy email token for the verified budget | per email, per network, per Privy user |
| `email-rebind` | false | a Privy email token (≤ 15 min old) + the new wallet's signature; `replace` to move a binding | per Privy user |
| `delete-account` | false | a Privy token (≤ 15 min old), or the wallet session with `{"method":"email-password"}` | per Privy user / wallet |
| `pin-media` | true | a wallet session | `edge_rate_gate` per wallet and network; 20 s budget |
| `aurora-proxy` | true | a wallet session; quotes only to and from that wallet | `edge_rate_gate` per wallet and network |
| `waitlist` | false | nothing (CORS: dyorhq.fun, www.dyorhq.fun; honeypot) | `edge_rate_gate` per network and overall |

Secrets (names only): `APP_JWT_SECRET` or `APP_JWT_SIGNING_JWK` (wallet-auth), `PRIVY_APP_SECRET` (+ optional
`PRIVY_APP_ID`), `PINATA_JWT` (+ optional `PINATA_GATEWAY`), `AURORA_API_KEY`, optional
`DELETE_ACCOUNT_TOKEN_MAX_AGE_S` (transition only). `SUPABASE_URL`, the service-role key and the publishable key are
injected by the platform.

## Tests

    deno test -A --no-config --node-modules-dir=none supabase/functions/        # unit tests, next to each function
    deno test -A --no-config --node-modules-dir=none supabase/tests/            # every migration, on a throwaway PGlite database

`--no-config` keeps the repository's Node `package.json`/`tsconfig.json` out of Deno's way. `tests/supabase_stub.sql`
stands in for the platform (roles, auth/storage/vault stubs, default privileges); nothing touches the live project.

## Minimum iOS build

`app_config` row `ios` = `{"min_build", "message", "url"}`. The app shows a blocking "Update required" screen (balances
and key export still work; nothing can be signed) when its CFBundleVersion is below `min_build`, and fails open on any
error. Raise it in the SQL editor: `update public.app_config set value = jsonb_set(value, '{min_build}', '<build>') where
key = 'ios';` — the CHECK constraint refuses a row the app could not parse.

## Takedown (public buckets)

Objects in `avatars` and `launch-media` are public, and launch-media is write-once with no owner delete (on-chain
pointers must keep resolving), so removing content is an owner action:

1. Block the wallet from uploading to either bucket (SQL editor, as postgres):
   `insert into public.upload_blocklist (wallet, reason) values (lower('0x…'), '<why, date>') on conflict (wallet) do nothing;`
2. Delete the object through Storage, never with SQL on `storage.objects` (that orphans the file): Dashboard → Storage →
   the bucket → the wallet's folder → Delete.
3. For Moment media also pinned to IPFS, unpin the CID in the Pinata dashboard. The on-chain URI stays; other IPFS
   nodes may still serve it.
4. Record what was removed and why, and answer the report (the security/support contact published on dyorhq.fun).

## Session signing key (OH-7)

wallet-auth signs sessions with the project's legacy JWT secret (`APP_JWT_SECRET`), which can also mint service-role
tokens. To move to a dedicated asymmetric key (owner, dashboard; no downtime, reversible until the last step):

1. `supabase gen signing-key --algorithm ES256` on a trusted machine; keep the private JWK offline as the backup.
2. Dashboard → Settings → JWT Keys: if the project is still on the legacy secret only, "Migrate JWT secret" first; then
   create a new standby key by importing that private JWK (same `kid`).
3. "Rotate keys" so the imported key is in use; the legacy secret moves to "previously used" and stays trusted, so
   existing sessions keep working. This project does not use Supabase Auth for users, so nothing else changes.
4. `supabase secrets set APP_JWT_SIGNING_JWK='<the private JWK JSON>'`, then redeploy wallet-auth. New sessions are
   ES256 with that `kid`; check one sign-in, a PostgREST read, an upload, a pin-media call and a bridge quote. Supabase's
   current guide says the gateway's verify_jwt accepts asymmetric keys, but its older signing-keys page warns it may
   not: if pin-media or aurora-proxy answer 401, unset `APP_JWT_SIGNING_JWK` (sessions go back to HS256) and do not
   continue until those two verify sessions in code.
5. After 12 hours (the session lifetime), `supabase secrets unset APP_JWT_SECRET`. Revoking the legacy secret itself
   also needs the functions moved to the new secret API keys first (they use the legacy service-role key) — a
   separate step.

## Still to build

`alerts`/push watcher (needs an APNs auth key), launch indexer, leaderboard/stats Edge Functions; and the remaining
iOS feature UIs (feed, follows, watchlist sync, alerts).
