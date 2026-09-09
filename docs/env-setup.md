# Environment and secrets checklist

Everything the DyorHQ apps read from the environment, where to get each value, and which file it goes in.
Nothing here is committed: `.env`, `.env.local` and `Secrets.xcconfig` are all git-ignored.

## 1. Expo app — `mainstreet-app/.env`

| Variable | Required | Where it comes from |
| --- | --- | --- |
| `EXPO_PUBLIC_PRIVY_APP_ID` | Yes, for Apple / Google / email sign-in | Privy dashboard → your app → **App ID** |
| `EXPO_PUBLIC_PRIVY_CLIENT_ID` | Yes, for Apple / Google / email sign-in | Privy dashboard → **Clients** → add a *mobile* client with bundle id `xyz.mainstreet.app` and allowed URL scheme `mainstreet`. Copy the `client-…` id. |
| `MERA_RP_ID` | Yes, for passkey wallets | The HTTPS host you control that serves `/.well-known/apple-app-site-association` (with your Apple Team ID + `xyz.mainstreet.app`) and `/.well-known/assetlinks.json`. Files live in `mainstreet-app/well-known/`. |
| `EXPO_PUBLIC_PIMLICO_BUNDLER_URL` | Optional | Pimlico dashboard → Monad bundler + paymaster URL. Enables gas-sponsored smart accounts; leave blank for a plain wallet. |
| `EXPO_PUBLIC_PERPL_BUILDER_ID` | Optional | Builder code (1–255) issued by Perpl. `0` = none. |
| `EXPO_PUBLIC_LAUNCHPAD_ADDRESS` | After you deploy | `contracts/deployments/143.json` → `launchpadFactory` |
| `EXPO_PUBLIC_LPLOCKER_ADDRESS` | After you deploy | `contracts/deployments/143.json` → `lpLocker` |
| `EXPO_PUBLIC_BACKEND_URL` | Later | Base URL of the backend that will hold the Monday Trade HMAC key and the Kuru `X-API-Key`. Not built yet; RWA acquisition throws until it exists. |
| `EXPO_PUBLIC_ONBOARDING_PREVIEW` | Dev only | `1` walks onboarding with a placeholder wallet when no Privy keys are set. Ignored in release builds. |

Sign in with Apple also needs the **Sign in with Apple** capability on the `xyz.mainstreet.app` App ID in your Apple Developer account and the same enabled in Privy → Login methods. Google needs OAuth credentials pasted into Privy → Login methods → Google (nothing goes in the app).

## 2. Native SwiftUI app — `ios/DyorHQ/Config/Secrets.xcconfig`

Copy `Secrets.example.xcconfig` to `Secrets.xcconfig` and fill in:

| Variable | Required | Where it comes from |
| --- | --- | --- |
| `PRIVY_APP_ID` | Yes | Same Privy app as above |
| `PRIVY_CLIENT_ID` | Yes | Privy dashboard → **Clients** → add a *mobile* client for bundle id `fun.dyorhq.app`, URL scheme `dyorhq` |
| `MONAD_RPC_URL` | Optional | A dedicated Monad mainnet RPC (Alchemy, QuickNode, …). Defaults to `https://rpc.monad.xyz`. |
| `PERPL_BUILDER_ID` | Optional | Same as above |
| `LAUNCHPAD_FACTORY`, `LAUNCH_ROUTER`, `FEE_ESCROW`, `HOLDER_FEE_SHARING`, `MEME_HOOK` | After you deploy | `contracts/deployments/143.json` |
| `DEVELOPMENT_TEAM` | For device builds | Xcode → Settings → Accounts → your team's **Team ID** (Personal Team while the paid enrollment is pending). Read at build time, survives `xcodegen generate`. |
| `PASSKEY_RP_ID` | Paid team only | `accounts.dyorhq.fun`, once the AASA is hosted at `https://accounts.dyorhq.fun/.well-known/apple-app-site-association`. Leave empty on a Personal Team (Associated Domains can't be signed) and keep the entitlement block in `ios/project.yml` commented out. |

## 3. Web app — `.env.local`

| Variable | Required | Where it comes from |
| --- | --- | --- |
| `NEXT_PUBLIC_MONAD_RPC` | Optional | Dedicated RPC URL; the public one is rate-limited on `eth_getLogs` |
| `NEXT_PUBLIC_LAUNCHPAD_FACTORY`, `NEXT_PUBLIC_LAUNCH_ROUTER`, `NEXT_PUBLIC_FEE_ESCROW`, `NEXT_PUBLIC_HOLDER_FEE_SHARING`, `NEXT_PUBLIC_MEME_HOOK`, `NEXT_PUBLIC_POOL_MANAGER` | After you deploy | `npm run sync:deployment` fills `app/lib/deployment.json` from `contracts/deployments/143.json`; these variables override it |
| `NEXT_PUBLIC_PAIR_TOKENS` | Optional | Comma-separated ERC-20 pair tokens you approved with `setPairEconomics` |

## 4. Contract deployment — shell environment for `forge script` (you run this; nothing is stored)

| Variable | Required | Notes |
| --- | --- | --- |
| `PRIVATE_KEY` | Yes | Deployer key. Passed as `--private-key`; becomes the owner of every contract. |
| RPC URL | Yes | `--rpc-url https://rpc.monad.xyz` or your dedicated endpoint |
| `PROTOCOL_FEE_RECIPIENT` | Optional | Treasury address; defaults to the deployer |
| `LAUNCH_FEE_WEI`, `PHANTOM_QUOTE_WEI`, `GRADUATION_THRESHOLD_WEI`, `CURVE_FEE_BPS`, `POOL_FEE_BPS`, `TICK_SPACING`, `MAX_CREATOR_TAX_BPS`, `PROTOCOL_FEE_SHARE_BPS`, `SUPPLY`, `POOL_MANAGER` | Optional | Economics overrides; defaults are in `contracts/script/Deploy.s.sol` |

## 5. Third-party keys that stay server-side (future backend)

| Key | Used for |
| --- | --- |
| Monday Trade API key + HMAC secret | Acquiring aRWA tokens for launches |
| Kuru `X-API-Key` | Kuru's authenticated endpoints (Flow quotes themselves need no key) |

Never put these in any `EXPO_PUBLIC_*`, `NEXT_PUBLIC_*` or xcconfig value: those ship inside the app bundle.

## 6. Launchpad pair assets (MON, USDC, AUSD, aBIL)

Per the RWA plan, memecoins pair with spot ERC-20s, not Monday Trade's HMAC book. Native **MON** (`address(0)`)
is approved at deploy (`contracts/script/Deploy.s.sol`, defaults: phantom 4,000 MON, graduation 16,000 MON). After
deploy, the owner approves each extra pair once with `AddPairToken.s.sol` (it reads `decimals()` on-chain; amounts
are raw token units):

```bash
# USDC (6 dec): $1,000 phantom depth, $4,000 graduation
FACTORY=0x<factory> PAIR_TOKEN=0x754704Bc059F8C67012fEd69BC8A327a5aafb603 \
  PHANTOM_QUOTE=1000000000 GRADUATION_THRESHOLD=4000000000 \
  forge script script/AddPairToken.s.sol:AddPairToken --rpc-url monad --broadcast --private-key $OWNER_KEY

# AUSD (6 dec): same shape as USDC; also Perpl collateral
FACTORY=0x<factory> PAIR_TOKEN=0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a \
  PHANTOM_QUOTE=1000000000 GRADUATION_THRESHOLD=4000000000 \
  forge script script/AddPairToken.s.sol:AddPairToken --rpc-url monad --broadcast --private-key $OWNER_KEY

# aBIL (18 dec, ~$90/token): size in aBIL, so ~$1,000 phantom ≈ 11 aBIL, ~$4,000 graduation ≈ 44 aBIL
FACTORY=0x<factory> PAIR_TOKEN=0x4fc5b9f8933597d3ecf84d0611687e1dc8dd576f \
  PHANTOM_QUOTE=11000000000000000000 GRADUATION_THRESHOLD=44000000000000000000 \
  forge script script/AddPairToken.s.sol:AddPairToken --rpc-url monad --broadcast --private-key $OWNER_KEY
```

Then expose them to the front ends:

- **Web** `.env.local`: `NEXT_PUBLIC_PAIR_TOKENS=0x754704Bc059F8C67012fEd69BC8A327a5aafb603,0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a,0x4fc5b9f8933597d3ecf84d0611687e1dc8dd576f`
- **iOS**: already wired — `Token.launchpadPairAssets` (USDC, AUSD, aBIL) is passed to `LaunchpadService.protocolInfo`,
  and the create form offers MON first, then whichever of these the factory reports as approved.

aBIL is a transferable ERC-20 in Monday Trade's **spot** AMM, so the in-app swap buys it with no partner key. This
is the honest "RWA HQ" pairing until Monday partner keys exist; in-app aNVDA/aAAPL book trading stays paused.
MetaMask USD (`mUSD` in the token list) and Monday's accounting `mUSD` (a Cashier credit, not an ERC-20) are NOT
pair assets — do not use them.
