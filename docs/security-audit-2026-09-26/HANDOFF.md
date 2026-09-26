# Handoff: where the audit fix-up stands (2026-09-26)

The report is `REPORT.md` in this folder, and `RUNBOOKS.md` covers the steps only an owner can do. All work is on
branch `claude/kind-brown-1520k1` in each repo. None of it is merged or deployed yet.

## Done and pushed

| Repo | What |
|---|---|
| IOS-app | Owner runbooks (`RUNBOOKS.md`). |
| IOS-app | Contracts v2 fixes for MO-1, MO-2, LP-1, LP-2 and LP-3 (not deployed), plus a post-review follow-up. See `contracts/CHANGELOG-v2.md`. Tests: 167 pass; the 11 that fail are fork tests that need the Monad RPC. |
| IOS-app | Keepers for the live contracts (`contracts/keepers/`, 43/43 tests pass). |
| IOS-app | Web: the Kuru fee tuple must be zero, and retired-cohort coins and hooks are refused (PR-6 and IOST-7, web side). |
| website | Only `public/` is served. Adds privacy and terms (**drafts for legal review**), support, security, 404 (which also handles Moment links), `security.txt`, robots, sitemap and manifest. Also fixes headings and animation length (a11y), the CTA and copy, and cuts image weight by about 85%. |
| docs | New contract registry from the deployment records (62 addresses, all checked against the repo); redacted receive QR; live graduation thresholds; past cohorts and retired launchpads; the governance-link note. |

## Not done yet (pick up here)

**Batch 1: security leftovers.** The parallel agents stopped before producing work.
- **Supabase:**
  - SB-4: new migration so the pepper network limit counts only anonymous requests. The patch is in REPORT §11.
  - SB-5: `unique(wallet,id)` and `onConflict 'wallet,id'`.
  - SB-9: add `supabase/config.toml`.
  - SB-10: require a recent `iat`.
  - SB-11: trim the upstream error text returned to clients.
  - SB-2: quotas for pin-media and aurora-proxy.
  - IOSK-7: sign in with EIP-4361, with the server accepting both formats during the transition.
  - SB-6 / PR-2: exclude `moment-*` objects from the `launch_media_owner_update` storage policy.
  - LR-4: a waitlist table and Edge Function, then set `data-endpoint` on the website form.
- **Web:**
  - WEB-2: sandbox TradingView or use lightweight-charts. An unfinished attempt was discarded.
  - WEB-4: CSP-Report-Only.
  - WEB-6: a lifetime subscribe budget per socket.
  - WEB-7: warn on unlisted tokens in swap deep links.
  - RW-7: give each `useTx` run an identity.
- **iOS transactions:**
  - PR-4: hash before broadcast, then poll by hash.
  - GL-2 / GL-3: record transactions at "sent".
  - IOST-1: fee ceiling for every wallet.
  - IOST-2: bind the economics hash to the terms shown.
  - IOST-6: sign Permit2 after Confirm.
  - IOST-7: Kuru fee tuple check on iOS, matching the web rule.
  - IOST-14: show unlimited approvals.
  - IOSK-10: Mera prompt-free policy fails closed.
  - IOST-3: bridge deposit address.
- **iOS keys and privacy:**
  - IOSK-4: App Lock on by default for new installs.
  - IOSK-8: block third-party keyboards.
  - IOSK-12: Mera address hint into the Keychain.
  - IOSK-13: a privacy window over sheets.
  - IOST-12: mark discovered tokens as unverified.
  - AI-13: spell out hex for VoiceOver.
  - PR-2: video poster.
  - MO-4: pending-policy warning.
  - IOSK-2: client-side part.
  - LR-1: a Privacy row in the app's Get Help and Profile screens, pointing to `https://dyorhq.fun/privacy`.

**Docs repo leftovers:**
- GE-7: recovery claims. Email & Password wallets can now export their key.
- GL-8: FAQ and bridge copy. The app now shows a View link on sent rows.
- LR-9: screenshot placeholders and alt text.
- LR-8: recompress the mockups.
- LR-7: add a security page.
- `.gitignore` and `SECURITY.md`.

**Batches 2 to 4:** reliability (GT, GL, RI, RO, RS and GE items), then the remaining Low/Info items, then
accessibility and UI (AI, AW and UI items). The full list with locations is in REPORT §5–6, under status "Open".

## Working rules used so far

- Read the finding and the cited code before changing anything. If a finding no longer reproduces, say so.
- Build iOS changes in Xcode and run the DyorKit tests. The cloud sandbox had no Swift compiler.
- Web: `npm test`, `npx tsc --noEmit -p .` and `npx eslint <files>`.
- Contracts: `forge test --offline`.
- SQL: test migrations before `supabase db push`.
- Live systems are read-only until the owner deploys: never apply migrations to production, never broadcast
  transactions.
- Commits end with the `Co-Authored-By` and `Claude-Session` trailers used on this branch.
