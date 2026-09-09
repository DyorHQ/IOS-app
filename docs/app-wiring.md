# DyorHQ app — what every screen reads and writes

The phone-frame app at `/` is wired to Monad mainnet. Nothing on screen is sample data; where a source does not
exist yet (for example the launchpad before it is deployed), the screen says so instead of pretending.

| Screen | Data | Actions | Source |
| --- | --- | --- | --- |
| **Home** | Portfolio total (token balances × live pool prices + Perpl equity), 24h delta, MON balance, top movers, on-chain activity (launchpad events) or the Perpl MON tape when the launchpad is not deployed | Receive (address sheet), Send (native or ERC-20 transfer from the wallet), Swap | `app/lib/app-data.ts`, `app/lib/market/prices.ts`, `app/lib/launchpad/events.ts`, Perpl WebSocket |
| **Markets** | All / Spot / Perps / Stocks. Spot prices come from the deepest Uniswap pool for each token (v4 hookless MON/USDC, v3 elsewhere) with the same read 24h earlier for the change. Perps rows come from Perpl's market context (mark, 24h, OI, volume). Stocks rows open TradingView charts (NVDA, TSLA, AAPL, MSFT, GOOGL, AMZN). | Search by name or address; token detail with a TradingView chart (exchange symbols) or a TradingView Lightweight chart built from curve trades (launchpad tokens); Buy / Sell (opens the swap with the pair preselected) | `loadPrices`, `fetchPerplContext`, `app/ui/tradingview.tsx` |
| **Launch** | Launches from the factory, per-token curve state, curve trade history (last two hours of logs), holder rewards | Create (same form as `/launchpad/create`), buy and sell on the curve, claims, retry graduation, sweep pool fees | `app/lib/launchpad.ts`, `app/launchpad/token-panels.tsx`, `app/lib/launchpad/events.ts` |
| **Trade · Swap** | Live quotes from Kuru Flow, Uniswap v3/v4 and Monday Trade | Executes the chosen venue from the wallet (see `docs/swap-spec.md`) | `app/lib/swap/*` |
| **Trade · Perps** | Perpl markets: mark, last and oracle prices, open interest, 24h volume, funding and max leverage; live L2 order book and trade tape; TradingView chart (Binance perpetual symbols); positions, open orders and collateral from the Exchange contract | Deposit / withdraw AUSD (first deposit opens the account), market and limit orders (`execOrders`), close position (reduce-only IOC), cancel order | `app/lib/perps/perpl.ts`, `app/lib/perps/ws.ts`, `worker/index.ts` (WebSocket bridge), `app/api/perpl/[...path]/route.ts` (REST proxy) |
| **Profile** | Wallet, total value, holdings with values, Perpl balance and positions, own launchpad activity | Copy address, Receive, Send, Swap, Disconnect | as above |

Top bar and menu: search focuses the Markets search; the bell opens the on-chain activity sheet; the avatar connects
a wallet (EIP-6963) or opens the wallet menu; the menu links to every tab, the appearance controls, help links and
disconnect. The studio panel (desktop) keeps the appearance controls.

## Charts

* **TradingView Advanced Chart** (`s3.tradingview.com/tv.js`) for anything with an exchange symbol: MON, BTC, ETH,
  SOL, HYPE, ZEC, the wrapped and staked variants, stablecoins, and US stocks. Perps use Binance perpetual symbols
  (`BINANCE:MONUSDT.P` and so on). The symbol table lives in `app/ui/tradingview.tsx`.
* **TradingView Lightweight Charts** (`lightweight-charts`, Apache-2.0) for launchpad tokens, fed with candles built
  from `CurveBuy` / `CurveSell` events.

## Perps on Perpl

Perpl (https://perpl.xyz) is the fully on-chain perpetuals order book on Monad mainnet. The app talks to its
Exchange contract `0x34B6552d57a35a1D042CcAe1951BD1C370112a6F` directly:

* `getAccountByAddr` → account id, balance, locked balance, position bitmap. `getPosition` per market → size, entry,
  margin, mark-to-market PnL and the liquidation price (entry ± (maintenance requirement − margin − premium) / size).
* Open orders: `getPerpOrderLocks` shows which markets hold locks, `getOrderIdIndex` gives the active order ids,
  `getOrder` returns each order (book prices are `basePricePNS + priceONS`).
* Writes: `createAccount` / `depositCollateral` (AUSD, 6 decimals, minimum 10 AUSD to open), `withdrawCollateral`,
  `execOrders` with an `OrderDesc` (order types OpenLong 0, OpenShort 1, CloseLong 2, CloseShort 3, Cancel 4).
  Market orders are immediate-or-cancel limits at the mark ± slippage, exactly how Perpl's own UI does it.
* Margin: initial and maintenance fractions are `100 / value` of `getMarginFractions` (MON: 10% and 5%).
* Perpl's WebSocket rejects foreign origins, so `worker/index.ts` bridges `/api/perpl/ws` to
  `wss://app.perpl.xyz/ws/v1/market-data`; its REST context is proxied by `app/api/perpl/[...path]/route.ts`.

Monday Trade was the first choice for perps, but its docs state perps are paused during the move to RWA trading
and its API host is offline; the spot venues stay on Monday.

## History without an indexer

Monad's public RPCs cap `eth_getLogs` at 100 blocks (rpc.monad.xyz) or 1,000 blocks (rpc1 / rpc3). The app reads
recent windows in parallel chunks: launchpad activity over the last hour or two, curve trades for a token over the
last two hours. Older history is one indexer away; the code is in `app/lib/launchpad/events.ts`.

## Verified

Read paths were exercised against Monad mainnet in the browser (prices, markets, Perpl book and tape, wallet
connection). Launchpad and swap transactions were exercised earlier on a local fork. Perpl order placement was
built from the contract ABI and the SDK's encoding rules; the first live order should be a small one.
