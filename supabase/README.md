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

Every migration applied to the live project is now in `migrations/` (01–23). 01–07 and 11 were restored on 2026-09-26
from the project's own migration history (`supabase_migrations.schema_migrations.statements`), byte-for-byte — each
file's md5 equals the recorded statements' md5. Two out-of-band changes are NOT in any migration: the Strategies tables
below were dropped directly (2026-09-18), and 18's revokes supersede 11's `grant execute … platform_volume … to anon`.
Record every future schema change as a numbered migration here, so the backend can be rebuilt and audited from source.

> The Strategies feature (copy-trading, market-making, delta-neutral) was removed from the app on 2026-09-18; its
> tables (`strategies`, `leaders`, `copy_relationships`, `copy_grants`, `copy_events`) were dropped from the project.

## Still to build

`alerts`/push watcher (needs an APNs auth key), launch indexer, leaderboard/stats Edge Functions; and the remaining
iOS feature UIs (feed, follows, watchlist sync, alerts).
