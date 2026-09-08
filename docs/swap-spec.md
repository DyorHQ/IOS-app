# DyorHQ Swap — spot trading across Monad venues

Route: `/swap`. Quotes three venues at once, ranks them by output, and executes the chosen one from the user's
own wallet. No DyorHQ contract sits in the path; every transaction targets the venue's own router.

## Venues

| Venue | What is quoted | How it executes | Source of the addresses |
| --- | --- | --- | --- |
| **Kuru Flow** | `POST https://ws.kuru.io/api/quote` with a per-address JWT from `POST /api/generate-token` (1 request/second per address). Returns `output`, `minOut` and a ready transaction `{to, calldata, value}` against `KuruFlowEntrypoint 0xb3e6778480b2E488385E8205eA05E20060B813cb`. | ERC-20 input: `approve(entrypoint, amount)` then the returned transaction (verified on a fork: the entrypoint calls `transferFrom` on the user). Native MON is address zero and rides on `value`. | https://docs.kuru.io/kuru-flow/flow-overview, https://docs.kuru.io/contracts/Contract-addresses |
| **Uniswap** | v3: `QuoterV2 0x661e93cca42afacb172121ef892830ca3b70f08d` over pools from `UniswapV3Factory 0x204faca1764b154221e35c0d20abb3c525710498` (direct at the three deepest fee tiers, two-hop through WMON/USDC/USDT0/WETH at the deepest tier per leg). v4: `V4Quoter 0xa222dd357a9076d1091ed6aa2e16c9742dd26891` over hookless canonical pools (fee/tick-spacing 100/1, 500/10, 3000/60, 10000/200) discovered through `StateView 0x77395f3b2e73ae90843717371294fa97cc419d64`, direct or through native MON, plus graduated launchpad pools (hooked) reached directly or through MON. The better of v3 and v4 is offered. | v3: `SwapRouter02 0xfe31f71c1b106eac32f1a19239c9a9a72ddfb900` `multicall(deadline, [exactInput(Single), unwrapWETH9?, refundETH?])`; native MON in via `value`, native out via `unwrapWETH9`. v4: `Universal Router 0x0d97dc33264bfc1c226207428a79b26757fb9dc3` `execute(V4_SWAP)` with actions `SWAP_EXACT_IN(_SINGLE)`, `SETTLE_ALL`, `TAKE_ALL`; ERC-20 input goes through `Permit2 0x000000000022D473030F116dDEE9F6B43aC78BA3` (`approve` token → Permit2, then `Permit2.approve(token, router, amount, 30 days)`); native MON in via `value`. | https://developers.uniswap.org/docs/protocols/v4/deployments (Monad), https://developers.uniswap.org/docs/protocols/v3/deployments/v3-monad-deployments |
| **Monday Trade** | Spot pools (concentrated liquidity with an embedded order book) through `QuoterV2 0xB97eCD41Aef0F842E773C8F9905919cDE49880C9` over pools from `Factory 0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21` at fee tiers 100, 300, 500, 3000 and 10000 (the tiers the factory enables). Same route search as Uniswap v3. | `SwapRouter 0xFE951b693A2FE54BE5148614B109E316B567632F`, which implements the Uniswap v3 SwapRouter v1 layout (deadline inside the params, `multicall(bytes[])`, `unwrapWETH9`, `refundETH`, `WETH9 = WMON`). Its selectors were verified against the deployed bytecode because Monday publishes addresses but no ABI. | https://docs.monday.trade/spot-trading/spot-contract-pair-specifications |
| **Wrap** | MON ↔ WMON is 1:1 through `WMON 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A` `deposit`/`withdraw` and never goes to a venue. | | Monad token list |

All addresses were checked for bytecode on Monad mainnet on 2026-09-08, and live quotes from each venue were
compared (100 MON → about 2.62 USDC on all three at the time).

## Token list

`app/lib/swap/tokens.ts` carries a curated set from Monad's official list (`monad-crypto/token-list`, mainnet
v2.48): MON, WMON, USDC, USDT0, WETH, WBTC, cbBTC, gMON, sMON, aprMON, shMON, AUSD, USDe, USD1, mUSD, LBTC,
ezETH, rETH. Graduated launchpad tokens are appended from the factory, and any ERC-20 can be added by pasting
its address (symbol, name and decimals are read on-chain; it is flagged as unlisted).

## Behaviour

* Every venue is quoted independently with a 20-second budget, so a slow venue never hides the others; the
  list refreshes every 12 seconds while an amount is entered and re-quotes right before sending when a quote
  is older than 45 seconds.
* The best output is preselected; the user can pick another venue. Minimum received follows the slippage
  setting (0.5%, 1%, 3%, 5%). Price impact is measured against the venue's own marginal price (a 1/1000 slice
  quote); above 3% the button turns into "Swap anyway".
* Execution runs a plan: approvals that are already sufficient are skipped, each transaction is simulated
  with `eth_call` before the wallet opens, and hashes are shown as they are sent. Native MON never needs an
  approval.
* Deep links: `/swap?in=MON&out=<address or symbol>`. The launchpad's graduated tokens link here.

## Files

`app/swap/page.tsx` (UI), `app/swap/layout.tsx`, `app/lib/swap/engine.ts` (per-venue quoting, ranking, plan
execution), `app/lib/swap/uniswap.ts`, `app/lib/swap/monday.ts`, `app/lib/swap/kuru.ts`, `app/lib/swap/tokens.ts`,
`app/lib/swap/config.ts` (addresses), `app/lib/swap/abis.ts`, `scripts/dev/pool-inventory.mjs` (read-only
mainnet inventory of pools per venue and tier).

## Not built

* Exact-output swaps (all quotes are exact-input).
* Limit orders on Kuru or Monday order books; the swap uses their market execution only.
* Monday Trade's RWA (tokenised stock) markets, which run through a separate authenticated API rather than the
  spot pools.
* A Kuru Flow referrer fee (`referrerAddress`/`referrerFeeBps` are supported by the API and can be added in
  `app/lib/swap/kuru.ts` once DyorHQ decides on a fee wallet).
