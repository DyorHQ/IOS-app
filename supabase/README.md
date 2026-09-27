# DyorHQ backend (Supabase)

Backs the *social trading HQ* features only — push & price alerts, social (profiles/follows/feed/comments/
leaderboards/referrals), a launch-discovery index, and cross-device sync. The core app stays
self-custodial and on-chain; **no private keys or the Perpl Ed25519 secret are ever stored here.**

- **Project:** `DyorHQ` · ref `fmnjqrguvopusfufmirs` · region eu-west-1 · Postgres 17
- **URL:** `https://fmnjqrguvopusfufmirs.supabase.co`
- **App keys (safe to embed):** publishable key `sb_publishable_s1G3ns-jmzTfnFs7rTvdbQ_8FJYODhT` (RLS protects data).
  Wired into the iOS app via `AppConfig` (defaults; overridable with `SupabaseURL` / `SupabaseKey` in Secrets.xcconfig).

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
| Audit 2026-09-26 (mig. 24–29) | `app_config` (public, read-only: `ios.min_build`), `waitlist`, `upload_blocklist`, `storage_upload_events` (launch-media's overall budget), `edge_rate_events` / `edge_rate_salt` (owner-only rate ledger); triggers `dyorhq_storage_upload_gate` and `dyorhq_launch_media_write_once` on `storage.objects` |

`activity.kind` ∈ swap, buy, sell, launch, perp, moment, **bridge**, **deposit**, **withdraw**, send; `activity.section`
∈ spot, perps, launch(pad), moments, bridge, wallet. The whole user journey — username (`profiles.handle`), wallet,
per-domain volume, deposits/withdrawals, notifications and activities — is stitched by the `user_journey` view.

Every migration applied to the live project is now in `migrations/` (01–22); 23–29 (security audit 2026-09-26) are
written but not yet applied. `migrations-deferred/` holds two that must wait for an app build AND for every older build
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
| `waitlist` | false | nothing (CORS: dyorhq.fun, www.dyorhq.fun; honeypot) | `edge_rate_gate` per network (IPv6 /48) and overall |

Secrets (names only): `APP_JWT_SECRET` or `APP_JWT_SIGNING_JWK` (wallet-auth; pin-media and aurora-proxy read
`APP_JWT_SECRET` to verify HS256 sessions — secrets are project-wide), `PRIVY_APP_SECRET` (+ optional `PRIVY_APP_ID`),
`PINATA_JWT` (+ optional `PINATA_GATEWAY`), `AURORA_API_KEY` (+ optional `AURORA_FEE_RECIPIENT`, `AURORA_FEE_BPS`).
`SUPABASE_URL`, the service-role key and the publishable key are injected by the platform.

Switches (unset = the behaviour the builds in use need; each header says when to flip it):
`WALLET_AUTH_LEGACY_SIGNIN=off`, `WALLET_AUTH_SESSION_S`, `REBIND_REQUIRE_REPLACE=on`,
`DELETE_ACCOUNT_TOKEN_MAX_AGE_S=900`. "Once build N is out" always means: build N has shipped AND every older build
is expired in App Store Connect / TestFlight — no build reads `app_config` yet, so raising `min_build` alone changes
nothing for the builds in use.

### Deploying the audit changes (order matters)

1. Apply migrations 23–29 in order, as `postgres` (none is live yet: checked read-only 2026-09-27), and run each
   file's "Verify after apply" queries. 26 is safe for the builds in use (a same-media retry still works; see its
   header). Apply nothing from `migrations-deferred/`.
2. Deploy the functions only after that: `wallet-auth`, `pin-media`, `aurora-proxy` and `waitlist` fail closed (503)
   without `edge_rate_gate` (migration 27) — wallet-auth only for a first sign-in — and `waitlist` also needs 29.
   `email-pepper`, `email-rebind` and `delete-account` need only migration 20, which is live (24 changes the pepper
   limits inside the database, whatever function version runs).
3. Before deploying `aurora-proxy`, set `AURORA_FEE_RECIPIENT` (and `AURORA_FEE_BPS` if not 10), or confirm the
   integrator fee is configured on the key in Aurora Studio: the proxy no longer forwards the app's `appFees`.
4. Leave the switches unset. Flip each one, and apply 30 / 31, only once its build is out (see above).

## Tests

    deno test -A --no-config --node-modules-dir=none supabase/functions/        # unit tests, next to each function
    deno test -A --no-config --node-modules-dir=none supabase/tests/            # every migration, on a throwaway PGlite database

`--no-config` keeps the repository's Node `package.json`/`tsconfig.json` out of Deno's way. `tests/supabase_stub.sql`
stands in for the platform (roles, auth/storage/vault stubs, default privileges); nothing touches the live project.

## Minimum iOS build

`app_config` row `ios` = `{"min_build", "message", "url"}` is a server switch only: **no build reads it yet**. A build
that implements it shows a blocking "Update required" screen (balances and key export still work; nothing can be
signed) when its CFBundleVersion is below `min_build`, and fails open on any error (migration 28 has the contract).
Builds without the check — every build so far, including the 12-and-earlier builds that hard-code retired contracts
(GP-2) — ignore it: retire those by expiring them in App Store Connect / TestFlight. Raise it in the SQL editor:
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

## Takedown (public buckets)

Objects in `avatars` and `launch-media` are public, and launch-media is write-once with no owner delete (on-chain
pointers must keep resolving), so removing content is an owner action:

1. Block the wallet from uploading to either bucket (SQL editor, as postgres; it also stops uploads already under way):
   `insert into public.upload_blocklist (wallet, reason) values (lower('0x…'), '<why, date>') on conflict (wallet) do nothing;`
2. Delete the object through Storage, never with SQL on `storage.objects` (that orphans the file): Dashboard → Storage →
   the bucket → the wallet's folder → Delete.
3. For Moment media also pinned to IPFS, unpin the CID in the Pinata dashboard. The on-chain URI stays; other IPFS
   nodes may still serve it.
4. Record what was removed and why, and answer the report (the security/support contact published on dyorhq.fun).

## Session signing key (OH-7)

wallet-auth signs sessions with the project's legacy JWT secret (`APP_JWT_SECRET`), which also signs the legacy anon
and service-role API keys and is shared by every function. Note what a dedicated key does NOT change: PostgREST and
Storage trust any key in the project's JWT signing keys for any `role` claim, so `APP_JWT_SIGNING_JWK` can mint a
service-role token just as the legacy secret can, and must be guarded the same way. What the move buys is that the
session key can be rotated and revoked on its own, and that the legacy secret can then be retired. OH-7 stays open
until it is revoked (step 6). The project's JWKS already lists two ES256 keys (read 2026-09-27), so the move to JWT
signing keys has been started in the dashboard: check its state before step 2. Owner, dashboard; no downtime,
reversible until the last step:

1. `supabase gen signing-key --algorithm ES256` on a trusted machine, outside any repository; keep the private JWK
   offline as the backup. (`*.jwk`, `signing_keys.json` and the CLI's `.temp/` and `.branches/` are git-ignored in
   `supabase/`, but do not rely on that.)
2. Dashboard → Settings → JWT Keys: if the project is still on the legacy secret only, "Migrate JWT secret" first; then
   create a new standby key by importing that private JWK (same `kid`).
3. "Rotate keys" so the imported key is in use; the legacy secret moves to "previously used" and stays trusted, so
   existing sessions keep working. This project does not use Supabase Auth for users, so nothing else changes.
4. Set the secret from a file, never on the command line (a command line lands in shell history and the process
   list): write `APP_JWT_SIGNING_JWK=<the private JWK JSON on one line>` to a new file outside the repository with mode
   0600 (`umask 077` first), run `supabase secrets set --env-file <that file>`, then delete the file. Redeploy
   wallet-auth. New sessions are ES256 with that `kid`; check one sign-in, a PostgREST read, an upload, a pin-media
   call and a bridge quote. pin-media and aurora-proxy verify ES256 sessions in code against the project's JWKS; if
   the gateway's verify_jwt refuses them (401 before the function runs), redeploy those two with `--no-verify-jwt` —
   the in-code check still admits only a valid wallet session — or unset `APP_JWT_SIGNING_JWK` to go back to HS256.
5. After the session lifetime (12 hours unless `WALLET_AUTH_SESSION_S` is shorter), `supabase secrets unset
   APP_JWT_SECRET`. pin-media and aurora-proxy then treat any HS256 token as no session (403), which is intended: no
   HS256 session is valid any more.
6. Revoke the legacy secret. This needs the functions moved to the new secret API keys first (they use the legacy
   service-role key) — a separate step. Only then is OH-7 closed.

## Still to build

`alerts`/push watcher (needs an APNs auth key), launch indexer, leaderboard/stats Edge Functions; and the remaining
iOS feature UIs (feed, follows, watchlist sync, alerts).
