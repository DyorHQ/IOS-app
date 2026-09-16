# Moments: research and proposed implementation

> Implementation source of truth: [DYOR HQ Moments build specification](moments-build-spec.md). Use that consolidated document for implementation; this document is retained as research history.

> Current direction: [Coin-only collection and taxed redemption](moments-coin-only-collection-model.md) supersedes the NFT transfer, OpenSea trading, and fee-free redemption assumptions below. Collectibles are now proposed to be non-transferable, with coin-backed acquisition and taxed redemption. Earlier sections are retained as research history.

> Superseded design direction: see [Moments product and integration brief](moments-product-and-integration-brief.md). Moments is a separate 100-million-supply product with dedicated contracts; Launchpad stays at 1 billion. The newer brief makes OpenSea NFT integration required and proposes 10,000 coins per edition instead of the initial one-coin example below.

Research date: 2026-09-12. This is a design recommendation, not an implemented feature or a contract audit. Repository findings below come from current source; public-chain deployment was not verified because the read-only RPC request failed.

## Decision

Moments is feasible on Monad. Treat each moment as one photo/video and one independent market with a maximum of **100,000,000 coins per moment**. Every holder sees the entire media file; the file itself is not cut into pieces.

For the fastest hackathon version, use an ERC-20 Moment coin and immutable media metadata. For the fuller requirement that buyers also receive an NFT visible on OpenSea, add a fully backed ERC-1155 representation: users can hold the same units as coins or NFT editions, with explicit conversion. This is a custom application architecture, not an OpenSea fractional-NFT product.

Do not describe an ERC-20-only balance as an NFT in a user's wallet. If receiving a native NFT on every purchase is essential to the demo, the ERC-1155 conversion must be part of the MVP, not deferred.

## What exists in this repository

| Area | Current evidence | Relevance to Moments |
| --- | --- | --- |
| Web | `app/`, React 19 / Next 16 conventions, vinext, viem, wallet discovery, launchpad routes, swap adapters, Perpl integration | Reuse wallet confirmation, discovery, quotes, trade history, and holdings patterns |
| Native iOS | `ios/DyorHQ/`, SwiftUI; `ios/DyorKit/` contains RPC, ABI, launchpad, swap, Perpl, and Supabase services | Best fit for phone capture; reuse launch flow and transaction confirmation |
| Other mobile code | `mainstreet-app/` is a separate working tree described in HANDOFF as an Expo app | Do not assume it is the current native implementation; primary review focused on SwiftUI and web |
| Strategy/social | iOS includes copy-trading models/watchers, market-making UI, social profiles and wallet authentication | Creator identity and social distribution can build on existing surfaces |
| Coin contracts | `LaunchToken.sol`, `LaunchpadFactory.sol`, `BondingCurve.sol`, `LaunchAndBuyRouter.sol` | Fixed supply, launch configs, launch-and-buy, curve liquidity, fee routing |
| Media | `SocialSession.uploadLaunchImage`, `09_launch_media_storage.sql` | Existing authenticated upload; bucket currently permits images only, up to 5 MiB |
| Graduation | `MondayGraduationExecutor.sol`, `MondayFeeVault.sol`, `DeployFeeVault.s.sol` | Newer implementation targets Monday's v3-style pools; LP fees can be collected to one global recipient |

Documentation drift matters: HANDOFF and launchpad-spec still say undeployed / Uniswap v4. `contracts/deployments/143.json` contains nonzero addresses and a newer fee-vault executor, whereas `app/lib/deployment.json` has zero launchpad addresses. Web environment overrides can supersede that file. These records establish configuration differences, not proof of current chain state. iOS also contains contradictory fee copy. Resolve actual deployed modules and update UI claims before shipping Moments.

`LaunchToken` already has name, symbol, logo, description and socials, but does not implement NFT `tokenURI` / `uri` or standard NFT interfaces. A logo URL alone will not make OpenSea display an ERC-20 as an NFT.

## Standards and marketplace findings

Monad provides EVM bytecode compatibility, so Ethereum ERC-20, ERC-721 and ERC-1155 implementations are applicable; a special Monad NFT standard is unnecessary. OpenSea explicitly lists Monad among its supported chains. [Monad documentation](https://docs.monad.xyz/), [OpenSea supported chains](https://support.opensea.io/en/articles/8867082-which-blockchains-are-compatible-with-opensea).

| Model | What the buyer owns | Fit and tradeoff |
| --- | --- | --- |
| ERC-721 alone | A unique token ID with one owner | Cannot give many wallets simultaneous ownership of the same token ID |
| ERC-1155 editions | A quantity of one token ID; all units share the same media | Closest simple NFT interpretation. Supply cap must be implemented. Existing ERC-20 swap/curve contracts cannot trade it directly |
| ERC-20 media coin | Fungible units associated with a photo/video | Fits the existing launchpad and 100M supply. No native NFT appears just because coins were purchased |
| ERC-721 held in a vault plus ERC-20 shares | A tokenized claim whose redemption rules must be defined | Appropriate for shared ownership of a single original. Requires custody, redemption/buyout design; shareholders do not each receive the original NFT |
| ERC-20 plus backed ERC-1155 editions | Either tradable coins or redeemable NFT editions | Recommended extension when both DEX trading and an OpenSea collectible matter |
| ERC-7631 dual-nature pair | Linked ERC-20 and ERC-721 balances | Can synchronize NFT issuance with coins, but adds transfer/gas complexity and fractional-balance UX |

ERC-1155 supports fungible quantities within a token ID. ERC-7631 specifies discoverable links and optional NFT skipping; it does not supply the synchronization implementation. Automatically minting/transferring NFTs on large coin transfers can exceed gas limits. These are reasons to prefer explicit conversion for this project. [ERC-1155](https://eips.ethereum.org/EIPS/eip-1155), [ERC-7631](https://eips.ethereum.org/EIPS/eip-7631).

OpenSea separates NFT marketplace orders from token swaps. Seaport can exchange ERC-721/1155 assets for payment, while OpenSea's swap API provides token quotes and executable transactions. Neither feature establishes an automatic 100M-share fractionalization mechanism. Check chain swap support through `GET /api/v2/chains`, then request a quote for the actual Moment coin. General Monad NFT support does not guarantee a route or indexing for a newly launched coin or its private bonding curve. [Seaport](https://docs.opensea.io/docs/seaport), [token swaps](https://docs.opensea.io/docs/swap-tokens), [chain discovery](https://docs.opensea.io/reference/get_chains).

## Concrete experience

1. Creator captures or imports a photo or short video, previews it, and gives it a title, ticker and description.
2. The app shows the fixed 100M supply, creator fee, launch cost, optional creator purchase and public-media status before signing.
3. Upload and media processing finish before the launch transaction. The contract records a permanent metadata reference and creator identity.
4. A buyer opens the Moment, sees the whole photo/video, and buys coins through the existing curve.
5. Their portfolio shows the Moment and coin balance. Buying 10,000 of 100M coins represents 0.01% of coin supply, not automatic ownership of copyright, the relationship, or creator revenue.
6. With the NFT extension, the buyer can choose “Collect as NFT”: an explicit conversion locks coins and issues identical ERC-1155 editions. An atomic buy-and-collect router can combine purchase and conversion.
7. NFT holders can transfer/list editions through compatible NFT marketplaces, or redeem editions back into coins and trade through the coin market.

All units refer to the entire Moment. NFT edition ownership and coin ownership must not be counted twice in portfolio valuation.

## Proposed contract design

### Coin and registry

Reuse the existing factory with a dedicated launch config of `100_000_000 * 10**18`, subject to actual deployed-module compatibility. The current deploy script defaults to 1 billion, so a UI label change is insufficient. Require the Moments registry to verify the exact supply and known factory origin.

Add a `MomentsRegistry` mapping a Moment ID to creator, coin address, metadata URI, content hash and optional edition ID. Registration must be authorized by the original launch deployer, allow one binding per coin, and freeze after publication. Blockchain registration proves who registered a hash; it does not prove who filmed the event.

For the smallest integration, launch through the existing wallet/router, then register after confirmation; keep the item in a recoverable “finish publishing” state until both steps complete. Do not assume an arbitrary new router can call `launchTokenFor`: the current factory restricts it to its configured router. Atomic publication requires explicit router/factory integration and preservation of creator attribution, exemptions, refunds and expected-economics checks.

### Optional NFT representation

Use one ERC-1155 collection with one token ID per Moment and a wrapper holding that Moment's ERC-20:

- Deposit `n * 10**18` base units to mint `n` editions.
- Burn `n` editions to redeem `n * 10**18` base units.
- All editions for one Moment resolve to its shared metadata.
- NFT issuance requires actual backing; no unbacked admin mint or reserve withdrawal.
- Track issued supply explicitly; ERC-1155 alone does not impose a cap.
- Fractional coins remain coins; the NFT edition interface uses whole units. A different conversion ratio is possible but must be fixed and disclosed.

Invariant: wrapper coin balance must be at least `editionSupply * 10**18`. Coin supply stays 100M; economically circulating unwrapped coins plus backed edition equivalents never exceed that supply. Pool, curve and other locked coin balances are still part of the same 100M.

Use established ERC-1155 code, safe receipt checks, reentrancy protection, verified token registration and bounded batch operations. Test receiver callbacks and wrap/unwrap within atomic trades. Set holder fee sharing off initially: otherwise wrapper-held coins would earn rewards that need separate pass-through accounting for NFT owners.

This provides editions of one work, not fractional title to a unique ERC-721 original. If a single original NFT with buyout rights is the desired product, choose a vault/share model instead and define redemption before implementation.

## Media implementation

OpenSea reads ERC-721 `tokenURI` or ERC-1155 `uri`. Metadata uses `image` for the picture/thumbnail and `animation_url` for video; MP4 is supported. [Metadata standard](https://docs.opensea.io/docs/metadata-standards), [media fields](https://docs.opensea.io/docs/media-and-traits).

Proposed metadata shape (illustrative URIs):

```json
{
  "name": "She Said Yes",
  "description": "A Moment captured by its creator.",
  "image": "ipfs://THUMBNAIL_CID",
  "animation_url": "ipfs://VIDEO_CID",
  "external_url": "https://YOUR_DYOR_DOMAIN/moments/MOMENT_ID",
  "attributes": [{ "trait_type": "Category", "value": "Life event" }]
}
```

Keep creator/coin linkage authoritative in the registry. For photos, omit `animation_url`. The NFT metadata method serves the JSON URI; the ERC-20 app view resolves the same registry entry.

Use Supabase for drafts, processing state and delivery if convenient. Add a separate Moments media flow for video validation/transcoding, thumbnail generation, retryable uploads and playback. The current iOS upload resizes images to 640 pixels and the current bucket excludes video; neither is a preservation pipeline for original Moments.

For durable publication, pin original media, a playback version, thumbnail and metadata to content-addressed storage with maintained redundancy. Store the content hash/reference onchain. This is onchain ownership and provenance with externally stored media, not the entire video stored on Monad. A CID verifies content but does not guarantee perpetual availability. Strip location metadata by default and make publication visibility clear before upload/pinning; public files can be copied even after the app hides them.

## Creator earnings

Separate three mechanisms:

- **Curve trading fees:** existing curve code can allocate fees to the creator. Proposed MVP: a simple disclosed creator/protocol split, holder sharing off, and no inherited extreme launch-time snipe tax without a deliberate product decision.
- **Post-graduation LP fees:** current `MondayFeeVault.collectFees(pool)` sends fees to one `lpFeeRecipient`. Add pool-to-Moment attribution and per-creator claim accounting at collection, or separate vaults per Moment. Preserve locked principal. A global splitter without pool attribution is insufficient. Fees apply to liquidity earning them, not every trade in every external pool.
- **Price appreciation:** benefits a creator only to the extent they hold coins, and realizes proceeds when they sell. The existing flow has no free team allocation; an optional creator buy can supply this exposure. A rising market cap is not creator revenue, and launch liquidity is not a creator payout.

Illustration only: if eligible volume is 100,000 MON and the creator receives 0.5% of that volume, gross creator fees are 500 MON. This is not a volume or income forecast. Buys and sells can both generate fees while the price falls.

ERC-2981 reports royalty information but does not force payment. OpenSea documents enforcement for ERC721-C/1155-C through transfer validators and Seaport hooks; that does not enforce fees on ERC-20 swaps. Validator support and wrapper compatibility on Monad would need separate verification. Keep collectible royalties optional initially rather than making perpetual royalties a core promise. [ERC-2981](https://eips.ethereum.org/EIPS/eip-2981), [OpenSea creator fee enforcement](https://docs.opensea.io/docs/creator-fee-enforcement).

## Build sequence and release evidence

1. Confirm chain bytecode, factory configs, current executor/vault and app address configuration; reconcile outdated launchpad and fee copy.
2. Add 100M config, Moments registry, creator attribution and image publication. Reuse existing curve trading and wallet confirmation.
3. Add video capture/import, processing, content-addressed metadata, playback and shareable Moment pages.
4. Implement per-Moment post-graduation fee accounting and creator claims. This is required before promising continuing creator income.
5. Add backed ERC-1155 collection and buy/collect/redeem flow if OpenSea NFT ownership is a launch requirement.
6. Verify NFT metadata, image/video rendering, balances, listing and purchase on OpenSea's actual supported Monad environment. Test ERC-20 swap discoverability separately. Do not make OpenSea indexing a prerequisite for native DYOR trading.

Required contract evidence: supply cannot increase; unauthorized registration fails; double wrapping/unbacked minting fails; arbitrary receiver reentrancy fails; sell/redeem slippage and refunds work; full supply can move through curve/graduation without NFT mint loops; each pool's fees reach its own creator; fee claims cannot withdraw LP principal. Include graduation into a pre-existing or adversarially initialized pool in the fork tests.

Required product evidence: publication can resume after upload/transaction failure; each Moment plays in app and metadata consumers; holdings and valuation do not double count wrapped balances; creator fee claims match recorded eligible fees; external API outages do not prevent direct chain trading.

Recommended hackathon scope: Monad/MON pair, one file per Moment, fixed supply, creator fees, buy/sell, holdings and sharing. Add the NFT representation when the demo specifically needs a collectible in OpenSea. Defer revenue-sharing promises, buyouts, cross-chain deployment and automatic dual-nature NFT synchronization.
