# DyorHQ on TestFlight — the short path

Goal: real people testing the real build through TestFlight, before any App Store submission. Everything below that
does not need Apple is already done in the repo; the rest is a sequence the owner runs once the paid membership is
active. The full App Store checklist stays in BETA-LAUNCH-CHECKLIST.md for later.

## 1. Already done in the repo (2026-09-17)

- Build number bumped to 1.1 (3); bump `CFBundleVersion` in `project.yml` before every upload.
- `ExportOptions.plist` (App Store Connect export + upload, automatic signing, symbols uploaded).
- `scripts/testflight.sh`: regenerates the project, archives in Release, exports and uploads in one go, with an
  optional App Store Connect API key for a login-free upload. Refuses to run against a local fork RPC.
- The "Coming soon" alert in Get Help is gone; the X row appears only once the handle is set.
- Privacy manifest, usage descriptions, launch screen, app icon, iPhone-only device family, export-compliance flag
  (`ITSAppUsesNonExemptEncryption = false`) are in place.

## 2. What waits on Apple

TestFlight needs the paid Apple Developer Program (individual is enough for TestFlight; the organization
requirement is an App Store review matter for wallets). While enrollment is pending nothing can be uploaded.
When the welcome email arrives:

1. Xcode → Settings → Accounts: sign in with the enrolled Apple Account. Put the team's ID in
   `DyorHQ/Config/Secrets.xcconfig` as `DEVELOPMENT_TEAM` (it replaces the Personal team).
2. Re-enable the two entitlements the Personal team could not sign, in `project.yml` under `entitlements`:
   `com.apple.developer.applesignin: [Default]` (Sign in with Apple is offered in onboarding and must work) and,
   once the domain hosts the well-known file, `com.apple.developer.associated-domains`. Then `xcodegen generate`.
3. developer.apple.com → Certificates, Identifiers & Profiles → Identifiers: register `fun.dyorhq.app` with the
   Sign in with Apple capability (automatic signing creates certificates and profiles on the first archive).
4. App Store Connect → Apps → "+": name DyorHQ, iOS, bundle `fun.dyorhq.app`, SKU `dyorhq-ios`, primary language
   English, category Finance. Add a privacy policy URL (required for the TestFlight test information too).
5. Privy dashboard: confirm the mobile client is bound to `fun.dyorhq.app` and that Apple login is configured with
   the new team; create a **test account** (email + fixed OTP) for Beta App Review.

## 3. Upload

```bash
scripts/testflight.sh
```

or with an API key (App Store Connect → Users and Access → Integrations → App Store Connect API, role App Manager):

```bash
ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx ASC_KEY_PATH=~/.private_keys/AuthKey_XXXXXXXXXX.p8 scripts/testflight.sh
```

Processing takes a few minutes. In App Store Connect → TestFlight, answer the export compliance question (the app
uses only standard encryption: TLS and wallet signatures) and the build becomes available to groups.

## 4. Testers

- **Internal group (no review, up to 100).** App Store Connect → Users and Access → add each tester (Apple Account
  email) with the Developer or App Manager role, enable TestFlight for them, then TestFlight → Internal Testing →
  create a group, add the build and the testers. They install the TestFlight app and accept the email invite.
  Best for the first days with friends and the team.
- **External group (Beta App Review, up to 10,000).** TestFlight → External Testing → create a group → add the
  build. Fill the test information (below). The first build is reviewed against the App Review Guidelines, usually
  within a day; later builds usually go straight through. Share the public link once approved. Builds expire after
  90 days.

Beta App Review is lighter than App Store review but it does reject crashes, placeholders, and logins without a
demo account. Before the external build: the Privy test account, the funded review wallet, and the in-app account
deletion and content reporting from the checklist (sections B of BETA-LAUNCH-CHECKLIST.md) should be in.

## 5. Test information (paste into App Store Connect)

**Beta app description.** DyorHQ is a self-custodial trading app for Monad: swap on the best venue, trade perps on
Perpl, launch and collect tokens and Moments, and run strategies such as Delta Neutral. Keys stay on your phone;
DyorHQ never holds funds.

**What to test.** Sign in (Apple, Google, email or import), fund the wallet with a little MON and USDC, one swap on
Trade, one small perps order, open a Moment, read Home's Total Volume and Portfolio, set up a Delta Neutral position
with $20–$50 and exit it, and check the notification center. Report anything that looks wrong or slow with a
screenshot from the TestFlight app.

**Feedback email.** support@dyorhq.fun

**Review notes (external group).** Self-custodial wallet and DeFi interface on the Monad blockchain. No custody, no
fiat, no exchange operated by us: swaps route to Kuru, Uniswap and Monday Trade contracts, perps to the Perpl
protocol, launches and Moments to our audited contracts. Test account: <email> with OTP <code> (Privy test account);
the wallet holds a few dollars of MON and USDC for a swap. Keys never leave the device; the app must stay open
while a strategy enters or exits.

## 6. Order

1. Enrollment approved → steps in section 2 → `scripts/testflight.sh` → internal group (same day).
2. Fix what internal testers hit; add account deletion and reporting; second upload.
3. External group with the test information above → public link.
