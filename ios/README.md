# DyorHQ for iOS

The native SwiftUI app. It talks to Monad mainnet directly (JSON-RPC and Multicall3), quotes swaps across Kuru
Flow, Uniswap v3/v4 and Monday Trade, trades perpetuals on Perpl's on-chain exchange, and drives the DyorHQ
launchpad once its contracts are deployed. Sign-in and the embedded wallet come from Privy; transactions are
signed on the device and broadcast by the app itself, so Monad never needs to be on Privy's hosted-network list.

## Layout

```
ios/
├─ project.yml            XcodeGen spec (run `xcodegen generate` after editing)
├─ Package.resolved       package pins the Xcode Cloud build uses (see Xcode Cloud below)
├─ ci_scripts/            Xcode Cloud post-clone script that generates the project in the cloud checkout
├─ DyorHQ/                the app target (SwiftUI, iOS 18+)
│  ├─ App/                entry point, environment, root view, cross-tab router
│  ├─ Config/             Secrets.example.xcconfig → Secrets.xcconfig (git-ignored), AppConfig
│  ├─ Design/             shared components (logos, amounts, change badges, confirmation rows)
│  ├─ Onboarding/         welcome, sign-in, email code, watch-only address
│  ├─ Home/ Launchpad/ Swap/ Perps/ Profile/
│  ├─ Wallet/             Session (Privy), PrivyWallet signer, TransactionRun + ConfirmationSheet
│  └─ Resources/          asset catalog (monochrome accent, semantic colors, wordmark, icon), privacy manifest
└─ DyorKit/               Swift package with everything testable without a simulator
   ├─ Core/               Keccak-256, ABI codec, JSON-RPC client, Multicall3, RLP, formatting
   ├─ Chain/              Monad constants, token list, ERC-20, transaction preparation and sending
   └─ Services/           Perpl, Swap (Kuru, Uniswap, Monday, wrap), Prices, Launchpad
```

## Build and run

1. Install XcodeGen once: `brew install xcodegen`.
2. `cp DyorHQ/Config/Secrets.example.xcconfig DyorHQ/Config/Secrets.xcconfig` and fill in the Privy app id and the
   mobile client id created for bundle id `fun.dyorhq.app` with URL scheme `dyorhq` (see
   `DyorHQ/internal: ios-app/docs/env-setup.md`).
   Without them the app still runs: sign-in shows what is missing and **Watch an Address** works.
3. `xcodegen generate`, open `DyorHQ.xcodeproj`, pick a simulator or device, run.

Command line:

```bash
xcodebuild -project DyorHQ.xcodeproj -scheme DyorHQ -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Package tests (fast, no simulator): `cd DyorKit && swift test`. The fixtures under `Tests/DyorKitTests/Fixtures`
were generated with viem and real `eth_call`s against Monad mainnet, so encoders are checked against the reference
implementation and decoders against live contract output.

Passkey accounts (Mera) in the Simulator: no real passkey can associate with `accounts.dyorhq.fun` there, so a Debug
Simulator build launched with `-MeraStubAuthenticator` uses a stub provider instead of the system sheet
(`DyorHQ/Wallet/Mera/StubPasskeyAuthenticator.swift`, compiled out of every other build). Its PRF secrets are random per
install, and it refuses to run unless the build points at a local fork (`MONAD_RPC_URL=http://127.0.0.1:8545`). An
optional mode after the argument reproduces a provider case: `full` (default), `unsupported`, `deferred` or `single`.

```bash
xcrun simctl launch booted fun.dyorhq.app -MeraStubAuthenticator single
```

Mera parity: the Swift port in `DyorKit/Sources/DyorKit/Services/Mera` is derived from `@category-labs/mera` 0.2.0
(credited in `THIRD_PARTY_NOTICES.md` at the repo root). `scripts/mera-parity` checks it against the published package,
pinned exactly with `@scure/bip39` and `@scure/bip32` 2.3.0. A fake WebAuthn client stands in for the passkey, so the
check needs no authenticator and no network once installed. It reads the vectors from `MeraTests.swift` and recomputes
each one with the library: the default salt; for PRF `0x000102…1f` the 24-word phrase, seed, index-0 and index-1 keys
and addresses, and the vault key; and the vault the Swift test seals, which Mera must decrypt. It exits non-zero on any
difference. Run it after changing anything in the port or its vectors. It needs Node 22 or later; npm warns that Mera
asks for 24, and the check passes on 22 and 23.

```bash
# from the repo root
cd scripts/mera-parity && npm ci --ignore-scripts --no-audit --no-fund && npm run parity
```

## Xcode Cloud

The DyorHQ workflow archives `ios/DyorHQ.xcodeproj` on every push to `main`. That project is git-ignored, so
`ci_scripts/ci_post_clone.sh` creates it in the cloud checkout: it installs the pinned XcodeGen, writes
`Secrets.xcconfig` from the workflow's environment variables, runs `xcodegen generate`, and copies the pinned
`Package.resolved` into the project (Xcode Cloud never resolves packages on its own).

- Environment variables: App Store Connect → Xcode Cloud → Manage Workflows → DyorHQ → Environment. Add
  `PRIVY_APP_ID` and `PRIVY_CLIENT_ID` with Secret ticked, plus any optional key the script lists. The Aurora API key
  is not a build variable: it lives only in the `aurora-proxy` Edge Function's secrets, so it never ships in the app.
  Enter plain values (no quotes, URLs as-is). An archive fails without the two Privy ids, because sign-up needs them;
  any other missing value switches its feature off, exactly as in a local build.
- After changing a package requirement in `project.yml` or `DyorKit/Package.swift`, run `scripts/pin-packages.sh`
  and commit `Package.resolved`; the cloud build fails with an out-of-date resolved file until the pins match.

## Design rules

- Apple's system: SF Pro through text styles (Dynamic Type), SF Symbols, system semantic colors, `List`, `Form`,
  sheets with detents, `ContentUnavailableView` for empty states, `.refreshable`, Swift Charts.
- Palette from `public/brand/dyorhq-design-system.md`: the accent is the text/canvas pair inverted (ink on paper,
  paper on ink), Positive #126A4B / #77D8AC, Negative #AD3047 / #F496AA, Attention #775812 / #E4C67D. No decorative
  accent. Gains and losses always carry a sign or a word, never color alone.
- The serif wordmark asset is the identity; the app icon is its D on paper.
- Copy: title case for buttons and titles, sentence case for everything else, no exclamation marks, numbers use
  tabular figures, every write ends in a confirmation sheet that shows exactly what will be sent.

## What needs the owner

- Privy keys (and a Privy mobile client for `fun.dyorhq.app`), Sign in with Apple capability on that App ID, and
  Google credentials configured in the Privy dashboard.
- The passkey host `accounts.dyorhq.fun` (the constant `Mera.relyingParty`) serving the AASA file for `fun.dyorhq.app`,
  and Associated Domains enabled on that App ID.
- Launchpad contract addresses after deployment (`LAUNCHPAD_FACTORY` and friends).
