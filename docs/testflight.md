# Shipping DyorHQ to TestFlight

The repo is already set up for this: `scripts/testflight.sh` archives a Release build and uploads it to App Store
Connect in one step, `ExportOptions.plist` is configured for `app-store-connect` upload, export compliance is
pre-answered (`ITSAppUsesNonExemptEncryption: false`), and signing is automatic. What's left is one-time Apple
account setup, then a single command per build.

- **Bundle ID:** `fun.dyorhq.app`
- **Current version / build:** `1.1 (3)` (in `ios/project.yml`)
- **Min iOS:** 18.0 · **iPhone only**

---

## Phase 0 — one-time account setup

### 1. Confirm your paid Team ID is set
Your paid Apple Developer **Team ID is `96X7N58MVV`**, and it's already set as `DEVELOPMENT_TEAM` in
`ios/DyorHQ/Config/Secrets.xcconfig` (gitignored — everything downstream reads it from there). Nothing to change.
If you ever need to verify it: <https://developer.apple.com/account> → **Membership details** → **Team ID**.

### 2. Sign Xcode into the paid account
Xcode → **Settings → Accounts → +** → add the Apple ID that holds the paid membership. This lets automatic signing
create the Distribution certificate and App Store provisioning profile for you.

### 3. Register the App ID (with Associated Domains)
<https://developer.apple.com/account> → **Certificates, Identifiers & Profiles → Identifiers → +** →
**App IDs → App** → Bundle ID **explicit** `fun.dyorhq.app`.
- Under Capabilities, tick **Sign in with Apple** (Enable as a primary App ID; the app's entitlement needs it) and
  **Associated Domains** (for passkeys later).
- Save. (Automatic signing *can* create the App ID, but enabling Associated Domains here up front avoids a signing
  failure on the first archive.)

### 4. Create the app record in App Store Connect
<https://appstoreconnect.apple.com> → **Apps → + → New App** → iOS → Name `DyorHQ`, primary language, Bundle ID
`fun.dyorhq.app`, SKU e.g. `dyorhq-ios`. (No screenshots/metadata needed for TestFlight.)

### 5. Create an App Store Connect API key (for CLI upload)
App Store Connect → **Users and Access → Integrations → App Store Connect API → +** → role **App Manager** →
Generate. Download the `.p8` (it downloads **once**). Note the **Key ID** and **Issuer ID**, then:
```
mkdir -p ~/.private_keys && mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.private_keys/
```

---

## Phase 1 — build & upload (repeat per build)

### 6. Pre-flight the config
- `ios/DyorHQ/Config/Secrets.xcconfig`: `DEVELOPMENT_TEAM` = `96X7N58MVV` (already set), and `MONAD_RPC_URL` points
  at **mainnet**.
- The script guards the RPC for you: it **aborts if Secrets points at a `127.0.0.1` fork** (so you never ship a
  local-fork build).
- **Build number is automatic:** the script bumps `CFBundleVersion` on every run (3 → 4 → …) so you can't hit the
  "duplicate build" rejection. Pin an exact number with `BUILD=7`, or keep the current one with `NO_BUMP=1`. Commit
  the bumped `project.yml` with your release.

### 7. Run the upload
```
cd ios
ASC_KEY_ID=XXXXXXXXXX \
ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
ASC_KEY_PATH=~/.private_keys/AuthKey_XXXXXXXXXX.p8 \
scripts/testflight.sh
```
This runs `xcodegen generate`, archives Release for a generic iOS device, then exports + uploads to App Store
Connect. First run also auto-creates the Distribution cert + App Store profile (needs step 2 or the API key).

> Fallback if CLI signing misbehaves: open `DyorHQ.xcodeproj` in Xcode, select **Any iOS Device**, **Product →
> Archive**, then in the Organizer **Distribute App → App Store Connect → Upload**. Same result, Xcode handles certs.

---

## Phase 2 — in App Store Connect

8. Wait a few minutes for **processing** (you'll get an email; the build shows under **TestFlight**).
9. **Export compliance:** already declared in Info.plist, so there's no per-build question. (If ever asked: standard
   encryption / HTTPS only → **exempt**.)
10. **Internal testing (fastest, no review):** TestFlight → **Internal Testing** → add testers (they must be users on
    your App Store Connect team, max 100) → they install via the **TestFlight** app. Available minutes after
    processing. Great for you + a small circle.
11. **Public link = the "just download it" path (this is what you want for real users).** TestFlight →
    **External Testing** → create a group → add the build → fill **Test Information** (what to test + a contact
    email) and a **privacy policy URL** → **Submit for Beta App Review** (usually < 24h, lighter than full App Store
    review). Once approved, enable **Public Link** — now *anyone* installs from a single URL (up to 10,000 testers),
    no per-tester invite, no account on your team. That URL is the iOS equivalent of handing out an APK.
    - Heads-up for a wallet app: Beta App Review does look at crypto/wallet apps (guidelines 3.1.5 / 4.7). Keeping it
      self-custodial with no in-app fiat purchase of crypto is the smooth path; have the privacy policy URL ready.

---

## Project-specific callouts (don't get surprised)

- **Passkeys (Mera) won't work in TestFlight yet — and that's expected.** The entitlement uses
  `webcredentials:$(PASSKEY_RP_ID)?mode=developer`, which only associates on a Developer-Mode device, not in
  TestFlight. It uploads fine and the app runs; **all other Privy sign-in methods work**. To turn passkeys on later:
  host the AASA at `https://dyorhq.fun/.well-known/apple-app-site-association`, then remove `?mode=developer` from
  `com.apple.developer.associated-domains` in `ios/project.yml` (the comment there spells it out) and re-upload.
- **Privacy manifest:** Apple may email an *informational* ITMS warning about required-reason APIs (e.g.
  `UserDefaults`). It does **not** block TestFlight, but add a `PrivacyInfo.xcprivacy` before an App Store submission.
- **Sign in with Apple (Guideline 4.8):** on. `com.apple.developer.applesignin` is in `project.yml`'s entitlements and
  the capability is enabled on the `fun.dyorhq.app` App ID. Apple and Google sign-in show only when
  `SOCIAL_LOGINS_ENABLED = YES` (Secrets.xcconfig, or the Xcode Cloud workflow environment), and always together.
- **Secrets stay on device / in the build config** — `scripts/testflight.sh` never prints them; keep the `.p8` and
  `Secrets.xcconfig` out of git (both already are).
