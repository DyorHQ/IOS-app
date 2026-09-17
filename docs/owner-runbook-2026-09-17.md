# DyorHQ owner runbook — the actions only you can do (2026-09-17)

Verified by an 11-agent research + adversarial-verification pass on 2026-09-17 (read-only; no transactions sent, no
secrets printed). Every on-chain reading below was reproduced on https://rpc3.monad.xyz. This supersedes the Path A
steps in docs/launchpad-redeploy-2026-09-17.md, which were incomplete (they never mentioned Moments).

Two answers up front:
- **OpenSea API key: NOT necessary.** Moments already render on OpenSea with no key (verified live). The key only
  buys a forced metadata refresh after graduation and, later, floor/listing data. Drop it from the launch list.
- **"Web deploy": not a web app.** It is 4-5 static files the iOS app itself depends on. It is NOT a TestFlight
  blocker, but it is what makes passkeys, the App Store URLs, and the NFT's outbound link work. Detail in §5.

---

## 1. Privy app secret (account deletion) — has a hidden blocker

Setting the secret alone will NOT work. The deployed Edge Function has a stale, invalid PRIVY_APP_ID baked in as a
fallback (`cmfvfr7ey01asjy0b24ky37ln`, which Privy rejects), different from the committed code
(`cmttp2squ00lk0djrso3z0yvm`, the real DyorHQ app). It fetches the token-verification key for that app id BEFORE it
checks the secret, so every call 401s regardless of the secret. You must set PRIVY_APP_ID too.

1. Privy dashboard → DyorHQ app → Configuration → App settings → Basics. Copy the **App secret** (regenerate if it
   was never saved — Privy does not store it). Copy the **App ID** from the same page. Do not paste either into the
   repo, Xcode, or chat.
2. Supabase → project `fmnjqrguvopusfufmirs` → Edge Functions → Secrets
   (https://supabase.com/dashboard/project/fmnjqrguvopusfufmirs/functions/secrets). Add two secrets:
   `PRIVY_APP_SECRET` = the secret, and `PRIVY_APP_ID` = the app id. Save. (Secrets inject at runtime — no redeploy
   needed for them to take effect.)
3. Ask the engineer to redeploy the function once so prod matches the repo:
   `supabase functions deploy delete-account --no-verify-jwt --project-ref fmnjqrguvopusfufmirs`.
4. **Do not test with a bogus token** — it 401s either way and proves nothing. Real test: sign in with a throwaway
   email in the app, confirm the user appears in Privy → Users, then Profile → Delete Account in the app, then
   confirm that user is gone from the Privy list. If it fails, read the function logs.
5. **Apple caveat.** Apple OAuth is currently disabled on your Privy app, so Sign in with Apple's
   delete-must-revoke-token rule (Guideline 5.1.1(v)) is dormant and you are safe to ship. Keep it disabled for the
   beta. If you enable Apple login later, get Privy's written answer on whether user-delete calls Apple's
   `/auth/revoke`, and add a "also remove DyorHQ under Settings → Sign in with Apple" line to the deletion screen.

The engineer also has two AccountDeletion.swift fixes to make (the wallet-deletion copy overstates Privy's soft
delete; a 401 mid-flow can leave a half-deleted account) — those are on the engineering side, not yours.

## 2. Treasury / fee wallets — bigger than the launchpad doc said

The leaked key (`0x5282cC04…`) is **owner/governance of nothing** — governance everywhere is `0xCf7A9f1D…`, so this
is a revenue-routing fix, not an emergency. Residual funds in the wallet are 0.254 MON and nothing else. BUT the
same address is the **Moments treasury** on the live v1.1 factory, which the launchpad doc never covered, and that
path has a 48-hour timelock. Do 1 and 2 today (both instant, both close a currently-open channel).

All commands are **owner-executed by you** from an encrypted keystore or Ledger — never a raw key in a shell.
`RPC=https://rpc3.monad.xyz`, `NEW_TREASURY=0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371`.

1. **Launchpad fee recipient** (instant; retroactively repoints even already-launched tokens — the recipient is read
   live at payout). The launchpad is OPEN to the public right now (whitelist off, 5 MON launch fee), so every launch
   pays the leaked address until this lands:
   ```bash
   cast send 0x10F34A174d9C393a90aFf94BDED7E1Db185446D7 "setFeePolicy(address,uint16)" $NEW_TREASURY 5000 --rpc-url $RPC
   ```
2. **Pause Moments publishing** before starting the timelock, so nothing new freezes the compromised treasury during
   the 48h window:
   ```bash
   cast send 0x64698c7702d85F87f43a6dFF7D495CDD2327C020 "setPublishingPaused(bool)" true --rpc-url $RPC
   ```
3. **Propose the new Moments policy** (starts the 48h clock). This tuple is the exact current policy with BOTH the
   treasury and the platform wallet updated — do both in one call or you pay a second 48h timelock. (Platform moves
   from `0xf4D4baF6…` to the new fees wallet `0x15ED3bb4…`; if you would rather leave platform as-is, keep
   `0xf4D4baF6…` in that slot.)
   ```bash
   cast send 0x64698c7702d85F87f43a6dFF7D495CDD2327C020 \
     "proposePolicy((uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,address,address))" \
     "(10000000,100000,2000,500,7500,1000,7000,500,0x15ED3bb488231213b141A2f78b62358D52235Cd7,0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371)" \
     --rpc-url $RPC
   cast call 0x64698c7702d85F87f43a6dFF7D495CDD2327C020 "pendingPolicyAt()(uint64)" --rpc-url $RPC   # clock started
   ```
4. **Moment #1: do nothing.** It has the compromised address frozen as its treasury immutably (no setter). At most
   ~0.16 USDC could ever route there if it expires. Trying to graduate it to avoid that is not worth it: it would
   cost ~$12.63, needs 7 transactions (batch cap is 20 editions), and a stuck graduation would hand the leaked key
   ~3 USDC instead. Let it be.
5. **Sweep the residual MON** (leave real gas headroom — send ~0.24, not 0.25, since fees are ~202 gwei):
   ```bash
   cast send $NEW_TREASURY --value 0.24ether --rpc-url $RPC   # signed by the LEAKED key, its last-ever use
   ```
   Then destroy that key material and never fund `0x5282cC04…` again.
6. **After 48h:** apply the policy and reopen publishing:
   ```bash
   cast send 0x64698c7702d85F87f43a6dFF7D495CDD2327C020 "applyPolicy()" --rpc-url $RPC
   cast send 0x64698c7702d85F87f43a6dFF7D495CDD2327C020 "setPublishingPaused(bool)" false --rpc-url $RPC
   ```
7. Optional housekeeping (not breach-driven — this wallet was never leaked): MondayFeeVault lpFeeRecipient
   `cast send 0x42a1C1c1d6BC2544d3f478E4d42F5b5ec75888De "setLpFeeRecipient(address)" 0x15ED3bb488231213b141A2f78b62358D52235Cd7 --rpc-url $RPC`.
8. Path A vs Path B: **Path A** (these setters) is correct. Path B (full redeploy) buys nothing here — the leaked
   key held no authority and no launch has pinned the old recipient. The engineer then updates the address records
   and re-ships the iOS app (MomentsModels.swift carries the treasury literal, though no app logic reads it).

## 3. IPFS pinning (Pinata) — necessary, do before TestFlight

A Moment's media URI is written once at publish and can never be changed by anyone, including governance. Today it
is a public Supabase URL. `momentCount()` is 1, so only one Moment is affected so far — but TestFlight is exactly
when that count goes from 1 to N, and each becomes permanent the instant it publishes. "Lasts forever on the
blockchain" is only true if the media is content-addressed.

1. Create a **Pinata** account (or Filebase / Storacha). Create an API key scoped to `pinFileToIPFS` only. Note the
   JWT and your dedicated gateway domain. Free tiers cover a beta; paid is ~$20/mo.
2. Give the engineer the JWT (as a Supabase secret) and the gateway domain. They add a `pin-media` Edge Function
   that pins each upload and writes `ipfs://<CID>` on-chain, keeping the Supabase copy as the fast mirror (the app
   already resolves `ipfs://`). This is a dual-write, so nothing else changes.
3. Because Moment #1 already depends on Supabase forever: keep the project (`fmnjqrguvopusfufmirs`) on the Pro plan
   with a card on file and never migrate it to a new project ref.

## 4. OpenSea API key — skip it

Not needed. Verified live: the Moment NFT serves its own on-chain metadata (image, animation, traits, ERC-2981
royalty, ERC-7572 collection), `monad` is a first-class OpenSea chain, and the "Spectacular" collection already
renders with its photo and all 7 editions at
`https://opensea.io/item/monad/0x1f247c933e903354E51f60a0708Ac686ddCf9DE0/1` with no key. The contract already emits
the ERC-4906 refresh event OpenSea documents as the primary way to be notified, and OpenSea offers an anonymous
"Refresh Metadata" button as the manual fallback. A key would only add a forced-refresh API call and floor/listing
data — post-launch polish. If you ever want it, it is self-serve and free at opensea.io/settings/developer.

Two real risks the OpenSea check surfaced, both independent of the API key:
- The "Spectacular" test collection's media is a still from *The Wolf of Wall Street* — a DMCA/delisting risk if it
  is the collection shown to beta users. Fine as a throwaway; do not demo on it.
- Before leaning on an "earn from royalties" marketing line, confirm OpenSea actually enforces the 5% (it is set on
  chain, but OpenSea enforces creator earnings via its Royalty Registry, and no figure shows on the live page yet).

## 5. The "web deploy" — 4-5 static files, and why an iOS app needs them

You are right that there is no web app to ship. `app/` (the Next.js project) has none of the routes the iOS app
needs and the app never calls dyorhq.fun for data — deploying it would be more work for less of what you need. What
the iOS launch needs is a handful of static files on any static host (Cloudflare Pages recommended):

- `/.well-known/apple-app-site-association` — Mera passkeys need it. Without it the associated-domains entitlement
  keeps its `?mode=developer` suffix, which does NOT work in a distribution (TestFlight) build, so passkeys break on
  real devices. Content: `{"webcredentials":{"apps":["<TEAMID>.fun.dyorhq.app"]}}`, served over HTTPS at the apex,
  `Content-Type: application/json`, no `.json` extension, behind **no redirect**.
- `/privacy` and `/terms` and `/support` — App Store Connect will not accept the app record without a privacy policy
  URL, and the in-app Get Help screen links all three. Support must show real contact info (team@dyorhq.fun + a legal
  address).
- `/moments/<id>` — every Moment NFT's `external_url` points here. Today it points at `dyorhq.app` (NOT registered —
  NXDOMAIN), so all 7 editions show a dead website link on OpenSea right now.
- `/export` — the Privy embedded-wallet key-export page (the iOS SDK has no native export).

Steps:
1. Create the files. Point DNS: dyorhq.fun is parked at Hostinger (nameservers byte/pixel.dns-parking.com). For
   Cloudflare Pages, move the nameservers to Cloudflare and add the apex as a custom domain. Serve the apex directly
   — never redirect apex → www (Apple refuses an AASA behind any redirect).
2. Verify the AASA from OFF your network (your ISP sinkholes dyorhq.fun at TLS, so your own curl will lie):
   `https://app-site-association.cdn-apple.com/a/v1/dyorhq.fun`. Get this right BEFORE the first TestFlight build —
   Apple's CDN caches a failed fetch.
3. Only after the page is live and verified, make the Moments external-link governance call — in this order, or you
   cache a dead link:
   ```bash
   cast send 0x64698c7702d85F87f43a6dFF7D495CDD2327C020 "setExternalBaseURI(string)" "https://dyorhq.fun/moments/" --rpc-url $RPC
   ```

## 6. The item that actually gates everything: paid Apple enrollment

None of the above uploads a build. The one true critical path is the **paid Apple Developer Program**: today
`DEVELOPMENT_TEAM` is still the free Personal team, the Sign-in-with-Apple and associated-domains entitlements are
commented out, and there is no App Store Connect record. Start enrollment today if you have not — Individual is enough
for TestFlight; Organization (needs a D-U-N-S number, 2-4 weeks) is what App Store review wants for a wallet app, so
begin the Organization conversion in parallel. Everything else in this runbook can be done while it processes.

Other owner-only items before the first EXTERNAL TestFlight group (internal testing of up to 100 needs none of them):
create the team@dyorhq.fun mailbox and the @DyorHQ_ X account (both are linked unconditionally in-app; a dead link is
a rejection); fund a review wallet with a few dollars of MON + USDC; decide whether Perps and in-app Moment collecting
ship in the first reviewed build or are flagged off (the biggest rejection risk); and commission the UGC report/block
work (Guideline 1.2 — none exists yet). Push notifications (APNs .p8) and Sentry are nice-to-have and do not block.
