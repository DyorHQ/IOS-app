# DyorHQ — TestFlight beta and App Store checklist

Status: 2026-09-17. Built from the current App Store Review Guidelines (quoted where they bite), Apple's TestFlight
help, the two shared threads (12 rejection reasons; 5-app shipping checklist), the Grok plan, and an audit of the
project as it is today. Boxes are unchecked until done and verified.

## A. Blockers before anything can be uploaded

- [ ] **Apple Developer Program, enrolled as an organization.** Guideline 3.1.5(i): "Wallets: Apps may facilitate
      virtual currency storage, provided they are offered by developers enrolled as an organization." An individual
      enrollment can build and TestFlight, but the wallet features are a rejection risk at review. Organization
      enrollment needs a legal entity, a D-U-N-S number and 2–4 weeks. If the pending enrollment is individual,
      start the organization one now (same Apple Account can be converted; Apple Developer Support handles it).
- [ ] **A live dyorhq.fun.** Today the domain resolves to Hostinger parking (nameservers pixel/byte.dns-parking.com)
      and, from Ghana, an ISP sinkhole. App Store Connect needs working privacy policy and support URLs; the Help
      screen links to dyorhq.fun/support and /terms; Mera and Privy universal links need
      `/.well-known/apple-app-site-association`. Host a small site: `/privacy`, `/terms`, `/support`, the AASA file.
- [ ] Registered bundle ID `fun.dyorhq.app` in the team, `DEVELOPMENT_TEAM` set in `Secrets.xcconfig`, automatic
      signing with a Distribution certificate + App Store profile.
- [ ] App Store Connect app record: name, primary language, bundle ID, SKU, Finance category.

## B. Guideline items specific to DyorHQ

- [ ] **Perps.** 3.1.5(iv) says apps "facilitating … cryptocurrency futures trading … must come from established
      banks, securities firms, futures commission merchants … or other approved financial institutions", and 3.2.2
      (viii) says derivatives apps "must be properly licensed in all jurisdictions". DyorHQ is a self-custodial
      interface to Perpl's on-chain protocol; Apple has passed wallet apps that open DEX perps, but it is the single
      biggest review risk here. Decision needed: ship Perps in the first review build (and say so plainly in the
      review notes: non-custodial, third-party protocol, no fiat, no order book operated by us), or feature-flag it
      off for the first review and enable it in a later build.
- [ ] **Moments and NFT purchases.** 3.1.1: "Apps may use in-app purchase to sell … services related to non-fungible
      tokens … Apps may allow users to view their own NFTs … Apps may allow users to browse NFT collections owned by
      others, provided that, except for apps on the United States storefront, the apps may not include buttons,
      external links, or other calls to action that direct customers to purchasing mechanisms other than in-app
      purchase." Buying and minting Moments with USDC in-app is outside what the text allows. Options: view-only
      Moments (own and browse) in the review build with collecting done on the web app; or ship it and accept the
      rejection risk. Launchpad token launches are not NFTs and are not covered by this paragraph.
- [ ] **Account deletion (5.1.1(v)).** "If your app supports account creation, you must also offer account deletion
      within the app." Missing today. Add Profile → Delete account: delete the Privy user (Privy API), the Supabase
      profile and rows, the local stores and Keychain items; for local/imported wallets show the export warning first.
- [ ] **Sign in with Apple (4.8).** Present (Apple, Google, Email via Privy). Keep it first in the list.
- [ ] **User-generated content (1.2).** Profiles (handle, bio, avatar), launch images and Moment images are UGC. Add:
      a Report action on profiles, launches and Moments (Supabase `reports` table + email alert), Block/hide creator,
      a basic filter on handles and text (profanity list), and published contact info (support@dyorhq.fun already
      in Help). Reply to reports within 24 hours during the beta.
- [ ] **Completeness (2.1).** Remove the "Coming soon" alert on the X row in Get Help (hide the row until the handle
      exists). No placeholder screens elsewhere; check every deep link and external link.
- [ ] **Demo account for review (2.1).** Privy dashboard → Test accounts: a review email with a fixed OTP; fund that
      wallet with a little MON and USDC on mainnet; write the review notes: self-custodial, keys on device, no custody,
      what each tab does, how to run a $5 swap, how the strategy tab works, that funds are the reviewer's own test funds.
- [ ] **Screenshots (2.3.3)** from the current UI on a 6.9" iPhone: Home, Trade, Perps, Moments, Strategy (Delta
      Neutral Simple mode), Portfolio. Regenerate after every visible change.
- [ ] **Privacy.** Nutrition labels in App Store Connect: email (Privy sign-in), wallet address, usage data (Supabase
      events), crash data (if Sentry). No tracking. `PrivacyInfo.xcprivacy` exists (UserDefaults CA92.1); add
      `NSPrivacyCollectedDataTypes` for the above and re-check required-reason APIs after adding Sentry.
- [ ] **Encryption export.** `ITSAppUsesNonExemptEncryption = false` is correct for standard TLS and signature
      cryptography; answer the export compliance questions the same way on each upload.
- [ ] **Age rating** questionnaire (expect 17+ for an unrestricted trading/wallet app); content rights; no IAP.
- [ ] iPhone-only is set (`TARGETED_DEVICE_FAMILY` 1). Do not mark iPad support unless it is tested.

## C. Backend and operations (from the Grok plan, adjusted to what exists)

- [ ] Supabase: tables for `profiles` (exists), `transactions` (type, amount, chain, status, tx hash, wallet,
      created_at), `events` (event name, jsonb metadata), `reports`; RLS on all, wallet-address policies (the
      existing pattern). Insert after every swap, perps order, deposit, withdrawal, launch, Moment, strategy step.
- [ ] Crash and error reporting: Sentry (sentry-cocoa) with a DSN in `Secrets.xcconfig`, `SentrySDK.start` at app
      launch, a hidden test crash in Settings for the beta; never attach keys, phrases or full addresses.
- [ ] RPC and price caching already in place; add a status banner when the RPC or Perpl gateway is down.
- [ ] Rate limits on any edge function (gas drip, reports); leaked-password protection is not applicable (Privy).
- [ ] A support inbox that someone reads (support@dyorhq.fun) and the X handle.

## D. Build, upload, TestFlight

- [ ] Bump `CFBundleVersion` on every upload (1.1 (3) next); `MARKETING_VERSION` 1.1 for the beta.
- [ ] Archive: `xcodebuild -project DyorHQ.xcodeproj -scheme DyorHQ -configuration Release -destination
      'generic/platform=iOS' -archivePath build/DyorHQ.xcarchive archive` then `-exportArchive` with an
      `ExportOptions.plist` (`method: app-store-connect`, `destination: upload`), or Xcode Organizer → Distribute.
- [ ] First processing in App Store Connect; answer export compliance; fix any missing-manifest or signing warnings.
- [ ] TestFlight test information: beta description, what to test, feedback email, privacy policy URL.
- [ ] Internal group first (up to 100 App Store Connect users, no review). Then an external group (up to 10,000):
      the first build goes through Beta App Review; later builds usually do not. Builds expire after 90 days.
- [ ] Public link with a tester cap once internal testing is stable; TestFlight 2.3+ collects screenshots and feedback
      in-app.
- [ ] Release notes for every build; keep a "what to test" list per build (swap, perps order, Moments, a small
      delta-neutral run, notifications, account deletion).

## E. QA before the first upload

- [ ] Real devices: iPhone 17 Pro Max plus an older/smaller model; Face ID and passcode paths; light and dark mode;
      largest Dynamic Type; airplane mode and RPC-down states; low-MON gas states; fresh install and re-login.
- [ ] Every external link and deep link (dyorhq: scheme for Privy OAuth) works; no dead URLs.
- [ ] Sign in, sign out, delete account, re-sign in; watch-only wallet paths.
- [ ] A full delta-neutral entry and exit with a small real amount on mainnet (the fork rehearsal was done; a mainnet
      run is the remaining check).
- [ ] Notifications permission flow and the in-app center.
- [ ] Crash-free session across all tabs for 30 minutes on device.

## F. Order of work

1. Organization enrollment + domain + legal pages (in parallel, mostly waiting time).
2. Account deletion, UGC reporting/blocking, Coming-soon removal, review demo account, Sentry, Supabase event logging.
3. Decide Perps and Moments scope for the review build; screenshots and listing.
4. Archive, upload, internal TestFlight; fix; external group with Beta App Review; public link.
