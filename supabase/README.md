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
| Journey (mig. 12–13) | `user_journey` (view — per-wallet spot/perps/launchpad/moments/bridge/deposits/withdrawals rollup, `security_invoker`), `platform_journey()` (platform totals by domain) |

`activity.kind` ∈ swap, buy, sell, launch, perp, moment, **bridge**, **deposit**, **withdraw**, send; `activity.section`
∈ spot, perps, launch(pad), moments, bridge, wallet. The whole user journey — username (`profiles.handle`), wallet,
per-domain volume, deposits/withdrawals, notifications and activities — is stitched by the `user_journey` view.

The migrations are applied in the live project; export with `supabase db pull` to snapshot them into `migrations/`.

> The Strategies feature (copy-trading, market-making, delta-neutral) was removed from the app on 2026-09-18; its
> tables (`strategies`, `leaders`, `copy_relationships`, `copy_grants`, `copy_events`) were dropped from the project.

## Still to build

`alerts`/push watcher (needs an APNs auth key), launch indexer, leaderboard/stats Edge Functions; and the remaining
iOS feature UIs (feed, follows, watchlist sync, alerts).
