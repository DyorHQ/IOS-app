# Moments product and integration brief

> Implementation source of truth: [DYOR HQ Moments build specification](moments-build-spec.md). Use that consolidated document for implementation; this document is retained as research history.

> Current direction: [Coin-only collection and taxed redemption](moments-coin-only-collection-model.md) supersedes the NFT transfer, OpenSea trading, and fee-free redemption assumptions below. Collectibles are now proposed to be non-transferable, with coin-backed acquisition and taxed redemption. Earlier sections are retained as research history.

## Product decision

**Moments is a distinct DYOR HQ feature: capture an experience, publish its media, and let people collect it as an NFT edition or hold its associated coins.** Each Moment has its own fixed economic supply of 100 million coins. The existing Launchpad remains a separate billion-token product. Neither a new tab over the existing Launchpad nor a changed Launchpad supply adequately expresses this separation.

Recommended initial design: a dedicated Moments factory, a fixed-supply ERC-20 for each Moment, and a backed ERC-1155 collectible. Lock 10,000 coins to mint one edition; burn one edition through the Moments redemption function to unlock 10,000 coins. Publish the ratio as an immutable product rule for the first version. This is a proposed starting denomination, not a market-tested optimum.

OpenSea NFT visibility, listing, purchase and subsequent redemption in DYOR are required launch capabilities. Native conversion inside OpenSea is a separate integration opportunity that has not been established. The product must remain usable without that custom interface being accepted.

For liquidity, distinguish product preference from an unfunded assumption. A directly seeded DEX pool avoids a graduation milestone and is the preferred pilot experience **if DYOR or a partner commits initial liquidity**. Without that capital, a dedicated Moments bootstrap curve is the more practical initial route. Do not implement both for the hackathon. Select one after comparing actual capital and development budgets.

This brief reflects documentation reviewed on September 12, 2026 and the current repository. It is an architecture and market-entry proposal; no Moments contracts or transactions have been deployed or integration-tested. Numerical examples are hypothetical and exclude costs unless specified.

## 1. Separation from Launchpad

| Dimension | Existing Launchpad | Proposed Moments |
|---|---|---|
| Main action | Launch a coin | Capture and publish a Moment |
| Supply | 1 billion under existing defaults | Exactly 100 million per Moment |
| Discovery | Coin markets and launch progress | Media feed, experiences, creators, event albums |
| Buyer object | Coin balance | Coins and convertible media editions |
| Creator setup | Token parameters and advanced economics | Photo/video, story, title, ticker, creator identity |
| Contract registration | Existing launch registry | Separate Moments factory and registry |
| OpenSea | Not core to its existing flow | NFT integration is a release requirement |
| Shared infrastructure | Wallet, chain client, quote patterns, design system | Reuse these services without sharing product state or changing live Launchpad economics |

Use separate Moments contract addresses, events, routes, analytics and discovery filters. Do not modify the existing factory's configs or global graduation executor to introduce Moments. Reuse reviewed libraries and transaction utilities, but deploy and validate a separate protocol instance with its own policy. Names such as `MomentPublished` and `EditionRedeemed` should replace Launchpad terminology in the new domain.

Repository paths relevant to implementation include `contracts/src/LaunchToken.sol`, `contracts/src/libraries/CurveMath.sol`, `contracts/src/MondayGraduationExecutor.sol`, `contracts/src/MondayFeeVault.sol`, `app/lib/actions.ts`, `ios/DyorHQ/Launchpad/LaunchpadView.swift`, `ios/DyorKit/Sources/DyorKit/Services/Launchpad/`, and `supabase/migrations/09_launch_media_storage.sql`. These are reusable implementation evidence, not authorization to change Launchpad.

## 2. What is actually being collected?

A Moment is one work: a photograph or video, metadata, creator attribution, and a market. Multiple NFT editions all display the complete work. An edition is a transferable bearer claim on a fixed quantity of that Moment's coin. It is not a cut-up video file, ownership of the event, or a promise of creator revenue.

ERC-1155 supports multiple units of one token ID and shared metadata. This directly fits identical editions. ERC-721 is better if every edition needs a distinct serial identity, but introduces per-token lifecycle management with little benefit for identical media. Monad's EVM compatibility allows these Ethereum standards, and OpenSea lists Monad as a supported chain. [^1][^2][^3]

For a lean pilot, use one lightweight, non-upgradeable ERC-1155 collection contract per Moment, containing one edition token ID. This keeps each Moment's offers, collection description, creator administration and market identity separate on OpenSea. A single global collection would reduce deployments but mingle unrelated Moments in collection-wide offers and floor statistics. A creator-level collection is a reasonable later option; per-Moment attribution and fees would still require explicit handling.

OpenSea documents contract ownership for creator attribution and `contractURI` for contract metadata. Give the creator the intended collection identity only through narrowly scoped ownership capabilities: no ability to mint unbacked editions, change the ratio, move backing, or replace immutable media. These powers must be constrained in code even if the creator has collection administration rights. [^4]

Avoid describing 10,000 editions as “10,000 unique originals.” They are identical editions. Burns and re-mints mean the meaningful cap is **simultaneously outstanding editions**, not cumulative lifetime mint events. With coins permanently in liquidity or other locks, fewer than the theoretical maximum may ever be outstanding at one time.

## 3. Lock-and-mint versus burn-and-mint

### Recommended: lock coins, mint editions; burn editions, unlock coins

The contract issues the entire 100 million ERC-20 supply once. To collect an edition, a holder authorizes and deposits the exact backing amount. The wrapper then issues the NFT to the chosen recipient. To return to coins, the current NFT holder calls the redemption function, which burns their editions and releases the backing atomically.

| Action | Coin effect | NFT effect |
|---|---|---|
| Collect 1 edition | Lock 10,000 coins | Mint 1 edition |
| Collect 3 editions | Lock 30,000 coins | Mint 3 editions |
| Redeem 1 edition | Return 10,000 coins | Burn 1 edition |
| Redeem 3 editions | Return 30,000 coins | Burn 3 editions |
| Sell an edition on OpenSea | Backing stays locked | Edition moves to buyer |
| Send an edition to another wallet | Backing stays locked | Redemption right moves with edition |

A new owner on OpenSea can redeem even if they never used DYOR before. They must control the wallet currently holding the edition, connect it to the Moments redemption page, and have transaction gas. An NFT purchase must not depend on a private allowlist, original-minter identity or DYOR login for redemption.

**Do not use OpenSea's generic burn/transfer-to-dead-address action to redeem.** That discards the asset and does not invoke the Moments contract's payout function. The help center's generic NFT deletion/burning instructions describe a different action. Clear collection metadata and a dedicated redemption page are necessary. [^5]

In whole-coin notation, let `S = 100,000,000`, `r = 10,000`, `N = outstanding editions`, and `B = wrapper coin balance`. The contract must maintain `B >= r × N`. Normally `B = r × N`; unsolicited transfers can make backing exceed the required amount without granting the sender an edition. With 18 decimals, all coin quantities are multiplied by `10^18` onchain.

Economic supply outside the wrapper plus edition backing equivalents is `S - B + r × N`, never above `S`. Do not add the NFT value on top of the full 100 million coin valuation: that counts its backing twice. Coins in LP positions, vaults and curves remain part of the same total supply.

### Alternative: burn coins to mint NFTs, burn NFTs to re-mint coins

This can work with a dedicated controller, but it requires an ERC-20 mint permission and a cross-contract invariant: live coin supply plus edition equivalents stays at or below 100 million. An ERC-20 cap alone is insufficient if the controller can mint coins while NFTs remain outstanding. At both conversion steps, updates must be atomic and resistant to callbacks and reentrancy.

The benefit is that the ERC-20's reported supply falls while editions exist. The drawbacks are more complicated supply reporting, a mint-capable controller and a larger security burden. Cumulative mint counts can exceed 100 million through repeated conversion even though outstanding economic supply does not. It would be misleading to market this reversible mechanism as permanent deflation.

The existing LaunchToken has no public re-mint function, reinforcing the case for a separate fixed-supply coin and lock-based wrapper. The proposed lock-based approach achieves the desired reversible experience without needing coin reissuance.

## 4. Conversion ratio and creator controls

| Coins per edition | Theoretical maximum outstanding editions | Practical effect |
|---:|---:|---|
| 1,000 | 100,000 | Smaller collectible denomination; more editions |
| **10,000** | **10,000** | Proposed standard starting denomination |
| 100,000 | 1,000 | Larger denomination; potentially harder for casual collectors to acquire |

No ratio creates value or liquidity by itself. With a hypothetical coin spot price of 0.00001 MON, these correspond to 0.01, 0.1 and 1 MON of coin value per edition. These are reference values, not executable purchase quotes or future price forecasts.

For v1, Moments sets the ratio globally and binds it immutably into each new Moment. Creators set the media, story, name, ticker and payout identity. They do not change the ratio, total economic supply, backing rules or fee schedule after launch. If later testing supports different denominations, offer a small set of fixed presets chosen before publication; never a slider that can change for existing holders.

The NFT market price is independent. A seller can ask any permitted marketplace price, while redemption still returns the same 10,000 coins. The app should show both the executable NFT ask and the executable proceeds from selling the redeemed coins. A displayed NFT floor is not a guaranteed bid.

Buying coins and wrapping can be cheaper than buying an NFT listing, or the reverse. The two-sided conversion creates an economic link, but gas, fees, market depth, stale orders and execution risk produce a spread. Do not promise an exact price peg or guaranteed arbitrage profit.

Keep collect/redeem conversion free of protocol fees initially, with network gas shown separately. Charge disclosed trading fees at the market layer. Exact-output “Buy 1 edition” must acquire all 10,000 backing coins after trading fees or revert; dust and unused payment return to the buyer. Partial coin holdings remain valid and visible without fabricating fractional ERC-1155 units.

## 5. What OpenSea can and cannot do

| Capability | Evidence status | Moments integration |
|---|---|---|
| Monad NFT market support | Documented | Validate the actual deployed collection on Monad |
| ERC-1155 item metadata and media | Documented | Serve standard metadata, thumbnail and video |
| NFT listings, offers and order fulfillment | Documented SDK/API | Use normal NFT trades; quantities and wallet signing need tests |
| Metadata validation and refresh | Documented | Validate first, then queue ingestion refresh as needed |
| Multiple owners of one edition ID | Documented owners API | Reconcile indexer results with chain balances |
| Coin quotes and swaps | Documented, conditional on chain and routes | Test the specific coin/pool, not just Monad support |
| Custom redemption inside OpenSea | Not established for Moments | Ship redemption in DYOR; assess hooks separately |
| Guaranteed indexing, promotion, verification or liquidity | Not established | None is a product promise |

OpenSea's NFT SDK uses Seaport and supports viem, matching the web application's existing Ethereum tooling. Its documentation requires API keys to remain on a backend. Wallet transactions and order signatures must still originate from the user; a server-side API key is not permission to sign for a wallet. [^6]

The listings API explicitly accepts ERC-721 and ERC-1155 NFTs. Metadata validation reads the contract directly and does not persist ingestion; refresh queues a later update. Owners can be queried for one ERC-1155 token ID. These tools support integration debugging and inventory, but onchain balances remain authoritative. [^7][^8][^9][^10]

For token trading, OpenSea exposes chain capability discovery and a swap API. Its help center describes aggregators as the normal route providers. An arbitrary Moments bonding curve will not automatically be routable, and a DEX pool does not guarantee a quote. A confirmed quote for the actual pool/token and wallet is the acceptance criterion. [^11][^12][^13]

### Redeemables and hooks: an actual lead, with a limit

OpenSea introduced a redeemables initiative in 2023 covering ERC-7498 and Seaport improvement proposals. ERC-7498 is still marked Draft in the retrieved standard. It describes redemption campaigns and discovery, rather than a hosted service that automatically implements our backing invariant. Treat the announcement as historical evidence of the direction, not proof of present Monad UI support. [^14][^15]

Seaport contract hooks can generate orders dynamically and perform custom processing; OpenSea's documentation gives an algorithmic NFT pool as an example. It also says custom hooks integrated into the OpenSea application require further engagement. A standards-compliant contract-level conversion is technically possible, but public storefront discovery and interaction are separate acceptance questions. [^16]

Phase-one compatibility should therefore be: collect in Moments, list on OpenSea, buy there with another wallet, and redeem in Moments. Phase two can investigate a contract-offerer or redeemables adapter without changing the underlying ratio or custody model.

### SeaDrop is not required

SeaDrop addresses primary drop distribution. It is not the backing vault, price curve or liquidity provider for this design. OpenSea's current Drops FAQ distinguishes ERC-721 drops from ERC-1155 collection creation, and says custom burn mechanics require deploying a custom contract outside its standard UI. Adding a default unrestricted drop mint to a backed edition would create a path to unbacked claims and must not happen. [^17]

### Royalties are separate

ERC-2981 reports requested royalty amounts; it does not force every marketplace to pay. OpenSea documents fee enforcement through ERC721-C/1155-C validators and Seaport zones. If used, the validator must permit authorized collect/redeem lifecycle operations, and its availability on Monad must be checked. NFT enforcement does not tax an ERC-20 swap or guarantee creator fees in every external market. [^18][^19]

### Practical API surface

| Purpose | Documented operation |
|---|---|
| Chain and swap support | `GET /api/v2/chains` |
| NFT data | `GET /api/v2/chain/{chain}/contract/{address}/nfts/{identifier}` |
| Validate metadata | `POST /api/v2/chain/{chain}/contract/{address}/nfts/{identifier}/validate-metadata` |
| Refresh metadata | `POST /api/v2/chain/{chain}/contract/{address}/nfts/{identifier}/refresh` |
| Create signed listing | `POST /api/v2/orders/{chain}/{protocol}/listings` |
| NFT purchase | SDK order fulfillment, with server-prepared data and user signing |
| Coin quote | `GET /api/v2/swap/quote` |
| Coin execution data | `POST /api/v2/swap/execute` |

Pin a tested SDK version and confirm exact request/response types during implementation. These interfaces were read from documentation; no authenticated endpoint was exercised in this research. Exact Seaport, conduit, validator and DEX deployment addresses should come from verified chain-specific deployment references and bytecode, not copied from Ethereum examples.

## 6. Liquidity and graduation

There are three separate mechanisms: conversion establishes the coin/edition ratio; the trading venue establishes coin prices; graduation optionally moves liquidity between venues. Neither NFT existence nor redemption needs graduation. A pool still has a pricing curve even when there is no separate bootstrap or graduation stage.

### Option A: immediate DEX pool

A creator, DYOR or a sponsor seeds a pool and locks its LP principal while permitting fee collection. This gives one market lifecycle and is the preferred small-pilot experience when capital is available. Launch and pool initialization should be atomic so a third party cannot initialize the intended pool at an incompatible price.

Illustration: depositing all 100 million coins and 1,000 MON into an idealized full-range constant-product pool implies an initial spot price of 0.00001 MON per coin. At the proposed ratio, one edition references 0.1 MON at that spot price, before price impact and fees. The 1,000 MON is real capital, not generated by creating the coins, and the initial coin allocation leaves no free creator allocation. A creator can subsequently buy on the same disclosed terms.

Locking that principal makes sponsoring a real economic commitment. The pilot must identify its payer and budget; no sponsor is confirmed. Display capital depth and expected execution, not only a token's quoted valuation.

Single-sided concentrated liquidity is another possibility. Uniswap documents depositing one asset over a price range, so “every DEX launch requires both assets up front” would be too broad. However, active ranges, quote accumulation, sell capacity and range management still need design and tests. This is not a shortcut to guaranteed liquidity at all prices. [^20][^21]

### Option B: dedicated Moments bootstrap curve

If creators should publish without putting up pool capital, a bonding curve can accumulate real MON from buyers and migrate once a reserve threshold is reached. Use the net real reserve held by the curve, not gross lifetime volume or a manipulable USD market cap, as the trigger. Sells reduce that reserve; fees should be excluded from capital claimed as available liquidity.

A hypothetical curve using the repository's constant-product virtual-reserve approach has `S = 100,000,000`, virtual quote `V = 1,000 MON` and graduation reserve `T = 4,000 MON`. These are sensitivity inputs, not recommended production settings.

At real reserve `Q`, ignoring integer rounding and fees:

- Coin reserve: `C(Q) = S × V / (V + Q)`.
- Marginal price: `p(Q) = (V + Q)² / (S × V)`.
- Graduation: when the actual net reserve reaches `T`.
- Graduation FDV: `S × p(T)`; this is not circulating market cap or withdrawable cash.

| Derived quantity | Hypothetical value |
|---|---:|
| Initial marginal coin price | 0.00001 MON |
| Marginal coin price at graduation | 0.00025 MON |
| FDV at graduation | 25,000 MON |
| Coins sold by curve | 80,000,000 |
| Coin reserve left in curve | 20,000,000 |
| New pool coin deposit preserving final price | 16,000,000 |
| Remaining coins locked separately | 4,000,000 |
| Edition's coin-reference value at graduation | 2.5 MON |

The pool figures follow the current graduation executor's price-continuity construction: the real quote amount buys liquidity against only part of the remaining coin reserve, because virtual quote is not available to deposit. “80% sold, therefore all remaining 20% goes into the pool” is incorrect for this formula. Contract arithmetic, fee handling and concentrated-liquidity rounding still need tests.

There is no universal market price at which Moments “should graduate.” The reserve threshold follows a chosen liquidity-depth target, expected trade sizes and desired issuance distribution. For an idealized full-range constant-product pool, a net buy of `b` against quote reserve `Q` has average execution price approximately `1 + b/Q` times the starting marginal price. This permits a depth target from acceptable execution cost instead of guessing an attractive headline market cap.

If chosen, retain trading on the curve until migration, support controlled retries and define failure recovery without jeopardizing NFT backing. Wrapping stays available independently. The graduation transaction must not mint NFT editions for the curve or the LP vault.

### Option C: permanent curve

A permanent redeemable curve avoids migration, but requires a solvent long-term reserve model and usually keeps coin trading in DYOR unless aggregators integrate that market. This weakens the OpenSea coin-routing objective, so it is not the preferred first architecture.

**Decision recommendation:** choose direct liquidity for a sponsored, curated pilot; otherwise build only the dedicated bootstrap path. In either case, NFT collecting and redemption are available independently of graduation. Avoid a user-facing success narrative that equates reaching a speculative valuation with the Moment becoming valuable as an experience.

## 7. Creator earnings and pricing

Use a simple proposed 1% total coin trading fee, split evenly between creator and protocol where the protocol controls the entire relevant fee stream. In a DEX pool, the actual claim is a share of fees earned by the locked Moments LP position. If other liquidity providers enter, Moments does not capture all pool fees. Do not promise 0.5% of all venue volume unless the fee architecture actually enforces that.

The existing Monday fee vault has one global payout recipient. Moments needs its own vault with immutable pool-to-Moment attribution or one vault per Moment, plus individual claim balances. Fees received in coin and quote currency should be accounted for separately; do not promise all rewards arrive in MON without implementing conversion and slippage handling. LP principal cannot be used to pay claims.

Protocol policy should separate creator fees, protocol fees, network gas, OpenSea charges and any optional NFT royalty. Read executable marketplace fee data rather than hardcoding a presumed OpenSea percentage. A custom redeem operation returns coins, not MON; a sell after redemption is a separate market trade that can incur fees and price impact.

Creator coin holdings can appreciate or depreciate. Creator fees require eligible trading activity. Neither mechanism warrants promises of income, an appreciating NFT floor or guaranteed liquidity. Do not add holder revenue sharing in v1: it complicates wrapper accounting and the explanation of what each purchase provides.

## 8. Required implementation and integrations

| Component | Work required | Completion evidence |
|---|---|---|
| Moments factory/registry | Create coin, wrapper and metadata links; immutable supply and ratio; creator attribution | Atomic creation, one-time initialization, correct creator and no Launchpad state changes |
| Coin | Standard fixed-supply ERC-20; contract metadata; no transfer tax for compatibility | Supply invariant; direct pool and router transfers succeed |
| Edition wrapper | ERC-1155 metadata, mint against deposit, burn against release | Backing invariants and adversarial callback tests |
| Moments router | Exact-output buy-and-collect; redeem-and-sell with recipient checks, refunds and slippage | No partial unbacked mint, no leftover user funds, no forced recipient |
| Liquidity | Selected direct or bootstrap route; protected pool initialization | Forked buy/sell, pool-depth and price-continuity tests |
| Fee vault | Per-Moment fee collection and claims | Multiple creators cannot claim each other's fees; principal remains locked |
| Media | iOS capture/import, upload authorization, validation, transcoding, thumbnail, persistent pinning | Photo and video render in DYOR and OpenSea |
| OpenSea backend | API key protection, NFT data, order preparation, metadata checks, quote proxy | Actual Monad listing and fulfillment, rate-limit handling |
| Wallet signing | Human-readable NFT order review and EIP-712 signing; chain-aware approvals | Same order verifies and fulfills for supported wallet types |
| Indexing | Moments events, coin transfers, edition mint/burn/transfers, claims, reorg-aware checkpoints | Portfolio reconciles against chain after external NFT sale/redemption |
| Sharing | Public Moment URL, media preview, attribution and event grouping | Opens without a wallet; collection/trading asks for a wallet only when needed |

The native app already has EIP-712 hashing and raw-digest signing used for Perpl. That is a useful foundation, not a verified Seaport integration. Implement the exact order schema and review flow; do not substitute personal-message signing. Web and iOS should sign user-approved orders locally, with the backend limited to preparing and relaying requests.

The current Supabase bucket is images-only with a 5 MiB limit, and the launch image flow resizes images. Moments needs a distinct upload pipeline that preserves an original, produces an efficient playback asset, removes sensitive location metadata by default and stores immutable publication metadata. IPFS/Arweave references are supported by OpenSea; maintain storage availability rather than equating a content hash with permanent hosting. [^22]

Use a public thumbnail and standard video metadata. Reject unsupported or oversized files before a publication transaction, and allow draft recovery if processing or signing fails. Public media can be copied. Publication consent and creator rights are especially relevant for personal events and festival recordings; private Moments require a different access/storage product.

### Release test sequence

1. Create a separate test Moment with the exact 100 million cap and immutable ratio.
2. Buy coins, collect one edition and verify the backing balance.
3. Validate metadata, then confirm the photo/video and edition quantity appear on OpenSea.
4. List a quantity, buy from a second wallet, and verify ownership changes onchain.
5. Have the second wallet redeem in DYOR; confirm NFT supply decreases and the exact backing is released.
6. Re-collect, transfer, test partial fills and stale listings, and verify current balances are honored.
7. Test redemption while an old listing exists. An unfulfilled listing may become fillable again when the same ERC-1155 balance is reacquired, so explain cancellation/expiry and surface outstanding orders.
8. Test the chosen pool through direct swaps and OpenSea's actual coin quotes. Treat missing aggregator routes as a visible integration limitation.
9. Exercise callback attacks, double redemption, cross-Moment token substitution, unauthorized minting, rounding, refunds, wrong-chain orders, wallet signing and fee isolation.
10. If there is graduation, test last-buy clamping, retries, adversarial pre-initialized pools and backing independence through migration.

These are launch acceptance criteria, not completed results. Deployed addresses in repository files conflict with older documentation, and the earlier RPC attempt failed. Verify actual modules before reusing deployment assumptions. No authenticated OpenSea call, live listing, wallet signature, or trade was performed for this brief.

## 9. Positioning and marketing

### Narrative

Proposed public line: **“Capture it. Collect it. Keep the moment.”**

One-sentence explanation: **“Moments turns photos and videos from real experiences into collectibles you can keep, share and trade.”**

Supporting explanation: **“Each Moment has a fixed coin supply. Collect an NFT edition, or hold its coins, with a transparent conversion between the two.”**

Zora already documents instantly tradable post-level coins. That establishes an adjacent product category, not evidence that Moments has demand. The differentiating hypothesis is the combination of real-experience capture, a media-first collection experience, reversible collectible denominations and OpenSea access. Avoid claims to have invented content coins or to be the first product with NFT/token conversion. [^23]

Lead with the memory and its creator. Charts belong behind the collectible's story and media. “Turn every memory into money” would make speculation the dominant promise and obscure the fact that most content may attract no trading demand. “Backed by coins” describes redeemable coin quantity, not guaranteed cash value.

### Initial audience and distribution hypothesis

Start with creators who already have a small community around an experience: event photographers, festival hosts with content rights, travel creators and hackathon communities. Their audience has a reason to recognize and share the media. A private proposal can demonstrate the concept with consent, but it is not a strong default mass-acquisition case because it raises privacy issues and strangers may have little reason to collect it.

For the first campaign, use the hackathon launch as the milestone and organize phases relative to product readiness. No fixed event date, paid budget or partner agreement is assumed. A two-week creator pilot is a planning hypothesis; it is not a committed schedule.

| Phase | Asset and channel | Purpose | Dependency |
|---|---|---|---|
| Before demo readiness | Invite 5–10 relevant creators through their existing communities; draft a short explainer | Gather real sample Moments and usability feedback | Creator consent, working draft upload |
| Demo week | Short capture-to-collect video; product page; conversion graphic | Show a complete experience rather than a price claim | Working media, conversion and wallet flow |
| First pilot week | Curated event/travel album, creator profiles, share cards, in-person QR links | Drive recognition and genuine collecting | Publication flow and usable wallet onboarding |
| Second pilot week | Creator stories, OpenSea purchase/redemption walkthrough, feedback sessions | Test repeat participation and cross-market use | Verified OpenSea round trip |
| After pilot | Publish observed outcomes and product changes | Decide whether to expand creators, events or spend | Reliable analytics and feedback |

These are proposed activities, not dispatched outreach or paid bookings. Keep initial distribution owned and community-led. Fund media production, onboarding assistance and any approved gas support before paid promotion. Avoid purchase-volume contests, wash-trading incentives and fabricated scarcity. Conversion does not make the underlying work permanently scarcer because editions can be re-created from coins.

### Growth loop and assets

The intended loop is creator publishes → participants recognize the experience → a collector shares their edition → new viewers discover the Moment → some return for the creator's next experience. An event album can connect Moments without pooling their tokens or implying all prices are linked.

Required assets: a 30–45 second demo, public media-first Moment page, a three-step conversion explainer, creator setup guide, OpenSea handoff/redeem guide, shareable collection card, and a plain fee/rights explanation. OpenSea is a distribution surface, not guaranteed promotion or a partner endorsement. Advertise the integration only after verifying the actual flow.

Product CTAs: **Capture a Moment**, **Collect an Edition**, **Trade Coins**, **Redeem for Coins**, and **View on OpenSea**. Only show the last action when the correct item is available. The conversion confirmation should explicitly say that the edition is burned and the stated coins are returned. Use **Publish** rather than **Launch a coin** in the creator flow to preserve separation from Launchpad.

### Pilot measurements

Proposed learning targets, not benchmarks or forecasts: recruit 10 consenting creators, publish 20 valid Moments, attract 50 distinct external collecting wallets, and observe at least 10 successful OpenSea purchase-to-DYOR-redemption journeys. Exclude team wallets and flag likely self-trading; unique wallets are not necessarily unique people.

Measure upload-to-publication completion, failed transaction rate, preview-to-collect conversion, first-to-second collection behavior, seven-day returning collectors, creator republishing, actual fees claimed, and qualified referrals. For liquidity, record executable buy/sell costs at a few representative order sizes rather than treating volume or FDV as success alone. Analyze the ratio by recording whether buyers stop because one edition requires too many coins or too much current payment currency.

Review results after each pilot week. Expand only when people understand what they own, the media and external NFT flow work, and repeated use is visible. If people watch and share but do not collect, improve the value proposition and audience fit rather than changing price mechanics to manufacture activity.

## 10. Implementation decision record

| Decision | Recommendation | Status |
|---|---|---|
| Separate feature | Dedicated Moments product and contracts | Required by product direction |
| Economic supply | 100 million per Moment | Required |
| OpenSea NFT round trip | Required before integration launch claims | Required; untested |
| Conversion | Lock coins; mint editions; burn editions to release coins | Recommended |
| Denomination | 10,000 coins per edition | Proposed pilot default |
| Creator control | Media/identity; no mutable backing or ratio | Recommended |
| NFT structure | Per-Moment ERC-1155 collection, one edition ID | Recommended; validate cost and indexing |
| Liquidity | Direct seeded pool if funded; otherwise dedicated bootstrap curve | Capital-dependent decision |
| OpenSea embedded redemption | Separate advanced integration | Unconfirmed; not required for DYOR redemption |
| Creator earnings | Disclosed fee share with per-Moment accounting | Required implementation |
| First audience | Event/travel creators and their existing communities | Pilot hypothesis |

The highest-value next engineering step is a narrow integration proof: one Moment, one fixed ratio, one collectible purchase on OpenSea, and one redemption by the buyer back in DYOR. That validates the distinctive feature before building a large feed or advanced launch economics. It should run in a supported test environment first; any mainnet validation requires an explicit small spending budget and approved wallets.

## Sources

Sources were accessed September 12, 2026 unless a historical publication date is noted. Endpoint availability and contract compatibility still require execution tests. Repository references above are current source evidence rather than independently verified public-chain state.

[^1]: Ethereum Improvement Proposals. [ERC-1155: Multi Token Standard](https://eips.ethereum.org/EIPS/eip-1155).
[^2]: Monad. [Introduction and EVM compatibility](https://docs.monad.xyz/).
[^3]: OpenSea Help Center. [Which blockchains are compatible with OpenSea?](https://support.opensea.io/en/articles/8867082-which-blockchains-are-compatible-with-opensea).
[^4]: OpenSea. [Contract-level metadata](https://docs.opensea.io/docs/contract-level-metadata).
[^5]: OpenSea Help Center. [How do I delete an NFT?](https://support.opensea.io/en/articles/8867104-how-do-i-delete-an-nft), October 10, 2025.
[^6]: OpenSea. [Buy and sell NFTs](https://docs.opensea.io/docs/buy-and-sell-nfts).
[^7]: OpenSea. [Create a listing](https://docs.opensea.io/reference/post_listing).
[^8]: OpenSea. [Validate NFT metadata](https://docs.opensea.io/reference/validate_nft_metadata).
[^9]: OpenSea. [Refresh NFT metadata](https://docs.opensea.io/reference/refresh_nft_metadata).
[^10]: OpenSea. [Get NFT owners](https://docs.opensea.io/reference/get_nft_owners).
[^11]: OpenSea. [Get supported chains](https://docs.opensea.io/reference/get_chains).
[^12]: OpenSea. [Swap tokens](https://docs.opensea.io/docs/swap-tokens), [Get swap quote](https://docs.opensea.io/reference/get_swap_quote), [Execute a token swap](https://docs.opensea.io/reference/post_swap_execute).
[^13]: OpenSea Help Center. [How do I swap using OpenSea?](https://support.opensea.io/en/articles/9101569-how-do-i-swap-using-opensea), May 12, 2026.
[^14]: OpenSea. [Define the standard for NFT redeemables](https://docs.opensea.io/changelog/define-the-standard-for-nft-redeemables), August 23, 2023.
[^15]: Ethereum Improvement Proposals. [ERC-7498: NFT Redeemables](https://eips.ethereum.org/EIPS/eip-7498), Draft status in retrieved document.
[^16]: OpenSea. [Seaport hooks](https://docs.opensea.io/docs/seaport-hooks).
[^17]: OpenSea Help Center. [Drops FAQ](https://support.opensea.io/en/articles/8867061-drops-faq), May 15, 2026.
[^18]: Ethereum Improvement Proposals. [ERC-2981: NFT Royalty Standard](https://eips.ethereum.org/EIPS/eip-2981).
[^19]: OpenSea. [Creator fee enforcement](https://docs.opensea.io/docs/creator-fee-enforcement).
[^20]: Uniswap. [Concentrated Liquidity](https://developers.uniswap.org/docs/get-started/concepts/liquidity-providers/concentrated-liquidity).
[^21]: Uniswap. [Understanding Range Orders](https://developers.uniswap.org/docs/get-started/concepts/liquidity-providers/range-orders).
[^22]: OpenSea. [Metadata storage](https://docs.opensea.io/docs/metadata-storage), [Media and traits](https://docs.opensea.io/docs/media-and-traits).
[^23]: Zora. [Zora Coins Protocol](https://docs.zora.co/coins).
