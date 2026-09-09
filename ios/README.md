# DyorHQ for iOS

The native SwiftUI app. It talks to Monad mainnet directly (JSON-RPC and Multicall3), quotes swaps across Kuru
Flow, Uniswap v3/v4 and Monday Trade, trades perpetuals on Perpl's on-chain exchange, and drives the DyorHQ
launchpad once its contracts are deployed. Sign-in and the embedded wallet come from Privy; transactions are
signed on the device and broadcast by the app itself, so Monad never needs to be on Privy's hosted-network list.

## Layout

```
ios/
├─ project.yml            XcodeGen spec (run `xcodegen generate` after editing)
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
   mobile client id created for bundle id `xyz.dyorhq.app` with URL scheme `dyorhq` (see `docs/env-setup.md`).
   Without them the app still runs: sign-in shows what is missing and **Watch an Address** works.
3. `xcodegen generate`, open `DyorHQ.xcodeproj`, pick a simulator or device, run.

Command line:

```bash
xcodebuild -project DyorHQ.xcodeproj -scheme DyorHQ -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Package tests (fast, no simulator): `cd DyorKit && swift test`. The fixtures under `Tests/DyorKitTests/Fixtures`
were generated with viem and real `eth_call`s against Monad mainnet, so encoders are checked against the reference
implementation and decoders against live contract output.

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

- Privy keys (and a Privy mobile client for `xyz.dyorhq.app`), Sign in with Apple capability on that App ID, and
  Google credentials configured in the Privy dashboard.
- A passkey relying-party domain serving the AASA file for `xyz.dyorhq.app` (`PASSKEY_RP_ID`).
- Launchpad contract addresses after deployment (`LAUNCHPAD_FACTORY` and friends).
