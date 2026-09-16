# DYOR HQ Moments — product and integration specification

**Status:** Implementation handoff with unresolved architecture and release gates. Read the companion [critical review and decision register](moments-readiness-review.md) before implementing market, LP or publication interfaces. Product direction consolidated September 12, 2026. Production economics and external integrations require the release decisions and verification described below. This document does not claim that Moments has been built, audited or deployed.

**Latest recommended decisions:** Read [the launch recommendation](moments-launch-recommendation.md) first. It resolves all 34 review items and supersedes this document's earlier recommended defaults where specified: 2% redemption, 20,000 default denomination, surplus burn, PositionManager seed custody, individual-position LP staking/streams, exact recovery/governance policy and web-first distribution. Earlier 5% examples remain historical arithmetic fixtures, not the current recommended launch policy. Core user requirements remain unchanged. Production release still requires evidence and real configuration.

**Audience:** Product, design and engineering, including Claude working in the DYOR HQ repository.

**Authority:** This is the current consolidated Moments specification. It supersedes `moments-research.md`, `moments-product-and-integration-brief.md` and `moments-coin-only-collection-model.md` wherever they differ. The earlier documents are research history, not alternative build instructions.

## 1. Executive overview

Moments combines a freely tradable Moment Coin with a real-world experience and NFT utility with a fixed coin requirement. People capture a photograph or video, publish its Moment Coin, and let others trade individual coins or lock a fixed quantity to collect the associated NFT. Every Moment has a separate coin with 100 million initially minted units. The creator selects between 10,000 and 1,000,000 coins per NFT before publication. That per-Moment ratio becomes immutable; collecting locks the selected amount in a dedicated backing vault.

The NFT is non-transferable. Its owner can display it, view the complete media and redeem it by burning it through the Moments contract. Redemption releases the associated coins minus a disclosed fee. The user can keep those coins or sell them through available coin markets. The backing vault is not a liquidity pool and must never trade, lend or invest backing needed by outstanding NFTs.

Moments is a separate product from DYOR HQ Launchpad. Launchpad retains its billion-token model and existing behavior. Moments shares wallet, network, media-service and design infrastructure where appropriate, but has its own contract deployments, domain models, discovery, creation flow and analytics.

OpenSea is a display/discovery integration, not an NFT trading venue for this feature. The contract must reject NFT transfers even if a marketplace or indexer fails to recognize the lock. Collecting and redeeming happen through the Moments protocol, with DYOR providing the primary interface.

Proposed positioning: **“Capture it. Collect it. Keep the moment.”** The promise is an understandable collectible experience with transparent coin backing. Price appreciation, income and continuous liquidity are not guaranteed product outcomes.

## 2. Decision ledger

### 2.1 Agreed product requirements

| ID | Decision |
|---|---|
| D01 | Moments is distinct from Launchpad; no changes to Launchpad supply or live economics. |
| D02 | Each Moment has its own coin with 100,000,000 initial units and no later issuance. |
| D03 | Creator selects 10,000–1,000,000 coins per NFT for that Moment before publication; the published ratio is immutable. |
| D04 | All NFTs for a Moment display the complete original photo/video. |
| D05 | Acquisition requires depositing Moment coins; no unbacked free NFT mint path. |
| D06 | Normal NFT transfers and marketplace sales are disabled. |
| D07 | NFT holders exit through owner-authorized redemption that burns the NFT and returns coins minus fees. |
| D08 | NFT backing remains in a dedicated non-trading vault, separate from LP assets. |
| D09 | Redemption fees support project and LP economics; creator earnings remain part of the feature objective. |
| D10 | OpenSea displays the collectible and recognizes its locked state; NFT buying/selling through OpenSea is not part of the product. |
| D11 | Higher demand can increase acquisition cost through the coin market; the NFT-to-coin ratio stays fixed. |
| D12 | Moment Coins trade individually, including fractional amounts supported by 18 decimals. The creator-selected coin amount is only the NFT collection requirement, not the trading unit or a dollar peg. |
| D13 | The coin launches on a dedicated Moments bonding curve and graduates into a Uniswap v4 pool on Monad. Coin trading continues independently of NFT ownership. |

### 2.2 Recommended engineering defaults

These are concrete defaults for implementation and fixtures, not claims that every detail was explicitly selected in conversation.

| Topic | Recommended default |
|---|---|
| NFT implementation | ERC-721 with ERC-5192 locked-state support; identical media, distinct serial IDs. |
| Deployment isolation | Separate Moments factory; one coin and one collectible/backing-vault instance per Moment. |
| Upgradeability | Immutable implementations/instances for published Moments; new versions create new instances. No upgrade path over existing backing. |
| Coin decimals | 18. Use integer base units end to end. |
| Backing denomination | `coinsPerNFT * 10**18` per live NFT; creator-selected within 10,000–1,000,000 whole coins, immutable after publication. |
| Initial creator allocation | No free token/NFT allocation; creator may buy on disclosed market terms. |
| Initial pairing | Native MON on the curve; native MON / Moment Coin on Uniswap v4 by default. Confirm currency encoding and router support. |
| Initial liquidity implementation | Dedicated Moments bonding curve followed by Uniswap v4 graduation, as selected in the latest product direction. |
| Redemption execution | Plain redemption independent of any market, API, indexer or OpenSea request. |
| Conversion fees | No additional collect fee in the initial model; redemption fee policy below. Trading and gas costs remain separate. |
| Navigation | Independent Moments route/feature reached from Home and a persistent menu; do not rename or nest it inside Launchpad. |
| Media | One photo or short video per Moment, with immutable published metadata and public playback. |

The curve-to-Uniswap-v4 lifecycle is now the selected product direction. The graduation reserve threshold and fee policy still require production configuration. Do not substitute Monday Trade or a direct-pool launch without a subsequent product decision. Neither graduation nor external trading changes NFT backing or redemption.

### 2.3 Production parameters still requiring a decision

| Item | Development fixture | Production status / owner |
|---|---|---|
| Redemption fee | 500 bps total | Product owner approves after scenario review; not previously agreed. |
| Fee split, measured against gross backing | 200 bps LP, 100 project, 100 creator, 100 true burn | Proposed illustrative split; freeze the selected policy per Moment. |
| Collect fee | 0 bps | Recommended initial default. |
| Coin trading fee | 100 bps total; 50/50 creator/project for curve fixture | Validate venue and LP fee behavior separately; do not double-charge by accident. |
| Curve virtual quote / threshold | 1,000 MON / 4,000 MON | Simulation values only, not launch settings. |
| Launch/publication fee | Explicit configurable fixture, 0 in local tests | Product owner selects economic policy. |
| LP incentive mechanism | Separate escrow with a functioning local reward adapter | Eligibility and production adapter approval required before advertising payable LP rewards. |
| Fee recipients | Distinct local test accounts | Real beneficiary addresses must be supplied and verified. |
| Media pilot limits | Photo 20 MiB; video 100 MiB and 60 seconds | Engineering verifies upload/transcoding cost and device behavior; limits are server-enforced. |
| NFT batch limit | 20 NFTs per transaction | Verify gas on target chain; UI splits larger requests explicitly. |
| Primary network | Monad mainnet for product; supported test/fork environments for development | Verify current network and external-service support before deployment. |

Development can proceed with these fixtures. A deployment configuration must explicitly distinguish `development` from `production`; no production deployment may silently inherit demonstration fee percentages, recipients, or liquidity values. These are release configuration gates, not reasons to stop writing and testing the feature.

## 3. Problem, users and outcomes

People already photograph travel, celebrations and live events. They need a way to publish a collectible around that media with understandable acquisition, ownership and exit rules. The product hypothesis is that people who recognize the experience or follow its creator will collect and share it; this hypothesis has not yet been validated by user research.

Primary users are event/travel creators and their audiences. Additional users are collectors, coin traders, liquidity providers and project operators. A trader can hold coins without collecting an NFT; the product should make that distinction explicit.

### User stories

- As a creator, I can capture/import media, preview publication terms and publish one Moment without learning token-contract configuration.
- As a visitor, I can watch a public Moment and understand its creator and collection terms without connecting a wallet.
- As a collector, I can use existing coins or buy the required amount to collect one or several NFTs.
- As a collector, I can see the exact number of coins reserved for my NFTs and the fee deducted on redemption.
- As a collector, I can redeem to coins even if a swap route, indexer or OpenSea is unavailable.
- As a collector, I understand that the NFT cannot be gifted, transferred or sold on an NFT marketplace.
- As a creator, I can inspect and claim my actual accrued fees.
- As an eligible LP, I can inspect the applicable reward rules and claim only rewards earned by my eligible liquidity.
- As an operator, I can diagnose failed publication, metadata processing and indexing without holding users' wallet keys.

### Outcomes and measures

Engineering launch outcomes: complete a photo and video journey from publish to collect to redeem; prove conservation of backing and fees; block all ordinary NFT transfers; reconcile displayed holdings with chain state; demonstrate OpenSea media display and lock recognition in an environment it actually supports.

Proposed pilot goals: 10 consenting creators, 20 published Moments and 50 distinct external collecting wallets. Track seven-day repeat collecting, creator republishing, publication failures, redemption failures and fees actually claimed. These are learning targets, not forecasts. Exclude team wallets and flag likely self-trading; wallets are not automatically distinct people.

## 4. Scope and priorities

| Priority | Requirement | Acceptance summary |
|---|---|---|
| P0 | Separate Moments discovery and creation | Reachable independently; existing Launchpad still works. |
| P0 | Photo/video pipeline | Published media renders in app and standard NFT metadata clients. |
| P0 | Fixed initial coin supply and immutable denomination | No reissuance or post-publication ratio changes; validate creator-selected denomination and exact coin units. |
| P0 | Backed non-transferable NFT | Every live NFT has reserved coins; normal transfers fail. |
| P0 | Taxed plain redemption | Owner burns NFT and receives exact net coins without a swap dependency. |
| P0 | Coin buying/selling | Individual/fractional coin quotes and settlement work on the Moments curve and after Uniswap v4 graduation; no NFT required. |
| P0 | Creator/project/LP fee separation | Fee allocation and claims are attributable and solvent. LP eligibility must be implemented, not a fake payout UI. |
| P0 | Portfolio and creator claims | Counts, backing, fees and transactions reconcile with chain state. |
| P0 | OpenSea display/lock verification | Verify real metadata and rejected transfer behavior; no listing workflow. |
| P0 | Slippage, failures and recovery | Wallet rejection, unavailable market and failed uploads have recoverable states. |
| P1 | Atomic buy-and-collect | The first functional version may use purchase then collect; final polished flow can combine them. |
| P1 | Atomic redeem-and-sell | Convenience only; never replace plain redemption. |
| P1 | Broader DEX/aggregator routes | Available routes only; no promise of converting into every asset. |
| P1 | Event albums and curated creator feeds | Group media without pooling distinct Moment coins. |
| P2 | Private media, cross-chain coins, gifting/recovery transfers, holder revenue sharing, post-publication ratio changes | Each changes the ownership/security model and is outside v1. |

Do not add NFT marketplace orders, auctions, Seaport trading signatures or NFT royalty enforcement to implement the current scope. These belonged to a superseded product direction. Do not use price appreciation or artificial trading volume as an acceptance test.

## 5. Economic model

### 5.0 Moment Coin is the market asset

A Moment Coin is an ordinary fungible market asset. A user may hold 1, 2, 100 or 9,999 coins without owning an NFT, and may trade fractional coins within the token's precision. Depositing the selected per-Moment coin amount is an optional utility action that creates one backed collectible; it is not the token lot size, the token supply, or a fixed fiat purchase price.

Use unambiguous direction labels: **Collect NFT with coins** means deposit coins and mint the NFT; **Redeem NFT for coins** means burn an owned NFT and receive coins minus fees. Holding the selected coins-per-NFT amount is required for the first action, not the second.

Hypothetical values with 100 million current coins, before supply burns, market fees and price impact:

The following price and net-redemption examples assume a creator selected **10,000 coins per NFT**; substitute the actual denomination for other Moments.

| Individual coin price | Coin FDV | Spot reference for 10,000 coins / one NFT |
|---:|---:|---:|
| $0.0001 | $10,000 | $1 |
| $0.001 | $100,000 | $10 |
| $0.01 | $1,000,000 | $100 |
| $1 | $100,000,000 | $10,000 |
| $10 | $1,000,000,000 | $100,000 |

These are arithmetic scenarios, not price targets. The $1-per-coin example implies $100 million FDV with this supply; $1 billion FDV implies $10 per coin. Current FDV is spot price times current total supply; circulating market cap uses a separately defined circulating supply. Neither indicates how much cash buyers could withdraw.

The NFT has no independent marketplace price. Its gross coin backing has a reference value, its acquisition has an executable cost, and its redemption has a net executable exit value. With the illustrative 5% fee and $1 spot price, one NFT returns 9,500 coins, whose spot reference is $9,500, before sell costs. Do not label the gross $10,000 as guaranteed sale proceeds.

Buying coins can move price upward on the curve/pool; selling can move it downward. Locking coins after purchase does not itself change AMM reserves or guarantee further appreciation. The interface should let users move directly between the market view and collection utility without confusing their quantities.

### 5.1 Coin supply and denomination

For each Moment, mint `S0 = 100_000_000 * 10**18` base units once. There is no external mint function or administrator permission to increase supply. A true burn lowers current `totalSupply`; therefore public wording is “100 million initial supply; no new issuance,” not “always exactly 100 million.”

Each NFT reserves `R = coinsPerNFT * 10**18`, with creator-selected integer `coinsPerNFT` between 10,000 and 1,000,000 inclusive. Collecting does not burn that backing. The theoretical maximum live NFT count is at most `floor(currentSupply / R)`, and usually lower because coins are also held by traders and liquidity positions. A serial ID counter may exceed the initial theoretical outstanding cap over many collect/redeem cycles; maximum outstanding supply is not a lifetime mint-count cap.

The cost to acquire `R` coins comes from an executable market quote. No oracle is needed to determine backing or redemption. Views, likes and follower counts never modify the ratio or contract price. Existing holders can collect using existing coins: fungibility prevents reliably requiring that every deposit was freshly purchased.

### 5.1.1 Creator denomination controls

The publication form offers **Coins per NFT** and **Target maximum outstanding NFTs** as two ways to configure the same immutable denomination. This is a choice between Moments, never a changing ratio within a published Moment. The creator can revise it in a draft, but neither creator nor administrator can change it after publication. Existing coins still trade individually and fractionally.

| Coins per NFT | Initial theoretical maximum outstanding NFTs |
|---:|---:|
| 10,000 | 10,000 |
| 20,000 | 5,000 |
| 50,000 | 2,000 |
| 100,000 | 1,000 |
| 200,000 | 500 |
| 250,000 | 400 |
| 500,000 | 200 |
| 1,000,000 | 100 |

Use these as optional presets and permit custom values. Recommended v1 input policy: whole coins only, inclusive bounds 10,000–1,000,000. For direct denomination input, derive `initialTheoreticalCap = floor(100_000_000 / coinsPerNFT)` and display any remainder that cannot back a complete NFT. For target-count input, require an integer between 100 and 10,000 and exact divisibility of 100,000,000 by that count so the resulting denomination is a whole coin. If it does not divide exactly, explain why and offer valid nearby choices; never silently round or publish a different count. This whole-coin validation is an engineering default, not a change to the ERC-20's 18-decimal trading precision.

These are theoretical concurrent supply ceilings, not promised issued quantities, lifetime edition limits or event seat counts. LP inventory, other holders and supply burns can reduce the achievable number. Burning an NFT frees backing coins minus fees and may allow later collection again. A higher denomination increases coin backing and acquisition cost at the same coin price; it does not guarantee popularity, liquidity or appreciation.

Factory validates denomination onchain; the vault stores base-unit `R` immutably. Include the selected denomination in publication events, registry reads, draft persistence, publication confirmation and the immutable metadata. Every client derives quotes and redemption amounts from the deployed Moment, never a global 10,000-coin constant. Publish selected denomination and theoretical cap in share cards, keeping fiat acquisition quotes separate and time-stamped. The target count is derived configuration, not a second independently editable contract limit.

### 5.2 Backing conservation

Let `N` be live NFTs, `B` the dedicated vault's coin balance, `D` cumulative supply destroyed by true burns, and `F` the number of coins held outside the backing vault. Required relationships:

```text
currentSupply = S0 - D
requiredBacking = N * R
B >= requiredBacking
F = currentSupply - B
F + requiredBacking <= currentSupply
```

The final inequality allows unsolicited extra coin transfers into the vault. Such transfers never mint NFTs and are not silently claimable as user deposits. For simplicity, no generic rescue/withdrawal of the backing coin is available in v1; extra accidental deposits may remain trapped. Explain this in developer documentation and provide a proper collect function rather than encouraging direct transfers.

Do not count `currentSupply * price` plus the same NFT backing value as separate project valuation. The NFTs represent a claim on coins already included in that supply.

### 5.3 Redemption fee conservation

For `n` NFTs:

```text
gross = n * R
lpFee      = floor(gross * lpBps / 10_000)
projectFee = floor(gross * projectBps / 10_000)
creatorFee = floor(gross * creatorBps / 10_000)
burnAmount = floor(gross * burnBps / 10_000)
feeTotal   = lpFee + projectFee + creatorFee + burnAmount
net        = gross - feeTotal
```

Require nonnegative valid rates whose sum is below 10,000 bps and conforms to the factory's allowed publication policy. Selected rates are copied into each Moment and cannot change afterward. With the fixed `R` and integer bps, the displayed 18-decimal arithmetic is exact for whole NFT counts; still use explicit integer rounding and overflow checks.

Burn the NFTs, reduce backing obligations, burn only the released burn allocation, transfer fee allocations to dedicated escrows and transfer `net` to the holder in one reverting transaction. If any required operation fails, every change reverts. Fees belonging to one collector's redemption must never consume backing for remaining NFTs.

Backing and fee escrows are separate. If an implementation combines addresses, it must prove that its balance covers both NFT obligations and all fee liabilities; separation is strongly preferred. No re-minting coins on redemption is needed.

### 5.4 Reference example

For 10 NFTs at a selected 10,000-coin denomination with the illustrative 5% development policy:

| Destination | Coins |
|---|---:|
| Collector | 95,000 |
| LP reward escrow | 2,000 |
| Project escrow | 1,000 |
| Creator escrow | 1,000 |
| True supply burn | 1,000 |
| Total released backing | 100,000 |

Ten NFTs cease to exist; 99,000 coins leave the backing vault and 1,000 coins are destroyed. If there were no previous burns, current coin supply becomes 99,999,000. This does not make all released coins scarce: returned and distributed coins can be sold.

At unchanged coin prices, the holder exits with fewer coins. A 5% fee requires approximately 5.26% price appreciation just to offset the redemption fee, before trading costs and gas. Test fee variants before publication policy is finalized. Do not describe the fee as a return-generating feature for the collector.

### 5.5 Liquidity is not backing

A DEX pool trades its coins away as buyers enter. Locking an LP position prevents principal withdrawal by its owner; it does not prevent traders from buying pool assets. It cannot guarantee the fixed coin backing owed to each NFT.

The backing vault neither supplies liquidity nor earns a yield. Creator/project/LP fees are taken only from backing released by redeemed NFTs or from explicitly configured market fees. The same coins cannot be simultaneously NFT backing, LP principal and a claimable fee balance.

## 6. State and transaction flows

### 6.1 Publication

States: `draft → uploading → processing → ready → awaiting_signature → submitted → published`. Failures retain enough context to retry; rejected wallet signatures return to `ready`. Indexing and OpenSea visibility are secondary statuses, not proof of chain publication.

1. Creator selects/captures media, enters title, ticker and description, and previews public visibility.
2. Backend validates/authenticates upload and processes the thumbnail/playback asset in private staging. Do not finalize or publicly pin metadata before the creator selects and confirms the publication terms.
3. UI obtains current publication policy and fees. Creator enters coins per NFT or a target theoretical NFT count using section 5.1 validation. Display the derived immutable denomination, theoretical outstanding cap, initial supply, non-transferability, redemption fee split and optional creator buy. Bind the selected denomination into the publication transaction and confirmation.
4. After explicit publication intent and confirmation of the selected terms, finalize and publicly pin matching media/metadata. Creator then signs a factory publication transaction bound to the expected policy hash, denomination and media URI/hash. If terms change before signing, regenerate and reconfirm the metadata rather than publishing stale terms.
5. Factory creates the coin, collectible/vault and selected market atomically; records all relationships and emits `MomentPublished`.
6. Client trusts a confirmed receipt and validates event addresses, then opens the Moment. Server indexer catches up independently.
7. Queue OpenSea metadata checks only after an NFT actually exists; a published Moment with no collector may have no item yet.

The application should not expose a private draft publicly before the creator's explicit publication action. Persistent public pinning must be part of that clearly explained action. Chain publication and external uploads cannot be one atomic transaction; an upload can remain public even if the chain transaction later fails. Surface that limitation, retain retry state and clean up removable orphan staging files.

### 6.2 Collect from existing coins

1. Read chain balance, denomination and redemption policy.
2. Choose a positive NFT count within the transaction batch limit; quote backing and gas.
3. Obtain only the necessary ERC-20 spending approval where practical.
4. Deposit exact backing and mint the selected count to the authenticated holder.
5. Display new NFTs, coin decrease and reserved backing after confirmation.

If the holder has less than the selected coins-per-NFT amount, they cannot collect a fractional NFT; offer acquisition of the missing amount. Contract wallets must support safe NFT receipt. A rejected receiver callback reverts both backing transfer and NFT issuance.

### 6.3 Buy and collect

The basic flow purchases the required coins, then collects. If purchase succeeds but collection fails, the UI must show the coins still owned and a retry action. Never describe the purchase as lost or the NFT as minted before its receipt confirms.

A later atomic router obtains enough coins after trading fees, deposits exact backing and refunds surplus. Use max input, minimum outputs and deadline. No arbitrary external target/calldata router may be introduced without constrained targets and asset/recipient validation. A partial trade that cannot fund the requested NFTs must revert instead of silently collecting fewer.

### 6.4 Plain redemption

1. Holder selects owned live NFT IDs and reviews gross backing, each fee allocation, net returned coins and gas.
2. Contract verifies every selected ID belongs to the holder and is unique.
3. Burn selected NFTs, release and allocate backing, and return coins atomically.
4. UI removes those IDs only after confirmation; show their historical redemption receipt.

The v1 direct method returns net coins to `msg.sender` and requires that sender to own every NFT. Standard operator approvals do not authorize redemptions. No indexer, media server, DEX or OpenSea availability is required.

### 6.5 Redeem and sell

The first release can perform redemption then offer a swap. If the swap fails, the user owns the returned coins and can retry. An atomic version needs explicit holder authorization binding selected IDs, recipient, min proceeds, nonce, chain and expiry; it must not rely on NFT approvals. It is P1 because a shared router must not burn another person's NFTs or redirect proceeds.

Show both redemption fee and market costs. “Redeem” alone returns Moment coins, not MON or a guaranteed fiat amount. Support an output asset only when a valid executable route exists.

## 7. Smart-contract architecture

Logical components may be combined only where conservation and access control remain clear. Suggested initial file layout is `contracts/src/moments/` with tests under `contracts/test/moments/`.

| Contract/module | Responsibilities |
|---|---|
| `MomentsFactory` | Publish registry, immutable per-Moment relationships, versioned policy validation, deterministic deployment if useful. |
| `MomentCoin` | Standard ERC-20, initial mint only, controlled true burn of the caller/vault's own coins, metadata reference. |
| `MomentCollectibleVault` | ERC-721 + ERC-5192, holds backing directly, backed collect, owner-only redeem, immutable denomination and fee policy. |
| `MomentFeeEscrow` | Separate fee liabilities by Moment, beneficiary and asset; pull claims; no backing custody. |
| `MomentMarket` / `MomentCurve` | Dedicated buy/sell market for the chosen initial liquidity path. |
| `MomentGraduationExecutor` | Protected migration from the Moments curve into the Monad Uniswap v4 PoolManager. |
| `MomentV4Hook` | Protected initialization and explicitly designed per-Moment trading fee accounting; independent of the existing Launchpad hook. |
| `MomentLiquidityVault` | Holds designated pool principal and collects market fees with per-Moment attribution. |
| `MomentLPRewards` | Explicit eligible-LP program for redemption-fee rewards; separate from automatic DEX fees. |
| `MomentsRouter` | Optional convenience transactions with strict payer, asset, recipient and slippage constraints. |

Combining NFT issuance and backing in `MomentCollectibleVault` eliminates the need for a second privileged mint/burn controller call across vault contracts. Fee escrow remains separate. No administrative NFT minting or generic ERC-721 burn extension should bypass the authorized accounting lifecycle.

### 7.1 Suggested ABI responsibilities

The following is a conceptual interface, not compile-ready Solidity. Final ABI should preserve these semantics and be exported to web/iOS fixtures.

```text
MomentsFactory
  publishMoment(media, identity, coinsPerNFT, expectedPolicyHash, salt) payable -> addresses
  getMoment(momentId) -> creator, coin, collectibleVault, market, metadata, coinsPerNFT, version
  previewPublicationPolicy() -> policy, policyHash, publicationFee

MomentCollectibleVault
  collect(count) -> mintedIds             // msg.sender pays and receives
  previewRedeem(count) -> gross, feesByDestination, net
  redeem(tokenIds) -> net                 // msg.sender owns IDs and receives coins
  coin() -> address
  coinsPerNFT() -> uint256                // whole coins, 10_000 through 1_000_000
  backingPerNFT() -> uint256              // ERC-20 base units; coinsPerNFT * 10**18
  outstandingSupply() -> uint256
  requiredBacking() -> uint256
  backingBalance() -> uint256
  feePolicy() -> immutable policy
  ownerOf(id), balanceOf(owner), tokenURI(id)
  locked(id) -> true for every existing NFT
  supportsInterface(interfaceId)

MomentFeeEscrow
  claimable(moment, beneficiary, asset) -> uint256
  claim(moment, asset)                    // no redirection to arbitrary caller

MomentMarket
  quoteBuy / quoteSell
  buy / sell with slippage and deadline semantics
```

Do not add `collectFor` or `redeemFor` until payer/holder intent is authenticated. If atomic routing needs them, restrict the caller to an immutable audited router and have the router derive the user from its transaction sender or a verified typed authorization, never an unauthenticated address parameter. Third-party minting to an unsuspecting wallet would allow unsolicited non-transferable collectibles.

Events include `MomentPublished`, `Collected`, `Redeemed`, `FeesAccrued`, `FeesClaimed`, `MarketTrade` and, when relevant, `Graduated`. Record gross/net quantities and beneficiary allocations so consumers can reconcile values. Standard ERC-20/721 transfer events and `Locked(tokenId)` remain necessary. Define one canonical event schema; regenerated web and Swift decoders must agree.

### 7.2 Transfer restrictions

All account-to-account NFT movement must revert, including `transferFrom`, both safe transfer overloads and operator paths. Reject granting meaningful transfer approvals. Permit only backed minting and owner-authorized redemption burning through internal paths.

Implement ERC-165, ERC-721 metadata and ERC-5192 discovery. Emit `Locked` on mint; no ordinary unlock function exists. `locked` and ownership queries must reject nonexistent/burned IDs as appropriate. Never reuse a burned serial ID. Keep batch count bounded and handle duplicate IDs safely.

ERC-5192 is an ERC-721 extension. Do not attach its interface ID to a custom ERC-1155 and call it compatible. If engineering prefers ERC-1155 for scale, that is an explicit spec change requiring equivalent transfer and OpenSea evidence. [S1](https://eips.ethereum.org/EIPS/eip-5192)

### 7.3 Authority and failure boundaries

- A creator controls content before publication and receives their designated fees; cannot alter supply, backing, ratio or already-published exit fees.
- Factory administration may set policies for future publications, never mutate an existing holder's contract terms.
- No project administrator withdraws NFT backing or burns another wallet's coins.
- No private signing keys are stored in Supabase or the web backend.
- Standard approvals do not grant redemption authority.
- Direct transfers to the vault do not imply a deposit entitlement.
- Prevent reentrancy across collect/redeem/claim callbacks; apply checks/effects/interactions with safe receipt behavior.
- Avoid indefinite redemption pausing. If incident controls are introduced, document their exact scope; default to pausing new publications/collections rather than seizing existing exits.
- No rewards claim or fee sweep may withdraw LP principal or NFT reserves.

Use a pinned, compiler-compatible OpenZeppelin version or equivalent reviewed primitives. The repository currently uses Solidity 0.8.26 with Foundry and via-IR; do not import a newer library requiring a different compiler without an explicit compatibility assessment. [S2](https://docs.openzeppelin.com/contracts/5.x/api/token/erc20)

## 8. Coin market and graduation

The selected path is a dedicated Moments curve followed by a Uniswap v4 pool on Monad. Reuse reviewed math patterns from the repository without changing the existing Launchpad factory or deployments. Coin holders may buy, sell and transfer individual or fractional coins before or after graduation without collecting NFTs.

For a virtual-reserve constant-product curve, let `S` be initial curve token allocation, `V` virtual quote and `Q` net real quote currently held. Ignoring integer rounding and fees:

```text
curveCoinReserve C(Q) = S * V / (V + Q)
marginalPrice p(Q)    = (V + Q)^2 / (S * V)
graduation trigger   = actual net real quote reserve reaches T
```

Because coins can later be burned outside the curve, the initial curve invariant is not recomputed using shrinking current total supply. Keep market reserves and the original pricing invariant consistent. Display FDV using current supply, and label any initial-supply valuation separately. A burn outside the pool does not automatically change the pool's reserve ratio.

With the illustrative `S = 100M`, `V = 1,000 MON`, `T = 4,000 MON`, the curve sells 80M coins and retains 20M. The marginal graduation price is 0.00025 MON. Preserving it with 4,000 MON deposits 16M coins into an idealized new pool, leaving 4M separately locked. This follows the repository executor's virtual-to-real reserve transition; do not deposit all remaining 20M and claim price continuity. If the 4M surplus remains permanently inaccessible, the theoretical outstanding ceiling falls to at most floor(96M / coinsPerNFT), before burns and practical market inventory constraints. Its custody or burn treatment must be explicit in the production allocation policy; see the readiness review.

Production values require depth and stress analysis. Use actual reserves, not an NFT floor or USD market cap, as the trigger. Sells reduce real quote; gross historical trade volume is not available capital. Fees and refunded excess input do not count toward graduation reserves.

Required migration behavior: protect pool creation/initial price, preserve price within specified rounding tolerance, lock intended principal, record the actual pool/position and its fee recipient, and support a retry state if migration fails. Define recovery for a failed migration without ever touching NFT backing. NFT collect/redeem works independently of market graduation.

A direct-pool launch is outside the selected first version. Graduation requires actual trading depth and deploys the coin market, not the NFT market. Locking LP principal does not mean locking all its token inventory against market purchases. [S3](https://developers.uniswap.org/docs/get-started/concepts/liquidity-providers/concentrated-liquidity)

### 8.1 Uniswap v4 integration requirements

Uniswap publishes Monad v4 core and periphery deployments. Verify the chain-specific PoolManager, Quoter, StateView, PositionManager and supported router addresses from its current deployment reference and onchain bytecode. A pool existing on the protocol does not guarantee discovery in every frontend or aggregator. [Uniswap v4 deployments](https://developers.uniswap.org/docs/protocols/v4/deployments).

Use `contracts/src/GraduationExecutor.sol`, `MemeHook.sol`, `LaunchLocker.sol` and existing web/native v4 swap adapters as source references. Deploy separate Moments modules; do not change the Launchpad executor or share mutable fee policy. The repository's newer Monday modules are not the Moments graduation target.

Record the full v4 PoolKey: sorted currencies, fee, tick spacing and hook. Model native MON using the selected v4 native-currency convention; do not automatically wrap every quote into WMON as a v3 adapter would. Rehearse initialization, unlock/callback settlement, liquidity ownership and fee collection against actual Monad contracts.

A custom hook must handle supported exact-input and exact-output swap directions, validate PoolManager callers, prevent unauthorized initialization of its registered pool, and provide per-Moment creator/project accounting. Verify hook permission/address bits and deployment salt handling. Test external-router interoperability; do not restrict ordinary post-graduation trades to the DYOR UI. Hooks support custom pool behavior, but their effects on routing must be tested. [Uniswap v4 hooks](https://developers.uniswap.org/docs/protocols/v4/concepts/hooks).

Do not copy the existing zero-LP-fee hook configuration without accounting for LP compensation. Choose and disclose the relationship between any hook fee, native LP swap fee and redemption incentive; no double charging or promise of LP swap income where the configured LP fee is zero. Ordinary coin trading should generate eligible creator fees without requiring NFT mint or redemption activity. NFT backing never enters PoolManager.

## 9. LP rewards and creator/project revenue

### 9.1 Two different fee streams

Market swap fees accrue under the selected venue's rules. Redemption fees come from released NFT backing. They are independently accounted for and displayed. A market's creator share must refer to actual fees attributable to the project's liquidity or hook—not every trade in every external pool.

The existing `MondayFeeVault` pays one global recipient. It is a reference for locked principal and fee collection, not a complete per-Moment incentive system. Do not wire all Moments into it and call that creator/LP reward accounting.

### 9.2 Redemption fee payouts

On redemption, credit creator, project and LP amounts in the Moment coin. Beneficiaries use pull claims. Claim records key by chain, Moment, coin and beneficiary. Fees paid in coins are not realized MON income; UI can show an indicative conversion only with freshness and route caveats.

No fee swap occurs inside plain redemption. This prevents pool failures from blocking exits and avoids selling every fee allocation synchronously with a collector's redemption. If a later processor converts fees, use explicit per-asset limits, deadlines and slippage protection.

### 9.3 LP eligibility contract — required design

LP rewards need a defined set of eligible liquidity and a measurable stake. Simply sending tokens to a DEX pool does not distribute an incentive to individual LPs. A protocol-owned LP position also does not imply that unrelated external LPs receive anything.

Recommended implementation target: a dedicated, per-Moment participating LP vault with internally recorded shares for the selected pool/range and a separate epoch reward accumulator. All eligible positions use the same range/strategy so share weights are comparable. External providers opt in; the UI must not say that all LPs everywhere are covered.

Before production, specify and test:

1. Which Uniswap v4 pool and position form are eligible; verify PoolManager versus PositionManager ownership, salts/IDs, and the actual chosen position adapter.
2. How deposited liquidity is valued into shares without accepting manipulated spot valuation; require proportional deposits or bounded quotes and explicit slippage.
3. How principal withdrawal works for external providers while permanently locked protocol seed principal remains a distinct, non-withdrawable stake.
4. Reward eligibility begins no earlier than the next epoch after deposit; no same-transaction liquidity deposit/redemption/reward capture.
5. Rewards accrue against actual eligible stake over time, not an instantaneous balance at redemption. Withdrawal checkpoints must stop future accrual while preserving earned rewards.
6. A cumulative index/checkpoint implementation supports bounded-time claims without looping over all LPs.
7. No eligible stake means fees remain in the LP-designated reserve under an explicit carry-forward rule; never silently pay them to the treasury.
8. Reward funding, index rounding, share transfers or non-transferability, empty epochs and final withdrawals cannot cause double claims or stranded user principal.

This module needs its own engineering design note and invariant tests. Local development can use a deterministic eligible-stake adapter to verify fee allocation, but a production release claiming LP rewards is incomplete until a real adapter and LP deposit/claim flow are implemented. If schedule requires a narrower pilot, call the bucket “liquidity reserve,” disclose that individual payouts are not enabled, and obtain a product scope decision rather than labeling it a finished rewards program.

Adding liquidity with accumulated fees is a different feature: it requires matching quote capital, controlled conversion, or a deliberately chosen single-sided range. It is not included automatically by the LP reward allocation. [S3](https://developers.uniswap.org/docs/get-started/concepts/liquidity-providers/concentrated-liquidity)

## 10. Product interface and copy

### 10.1 Discovery

A media-first feed presents thumbnail/video preview, title, creator, category and collectible count. The primary action is opening the Moment. Secondary data includes acquisition cost, coin market state and a clear indication when trading is unavailable. Do not display a fake NFT floor or rank solely by speculative valuation.

Start with New and Curated views. Trending can be P1 once the metric is defined and resistant to trivial self-generated activity. Distinct Moment markets must not be aggregated into one misleading price.

### 10.2 Creator flow

Screens: capture/import → media preview → title/ticker/story → coins-per-NFT selection and derived ceiling → publication terms → wallet confirmation → submitted/result. Keep advanced market configuration out of the consumer flow. Creator payout identity must be visible; any address change uses deliberate verification.

The terms preview states: public media; 100M initial coin supply; selected coins locked per NFT and derived theoretical outstanding cap; NFT is non-transferable; redemption burns the NFT and deducts the exact selected fee; coin value may change. Optional creator purchase is a market transaction, not a hidden allocation.

### 10.3 Moment detail

Show full media, creator attribution, story, share action, Collect an NFT, Trade Coins, current holdings and a clear redemption entry point. Display gross backing and net redemption separately. Label transaction and metadata status honestly.

OpenSea action is **View on OpenSea** only when a verified item link exists. No **Buy on OpenSea**, **List NFT**, marketplace offer or royalty controls appear. For multiple owned serials, link the selected actual token ID rather than inventing a collection/item URL.

### 10.4 Portfolio and claims

“My Moments” groups owned NFTs by Moment but preserves individual serial IDs for redemption. Show free coin balance, owned NFT count, locked backing and net redeemable coins. A coin-only holder has zero NFTs; display that distinction.

Creator earnings show accrued/claimable/claimed amounts by asset. LP rewards identify the eligible stake program and current epoch/status. Historical burned NFTs can appear in activity, not current holdings. Value estimates never count underlying backing twice.

### 10.5 Required copy

- Collect: “Lock [coinsPerNFT] [ticker] to collect one NFT.”
- Lock explanation: “These coins stay reserved for this NFT. They are not used for trading liquidity.”
- Transfer rule: “This NFT cannot be transferred or sold. Redeem it for coins through Moments.”
- Redemption: “Burn [count] NFTs and receive [net] [ticker] after a [fee]% redemption fee.”
- Missing coins: “You need [amount] more [ticker] to collect.”
- Swap unavailable: “Your coins can still be redeemed. A swap route is currently unavailable.”
- OpenSea pending: “External display is still processing. Your NFT ownership is confirmed onchain.”

Never say that the entire video is stored onchain when only hashes/URIs are, that an NFT burn guarantees a higher price, or that redemption returns the original amount before deducting the disclosed fee.

### 10.6 Accessibility and behavior

Support Dynamic Type and screen readers on iOS, keyboard/focus navigation on web, reduced motion and existing light/dark themes. Videos start muted, respect data-saving behavior and have playback controls. Loading, wallet rejection, network mismatch, partial multistep success and retry states must be explicit. Use text/signs as well as color for financial changes.

Follow the current DYOR brand guide and design-system assets. iOS uses the native system typography and components already established in its README; web uses the approved editorial identity. Do not introduce a separate unrelated brand palette for Moments.

## 11. Repository integration map

These paths existed during review; inspect current versions before editing. `HANDOFF.md` and some launchpad docs contain stale deployment/venue claims. Source and actual verified chain configuration take precedence over those claims.

| Area | Existing reference | Proposed additions |
|---|---|---|
| Web routes | `app/launchpad/`, `app/swap/` | `app/moments/`, `app/moments/create/`, `app/moments/[momentId]/`, portfolio/claims views |
| Web domain | `app/lib/launchpad.ts`, `app/lib/actions.ts` | `app/lib/moments/{types,reads,actions,quotes,events,abi}.ts` |
| Web wallet | `app/lib/wallet.tsx`, `app/lib/use-tx.ts` | Reuse signing/simulation; add Moments-specific errors and receipts |
| Web navigation | `app/page.tsx`, `app/ui/nav.ts` | Independent Moments entry and route integration |
| Native app | `ios/DyorHQ/Launchpad/`, `Home/`, `Profile/` | `ios/DyorHQ/Moments/` screens and model store |
| Native navigation | `ios/DyorHQ/App/Router.swift`, `RootView.swift` | Add `openMoment` and Home/menu entry; avoid a sixth bottom tab without a design decision |
| Native chain services | `ios/DyorKit/Sources/DyorKit/Services/Launchpad/` | `Services/Moments/` ABI, models, reads, transaction plans and events |
| Native wallet | `ios/DyorKit/.../Chain/Transactions.swift`, `ios/DyorHQ/Wallet/` | Use existing signer abstraction; main flows need normal transactions |
| Media auth/storage | `ios/DyorHQ/Social/SocialSession.swift`, `supabase/functions/wallet-auth/` | Authenticated Moments upload/session endpoints, separate buckets |
| Database | `supabase/migrations/` | New migration after inspecting actual current numbering/schema |
| Contracts | `contracts/src/`, `contracts/test/` | Isolated `moments/` modules/tests and deployment scripts |
| ABI/deploy tooling | `scripts/export-abis.mjs`, `scripts/sync-deployment.mjs` | Separate Moments artifacts and address map, without overwriting Launchpad config |
| Brand | `public/brand/dyorhq-brand-guide.md`, `public/brand/dyorhq-design-system.md` | Reuse identity and platform-specific conventions |

The primary native target is SwiftUI in `ios/`. `mainstreet-app/` is a separate mobile working tree; do not assume it is the implementation target or modify both mobile stacks. Web and SwiftUI should both support the core collection lifecycle; native adds phone capture and web adds public shareable discovery.

## 12. Media, metadata and storage

### 12.1 Pipeline

Use separate private draft/staging storage and published media storage. The existing `launch-media` bucket is images-only and limited to 5 MiB; do not silently expand it for another product. Reuse authenticated wallet identity, not its restrictive file processing assumptions.

Validate actual media bytes, MIME, size, duration and dimensions server-side. Reject executable/HTML uploads in v1. For video produce broadly supported MP4 playback and a still thumbnail; preserve an original if policy permits. Remove precise GPS metadata by default. Upload/transcoding must be retryable with idempotent job IDs and content hashes.

A proposed pilot limits originals to 20 MiB for images and 100 MiB/60 seconds for videos. Those values are configuration defaults to cost-test, not OpenSea limits. The app reports restrictions before a large upload. Native capture includes appropriate camera/microphone/photo-library permission copy and handles denied access.

Pin immutable published metadata and media to content-addressed storage using a maintained provider and backup/redundancy plan. Supabase can hold drafts, job status, delivery URLs and indexes. Do not call a content hash a guarantee of perpetual availability. Signing a transaction does not verify that the creator owns the photographed scene or footage; obtain a publication-rights attestation and provide reporting/moderation for app discovery.

### 12.2 Canonical metadata

Any numeric denomination in the JSON example below is illustrative. Generate the actual selected denomination and derived theoretical cap at publication and verify agreement with the contract.

OpenSea reads ERC-721 `tokenURI`; `image` supplies the photograph/thumbnail and `animation_url` supports video. All serials can resolve to the same immutable media JSON. Individual ownership and serials remain onchain. [S4](https://docs.opensea.io/docs/metadata-standards)[S5](https://docs.opensea.io/docs/media-and-traits)

```json
{
  "name": "Sunset After the Festival",
  "description": "A Moment published by its creator. Collect with its Moment coin. This NFT is non-transferable; redeem through DYOR HQ for coins minus the disclosed redemption fee.",
  "image": "ipfs://THUMBNAIL_OR_PHOTO_CID",
  "animation_url": "ipfs://PLAYBACK_VIDEO_CID",
  "external_url": "https://APP_DOMAIN/moments/MOMENT_ID",
  "attributes": [
    { "trait_type": "Category", "value": "Travel" },
    { "trait_type": "Coins per NFT", "value": 10000 },
    { "trait_type": "Transferability", "value": "Locked" }
  ]
}
```

Omit `animation_url` for photos. Placeholder values above are not deployable URLs. The registry provides authoritative coin, vault, creator and policy linkage; JSON does not override contract accounting. Avoid current price or outstanding supply in immutable metadata, since both change. Serve changing values from live chain reads in the app.

Implement `contractURI` for collection-level identity. OpenSea uses contract ownership for creator attribution, but ownership capabilities must not grant economic mutation rights. The initial registry/metadata identity can derive from a committed creator+salt Moment ID, avoiding a circular dependency between metadata CID and contract address. Publish coin linkage onchain and resolve it from the Moment page. [S6](https://docs.opensea.io/docs/contract-level-metadata)

### 12.3 Moderation and permanence

App moderation can hide an item from discovery, stop processing malicious content and remove an app-hosted rendition. It cannot promise deletion of independently pinned public media or erase onchain ownership. Moderation never freezes plain redemption. Do not implement private Moments by merely hiding a public URL.

## 13. Backend, data and indexing

Supabase serves indexed product data and authenticated drafts; it is not the ledger of NFT ownership or redemption entitlements. Review existing remote schema before writing migrations because the README describes earlier migrations not all present in the local folder. Never include service-role credentials or private wallet keys in client builds.

### Suggested entities

| Entity | Key fields / purpose |
|---|---|
| `moment_drafts` | UUID, creator wallet, media job ID, content fields, selected coinsPerNFT, derived theoretical cap, confirmed policy hash, status, timestamps; owner-only writes |
| `moment_media_jobs` | Owner, content hash, staging key, validated MIME/size/duration, processing state, published CIDs, safe error code |
| `moments` | Chain ID, factory, Moment ID, creator, coin/vault/market addresses, publication block, metadata URI, version |
| `moment_policy_snapshots` | Moment key, ratio and fee split as exact integers, policy hash |
| `moment_events` | Chain ID, transaction hash, log index, block number/hash, event type, decoded exact values |
| `moment_nfts` | Chain ID, collection address, serial ID, owner, minted block, burned block/status |
| `moment_market_snapshots` | Reserve amounts, market phase, quote timestamp, route state; cache only |
| `moment_fee_balances` | Indexed accrued/claimed amounts by Moment, beneficiary, asset; reconciled against contracts |
| `moment_indexer_checkpoints` | Chain/factory, block hash, replay position, health |
| `moment_reports` | Reporter, Moment reference, category, moderation state; permissions appropriate to role |

Use composite unique keys for chain/address/ID and `(chainId, txHash, logIndex)` event deduplication. Store large integers as decimal strings or sufficiently sized exact numeric columns; never JavaScript floating-point numbers. Onchain mint/redeem/fee records are written by a trusted indexer, not the public client.

RLS: users edit their own drafts and upload paths; public users read published/allowed discovery data; ownership and financial indexes are service-written. Client requests cannot forge creator identity by submitting another wallet address. Reuse verified wallet-auth session claims.

Indexer processing should be idempotent, ordered and resumable. Store block hashes and handle reorg/replay; a permanent browser session is not an indexer. Use bounded RPC log ranges and backoff. Derive NFT ownership from standard transfer events and accounting from canonical custom events. Reconcile aggregate backing, outstanding counts and claim balances against chain reads periodically and before critical UI confirmations.

If indexed data is stale, expose freshness and read the needed values directly. Redemption must not depend on the backend agreeing the user owns an NFT; the contract is authoritative. NFT selection can fall back to user-provided known IDs/receipt history where index availability fails.

### Suggested backend routes

```text
POST /api/moments/drafts
POST /api/moments/uploads
GET  /api/moments/media-jobs/:id
POST /api/moments/drafts/:id/prepare-publication
GET  /api/moments
GET  /api/moments/:id
GET  /api/moments/:id/activity
GET  /api/moments/:id/opensea-status
GET  /api/moments/:id/quotes
POST /api/moments/:id/reports
```

Mutation routes authenticate the wallet and enforce ownership/idempotency. Quote routes return bounded data, not arbitrary destinations from user input. Use cache/rate limits for public reads. The API never exposes a server-signed user transaction. Log useful status/errors without bearer tokens, upload credentials or wallet secrets.

## 14. OpenSea integration

### Required behavior

1. Standard NFT metadata resolves, including image/video.
2. Minted IDs and their actual owners can be discovered.
3. `Locked` events and ERC-5192 identify the asset as non-transferable.
4. OpenSea marks the NFT ineligible for trading, per its documented lock support.
5. The onchain contract rejects transfer regardless of external UI state.
6. The item links back to the public Moment page and redemption explanation.

OpenSea documents the lock event behavior; actual Monad collection indexing, playback and UI state must be observed. A valid interface or successful metadata validation is not proof of completed indexing. [S7](https://docs.opensea.io/docs/locked-and-staked-nfts)

### API responsibilities

| Operation | Endpoint / approach |
|---|---|
| Supported chain metadata | `GET /api/v2/chains` |
| NFT fetch | `GET /api/v2/chain/{chain}/contract/{address}/nfts/{identifier}` |
| Metadata validation | `POST /api/v2/chain/{chain}/contract/{address}/nfts/{identifier}/validate-metadata` |
| Refresh | `POST /api/v2/chain/{chain}/contract/{address}/nfts/{identifier}/refresh` |
| Wallet display reconciliation | NFTs-by-account endpoint, backed by chain checks |
| Deep link | Use a verified actual asset URL, not a guessed unindexed path |

Keep API keys server-side. Use cached fetches, rate-limit handling and background refresh queues; do not request a refresh on every view. Metadata validation does not itself persist indexing, and refresh is asynchronous. [S8](https://docs.opensea.io/reference/validate_nft_metadata)[S9](https://docs.opensea.io/reference/refresh_nft_metadata)

OpenSea coin swapping is optional discovery/routing, distinct from NFT display. Do not implement NFT listing, offer, drop minting, custom marketplace redemption, ERC-7498 campaigns or enforced marketplace royalties for v1. A supported-chain response does not guarantee a route for the new coin. No OpenSea partnership or promotional placement is implied.

Integration evidence must contain the actual chain, contract, NFT ID, metadata response, item URL/screenshot, owner read and rejected transfer simulation/transaction result in a safe test setup. No private API keys appear in evidence artifacts.

## 15. Configuration and environments

Separate Moments address manifests from Launchpad manifests. Suggested files: `contracts/deployments/moments/<chain-id>.json`, `app/lib/moments/deployment.json`, and a matching native Moments configuration. Each records chain ID, factory/module addresses, deployment block, ABI version and policy identifiers. Never overwrite `contracts/deployments/143.json` or existing app launchpad addresses as a side effect.

Use explicit development/test/mainnet configurations. Validate RPC chain ID, nonzero bytecode and configured relationships at startup/deployment. Public chain addresses are safe client configuration; API keys, pinning credentials, storage signing credentials and service-role tokens remain backend-only.

Potential secret/config categories: Monad RPC endpoint, Moments addresses, OpenSea API key, storage/pinning provider credentials, media processor endpoint, app public domain, creator/project/LP beneficiaries, deployment signer and approved publication policy. Document them in an example configuration with placeholders only; never copy real secrets into the handoff or repository.

The repository contains nonzero contract deployment records and an app fallback file with zero Launchpad addresses; environment overrides may change runtime behavior. Earlier public RPC verification failed. Recheck actual deployment state rather than assuming the existing contracts are live or absent. Monad documentation is the source for current network configuration. [S10](https://docs.monad.xyz/developer-essentials/network-information)

## 16. Acceptance and security test matrix

| ID | Scenario | Required result |
|---|---|---|
| A01 | Publish a Moment | Exactly 100M coins issued, correct creator/media linkage, isolated addresses and policy. |
| A02 | Attempt later coin mint / NFT admin mint | Reverts; no alternate issuance path. |
| A03 | Collect 10 NFTs at a selected 10,000-coin denomination | Exactly 100,000 coins received as backing; 10 live locked NFTs; correct events. |
| A04 | Insufficient coins or rejected receiver | Full transaction reverts; no loss of backing or partial NFT issue. |
| A05 | Redeem with illustrative policy and 10,000-coin denomination | 95,000 returned, 4,000 fees, 1,000 true burn for 10 NFTs; all sums exact. |
| A06 | Partial redemption | Remaining NFTs retain full gross backing. |
| A07 | Duplicate IDs, already-burned ID or another owner's ID | Reverts; no double payout. |
| A08 | Direct/safe/operator NFT transfer | All reject, even with attempted approvals. |
| A09 | Unauthorized router redemption | Cannot burn holder NFTs or redirect funds. |
| A10 | Malicious callback on collect/claim | No reentrant mint, redemption or fee theft. |
| A11 | Repeated collect/redeem fuzz sequences | Supply, backing and fee invariants always hold. |
| A12 | Donations to backing/fee contracts | Cannot fabricate ownership or fees; liabilities remain valid. |
| A13 | Multiple Moments and assets | No cross-Moment claims, backing use or reward leakage. |
| A14 | Fee beneficiary rejects payout | Pull claims isolate failure; other holders can redeem. |
| A15 | DEX/API/media outages | Plain redemption still works; correct degraded UI. |
| A16 | Curve buys/sells/final buy | Fee math, net reserve trigger, clamping/refunds and slippage hold. |
| A17 | Migration / pre-initialized pool | Price validation, no wrong-price deposit, no backing exposure, retry behavior explicit. |
| A18 | LP fee collection | Correct Moment attribution; principal inaccessible to fee claims. |
| A19 | LP incentive attacks | No same-transaction reward capture, double claims or invalid stake weighting. |
| A20 | Media publication failure | Retry/recovery preserves draft state; public pinning status is honest. |
| A21 | OpenSea display | Media, owner and locked state verified for actual deployed asset. |
| A22 | Index replay/reorg | No duplicate balances/fees; aggregate values reconcile to chain. |
| A23 | Web/Swift ABI fixtures | Matching calldata, decoded events and base-unit quantities. |
| A24 | Existing Launchpad regression | Supply defaults, routes, ABI consumers and deployments remain intact. |
| A25 | Accessibility | Essential flows usable with assistive technologies and enlarged text. |
| A26 | Creator denomination boundaries | Accept 10,000 and 1,000,000; reject values outside bounds or non-whole-coin input; contract and clients agree. |
| A27 | Count input and preview | 50,000 coins derives 2,000 NFTs; 5,000 NFTs derives 20,000 coins; invalid/nondivisible target counts are not silently rounded. |
| A28 | Per-Moment denomination isolation | Collect/redeem at different selected ratios uses each vault's immutable R; metadata, web and Swift match; no global ratio assumption. |
| A29 | Ratio immutability and supply limits | Post-publication mutation fails; burns and repeated collection preserve backing and theoretical concurrent limits without imposing an accidental lifetime mint cap. |

Run Foundry unit/fuzz/invariant tests for the new contracts. Use fork integration tests for the selected real DEX; simulated mocks alone cannot establish venue compatibility. Run relevant Swift package tests, app build checks, web typecheck/lint/build and targeted user-flow verification after implementation. Capture final command exit status; a build timing message is not success evidence.

No test should require spending real funds by default. Live OpenSea checks may require a chain it supports and explicit small deployment/gas budget; prepare scripts and exact reviewable transactions before that release step. A failed external dependency is reported, not substituted with a fabricated success screenshot.

## 17. Delivery plan

### Phase 1 — protocol slice

Implement isolated coin, collectible/backing vault, policy and fee escrow with local invariant tests. Demonstrate minting 10 NFTs, rejecting all transfers and redeeming under the fixture split. Export one canonical ABI/fixture set. This phase establishes the distinct product's ownership model before building its feed.

### Phase 2 — market and LP accounting

Implement the Moments curve, native quotes, buys/sells, Uniswap v4 graduation and separate fee accounting. Complete LP incentive design and real stake adapter or explicitly identify a narrower liquidity-reserve pilot. Validate migration, post-graduation trading and failure recovery on a Monad fork.

### Phase 3 — media and product UI

Build draft/upload/processing/publication, discovery, Moment detail, holdings, collection, redemption and claims in SwiftUI/web. Add transaction recovery and stale-data behavior. Implement direct two-step flows first; combine transactions only after correctness is established.

### Phase 4 — external display and indexing

Run continuous indexing, standard metadata, OpenSea lock/display tests, share links and published-media moderation. Remove any inherited UI that suggests NFT listing or free redemption.

### Phase 5 — release candidate

Complete test matrix, address manifests, source verification plan, deployment dry run, selected production economics, real beneficiary addresses, media cost plan, LP reward policy and rollback/incident runbook. Produce a demo video and evidence ledger. Deployments and live fund movement follow the explicit production authorization/budget for that environment.

No fixed delivery date was supplied. Sequence by dependencies rather than inventing a calendar estimate. Do not declare the full feature complete with placeholder LP rewards, mock onchain holdings or unverified OpenSea behavior.

## 18. Marketing and launch assets

Lead with experiences and creators, not price promises. The acquisition loop is creator publishes → participants recognize media → collectors share their collection page → new viewers discover the creator. A share is a link/image, not a transfer of the locked NFT.

Required launch assets: public feature explainer, photo/video demo, a conversion graphic showing the creator-selected coins per NFT and theoretical outstanding cap, non-transferability explanation, fee example, creator setup guide, redemption troubleshooting and a clear OpenSea display walkthrough. Use **Capture a Moment**, **Collect an NFT**, **Trade Coins**, **Redeem for Coins** and **View on OpenSea** consistently.

Start with consenting event/travel creators and their existing audiences. Pilot scope is deliberately small; no partner, ad budget or OpenSea endorsement is assumed. Measure genuine repeat participation and completion rates. Avoid trading-volume competitions or “burns make the price rise” messaging.

Public explanation: “Lock Moment coins to collect an NFT of the experience. Your NFT stays with your wallet. When you redeem, the NFT is burned and the reserved coins are returned minus the disclosed fee.” Explain that the market price of coins may rise or fall and that redemption does not itself convert into cash.

### 18.1 Moment Coin narrative and sharing loop

Proposed product explanation: **“Every Moment has a coin. Trade the coin, or lock its collection amount to collect the Moment.”** The experience/media creates a reason to care; the freely traded coin creates a market; the collectible provides a clear use for the coin. This is a product hypothesis, not a mechanism that guarantees virality.

Three complementary audiences: participants who recognize the experience; fans who want the collectible; traders who want coin exposure without an NFT. The UI supports all three. Share cards should feature the media, creator, event/story and a link to both coin trading and collection. Public readers see individual coin price separately from the current cost of the selected coins-per-NFT amount.

Potential loops to test: event attendees sharing their personal collection page; creators documenting the event before and afterward; fans collecting a milestone and inviting friends into the story; event albums connecting independent Moments. Early collector dates can provide truthful social context without promising returns or manufacturing scarcity.

Measure share-to-visit, visit-to-coin-purchase, purchase-to-collection, repeat collectors, creator republishing and actual creator fees. Keep net buy/sell flow and price changes separate from organic audience growth. A modest engaged community can generate fees; a viral price spike is neither required nor sufficient for sustained creator income. No wash-trade incentives, price-target contests or fabricated activity.

### 18.2 Event invitations and admission — proposed extension

A wedding invitation or event pass is a useful candidate utility, but an NFT containing invitation artwork does not automatically confer admission. Do not advertise a real ticket until an organizer defines eligibility, capacity, event time, check-in and cancellation rules. This extension is proposed for subsequent product design, not silently added to the core P0 collectible scope.

The key distinctions are:

- A Moment Coin can be open to trading while attendance remains restricted by an organizer's allowlist or verified invitation. Buying coins alone does not guarantee a seat.
- At the immutable creator-selected coin requirement, a rising price also raises the cost for later guests. Private events need to decide whether this is appropriate; avoid promising universally affordable admission.
- A collectible backed by redeemable coins is not ordinary non-refundable ticket revenue. Its locked coins belong to redemption backing, not the organizer's event budget. Real ticket-sale revenue requires a separate disclosed charge or economic model; do not spend the backing on the event.
- An admission claim must bind to an eligible, live NFT and authenticated holder. Redeeming before check-in invalidates that claim. Check-in consumption must persist even after the NFT burns.
- Recollecting an NFT does not reset a consumed invitation or create unlimited event capacity. Track event-level invitation IDs/eligibility and consumed attendance independently of NFT serial IDs and cumulative mint counts.
- QR admission requires replay-resistant challenges and authenticated organizer check-in, not a reusable screenshot of a public NFT. Wallet access, accompanying guests and recovery require explicit UX decisions.
- After attendance, redemption should retain its disclosed coin terms. Do not retroactively freeze or confiscate backing. Event cancellation policy cannot promise a fixed-dollar refund from volatile coin backing.

Start the demonstration with a commemorative event Moment whose utility is clear. Treat real admission as an additional tested feature, rather than assuming the NFT contract already implements a ticketing system.

## 19. Build handoff checklist

The implementation report accompanying a finished build should include:

- Completed P0 requirements with file references and test evidence.
- Final contract interfaces, immutable fields, privileged roles and invariant results.
- Exact chosen fee/market configuration, clearly distinguished from fixtures.
- Deployment manifests and verification status for each environment.
- Web and iOS demo paths, including failure/retry flows.
- Actual OpenSea item display/lock evidence, or a plainly identified outstanding blocker.
- LP eligibility, accounting and working claim evidence; no ambiguous “LP revenue” label.
- Migration/RLS details, media storage configuration and indexer operation instructions.
- Remaining P1/P2 work and material risks, without presenting it as complete.

Before starting implementation, inspect current repository guidance and relevant files. Use this document's latest product direction rather than restoring the older transferable ERC-1155/OpenSea trading design. If an implementation change would alter the fixed backing claim, disable holder exits, enable NFT transfers, change existing Launchpad behavior or publish an unapproved production fee policy, make the proposed difference explicit for review.

## 20. Sources and verification boundaries

Primary sources support standards and integration expectations, not successful deployment of this feature. Documentation accessed September 12, 2026. Repository sources were inspected directly for the implementation map. There has been no Moments contract audit, authenticated OpenSea integration test or mainnet transaction in this specification task.

- [S1 — ERC-5192: Minimal Soulbound NFTs](https://eips.ethereum.org/EIPS/eip-5192): locked ERC-721 interface and transfer semantics.
- [S2 — OpenZeppelin ERC-20 reference](https://docs.openzeppelin.com/contracts/5.x/api/token/erc20): standard token behavior and genuine supply-reducing burns; select a compiler-compatible release.
- [S3 — Uniswap fees](https://developers.uniswap.org/docs/get-started/concepts/fees), [concentrated liquidity](https://developers.uniswap.org/docs/get-started/concepts/liquidity-providers/concentrated-liquidity): pool inventory, active liquidity and fee distinctions.
- [S4 — OpenSea metadata standards](https://docs.opensea.io/docs/metadata-standards): tokenURI/JSON metadata.
- [S5 — OpenSea media and traits](https://docs.opensea.io/docs/media-and-traits), [metadata storage](https://docs.opensea.io/docs/metadata-storage): video/image fields and storage references.
- [S6 — OpenSea contract-level metadata](https://docs.opensea.io/docs/contract-level-metadata): collection metadata and creator attribution.
- [S7 — OpenSea locked and staked NFTs](https://docs.opensea.io/docs/locked-and-staked-nfts): documented lock-event indexing behavior.
- [S8 — OpenSea validate NFT metadata](https://docs.opensea.io/reference/validate_nft_metadata): validation is not persisted indexing.
- [S9 — OpenSea refresh NFT metadata](https://docs.opensea.io/reference/refresh_nft_metadata): asynchronous refresh request.
- [S10 — Monad network information](https://docs.monad.xyz/developer-essentials/network-information): verify current chain and deployment environment.
- [OpenSea supported chains](https://support.opensea.io/en/articles/8867082-which-blockchains-are-compatible-with-opensea): general Monad support; not proof of a specific asset's display.

- [Uniswap v4 deployments](https://developers.uniswap.org/docs/protocols/v4/deployments): Monad-specific contracts and periphery; verified documentation, not execution evidence.
- [Uniswap v4 hooks](https://developers.uniswap.org/docs/protocols/v4/concepts/hooks): custom pool behavior and integration design.
