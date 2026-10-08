# DyorHQ backend (Supabase)

Backs the parts of DyorHQ that are not on chain: wallet sign-in sessions (`wallet-auth`), email-and-password
accounts (`email-pepper`, `email-rebind`, `delete-account`), profiles, follows, feed, comments, leaderboards and
referrals, price and push alerts with their devices, a launch-discovery index, activity and cross-device sync,
Moment media pinning (`pin-media`) and the bridge quote proxy (`aurora-proxy`). The core app stays self-custodial and
on-chain; **no private keys or the Perpl Ed25519 secret are ever stored here.**

- **Project:** `DyorHQ` · ref `fmnjqrguvopusfufmirs` · region eu-west-1 · Postgres 17
- **URL:** `https://fmnjqrguvopusfufmirs.supabase.co`
- **App keys (safe to embed):** publishable key `sb_publishable_s1G3ns-jmzTfnFs7rTvdbQ_8FJYODhT` (RLS protects data).
  Embedded in the iOS app (`ios/DyorHQ/Config/AppConfig.swift`).

## Auth (login stays in Privy)

The app has the Privy wallet `personal_sign` a sign-in message around a fresh server nonce (EIP-4361 bound to
dyorhq.fun and chain 143, or the legacy template until `WALLET_AUTH_LEGACY_SIGNIN=off`); the **`wallet-auth`** Edge
Function (`functions/wallet-auth/`) recovers the signer, checks freshness, consumes the nonce, and mints a Supabase JWT
with a `wallet_address` claim, valid for 12 hours (`WALLET_AUTH_SESSION_S` can shorten it; it cannot be revoked
earlier). A wallet's first sign-in (no profile row yet) is limited per client network, because wallets cost nothing.
Every RLS policy keys off `public.app_wallet()` = that claim (lowercased). Public data is world-readable with the
publishable key; writes require the wallet's session.

**Signing key:** `APP_JWT_SECRET`, the project's legacy **JWT Secret** (HS256), until the owner moves sessions to a
dedicated ES256 key, `APP_JWT_SIGNING_JWK` (see "Session signing key" below), which then takes precedence. Either way
PostgREST accepts the tokens. pin-media and aurora-proxy verify sessions in code with the same keys: `APP_JWT_SECRET`
for HS256 and the project's JWKS for ES256.

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
| Hardening 2026-09-26 (mig. 24–29) | `app_config` (public, read-only: `ios.min_build`), `waitlist`, `upload_blocklist`, `storage_upload_events` (launch-media's overall budget), `edge_rate_events` / `edge_rate_salt` (owner-only rate ledger); triggers `dyorhq_storage_upload_gate` and `dyorhq_launch_media_write_once` on `storage.objects` |

`activity.kind` ∈ swap, buy, sell, launch, perp, moment, **bridge**, **deposit**, **withdraw**, send; `activity.section`
∈ spot, perps, launch(pad), moments, bridge, wallet. The whole user journey — username (`profiles.handle`), wallet,
per-domain volume, deposits/withdrawals, notifications and activities — is stitched by the `user_journey` view.

`migrations/` holds every migration applied to the live project, 01–28 (23–28 are the 2026-09-26 hardening); 29
(`waitlist`) is written but not applied, and its Edge Function is not deployed, because the website keeps its own
signups. `migrations-deferred/` holds two that must wait for an app build AND for every older build
to be expired in App Store Connect / TestFlight (each header says which build; each refuses to run until armed):
`30_activity_primary_key_wallet_id.sql` (the build that upserts activity with `on_conflict=wallet,id`) and
`31_launch_media_strict_write_once.sql` (the build that uploads launch-media with `x-upsert: false`). 01–07 and 11 were restored on 2026-09-26
from the project's own migration history (`supabase_migrations.schema_migrations.statements`), byte-for-byte — each
file's md5 equals the recorded statements' md5. Two out-of-band changes are NOT in any migration: the Strategies tables
below were dropped directly (2026-09-18), and 18's revokes supersede 11's `grant execute … platform_volume … to anon`.
Record every future schema change as a numbered migration here, so the backend can be rebuilt and audited from source.

> The Strategies feature (copy-trading, market-making, delta-neutral) was removed from the app on 2026-09-18; its
> tables (`strategies`, `leaders`, `copy_relationships`, `copy_grants`, `copy_events`) were dropped from the project.

## Edge Functions

`config.toml` pins each function's gateway JWT check; deploy with `supabase functions deploy <name>` from the repository
root (the CLI bundles `functions/_shared/`). Never run `supabase config push` from this repository.

| Function | verify_jwt | Caller proves | Limits |
|---|---|---|---|
| `wallet-auth` | false | a wallet signature over a server nonce (EIP-4361, or the legacy template until switched off) | single-use nonce; a first sign-in: `edge_rate_gate` per network (IPv6 /48) |
| `email-pepper` | false | nothing, or a Privy email token for the verified budget | per email, per network, per Privy user |
| `email-rebind` | false | a Privy email token (≤ 15 min old) + the new wallet's signature; `replace` to move a binding once `REBIND_REQUIRE_REPLACE=on` | per Privy user |
| `delete-account` | false | a Privy token (≤ 1 h old unless `DELETE_ACCOUNT_TOKEN_MAX_AGE_S` tightens it), or the wallet session with `{"method":"email-password"}` | per Privy user / wallet |
| `pin-media` | true | a wallet session, verified in code too | `edge_rate_gate` per wallet, network and overall; 20 s budget |
| `aurora-proxy` | true | a wallet session, verified in code too; quotes only to and from that wallet | `edge_rate_gate` per wallet and network |
| `waitlist` (not deployed) | false | nothing (CORS: dyorhq.fun, www.dyorhq.fun; honeypot) | `edge_rate_gate` per network (IPv6 /48) and overall |

Secrets (names only): `APP_JWT_SECRET` or `APP_JWT_SIGNING_JWK` (wallet-auth; pin-media and aurora-proxy read
`APP_JWT_SECRET` to verify HS256 sessions — secrets are project-wide), `PRIVY_APP_SECRET` (+ optional `PRIVY_APP_ID`),
`PINATA_JWT` (+ optional `PINATA_GATEWAY`), `AURORA_API_KEY` (+ optional `AURORA_FEE_RECIPIENT`, `AURORA_FEE_BPS`).
`SUPABASE_URL`, the service-role key and the publishable key are injected by the platform.

Switches (unset = the behaviour the builds in use need; each header says when to flip it):
`WALLET_AUTH_LEGACY_SIGNIN=off`, `WALLET_AUTH_SESSION_S`, `REBIND_REQUIRE_REPLACE=on`,
`DELETE_ACCOUNT_TOKEN_MAX_AGE_S=900`. "Once build N is out" always means: build N has shipped AND every older build
is expired in App Store Connect / TestFlight, or is below `app_config` `min_build` (see below).

Owner procedures (the deploy order of the hardening changes, takedowns in the public buckets, the session signing
key rotation) are in DyorHQ/internal (private): `ios-app/supabase/owner-procedures.md`.

## Tests

    deno test -A --no-config --node-modules-dir=none supabase/functions/        # unit tests, next to each function
    deno test -A --no-config --node-modules-dir=none supabase/tests/            # every migration, on a throwaway PGlite database

`--no-config` keeps the repository's Node `package.json`/`tsconfig.json` out of Deno's way. `tests/supabase_stub.sql`
stands in for the platform (roles, auth/storage/vault stubs, default privileges); nothing touches the live project.

## Minimum iOS build

`app_config` row `ios` = `{"min_build", "message", "url"}` is a server switch. A build that reads it (build 14 and
later, `ios/DyorHQ/App/UpdateGate.swift`) shows a blocking "Update required" screen (balances and key export still
work; nothing can be signed) when its CFBundleVersion is below `min_build`, and fails open on any error (migration 28
has the contract). Older builds ignore it, including the ones that hard-code retired contracts: retire those by
expiring them in App Store Connect / TestFlight. Raise it in the SQL editor:
`update public.app_config set value = jsonb_set(value, '{min_build}', '<build>') where key = 'ios';` — the CHECK
constraint refuses a row the app could not parse.

## Upload budgets (public buckets)

Migration 26: launch-media is write-once (a trigger refuses any upload over an existing object, move or rename, even
from the service role; interim exception for the same bytes under a `moment-<hash>` name until deferred 31), upload
names are pinned, and uploads are limited per wallet (40 objects and 500 MiB per 24 h) and overall (1,000 uploads and
5 GiB per 24 h, a circuit breaker). Storage checks permissions before it reads the bytes and writes the row later as
the service role, so the limits are enforced by triggers on `storage.objects` when the row is written. When the
overall budget is spent every launch-media upload fails (403) until older uploads age out; the day's total is
`select count(*), sum(bytes) from public.storage_upload_events where created_at > now() - interval '1 day';`.

## Not built yet

Server-side push delivery (a watcher with an APNs auth key), a launch indexer job, and leaderboard/stats Edge
Functions. The app computes alerts and the social views itself from the tables above.
