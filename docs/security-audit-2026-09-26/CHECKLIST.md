# DyorHQ security audit checklist (2026-09-26)

Scope: DyorHQ/IOS-app (iOS app, DyorKit, Next/vinext web app, Cloudflare worker, Supabase
migrations + Edge Functions, Foundry contracts, scripts, CI), DyorHQ/website, DyorHQ/docs,
DyorHQ/accounts-domain.

## A. Secrets and leak surface
- A1 Private keys, mnemonics, JWT secrets, service-role keys, API tokens (Pinata, Privy app secret,
  Kuru, Aurora, APNs, App Store Connect) in the tree or anywhere in git history (all branches).
- A2 Secrets that reach a client: `NEXT_PUBLIC_*`, iOS Info.plist / xcconfig / bundled resources,
  web build output, source maps, website/docs assets.
- A3 Secrets written to logs, crash reports, analytics, error toasts, clipboard, pasteboard,
  screenshots, iCloud/iTunes backups, UserDefaults, temp files.
- A4 `.gitignore` coverage (.env*, *.pem, xcconfig secrets, broadcast/ run logs from forge).
- A5 Deployment/relaunch scripts: keys passed on the command line (visible in ps / shell history),
  keys echoed, keys written to disk.

## B. Backend (Supabase, the "vibe-coded app" failure modes)
- B1 RLS enabled on every table; no `using (true)` on write policies; no policy that trusts a
  client-supplied column (user_id / wallet) instead of the JWT claim.
- B2 Grants: anon/authenticated can't INSERT/UPDATE/DELETE/TRUNCATE what they shouldn't; views
  don't bypass RLS (`security_invoker`), materialized views not exposed.
- B3 SECURITY DEFINER functions: `search_path` pinned, EXECUTE revoked from anon/public, argument
  checks against `auth.jwt()`; no dynamic SQL built from input.
- B4 Storage buckets: public vs private, per-object owner checks on upload/overwrite/delete,
  listing, content-type/size limits, path traversal in object names.
- B5 Edge Functions: authn on every mutating function, JWT signature + expiry + audience checks,
  signature/nonce replay protection, CORS policy, rate limiting / brute force (email OTP, pepper
  oracle), SSRF in proxies, error messages leaking internals, service-role key scope.
- B6 Custom JWT minting: secret strength, `exp`, `aud`, `role`, claims derived only from verified data.
- B7 Account deletion actually deletes (GDPR/App Store 5.1.1(v)) and can't be triggered for others.

## C. Authentication and sessions
- C1 Sign-in nonce is server-issued, single-use, short-lived, bound to address + domain + chain.
- C2 Message signed for login can't be replayed as a transaction or on another service
  (EIP-191 / EIP-4361 domain binding).
- C3 Email/password wallet derivation: KDF strength, offline guessing, pepper handling, lockout
  that can't be abused to lock someone out.
- C4 Passkeys / WebAuthn (Mera): RP ID, apple-app-site-association, challenge freshness,
  user verification.
- C5 OAuth (Apple/Google via Privy): state/nonce, token validation, redirect handling.
- C6 Session expiry, sign-out clears keychain and caches, account switching isolation.

## D. iOS app / wallet
- D1 Key storage: Keychain accessibility class (ThisDeviceOnly, WhenUnlocked), Secure Enclave,
  biometry (`.biometryCurrentSet`), no keys in UserDefaults/files/logs.
- D2 Mnemonic generation entropy (SecRandomCopyBytes), BIP-39 checksum, BIP-32/44 derivation.
- D3 Recovery phrase / private key export: auth gate, screenshot/screen-recording protection,
  clipboard expiry, background snapshot blur.
- D4 Transaction signing: chain ID, EIP-155, EIP-1559 fields, nonce handling, what-you-see-is-
  what-you-sign, typed-data (EIP-712) domain + content validation before signing (Perpl, Permit2).
- D5 Token approvals: unlimited approvals, approval to the right spender, Permit2 expiry/amount.
- D6 Slippage / min-out / deadline on swaps, launchpad buys/sells, bridge quotes.
- D7 Network: ATS exceptions, HTTPS only, no plain-HTTP RPC, certificate trust, JSON parsing of
  untrusted responses (integer overflow, amounts), RPC response trust (failover).
- D8 WebViews: JS bridges (`WKScriptMessageHandler`), `javaScriptEnabled` on untrusted content,
  navigation to arbitrary URLs, file:// access, injected HTML from API data.
- D9 Deep links / universal links / URL schemes: parameter validation, no signing triggered by
  a link, open-redirects.
- D10 Third-party data rendered in UI (token names, NFT metadata, news): spoofing, homoglyphs,
  malicious URLs.
- D11 CI/build: ci_scripts, secrets in Xcode Cloud logs, entitlements, provisioning.

## E. Web app and worker
- E1 XSS: `dangerouslySetInnerHTML`, unsanitized URLs in `href`/`src` (javascript:), token
  metadata rendering.
- E2 Proxies (`app/api/perpl`, worker WebSocket bridge): open proxy / SSRF, path traversal,
  header forwarding, abuse / DoS amplification, CORS.
- E3 Security headers: CSP, frame-ancestors / X-Frame-Options, HSTS, Referrer-Policy,
  Permissions-Policy, nosniff.
- E4 Dev-only code shipped to prod (dev wallet key from `NEXT_PUBLIC_*`, fork RPCs).
- E5 Open redirects (`returnTo`), SSRF, auth header trust (`oai-authenticated-*`).
- E6 Dependency CVEs (npm, SwiftPM pins, submodules).

## F. Smart contracts (Launchpad + Moments on Monad)
- F1 Access control on owner/admin functions; two-step ownership; role separation.
- F2 Reentrancy (ETH/MON transfers, hooks, ERC-721/1155 callbacks), CEI.
- F3 Arithmetic: rounding direction, precision loss, overflow in unchecked blocks, fee math.
- F4 Bonding curve / graduation: price manipulation, sandwiching, graduation griefing, dust,
  first-depositor issues, locked liquidity really locked.
- F5 Uniswap v4 hooks: permission bits, `beforeSwap` return deltas, fee extraction, who can call.
- F6 Refund/expiry paths: double-claim, claim after graduation, stuck funds.
- F7 External calls to untrusted tokens (fee-on-transfer, rebasing, return-value).
- F8 Signature / permit replay, front-running of create / collect.
- F9 Deployed-address config matches reviewed source; deployment JSON integrity.

## G. Process / org
- G1 Public repos exposing internal runbooks, wallet addresses, infra IDs that aid attackers.
- G2 apple-app-site-association correctness (webcredentials for passkeys).
- G3 Website forms (email capture): where data goes, injection, spam.

## H. Race conditions, concurrency, state integrity (tweet 1)
- H1 Double submission: repeated taps / retries sending a swap, trade, launch, collect, bridge deposit,
  send, or edge-function call twice (duplicate on-chain tx = duplicate spend).
- H2 Nonce races between concurrent sends (approve + swap, parallel flows), replacement/stuck txs.
- H3 Out-of-order async responses: stale quote shown/signed for a different amount/token/route,
  stale balances/allowances, cancelled Tasks still writing state.
- H4 Actions left enabled while an operation is in flight; missing idempotency on backend writes.
- H5 Effects, subscriptions, WebSocket listeners, timers not cleaned up (web + iOS).
- H6 Cache invalidation, multi-device / multi-account state bleed, poor-network behaviour.

## I. Reliability and failure handling (tweet 1)
- I1 Swallowed errors (`try?`, empty catch), silent failures, unhandled promise rejections.
- I2 Infinite loading, missing timeout/offline/error/empty/partial-success states.
- I3 Partial success leaving inconsistent state (approve ok + swap fail; on-chain ok + backend
  sync fail; upload ok + pin fail; account deletion half-done).
- I4 Assumptions on API shape/nullability/ordering; unbounded memory; hot loops.

## J. Accessibility (tweet 1, WCAG 2.2 AA)
- J1 iOS: accessibilityLabel on icon-only buttons, Dynamic Type (fixed font sizes), 44pt targets,
  Reduce Motion, colour-only meaning (green/red P&L), VoiceOver on sheets/toasts/charts.
- J2 Web: semantic landmarks/headings, labels, alt text, keyboard/focus, contrast, reduced motion.

## K. Visual and interaction consistency (tweets 1, 5, 6)
- K1 Design tokens vs hard-coded colours/spacing/radii/fonts; inconsistent shared components.
- K2 Missing hover/pressed/disabled/loading/error states; empty states ("No data").
- K3 Copy/terminology drift, number/date/currency formatting, truncation of long names/addresses.
- K4 Haptics on confirmations, icon family consistency, onboarding friction.

## L. Ops and org hygiene (tweets 2, 3)
- L1 Every API key/credential's scope (least privilege): Supabase service role, Pinata JWT, Aurora,
  Privy app secret, App Store Connect, deployer/owner wallets.
- L2 Rate limiting + bot protection on every public route (edge functions, worker, Perpl relay,
  storage uploads); trim API responses (no internal detail).
- L3 Webhook handlers and signature verification (any inbound webhooks?).
- L4 Map every AI/LLM call and what it can touch; prompt-injection guardrails.
- L5 Backups (Supabase PITR/daily) restore-tested and documented; incident runbook ("prod DB leaked
  tonight"); key-rotation runbook.
- L6 Secrets baked into build artefacts (vinext bundle, Xcode archive, Docker images).
- L7 Dependency CVEs (npm audit, SwiftPM pins).

## M. Website launch readiness (tweet 4) — DyorHQ/website, web app
- Custom 404, meta title/description per page, favicon set, robots.txt, sitemap.xml, Open Graph
  image, alt text, mobile breakpoints, loading/form-error/thank-you states, privacy policy, terms,
  cookie banner (only if cookies/analytics), analytics, real contact address, compressed images.
