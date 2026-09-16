# Moments: coin-only collection and taxed redemption

> Implementation source of truth: [DYOR HQ Moments build specification](moments-build-spec.md). Use that consolidated document for implementation; this document is retained as research history.

This proposal supersedes the transferable-NFT and OpenSea marketplace assumptions in the earlier Moments brief. Moments remains separate from the billion-token Launchpad. The design below is research, not implemented code; fee percentages are illustrative and have not been adopted.

## Product model

Each Moment starts with 100 million coins and a fixed denomination of 10,000 coins per collectible. A user acquires coins, locks them to collect, and burns the collectible through the redemption contract to receive coins minus a disclosed redemption fee. The collectible cannot transfer between wallets. OpenSea is a discovery/display surface; it is not an NFT acquisition or sale venue for Moments.

The contract can require coin backing, but cannot reliably prove that fungible coins were freshly purchased rather than previously held, transferred, or earned. State the rule as “Collect with Moment coins,” not “Every mint forces a new purchase.” Ordinary coin holders can trade without collecting, so this design does not guarantee collection demand or fee revenue from all coin trading.

An OpenSea NFT resale would not create unbacked supply under the earlier model, but it would let the collectible change hands without the redemption flow. The new restriction makes redemption the ordinary protocol exit and removes that alternate transfer route. This is a product tradeoff: collectors lose gifting, NFT resale and ordinary wallet migration. It does not prevent sale or transfer of control of a wallet itself.

## Lifecycle

1. Acquire or use 10,000 Moment coins.
2. Deposit them into the backing vault and mint one non-transferable collectible to the authorized collector.
3. Show the original media, collectible ownership, gross backing and net redeemable balance.
4. On redemption, verify ownership, burn the chosen collectible, remove its backing obligation and split the released coins atomically.
5. Return net coins to the holder. They can keep them or separately swap through an available coin route.

The coin requirement is fixed; the payment-asset cost of obtaining those coins changes with executable market quotes. Popularity has no automatic contract effect: net buying can raise the pool price, while selling can lower it. Do not use views or social engagement counts as a price oracle.

There is no independent NFT marketplace floor under this design. Display “Cost to collect” and “Estimated proceeds after redemption and sale,” not a fabricated NFT floor price. The NFT carries the media and a net coin-redemption claim, not guaranteed cash value.

## What scarcity does and does not mean

- Collecting locks coins, reducing immediately available balances outside the backing vault. Locking alone does not change total coin supply or mechanically update AMM price; the preceding purchase can move the price.
- Redeeming burns the NFT and releases its backing. NFT count goes down, but coins return outside the backing vault.
- Permanently burning a portion of released coins reduces total supply. Revenue and LP reward transfers do not.
- A holder selling returned coins creates sell pressure. A small supply burn does not guarantee it outweighs that selling.
- NFTs can be collected again, so a reduction in current NFT count is not permanent edition scarcity. With unique serial IDs, a burned serial can remain retired while new serials are minted against backing.

If actual coin burns are enabled, describe the supply as “100 million minted initially, no further issuance, decreasing through burns,” rather than “always exactly 100 million.” The supply cap and remaining current supply must be distinct in the interface.

## Worked redemption example

A collector deposited 100,000 coins and received 10 collectibles. Suppose the immutable redemption fee is 5% of gross released backing:

| Destination | Share of gross backing | Coins |
|---|---:|---:|
| Collector | 95% | 95,000 |
| LP rewards escrow | 2% | 2,000 |
| Project treasury | 1% | 1,000 |
| Moment creator | 1% | 1,000 |
| Permanent coin burn | 1% | 1,000 |
| Total | 100% | 100,000 |

All 10 NFTs burn. Backing falls by 100,000 coins. Of those coins, 99,000 leave the backing vault to users or fee recipients and 1,000 cease to exist. Total coin supply falls from 100,000,000 to 99,999,000 if this was its first burn. This is not a 100,000-coin supply reduction.

The creator share preserves the original creator-income objective; its exact allocation remains a product decision. “5% fee” in this example includes the 1% burn: do not add it twice. Rates are measured against gross backing, not against the already-deducted net amount.

If the coin's price is unchanged, the user exits with fewer coins than they deposited. A 5% redemption fee alone requires approximately a 5.26% price increase to break even in the original payment asset, excluding entry fees, exit fees, gas and price impact. A high fee can deter the casual collecting the product wants. Compare 0%, 2%, 3% and 5% in simulations and user testing before choosing a launch rate; this example is not an endorsement of 5%.

Do not increase the required backing per NFT as supply burns. Keeping the denomination fixed keeps the claim understandable; the theoretical maximum outstanding collectibles declines as remaining coin supply declines. Actual circulating editions will usually be lower because some coins remain in liquidity and other balances.

## Accounting and solvency

Let `r` be coins locked per NFT, `N` the number of outstanding NFTs, and `B` the vault's backing balance. Maintain `B >= r * N`. Use base-unit integer arithmetic, bounded batch sizes and an explicit rounding policy.

For redemption of `n` NFTs, `gross = n * r`; `fee = gross * feeBps / 10,000`; `net = gross - fee`. Fee allocations plus net must equal gross exactly. Burn and distribute only backing released by the NFTs being destroyed. Backing for NFTs still held must remain untouched.

If the contract retains claimable fees in the same address, its reserve requirement must cover both remaining NFT backing and all claimable fees. Prefer separate backing and fee escrows so those liabilities are harder to confuse. Collecting cannot mint without actual received coins; unsupported fee-on-transfer coins are rejected.

Burn coins with a genuine total-supply-reducing operation, not a transfer to an inaccessible address presented as equivalent supply accounting. The new Moment coin can expose a narrowly scoped burn operation over the redemption vault's own released coins. It must never allow the controller to burn arbitrary users' balances. OpenZeppelin documents supply-reducing ERC-20 burns. [ERC-20 reference](https://docs.openzeppelin.com/contracts/5.x/api/token/erc20).

The ratio and fee split should be frozen per Moment. A creator or administrator must not be able to raise an existing holder's exit tax, mint unbacked collectibles or seize reserves. Avoid a general emergency switch that can freeze redemptions indefinitely; any controls require explicit, narrow scope and disclosure.

## NFT standard and OpenSea

The changed requirements justify revisiting the earlier ERC-1155 choice. Recommended prototype: ERC-721 with ERC-5192 lock signaling, identical media across editions and distinct serial IDs. ERC-5192 standardizes locked ERC-721 discovery and requires account-to-account transfers of locked NFTs to fail. OpenSea explicitly documents the associated lock events for marking tokens ineligible for trading. [ERC-5192](https://eips.ethereum.org/EIPS/eip-5192), [OpenSea locked and staked NFTs](https://docs.opensea.io/docs/locked-and-staked-nfts).

Enforce the rule in the contract's shared transfer path, covering direct transfers, safe transfers and approved operators. Only backed minting and owner-authorized redemption burning are allowed. Emit the documented locking event when minting. Approvals must not enable transfer or let an operator steal redemption proceeds. Redemption must authenticate the holder and bind the payout recipient; a router needs explicit authorization.

ERC-1155 can also use custom non-transferability, and batch minting is convenient. However, ERC-5192 is specifically an ERC-721 extension; do not claim a restricted ERC-1155 implements that standard. Compare gas and OpenSea's actual handling before making the final choice. Automatic NFT minting on every coin transfer remains unnecessary: mint only through explicit collect transactions.

The OpenSea acceptance test changes from successful listing/purchase to successful display and unsuccessful NFT transfer/marketplace fulfillment. Confirm image/video playback, ownership and locked status on the actual Monad deployment. Documentation establishes intended support, not that this collection has been indexed or tested. Include a direct link to DYOR with plain collect/redeem instructions.

Do not blacklist only Seaport: users could then transfer or sell through another operator. Conversely, the UI must explain that all normal NFT transfers, including gifts and wallet-to-wallet migration, are disabled. A future recovery feature must not become a general-purpose tax-free transfer bypass.

## LP rewards versus adding liquidity

LP rewards and pool funding are different mechanisms. A 2,000-coin fee allocation can compensate LPs in Moment coins. It does not create 2,000 coins worth of MON, and sending coins to a DEX pool address is not a reliable substitute for minting a valid liquidity position.

For LP provider rewards, use an explicit eligible-position program. A dedicated LP vault with measurable shares is simpler to account for than arbitrary external concentrated-liquidity positions. Reward participating LP shares over time, rather than using the instantaneous LP balance at redemption; otherwise someone may briefly deposit liquidity just to capture a large fee. Define the pool, position eligibility, custody, measurement and claim rules before launch. Staking LP shares is additional user interaction and does not automatically include every external LP.

For protocol-owned liquidity, route the allocation to a clearly named liquidity reserve. Turning it into deeper two-sided liquidity requires matching quote capital, a controlled swap of part of the fees, or a deliberately chosen single-sided position. Each has costs and exposure. A swap into MON can push price down and requires limits and slippage controls. Do not sell fee coins inside the core redemption transaction, because a missing DEX route should not block returning a holder's net coins.

Recommendation: separate fee accrual from distribution and liquidity management. Redemption releases net coins immediately and accrues fees into distinct escrows. LP reward settlement or liquidity additions happen later under explicit rules. If no eligible LPs exist yet, hold the LP allocation in its designated reserve until the pre-disclosed eligibility condition is met; do not silently redirect it to the project.

Ordinary AMM swap fees remain separate from this redemption reward. Uniswap documents fees accruing to active liquidity positions; our redemption allocation requires its own accounting. [Uniswap fees](https://developers.uniswap.org/docs/get-started/concepts/fees).

## Curve and entry pricing

A direct pool or dedicated Moments bootstrap curve can both serve this collectible model. Use a fixed coin denomination and actual market quotes; neither the NFT burn nor a display on OpenSea requires graduation. Keep the earlier funding-dependent choice: direct seeded liquidity when capital is committed, otherwise a separately deployed Moments bootstrap curve.

A bootstrap curve lets early buyers acquire coins at lower points on its pricing schedule, but later prices can also fall with selling. Show slippage-protected acquisition costs and avoid promising early collectors returns. Do not add a second formula making NFT backing depend on its estimated dollar value; that would make liabilities and redemption harder to reason about.

Use an optional “Collect now” router that buys exactly the required backing and mints to the authenticated collector. “Redeem and sell” may provide one user flow, but plain coin redemption must remain independently available. Other-asset payouts depend on available swap routes; an arbitrary asset cannot be guaranteed.

## Proposed implementation boundary

- Dedicated Moments factory and registry; no existing Launchpad policy changes.
- Initially capped ERC-20, no further minting, controlled burn of released fee coins.
- Locked collectible contract; backed minting; no ordinary account transfers.
- Backing vault and owner-authorized atomic redemption.
- Immutable fee policy; separate creator, project and LP reward accounting.
- Optional buy-and-collect / redeem-and-sell router with quotes, deadlines and minimum outputs.
- OpenSea metadata and lock signaling, without NFT listing/offer workflows.
- Indexer showing current coin supply, cumulative burns, locked backing, collectible counts and net exit amounts.

Contract tests should include repeated collect/redeem cycles, partial redemption, fee rounding, multiple Moments, unauthorized operators, malicious receiver callbacks, direct donations, failed fee claims, absent swap liquidity and all transfer variants. Accounting must prove that permanent burns plus distributed fees never consume backing owed to remaining collectors. LP reward tests must address short-lived deposits, reward capture and duplicate claims. OpenSea tests must distinguish backend lock recognition from actual onchain transfer enforcement.

The first useful product experiment is a simulated collector journey comparing several fee rates: acquisition cost, collectible count, locked coins, net redemption, realized swap proceeds and LP rewards. Evaluate whether people actually want to collect rather than hold the untaxed coin. Scarcity is one property of this design, not a substitute for demand for the media or a guarantee of appreciation.
