# Supabase across the whole app (2026-09-17)

Project `fmnjqrguvopusfufmirs`. Every row is keyed by the wallet and protected by row-level security on the
`wallet_address` claim of the session the `wallet-auth` function mints from one signature. The app connects that
session automatically as soon as a wallet that can sign is in use, so nothing below needs a separate step.

## What is recorded, and where it comes from

| Table | Rows | Written by | Restored on a fresh device |
| --- | --- | --- | --- |
| `profiles` | handle, display name, bio, avatar URL | **auto-created on sign-in** (`SocialSession.ensureProfile`, on every sign-in/restore) so creating an account, importing a PK, or using a passkey all seed a profile; the user edits it on the Social profile screen | yes (read) |
| `sessions` | one row per app sign-in — `signed_in_at`, `signed_out_at` | `SocialSession.openSession` on sign-in, `closeSession` on sign-out | – (analytics) |
| `activity` | every action with kind, section, title, tx hash, USD size, USD fee, time | `ActivityLog.record` → `BackendSync` (swaps `spot`, curve buys/sells + launches `launch`, perps orders `perps`, Moment publish/collect/claim `moments`, bridge `bridge`, Perps funding `deposit`/`withdraw`, external sends `withdraw`) | feeds Portfolio history + the journey rollup |
| `strategies` | delta-neutral, market-making and copied-trader records (JSON) | `DNStore` / `MMStore` / `CopyStore` saves | yes |
| `notifications` | the in-app notification center | `NotificationStore.save` | yes |
| `alerts` (`kind = price`, `payload`) | price alerts | `PriceAlertStore.save` | yes |
| `user_settings` | appearance, notification toggles, leverage, slippage, Simple/Pro | `AppSettings` changes | yes, unless the device already changed a setting |
| `device_tokens` | APNs tokens (future push) | not yet — no push server | – |
| `follows`, `posts`, `comments`, `reactions`, `watchlist`, `leaders`, `copy_*`, `referral_*`, `leaderboard`, `launches` | social graph, feed, copy trading, referrals, launch index | web app / indexer today | – |

## The user journey (rollup)

`activity` is the canonical event log for the whole journey. Two additive relations aggregate it (migration `12_user_journey`):

- **`user_journey`** (view, `security_invoker`) — **one row per user (built on `profiles`, so every signed-in wallet
  appears even before its first trade)**: username (`handle`), wallet, **`joined_at`** (profile creation), the
  session lifecycle **`first_sign_in_at` / `last_sign_in_at` / `last_sign_out_at` / `sessions_count`** (from the
  `sessions` table, migration 14), and the per-domain rollup — `spot`, `perps`, `launchpad` (+ `launches_created`),
  `moments`, `bridge`, `deposits`, `withdrawals`, `transfers`, `total_volume_usd` (the four trading surfaces only),
  `total_fees_usd`, `notifications_count`, first/last activity. **Internal analytics only** — `EXECUTE`/`SELECT` are
  revoked from `anon`/`authenticated`; query it with the service role (Supabase MCP / dashboard), not from the app.
- **`platform_journey(since)`** (security definer, publishable key) — platform totals by domain with no wallet
  exposed, mirroring `platform_volume`. The domain buckets are derived from `kind`/`section`, so bridges,
  deposits and withdrawals are counted separately from trading volume.

The classification depends on the clean `kind`/`section` the app now emits (bridge → `bridge`, Perps funding →
`deposit`/`withdraw`, external send → `withdraw`); `section='bridge'` is allowed by migration `13`.

Platform-wide volume: `platform_volume(since)` (security definer, callable with the publishable key) sums `activity.usd`
by section with no wallet exposed; the Portfolio shows it as "Everyone on DyorHQ, all time".

Account deletion removes the `profiles` row; every table above cascades from it.

## Storage

| Bucket | Path | Content |
| --- | --- | --- |
| `avatars` (public) | `<wallet>/avatar.jpg` | profile pictures (owner insert/update/delete) |
| `launch-media` (public, 50 MB, images + MP4/MOV) | `<wallet>/<uuid>.jpg` coin logos · `<wallet>/moment-<uuid>.jpg|mp4|mov` Moment photos, videos and video cover frames | NFT media the contracts point at; kept when an account is deleted because tokens on-chain reference them |

## Edge Functions

- `wallet-auth` — signature → session JWT.
- `delete-account` — deletes the Privy user for account deletion (needs `PRIVY_APP_SECRET`).
- Next: `pin-media` (IPFS pinning for Moment media, needs a Pinata key) and `opensea-refresh` (metadata refresh
  after a Moment graduates, needs an OpenSea API key). See `ios/docs/moments/NFT-OPENSEA-PLAN.md`.

## Client pieces

- `DyorKit/Services/Supabase/SupabaseClient.swift` — PostgREST read / upsert / `upsertRows` / delete, Storage
  upload and folder delete, RPC, Edge Function calls with a foreign bearer.
- `DyorHQ/Backend/BackendSync.swift` — store hooks, debounced uploads, restore.
- Migrations: `supabase/migrations/08…10` plus the ones applied through the Supabase MCP on 2026-09-17
  (`moments_video_media`, `app_sync_activity_strategies_notifications`); mirror them into files before the next
  `supabase db push`.
