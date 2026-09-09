# DyorHQ Launchpad — contracts and app spec

Monad mainnet (chain id 143) · Uniswap v4 liquidity · owner-operated, non-custodial.

This document describes the launchpad built in `contracts/` (Foundry) and wired into the web app under
`app/launchpad`. It is modelled on Pons v2 (Robinhood Chain), re-implemented for Monad's canonical Uniswap v4
deployment. **Nothing has been deployed to a public chain.** The owner deploys with the runbook in
`contracts/script/README.md`; every contract is owned or controlled by the deploying wallet.

## 1. What it does

1. A creator launches a token: name, ticker, image, description, socials, paired asset, optional developer buy,
   optional creator tax, optional holder fee sharing, optional snipe-tax exemptions. The whole supply mints to a
   bonding curve. No team allocation exists.
2. Anyone buys and sells on the curve (constant product with a phantom quote reserve, like Pons). A trade fee,
   an optional creator tax, and a decaying snipe tax during the first seconds are taken on every trade.
3. When the curve has collected the graduation threshold of the paired asset, the factory sweeps the reserves,
   opens a Uniswap v4 pool at the curve's final price with a hook that keeps charging the same fees, and locks the
   full-range position in a locker that has no withdrawal path. Supply that the curve never sold is locked with it.
4. After graduation the token trades on Uniswap v4. The hook forwards fees to the protocol and to the creator
   (or pro-rata to holders when holder fee sharing was enabled).

## 2. Pons v2 → DyorHQ contract map

| Pons v2 module | DyorHQ contract | Notes |
| --- | --- | --- |
| Factory | `LaunchpadFactory` | Policy, launch registry, graduation orchestration, stuck-launch valve, timelocked fee-recipient takeovers. |
| Launch Deployer | `LaunchDeployer` + `CurveDeployer` | Hold the token and curve creation code (CREATE2). Keeps the factory under the 24 KB EIP-170 limit. |
| Bonding curve | `BondingCurve` (one per launch) | Curve math, fees, snipe tax, completion, rescue mode. |
| Token | `LaunchToken` | Minimal ERC-20 with on-chain logo, description and socials (`getTokenInfo`). |
| Meme Hook | `MemeHook` | Uniswap v4 hook: fee-on-swap for graduated pools, blocks pool initialisation by anyone but the executor. |
| Fee Escrow | `FeeEscrow` | Pull-payment escrow for protocol and creator fees (native and ERC-20). |
| Holder fee sharing | `HolderFeeSharing` | Pro-rata fee distribution to holders with settlement before every transfer. |
| Launch Locker | `LaunchLocker` | Owns the full-range v4 position. No function removes liquidity. |
| Launch and Buy Router | `LaunchAndBuyRouter` | Launch and developer buy in one transaction. |
| Graduation Executor | `GraduationExecutor` | Initialises the pool at the curve price and mints the locked position. |
| Graduation Guard | `MemeHook.beforeInitialize` + factory phases | Only the executor may initialise a registered pool, so nobody can pre-seed the pair at a different price. |
| Buyback Vault | not included | Pons buys back with part of the fees; DyorHQ routes that share to holders instead (see §4). Can be added as a fee recipient later. |

Every contract is immutable (no proxies). Module addresses are wired once with `setModules`; the hook, locker,
escrow and fee-sharing addresses lock permanently after the first launch.

## 3. Lifecycle

### Launch
`LaunchpadFactory.launchToken(params, configId, pairToken, exemptions)` payable with the launch fee, or
`LaunchAndBuyRouter.launchAndBuy(...)` payable with fee + developer buy.

* `params.expectedEconomics` must equal `previewLaunchEconomics(configId, pairToken)`: a hash of the launch
  config, pair economics, launch fee, protocol share and max creator tax. The owner cannot change the deal
  between the user reading the terms and the transaction landing.
* Token and curve addresses are CREATE2 from `keccak(deployer, params.salt)`.
* With holder fee sharing, the token is registered with `HolderFeeSharing` before it exists so the mint settles
  correctly; the factory, locker, pool manager, hook, executor, curve and the dead address are excluded from
  rewards.
* The launch fee goes to the protocol recipient through the escrow.

### Curve trading
Constant product with a phantom quote reserve `P` and graduation threshold `T`:

* `tokensOut = net · tokenReserve / (quoteReserve + net)`, `quoteReserve = P + realQuote`.
* Reserved supply that graduates into the pool: `supply · P / (P + T)`. With the defaults (1 B supply,
  P = 4 000 MON, T = 16 000 MON) 200 M tokens are reserved and 800 M are sellable on the curve.
* Buy fees come off the input: trade fee `feeBps`, creator tax `creatorTaxBps`, snipe tax
  `snipeTaxSchedule[secondsSinceLaunch]` (0 after the schedule ends; deployer, creator wallet and listed
  exemptions never pay it). The final buy is clamped to what completes the curve and the rest is refunded.
* Sell fees come off the output (no snipe tax).
* Fee split: `protocolFeeShareBps` of (trade fee + snipe tax) to the protocol; the rest plus the creator tax to
  the creator wallet, or to `HolderFeeSharing.notifyReward` when sharing is on.

### Completion and graduation
The buy that reaches `T` marks the curve complete and calls `factory.onCurveComplete`, which attempts
`graduate` with `GRADUATION_GAS` (2 M) and requires that much gas to be available. The requirement matters:
without it, `eth_estimateGas` settles on a limit where the buy succeeds while the caught inner call runs out of
gas, stranding every launch. `graduate` (public, so anyone can retry a stuck launch):

1. `curve.sweep(executor)` moves the raised quote and the unsold tokens to the executor (phase `Swept`).
2. `hook.registerLaunch(poolKey, …)` records fee settings for the pool id.
3. `executor.graduate(...)`: tokens for the pool = `tokens · quote / (P + quote)` (exactly the reserved supply),
   `sqrtPriceX96` from those amounts (price continuity with the curve), `poolManager.initialize`, full-range
   liquidity, everything transferred to the locker, `locker.lock`. Leftover tokens stay in the locker and one
   millionth of the quote is left as rounding dust. Phase `PoolCreated`.

If graduation keeps failing for 7 days, the owner may call `rescue(token)`: the curve enters refund mode, buys
close, and sells are fee-free at the curve price (phase `Rescued`).

### Pool trading
The pool's LP fee is 0; `MemeHook` charges the launch's `poolFeeBps` (+ creator tax) instead:

| Swap | Fee taken from |
| --- | --- |
| exact input, paying quote | the quote input (before the swap) |
| exact input, paying token | the quote output |
| exact output, receiving token | on top of the quote paid (`grossForNet`) |
| exact output, receiving quote | the token input |

Fees accumulate in the hook per pool and currency; `sweepPoolFees(poolId, currency)` (anyone) pays the
protocol share to the escrow and the creator share to the creator, or to holders for quote-denominated fees.

### Creator fee recipient changes
The creator wallet can hand its fee stream to another address (`transferCreatorFeeRecipient`). The owner can
propose a change with a 3-day timelock and a 3-day execution window (`proposeCreatorFeeRecipient` →
`executeCreatorFeeRecipientChange`), the Pons "community takeover" mechanism for abandoned launches.

## 4. Parameters (defaults in `contracts/script/Deploy.s.sol`)

| Parameter | Default | Env override |
| --- | --- | --- |
| PoolManager | `0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e` (Uniswap v4 on Monad) | `POOL_MANAGER` |
| Launch fee | 1 MON | `LAUNCH_FEE_WEI` |
| Protocol share of fees | 50 % | `PROTOCOL_FEE_SHARE_BPS` |
| Max creator tax | 10 % | `MAX_CREATOR_TAX_BPS` |
| Supply | 1 000 000 000 tokens | `SUPPLY` |
| Curve trade fee | 1 % | `CURVE_FEE_BPS` |
| Pool trade fee | 1 % | `POOL_FEE_BPS` |
| Tick spacing | 60 | `TICK_SPACING` |
| Phantom quote (MON pair) | 4 000 MON | `PHANTOM_QUOTE_WEI` |
| Graduation threshold (MON pair) | 16 000 MON | `GRADUATION_THRESHOLD_WEI` |
| Snipe tax schedule | 98 %, 25 %, 3 %, 0.3 % for seconds 0–3, then 0 | edit the script |
| Protocol fee recipient | the deploying wallet | `PROTOCOL_FEE_RECIPIENT` |

Owner controls after deployment: `setLaunchFee`, `setFeePolicy`, `setMaxCreatorTaxBps`, `addLaunchConfig` /
`setLaunchConfigEnabled`, `setPairEconomics` (approve tokenised-stock pairs with their own phantom and
threshold), `setWhitelistEnabled` / `setWhitelisted`, `setModules` (executor and router stay replaceable; the
rest lock after the first launch), `rescue`, takeover proposals, two-step ownership transfer.

What the owner cannot do: withdraw locked liquidity, touch curve reserves, change a live launch's fees, mint
tokens, or pause trading.

## 5. Monad specifics

* Contract size: every contract is under 24 576 bytes (factory 24 220, largest deployer 14 565) so forge's
  simulation and any EVM fork accept them. Monad itself allows 128 KB.
* Gas is charged on the gas limit, not gas used. The app relies on the wallet's estimate; the factory's
  `GRADUATION_GAS` floor keeps the completing buy's estimate honest.
* Native MON is `address(0)` in Uniswap v4 and in the launchpad (`pairToken == address(0)`).
* Hook address flags are mined against the CREATE2 deployer proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C`,
  which forge uses for `new X{salt: …}` and which is live on Monad.

## 6. Deployment and verification

1. `cd contracts && forge test` (25 tests: curve economics, fees, snipe tax, router, holder sharing, takeovers,
   rescue, hook fee accounting for all four swap cases, graduation price continuity, locker access).
2. Dry run: `forge script script/Deploy.s.sol:Deploy --rpc-url monad`.
3. Deploy from the owner wallet: add `--broadcast --private-key $OWNER_KEY`. The script writes
   `contracts/deployments/143.json`.
4. `npm run sync:deployment` copies the addresses into `app/lib/deployment.json` (or set the
   `NEXT_PUBLIC_*` variables from `.env.example`). Rebuild and deploy the app.
5. Verify sources on Monadscan (Etherscan v2 API, chain 143), for example
   `forge verify-contract --chain 143 --verifier etherscan --etherscan-api-key $KEY <address> src/LaunchpadFactory.sol:LaunchpadFactory --constructor-args $(cast abi-encode "constructor(address,address,uint256,uint16,uint16)" …)`.
6. Approve tokenised-stock pairs with `script/AddPairToken.s.sol` and list them in `NEXT_PUBLIC_PAIR_TOKENS`.

Local rehearsal (no public chain involved): `anvil --fork-url https://rpc.monad.xyz --chain-id 143`, deploy with
anvil's first key against `http://127.0.0.1:8545`, then `node scripts/dev/seed-fork.mjs contracts/deployments/143.json`
launches three tokens, trades them, and graduates one into the forked PoolManager. This is how the integration
with the real Monad Uniswap v4 bytecode was exercised.

## 7. Web app

| Route | Purpose |
| --- | --- |
| `/launchpad` | Explore: live launches from the factory, progress to graduation, market cap, filters and sort. |
| `/launchpad/create` | Pons-style create form with the "Your token" summary card: image, name, ticker, description, X, Telegram, website, paired asset, developer buy (with estimated tokens), advanced options (holder fee sharing, creator wallet, creator tax, snipe-tax exemptions). Submits `launchToken` or `launchAndBuy`. |
| `/launchpad/[token]` | Token page: price, market cap, raised, progress, buy/sell on the curve with quotes, fee breakdown, snipe-tax countdown and slippage; graduation and refund states; holder reward and creator fee claims; pool fee distribution. |

Library: `app/lib/chain.ts` (Monad chain, RPC, addresses), `app/lib/wallet.tsx` (EIP-6963 wallet discovery,
EIP-1193 session, network switch, viem wallet client), `app/lib/launchpad.ts` (reads through multicall),
`app/lib/actions.ts` (simulate-then-write for every transaction), `app/lib/abi.ts` (generated by `npm run abis`).

## 8. Not built yet

* Swapping graduated tokens inside the app (they trade on Uniswap v4 through the Universal Router; the token page
  shows the pool state and the fee sweep).
* An indexer for holder counts, trade history and price charts; the pages read contract state only.
* Image hosting: the create form takes an image URL. Add an R2 bucket and an upload route when hosting is wired.
* A buyback vault, tokenised-stock pair approvals, and an external audit before mainnet use.
