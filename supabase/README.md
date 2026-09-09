# DyorHQ backend (Supabase)

Backs the *social trading HQ* features only — push & price alerts, social (profiles/follows/feed/comments/
leaderboards/referrals), a launch-discovery index, cross-device sync, and hybrid copy trading. The core app stays
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
| Copy trading (hybrid) | `leaders`, `copy_relationships` (mode signal\|auto + caps), `copy_grants` (encrypted, no-read), `copy_events` |

`copy_grants` holds only a follower's *trade-scoped* Perpl key (can't withdraw), encrypted, with **no SELECT policy** —
only the service role decrypts it to mirror trades. The migrations are applied in the live project; export with
`supabase db pull` to snapshot them into `migrations/`.

## Still to build

`alerts`/push watcher (needs an APNs auth key), launch indexer, copy-trade watcher/executor, leaderboard/stats
Edge Functions; and the remaining iOS feature UIs (feed, follows, watchlist sync, alerts, copy trading).
