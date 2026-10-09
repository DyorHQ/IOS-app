# App wiring — what every screen of the iPhone app reads and writes

DyorHQ is a SwiftUI iPhone app (`ios/DyorHQ`) over a Swift package (`ios/DyorKit`). It talks to Monad mainnet
(chain id 143) directly: plain JSON-RPC over HTTPS to the keyless public endpoints, `rpc.monad.xyz` first and
`rpc1.monad.xyz` as failover (`Monad.publicRPCs` in `ios/DyorKit/Sources/DyorKit/Chain/Monad.swift`; the client in
`Core/RPCClient.swift` batches up to 40 calls per request and fails over on 429/5xx). Contract reads are bundled into
one `eth_call` through Multicall3 `aggregate3` at `0xcA11bde05977b3631167028862bE2a173976CA11` (`Core/Multicall.swift`);
event history is `eth_getLogs` on `rpc1.monad.xyz` (`LaunchpadService.defaultLogsRPC`). Every write is a plan of
`TransactionStep`s that a `ConfirmationSheet` (`ios/DyorHQ/Wallet/TransactionRun.swift`) hands to `TransactionSender`
(`Chain/Transactions.swift`): each step is simulated with `eth_call`, gas-estimated (+20%), priced EIP-1559, signed on
the phone by the session's wallet, broadcast with `eth_sendRawTransaction` and polled for its receipt. The signer is one
of `PrivyWallet` (Privy's embedded wallet: email code, Apple, Google), `LocalWallet` (an imported key or the email +
password key, in the iPhone Keychain) or a Mera passkey session (`Wallet/Mera/`, key derived from the passkey's PRF
output, never stored). No DyorHQ server signs or relays transactions. The only backend is Supabase
(`Services/Supabase/SupabaseClient.swift`): PostgREST reads with the publishable key, writes under a wallet session
minted by the `wallet-auth` Edge Function from a `personal_sign` over a single-use nonce, row-level security by wallet.

Tabs: Home, Launch, Trade (Swap | Perps), Moments (`ios/DyorHQ/App/RootView.swift`). The side menu adds Portfolio,
News and Get Help; Home's header opens Profile and Notifications (`App/Router.swift`). Paths below are relative to
`ios/DyorHQ/` for screens and `ios/DyorKit/Sources/DyorKit/` for services.

## Home

| Screen | Reads | Writes | Source |
| --- | --- | --- | --- |
| Home | Balances of MON, of the curated list and of every held token, read with `ERC20.balances` through Multicall3; held tokens found from the wallet's incoming `Transfer` logs (6,480,000-block window). Prices from `PriceService`: Uniswap v4 `StateView` / v3 `slot0`, Nad.fun v2 reserves, and for DyorHQ coins their own curve or pool (`DyorVenue`); the 24h change re-reads at the day-ago block (`BlockClock`). Perpl account and positions (`getAccountByAddr`, `getPosition`). Newest launches (`launchListing`), the wallet's Moments (`MomentsService.portfolio`), Total Volume from `PortfolioModel`, logos from `GET api.kuru.io/api/v1/markets`. Polls every 30 s. | None of its own. Sheets: Receive (QR); Send (native or ERC-20 `transfer`); Transfer (Spot ↔ Perps: approve AUSD → `createAccount` / `depositCollateral`, buying the missing AUSD with MON first when short; `withdrawCollateral` the other way); Bridge (below). | `Home/HomeView.swift`, `Home/TransferSheet.swift`, `Home/AddFundsCard.swift`, `Services/Prices/`, `Services/WalletTokenDiscovery.swift` |
| Token page | Price and 24h change, a 24-hour history (48 Multicall3 reads at past blocks, Swift Charts), the wallet's balance, and the coin's launch or Moment when it is a DyorHQ coin (`DyorCoinRegistry`, read from the factories themselves). | None; Buy / Sell open Swap on the pair, or the Launch page when the coin still trades on a curve. | `Home/HomeView.swift`, `Services/DyorCoins/DyorCoinRegistry.swift` |
| Bridge | Aurora Intents Swap API through the `aurora-proxy` Edge Function (wallet session; the Aurora key stays server-side): `tokens`, `quote`, `status`. Balances on the source chains from public RPCs (`eth_getBalance`, Multicall3 `balanceOf`; `EVMChain.supported`). `BridgeTracker` polls the status and the destination balance until the funds land. | The source-chain deposit, signed on the phone with a `TransactionSender` bound to that chain's id and RPC (one side is always Monad); `submitDeposit` to Aurora through the proxy. | `Bridge/*.swift`, `Services/Aurora/`, `Chain/EVMChain.swift`, `supabase/functions/aurora-proxy/` |

## Launch

| Screen | Reads | Writes | Source |
| --- | --- | --- | --- |
| Board and coin page | Factory and curve state through Multicall3 on the live v2 stack (factory `0x3B1f5f562f5F61B980aBfDDbebD6cdF9a73b0b5b`) and the four retired stacks: `getLaunches`, `getLaunchedToken`, curve `price` / `getReserves` / `quoteBuy` / `quoteSell`, `HolderFeeSharing` and `FeeEscrow` balances. Per coin: curve fills from `CurveBuy` / `CurveSell` logs over the last 24 h (candles in Swift Charts) and the holder count from the token's `Transfer` logs (6,480,000 blocks). Pair-token prices from `PriceService`. | Buy (approve the pair token if ERC-20, curve `buy`); Sell (approve, curve `sell`); Launch (factory `launchToken` with the launch fee in MON, or router `launchAndBuy` with a developer buy; the fee and economics hash shown are re-checked before signing); Retry graduation (`graduate`); Claim rewards (`HolderFeeSharing.claim`); Claim creator fees (`FeeEscrow`). Coin image: upload to the Supabase bucket `launch-media` under the wallet session. Retired stacks are sell-only. | `Launchpad/LaunchpadView.swift`, `Services/Launchpad/LaunchpadService.swift`, `LaunchpadContracts.swift`, `LaunchpadEvents.swift`, `RetiredLaunchpads.swift`, `contracts/src/` |
| Launch profile | The wallet's curve positions and PnL (own fills, up to 30 days), the coins it launched, claimable creator fees per stack escrow and holder rewards per coin, its launchpad activity (1,512,000-block window). | Claim one asset, one coin's rewards, or everything (`claimEscrowPlan`, `claimRewardsPlan`). | `Launchpad/LaunchpadProfileView.swift`, `Services/Launchpad/LaunchpadPortfolio.swift` |

## Trade

| Screen | Reads | Writes | Source |
| --- | --- | --- | --- |
| Swap | Quotes from every venue at once (`SwapEngine`): Kuru Flow (`POST ws.kuru.io/api/quote`, JWT from `/api/generate-token`), Uniswap v3 `QuoterV2` and v4 `V4Quoter` / `StateView`, Monday Trade `QuoterV2` — the contract quotes via Multicall3, 20 s budget per venue, refreshed every 15 s. Balances and prices. Token picker: tokens the wallet acquired (`KnownTokenStore`), every token with a pool on Uniswap v3/v4 or Monday (pool-creation logs from genesis, `VenueTokenList`), Kuru's token directory (`GET api.kuru.io/api/v1/tokens/search`), or a pasted address (`ERC20.metadata`). History: the local activity log merged with the wallet's `Transfer` logs (`SwapHistoryService`, 24H / 7D / 30D). | The chosen venue's plan: approvals, then the venue router call (`docs/swap-spec.md`); MON ↔ WMON `deposit` / `withdraw`. | `Swap/SwapView.swift`, `Trade/TradeView.swift`, `Services/Swap/`, `Services/SwapHistory.swift`, `Services/VenueTokensService.swift` |
| Perps · on chain | Perpl's Exchange contract via Multicall3: `getPerpetualInfo`, `getMarginFractions`, `getAccountByAddr`, `getPosition`, `getPerpOrderLocks` / `getOrderIdIndex` / `getOrder`; the wallet's AUSD balance and allowance. | `createAccount` / `depositCollateral` after an AUSD approval, `withdrawCollateral`, `execOrders` for market and limit orders, reduce-only closes, cancels and added margin, `allowOrderForwarding(true)` for one-click trading. | `Perps/PerpsView.swift`, `Perps/PerpTradeView.swift`, `Services/Perpl/PerplService.swift`, `PerplExchange.swift` |
| Perps · Perpl API | REST, no auth: `GET app.perpl.xyz/api/v1/pub/context` (24h, volume, OI, funding) and `…/v1/market-data/{id}/candles/{res}/{from}-{to}`. Market-data WebSocket `wss://app.perpl.xyz/ws/v1/market-data` (heartbeat, market state, order book, trades). With an enrolled trading key: the trading WebSocket `wss://app.perpl.xyz/ws/v1/trading` (open orders, keeper triggers, positions) and Ed25519-signed history (`/v1/trading/fills`, `/v1/trading/position-history`, `/v1/trading/account-history`). Chart: TradingView Lightweight Charts bundled in `Resources/Web/`, fed by Perpl's candles. | Through the trading socket, once a key is enrolled: market / limit orders and take-profit / stop-loss as `mt:22` frames (keeper-managed triggers; the contract has none). Enrollment: `POST …/v1/api-key/payload` → the wallet signs the validated EIP-712 digest → the Ed25519 key is kept in the Keychain (a passkey account derives it per session). | `Perps/PerpsPortfolioView.swift`, `Perps/TradingViewChart.swift`, `Wallet/PerplTrading.swift`, `Services/Perpl/PerplFeed.swift`, `PerplTradeClient.swift`, `PerplAuth.swift`, `PerplHistory.swift` |

## Moments

| Screen | Reads | Writes | Source |
| --- | --- | --- | --- |
| Board, Moment page, portfolio | The v2 contracts (factory `0x95eb7F5A88B10D9dF32aC54F48C767927fa80840`) through Multicall3: `policy` / `termsHash`, `momentCount`, `getMoment`, Collect `ledger` / `state` / `quote`, Vesting `claimable` / `entitlement`, the graduation record and the pool's `slot0` via `PoolManager.extsload`; NFT holders (`ownerOf`). The wallet's history from `Collected` / `Claimed` / `Withdrawn` / `FeesWithdrawn` / `Published` logs since the deploy block. Media from IPFS gateways or the Supabase mirror, size-capped (`RemoteMedia`). Share links `dyorhq.fun/moments/<name>` (universal links) resolve through `MomentDirectory`. | Publish (factory `publish(params, expectedTermsHash)`); Collect (approve USDC → Collect `collect`); Claim / Claim all (Vesting `claim` / `claimAll`); creator proceeds and pool-fee withdrawals; platform / treasury withdrawals; retry graduation; expire; buyback. Media: upload to the `launch-media` bucket, then the `pin-media` Edge Function pins it to IPFS; the on-chain URI is `ipfs://<cid>` and the file's keccak-256 is recorded. | `Moments/*.swift`, `Services/Moments/`, `contracts/src/moments/`, `supabase/functions/pin-media/` |
| Past cohorts | Cohorts 1–3 (claim-only) read from their own contracts: vested coins, creator proceeds and pool fees still owed. | `claim`, `withdrawCreator`, the hook's creator-fee withdrawal — nothing else. | `Moments/RetiredMomentDetailView.swift`, `Portfolio/PastCohortsCard.swift`, `Services/Moments/RetiredMoments.swift` |

## Portfolio, Profile and the rest

| Screen | Reads | Writes | Source |
| --- | --- | --- | --- |
| Portfolio (menu) | Volume, fees and P&L per section: Spot from the wallet's `Transfer` logs (up to 90 days), Perps from Perpl's signed fills and position history, Launch from own curve fills and claims, Moments from the Moments logs (live and retired cohorts), Bridge from the local `BridgeStore`. Assets: every held ERC-20 (Multicall3 balances, discovery from `Transfer` logs) and ERC-721 (the four-topic `Transfer` logs among the transfers into the wallet its history store holds, then `ownerOf`, `tokenURI`; no scan of their own). | None; rows navigate to their section. | `Portfolio/PortfolioModel.swift`, `Portfolio/AssetsModel.swift`, `Services/WalletNFTDiscovery.swift` |
| Profile (header) | The wallet's `profiles` row (PostgREST), Recent Activity (local log merged with launchpad activity and 7-day swap scans), Perpl trading status, price-alert count, the RPC host. | Send (native transfer or ERC-20 `transfer`; the recipient is checked with `eth_getCode`). DyorHQ Social: sign in (`wallet-auth`), upsert `profiles` (handle, display name, bio), avatar to the `avatars` bucket. Settings mirrored to `user_settings`. Perpl: enroll or remove the trading key, enable one-click trading. Export: the Keychain key behind Face ID, Privy's export page in a `WKWebView`, or a passkey account's recovery phrase. Delete account: the `delete-account` Edge Function (a Privy token, or the wallet session for an email + password account), the `email_accounts` row, then everything on the device. Sign-out closes the `sessions` row. | `Profile/ProfileView.swift`, `Profile/Settings.swift`, `Profile/RecentActivityView.swift`, `Profile/AccountDeletion.swift`, `Social/SocialSession.swift`, `Social/SocialProfileView.swift`, `Wallet/WalletExportView.swift` |
| Notifications (bell) | The in-app center (`NotificationHub`, on device). While the app is open, `AlertCenter` checks price alerts every 30 s against `PriceService` and open Perpl positions for margin warnings (`PerpRisk`), fills and closes. There is no push server: local notifications only. | Local `UNUserNotificationCenter` posts; the center and price alerts are mirrored to the `notifications` and `alerts` tables. | `Notifications/*.swift`, `Wallet/Notifications.swift`, `Wallet/PriceAlerts.swift`, `Services/Notifications/` |
| News (menu) | The public RSS feeds of CoinDesk, Cointelegraph, Decrypt, The Defiant and The Block, fetched directly; articles open on the publisher's site. | None. | `News/NewsView.swift`, `Services/News/NewsService.swift` |
| Onboarding | Sign-in: Privy (email code, Apple, Google; Privy passkeys when enabled); a Mera passkey (WebAuthn PRF, rpId `accounts.dyorhq.fun`, when `PasskeysEnabled`); email + password (PBKDF2 1,000,000 rounds, the `email-pepper` Edge Function's HMAC, HKDF → secp256k1 key in the Keychain, bound to the wallet through `email-rebind`); an imported phrase or private key (derived on device, Keychain); or watch-only. | Nothing on chain. After sign-in: the backend session (`wallet-auth`), a `profiles` row, a `sessions` row. | `Onboarding/OnboardingView.swift`, `Onboarding/ImportWalletView.swift`, `Wallet/Session.swift`, `Wallet/Mera/`, `Chain/EmailWallet.swift`, `Services/Mera/` |
| Get Help, side menu | Links to the docs (`dyorhq.gitbook.io/docs`), dyorhq.fun and X. | None. | `Support/GetHelpView.swift`, `Menu/SideMenuView.swift`, `Core/DocsLinks.swift` |

## Charts

* Perps: TradingView's Lightweight Charts engine, bundled in `Resources/Web/chart.html` and
  `lightweight-charts.standalone.production.js` and rendered in a `WKWebView` with no network access of its own
  (`Perps/TradingViewChart.swift`); every candle comes from Perpl's REST candles above.
* Launch coin pages (candles built from `CurveBuy` / `CurveSell` fills) and Home token pages (the 24-hour price history)
  use Swift Charts.

## Build configuration

`Config/AppConfig.swift` reads build-time values from `Secrets.xcconfig` through `Info.plist`: the Privy app and client
ids, the social-login and passkey switches, the Perpl builder id, the Supabase URL and publishable key (with working
defaults), the wallet-export page and the bridge fee recipient. Contract addresses are baked into DyorKit
(`LaunchpadAddresses.monadMainnet`, `MomentsAddresses.monadMainnet`); a Debug build may point the RPC and the stacks at
a local fork, a Release build never reads those overrides. No provider API key ships in the app.

## Backend sync and remote switches

`Backend/BackendSync.swift` mirrors the device's activity log, notification center, price alerts and settings to the
wallet's own rows (`activity`, `notifications`, `alerts`, `user_settings`) under the wallet session, queued on the
device until an upload succeeds, and restores them after a sign-in on a new device (`Services/Supabase/BackendRestore.swift`
checks every restored value). `App/UpdateGate.swift` reads the public `app_config` row `ios` with the publishable key at
launch and at most every ten minutes: `min_build` retires old builds (balances and export stay reachable, nothing
signs) and `flags` are the owner's switches (`RemoteFlags`). Tables and functions: `supabase/migrations/`,
`supabase/functions/`, `supabase/README.md`.

## Perps on Perpl

Perpl is the on-chain perpetuals order book on Monad. The app talks to its Exchange contract
`0x34B6552d57a35a1D042CcAe1951BD1C370112a6F` (`Chain/Monad.swift`, `Services/Perpl/PerplExchange.swift`) directly:

* `getAccountByAddr` → account id, balance, locked balance, frozen flag, position bitmap. An address that never
  deposited reverts with `AccountNotFound(address)` (selector `0x03a0e277`); only that revert means "no account".
  `getPosition` per market → size, entry, margin, premium and the mark; the liquidation price is
  entry ± (entry × size × maintenance fraction − margin − premium) / size.
* Open orders: `getPerpOrderLocks` shows which markets hold locks, `getOrderIdIndex` gives the order ids, `getOrder`
  returns each order (book prices are `basePricePNS + priceONS`).
* Writes: `createAccount(amount)` / `depositCollateral(amount)` (AUSD, 6 decimals, minimum 10 AUSD to open),
  `withdrawCollateral`, `execOrders([OrderDesc], revertOnFail)` with order types OpenLong 0, OpenShort 1, CloseLong 2,
  CloseShort 3, Cancel 4, IncreasePositionCollateral 5 (added margin), Change 6. A market order is an
  immediate-or-cancel limit at the mark ± slippage. `allowOrderForwarding(true)` turns on one-click trading.
* Margin: the initial and maintenance fractions are `100 / value` of `getMarginFractions` (MON: 1000 and 2000, so 10%
  and 5%); a market whose read fails shows an unknown liquidation price rather than a guessed one.
* Take-profit and stop-loss exist only as Perpl keeper triggers: they go through the authenticated trading WebSocket
  with an enrolled Ed25519 key (`PerplTradeClient.swift`, `PerplAuth.swift`, `Wallet/PerplTrading.swift`), never
  through the contract.
* The market-data WebSocket and the public REST endpoints are called directly from the phone, with no proxy and no
  `Origin` header (`PerplFeed.swift`). Perps run only on Perpl; Monday Trade is a spot venue in this app.

## History without an indexer

Every history view is `eth_getLogs` over a bounded window, split into ranges the endpoint accepts
(`RPCClient.chunkedLogsReport` in `Core/Logs.swift`; a range that is refused is halved, and what still cannot be read is
left as a gap rather than failing the whole read). Range sizes per endpoint (`RPCClient.logChunkSize`, measured
2026-09-29): `rpc.monad.xyz` 100 blocks; `rpc1.monad.xyz` 100,000-block ranges (it answers a range of any span up to
10,000 logs per answer); `rpc3` / `rpc4` 1,000 blocks; a local fork 50,000. Every scan therefore goes to `rpc1`
(`LaunchpadService.defaultLogsRPC`), filtered by a contract or by the wallet's own address as a topic. Windows in the
code: curve trades 24 hours (`BlockClock` turns it into blocks), launchpad activity 1,512,000 blocks (about 5.3 days),
a launch coin's holders from its launch and a Moment coin's from its publish, wallet token discovery 6,480,000 blocks
(about 22.7 days), swap history up to 90 days, Moments history from each cohort's deploy block, and the venue token list
from genesis (in 5,000,000-block segments, checkpointed). The wallet's NFTs come from its history store's transfers in,
with no scan of their own. A screen's scan wider than its budget reads newest first (`RPCClient.newestLogs`,
`chunkedLogsReport(order: .descending)`) and says when it stopped short: a holder count is then a minimum ("12+", with a
plain note rather than an error, since no read can do better for a coin older than the budget reaches), and the 24h
volume of the trades read too. A range refused for ending past the answering node's head is asked again after a pause
(`LogsRouter.headPause`), and the head of those windows is read from the logs endpoints themselves. The NFTs list says how
far back the transfers into the wallet reach ("Only NFTs received since …") and counts what it lists as a minimum. Monad's
pace is measured from block headers rather than assumed
(`Chain/BlockClock.swift`).
