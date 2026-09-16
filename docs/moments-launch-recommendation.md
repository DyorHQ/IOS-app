# Moments: recommended product, protocol and launch decisions

## Executive decision

Build Moments as **a way to collect a creator's real experience, with an independently tradable coin underneath it**. The consumer story is: watch the moment, collect it if it matters to you, display your connection, and redeem for coins when you choose. The creator story is: publish a memorable experience, bring your existing community, and earn a disclosed share of eligible trading and redemption fees.

Preserve the core requirements: separate from Launchpad; 100 million initial Moment Coins; creator-selected immutable 10,000–1,000,000 coins per NFT; transferable ERC-20 coins; non-transferable ERC-721 collectibles; dedicated backing; owner-authorized redemption; a Moments curve graduating to Monad Uniswap v4; OpenSea display rather than NFT sales.

The recommended launch profile is **20,000 coins per NFT by default, a 2% redemption fee, free collection apart from gas and coin acquisition, a 1% curve trading fee, and a v4 pool with a 0.3% ordinary LP fee plus a 0.7% input-based hook charge**. Fee composition is explained below; v4 charges must not be misrepresented as an exactly additive 1% in every execution path.

Start with a public-web pilot serving a curated group of event and community creators. Build native capture and portfolio integration, but separate native distribution approval from web release. Real event admission, private media, paid referrals, perpetual rewards promises and custom atomic redemption routing are deferred. Public LP incentives remain a required, separately tested module before marketing that benefit.

This report resolves the review's 34 design questions into recommendations. It supplements `moments-build-spec.md` and replaces its earlier demonstration defaults only in the recommended profile described here. It does not authorize deployment, spending or promotional outreach. Numeric settings are engineering candidates backed by the model below; they are not proven optimal economics. Actual security, distribution and demand evidence remain release gates.

## 1. Positioning and the reason to collect

### R01: collector motivation

The strongest criticism is correct: someone seeking only price exposure is better served holding coins than collecting and incurring a redemption fee. Accept that. Do not force speculative traders to mint NFTs. The NFT is for people who value a visible connection to the experience or creator.

The first collection benefits should be an attributable collectible with original media, a unique serial, first-collection date, a personal collection page, and optional inclusion in a creator's collector wall. These features must be useful on their own. No claim of copyright ownership, equity, revenue participation, verified attendance or guaranteed exclusivity is implied.

POAP provides a relevant precedent for collecting shared memories and community identity. Its issuer guidance also distinguishes verified participation from indiscriminate distribution. Moments can borrow the community emphasis while recognizing that its speculative coin market and refundable backing are materially different.[^1] Zora demonstrates an existing content-coin category; this is not an invention of content monetization itself. Its documentation also scopes rewards to its markets. Moments must differentiate through experience capture and understandable collection/redemption, rather than claim every global trade pays a creator.[^2]

The product should show public media free of charge. The action below it is **Collect this Moment**, with **Trade coin** secondary but accessible. A funded collector sees a single clear confirmation containing the coins locked, gas, non-transferability and eventual redemption charge. A trader sees normal individual-coin trading without an NFT obligation.

Current collectors and historical collectors must be distinct. An NFT burn removes current ownership; history can show that someone once collected. Avoid free historical badges promising the same continuing benefits as a live NFT. Do not create monetary privileges for low serials or repeat mints. Creator wall participation is opt-in for profile association; blockchain ownership remains public regardless.

### R02–R03: edition meaning and allocation

Use “coins per collectible” as the main creator setting. Default to **20,000**, with selectable presets and custom whole-coin values in the agreed inclusive range. The reverse NFT-count input remains a convenience calculation; it is labelled “initial theoretical maximum,” never “guaranteed edition size.” Nondivisible target counts receive valid suggestions, not silent rounding.

No lifetime mint cap and no reused serials. Each live NFT requires full backing. NFTs burned today can be replaced by newly numbered NFTs collected later. A live collectible is not proof that its holder attended an event.

Allocate all 100M initial coins to the curve; no free team or creator allocation. Creators may buy under the same fee rules as everyone else, with the purchase visible. At successful migration, **burn actual surplus coins that cannot enter the price-preserving seed position**, instead of leaving a permanently inaccessible, unburned surplus. Use a dedicated migration burn authority that can burn only its own held surplus; it cannot touch holder balances or backing.

This is an explicit recommendation replacing the earlier permanent-surplus-lock fixture. Under the idealized 1,000/4,000 MON profile, approximately 4M coins burn, leaving 96M total supply before redemption burns. The initial theoretical count at 20,000 is 5,000; after this migration burn it is at most 4,800. Pool and wallet inventories make actual simultaneous collection lower. Publish both the initial supply and current supply. Burning leftovers does not create an automatic price increase; the pool price is set by its reserves.

## 2. Economics that users can understand

### R04: curve and graduation profile

Choose a virtual-reserve constant-product curve. Keep parameter control at the platform-policy level, immutable per published Moment. Creators choose media, identity and denomination; they do not edit virtual liquidity, hooks or fee schedules.

Recommended initial simulation profile:

| Variable | Recommended candidate |
|---|---:|
| Initial curve coin inventory S | 100,000,000 coins |
| Virtual MON reserve V | 1,000 MON |
| Real MON graduation reserve T | 4,000 MON |
| T / V | 4 |
| Coins sold by graduation, idealized | 80,000,000 |
| Seed pool coins, idealized | 16,000,000 |
| Surplus burn, idealized | 4,000,000 |
| Seed pool MON, before execution dust | 4,000 |
| Initial marginal price | 0.00001 MON per coin |
| Graduation marginal price | 0.00025 MON per coin |

For real net quote reserve Q: `C = S*V/(V+Q)` and `p = (V+Q)^2/(S*V)`. Fees and refunded excess do not increase Q. Actual contract math uses integers and bounded rounding, not floating point.

These MON amounts are candidate launch parameters, not a declaration of affordability at the current dollar price. Before production, compare the resulting first-collection cost against the intended audience and their actual willingness to pay. If MON's purchasing power makes the pilot unsuitable, scale V and T together for future launches, preserving T/V = 4; never mutate existing markets or use a live USD oracle to rewrite their curves.

The model compares T/V values of 4, 9 and 19. Increasing that ratio sells 80%, 90% and 95% before graduation but reduces idealized pool coin inventory from 16M to 9M and 4.75M. That worsens the coin-side depth for a fixed NFT denomination. The starting choice is therefore 4, not an aggressive sell-through target.

### R07: complete fee policy

Set the redemption fee to **2%** of gross released backing:

| Destination | Percent of gross backing | Coins from a 1M-backed NFT |
|---|---:|---:|
| Holder | 98% | 980,000 |
| Eligible LP incentive program | 0.75% | 7,500 |
| Creator | 0.50% | 5,000 |
| Project | 0.50% | 5,000 |
| True burn | 0.25% | 2,500 |

The 2% choice is a product judgment to reduce exit friction, not a research-derived optimum. It gives a fee-only break-even price increase of about 2.04%, compared with 5.26% for 5%. Swaps, gas and price impact add costs. No collect charge, NFT royalties or token transfer tax. Set the publication fee to zero for the curated pilot; rate-limit subsidized media publication and reconsider a transparent creation fee only for future policies if actual costs require it. Fees are immutable per Moment; any later experiment uses a visibly new publication policy.

Curve trading charges 1%: 0.5% creator, 0.3% project, 0.2% LP-designated reserve. Charge buys against gross MON input and sells against gross MON output. That yields MON-denominated curve fees and supports creators even when nobody collects an NFT.

V4 uses an ordinary static LP fee of 3,000 units (0.3%) and a custom 70-bps hook charge split 50 bps creator / 20 bps project. The hook charges in the swap input asset: MON on buys, Moment Coin on sells. For exact-input, remove the hook amount before normal pool execution; for exact-output, calculate and collect the input-side charge from actual pool input using a rounding-up gross-up calculation. At 70 bps, hook-inclusive input is `ceil(poolInput * 10,000 / 9,930)`. Allocate the hook charge proportionally 5/7 creator and the remainder project. Test the actual return-delta implementation; this is not a drop-in change to the existing quote-asset hook.

For exact-input, sequential 0.7% then 0.3% charges imply approximately 0.9979% of gross input before any pool protocol-fee interaction. Show actual quoted fees by asset, not a universal “exactly 1%.” V4's fee field uses hundredths of a basis point, unlike the application's 10,000-bps denominator.[^3] Record protocol-fee settings and actual LP proceeds in the integration fixture. External pools without this hook are outside creator/project fee coverage.

Freeze the full fee matrix in each publication's policy hash. No referral fee in v1. No hidden creator exemption. Native MON claims use a pull-payment escrow with an owner-selected WMON claim option if the beneficiary cannot receive native currency; wrapping requires a verified WMON contract and does not alter accrued amounts.

### R32: valuation and user quotes

Show free coins, reserved backing, live NFT count, current coin supply, net redeemable coins, and a timestamped executable quote. Never add NFT backing value to the value of those same coins. Avoid a headline “NFT floor.” Use “coins locked” and “estimated cost to collect.”

Use MON as the canonical quote currency. Optional USD estimates can use a cached independent MON price feed, but disable them when more than 60 seconds stale and never use them for settlement. The first build can omit USD entirely until a provider and identity mapping are verified; that is a clearer default than inventing a reliable oracle.

A standard 20,000-coin NFT initially costs about 0.20004 MON in the idealized curve. Just after the illustrative graduation it costs about 5.0063 MON before fees. At the 1M denomination, a fresh pool purchase costs about 266.67 MON rather than the 250 MON spot estimate. This difference is price impact, not an undisclosed platform fee.

Redeeming a 1M-backed NFT under the recommended 2% fee returns 980,000 coins. Selling them into the illustrative pool yields about 230.86 MON before swap fees, versus a 245 MON spot reference. Large batch exits have much greater impact. Each comparison assumes the same independent initial pool snapshot.

Default slippage tolerance: 1%; quote refresh: 10 seconds; transaction deadline: 60 seconds. Reconfirm if more than 5% estimated price impact; require an explicit additional confirmation above 15%. Plain coin redemption never uses these price-impact checks. Users may sell voluntarily at an unfavorable price after informed confirmation; the app must not trap exits by enforcing a minimum market value.

### Scarcity and ongoing revenue

Collection removes coins from free circulation but does not burn them. Redemption returns coins and fee allocations outside backing, except for the true burn. At the proposed 0.25% burn, redeeming 1M gross backing puts 997,500 coins outside the vault and destroys 2,500. Do not portray redemption waves as necessarily bullish.

Creator revenue is earned only from actual eligible fees; refundable backing is never creator working capital. The project should not rely on redemption taxes or speculative token appreciation to fund operating expenses. At 0.3% project share, covering $300 of expenses solely from eligible curve volume would require $100,000 of equivalent volume before other costs. Post-graduation hook proceeds have a different share and may be received in the Moment Coin. These are unit-economics examples, not volume forecasts.

## 3. Failure-safe protocol decisions

### R05–R06: market lifecycle

Use four explicit states: CurveTrading, GraduationPending, V4Trading, RescueSellOnly. A never-graduating market remains on its curve without an arbitrary expiration. NFTs remain collectible and redeemable in every state, subject only to actual coin possession and the NFT rules.

The threshold buy commits only once. Attempt migration in an isolated external subcall that either completes everything or reverts everything: reserve sweep, protected pool initialization, liquidity mint, seed lock, surplus burn and registry update. If that subcall fails, catch it and enter GraduationPending with the actual reserves still held by the curve. Reserve custody must not move to an intermediate account after failure.

Permit anyone to retry graduation. After **24 hours from the first failed committed threshold attempt**, permit anyone to activate irreversible RescueSellOnly if migration is still pending. Retrying does not reset the clock. Rescue disables future buys and migration; allows fee-free curve sells subject to actual MON reserves; never sweeps money to an administrator. Ordering determines whether a simultaneous retry or rescue wins, and the second operation must reject the changed phase. Twenty-four hours is the recommended pilot recovery window, not a chain requirement.

NFT redemption continues even during a stuck migration, with no dependency on an operator, API, market or LP reward process. Exiting to coins is guaranteed by backing invariants; selling those coins for a particular amount of MON is not guaranteed.

### R08, R17–R20: authority and interfaces

Creator and project beneficiaries are immutable account addresses for a published Moment. Use a creator-controlled recoverable wallet where available and a project multisig. Signer rotation inside those wallets does not change the protocol beneficiary. No factory owner can redirect existing claims.

Moment Coin is a standard 18-decimal ERC-20. Only the collectible vault and graduation executor are authorized to call the explicit burn method, and each can burn only its own balance. Do not expose a public burn-from-other-accounts route or holder-reward transfer callbacks. Holders can transfer coins normally; sending coins to an inaccessible address is not reported as a total-supply burn.

Use ERC-721 plus ERC-5192. `collect(count)` takes coins from and mints to `msg.sender`; `redeem(ids)` requires ownership by and pays `msg.sender`. Every transfer path fails except accounting-controlled mint and burn. No operator redemption, free admin mint, unlock or generic inherited NFT burn. Batch cap 20. ERC-5192 communicates locked status; it does not prove personal identity or prevent changes in wallet control.[^4]

ABI units: `coinsPerNFT()` returns whole coins; `backingPerNFT()` returns base units. Every balance, fee and amount in events uses base units. Store numeric values as BigInt / exact decimal strings in clients and exact numeric database columns. Define event schemas once and generate web and Swift fixtures from one ABI source.

Factory governance is a 2-of-3 multisig with a 48-hour delay for future publication-policy changes. It can immediately pause new factory publications. Published instances have no upgrade path, backing withdrawal or redemption pause. I recommend no per-instance admin collection pause in v1: a partial pause adds authority without repairing immutable unsafe contracts. On an incident, hide unsafe actions in the app, pause new publications, preserve evidence and publish the known issue; do not promise to reverse irreversible contract losses.

Security scope includes failure of dependencies used by redemption. Redeeming credits fee escrow only; it does not invoke a swap, LP position operation, reward claim or price oracle. Keep that escrow immutable and small, with exact per-asset liabilities and no arbitrary external calls during accrual.

### R14–R16: bots and transaction convenience

Protect initialization of the canonical PoolKey with factory registration and hook caller checks. Anyone may create an unrelated pool for a transferable coin; accept this rather than attempting global trading censorship. Do not claim per-wallet limits prevent Sybil participation. Provide transparent public launch terms, no privileged creator tax exemption, and no fake activity or volume competitions.

In v1, use buy then collect, or redeem then sell, with one guided UI showing each actual transaction. If a buy reaches graduation before buying enough coins, wait for the new phase, requote the missing amount, then collect. Do not silently mint fewer NFTs or treat a completed buy as lost when collection fails.

Defer custom atomic routers. Where a verified wallet can batch existing direct calls from the same account, it can improve UX later without adding arbitrary recipient privileges. Any future signed authorization must bind chain, verifying contract, vault, action, payer, recipient, amount/IDs, maximum input or minimum output, nonce and expiry. EIP-712 structures the signature but does not itself supply replay protection; contract-wallet authorization requires ERC-1271 validation.[^5]

## 4. A concrete LP program

### R09–R13: separate seed liquidity, ordinary fees and incentives

Use **Uniswap v4 PositionManager NFTs** for the new Moments implementation. This is a deliberate change from copying the repository's core-owned locker layout. The seed position is full-range, held by a dedicated immutable seed locker. It can collect fees through a zero-liquidity decrease and take-pair action; no arbitrary call, approval or nonzero decrease is exposed. Uniswap documents this fee-collection mechanism.[^6]

Seed principal is permanently locked. Ordinary fees earned by the seed position go to a disclosed per-Moment liquidity maintenance reserve, with no treasury sweep in v1. They are not distributed to unrelated external LPs. They remain visible and reserved; the first release does not automatically reinvest them. This sacrifices some capital efficiency to keep fee collection separate from potentially manipulable rebalancing. External positions earn their own normal 0.3% pool fees under v4 rules.

Use a static full-range pool with tick spacing 60 and fee 3,000. Sorted currencies are native MON (`address(0)`) and Moment Coin. Derive full-range usable ticks from the pinned v4 library; do not hardcode unrounded bounds. Verify Monad PoolManager, PositionManager, StateView, Quoter and router bytecode/relationships from current deployment references and a fork test. A protocol deployment does not guarantee frontend routing of a custom hook.[^7]

For extra redemption incentives, implement **per-Moment staking of full-range PositionManager NFTs**, not a pooled share vault. This removes proportional minting, shared-principal valuation and share-transfer bookkeeping from v1. It still requires dedicated tests and security review.

1. A provider independently creates a position in the canonical pool using bounded quote/deposit amounts. They own the position and its normal LP fees.
2. They explicitly stake the position NFT in `MomentLPRewards`. Verify actual PositionManager, PoolKey, full-range ticks, nonzero liquidity, ownership and expected safe-transfer context. Reject unsolicited transfers as registrations.
3. The NFT remains in custody, so the owner cannot change its liquidity while staked. Staking records position ID, beneficiary, fixed liquidity units and deposit time. There is no transferable stake receipt.
4. Position liquidity units determine reward weight, never spot-valued dollars. Restricting all eligible positions to the same pool and range makes those units comparable.
5. After a **24-hour warm-up**, anyone can activate the stake; activation earns only prospectively. The app or keeper calls activation, but the holder can do so independently. There is no retroactive activation or hidden requirement to keep a browser open.
6. The holder can withdraw the position at any time, including during warm-up. Checkpoint reward accounting, deactivate it, then return the position to its beneficiary. Accrued incentive claims remain available after withdrawal. Withdrawal does not require claiming incentive tokens or collecting ordinary pool fees.
7. Fee collection while staked is a constrained operation on that exact position, paying its recorded beneficiary. It cannot withdraw liquidity or change approvals. A failed fee payment does not prevent separately withdrawing the position.

Recommended minimum accepted liquidity is `max(1, seedLiquidity / 1_000_000)` integer liquidity units, fixed per Moment at graduation. This limits meaningless dust stakes without using dollar-price manipulation. It is a gas/abuse default to test, not a minimum investment promise.

### R10–R11: reward streaming and backlog

Maintain separate reward accumulators for MON and Moment Coin. Curve LP allocations accrue in MON; redemption allocations accrue in the Moment Coin. New rewards enter a per-asset queue. **Never call `donate` to distribute a redemption lump sum to whichever liquidity happens to be active in the pool.** That would not implement the chosen eligibility/warm-up rules.

When no stream is running and at least one stake is active, anyone can start a **seven-day stream** from the queued funds for that asset. Funds arriving during a stream queue for the next stream, so repeated small top-ups cannot keep resetting the finish time. Each asset has its own stream balance, duration and cumulative reward-per-liquidity index; all updates are O(1), with no loop over participants or historical epochs.

For elapsed eligible time `dt`, the index increases by released reward units times fixed precision divided by active liquidity. Checkpoint global and individual indexes before activation, withdrawal or claim. When active liquidity becomes zero, pause the remaining stream duration; no reward is assigned to absent LPs. Later activation resumes remaining duration. Round down payouts, retain unallocated dust as reward liabilities and roll completed-stream dust into the next queue. Implement rewards with integer arithmetic and `mulDiv`, backed by an independent reference model.

Protocol seed liquidity is **excluded** from this extra incentive program. External providers earn all of its distributions. If nobody ever stakes, allocated fees remain in the per-Moment LP reserve indefinitely; they are never reassigned to the project. An initial eligible provider may earn a large share of the early stream while supplying liquidity over time. This is an explicit program rule, not a claim that timing advantages disappear. Warm-up and streaming prevent instant past-reward capture; they do not remove rational competition for announced future rewards.

This program intentionally differs from the previous shared-vault/epoch outline. It answers eligibility, ownership, entry, exit, no-stake periods, backlog, fee assets and principal separation with fewer moving parts. It must still be verified for adversarial timing, arithmetic overflow, checkpoint order and reward solvency before real funds enter.

## 5. Media, publication and data operations

### R21–R24: concrete service choices

Retain the repository's web stack and Supabase authentication/database. Use private Supabase Storage for image staging, Cloudflare Stream for private video upload/transcoding, Cloudflare Queues and Workers for orchestration, Pinata Public IPFS for immutable published media/metadata, and an R2 archive for the exact published bytes/CIDs. This is an intentional small set of managed services; no custom video transcoder service in the first release.

Cloudflare supports one-time creator upload URLs and resumable tus uploads without exposing service credentials.[^8] Keep draft videos signed/private. Once processing succeeds, obtain a controlled MP4 export and thumbnail, validate the export, and publish the approved bytes to IPFS; Stream supports MP4 downloads, including signed access for private assets.[^9] Stream playback is a fast app delivery path; the NFT `animation_url` points to the public immutable MP4 CID rather than an expiring Stream URL. The Stream rendition and published MP4 must represent the same approved content. Store signing/provider secrets only in backend bindings. Do not accept arbitrary remote fetch URLs: allow only configured provider endpoints and verified object IDs, cap response size and prevent redirects into private networks.

Pinata supports scoped signed uploads with expiry, size and MIME constraints.[^10] For public publication, prefer server-orchestrated upload of validated outputs, not direct publication of an unvalidated original. Reuse Supabase RLS for owner-only draft paths; service-role credentials stay server-side.[^11]

Publication order: private upload → processing → creator selects content/denomination → reads fee policy → confirms public publication and rights → finalize media/metadata → pin public CIDs → sign transaction bound to creator, salt, policy hash, denomination and metadata hash → observe receipt → finalize indexed publication. Any changed terms require regenerated metadata and renewed confirmation. Public pinning can succeed before a chain transaction fails; explain that accurately.

Initial operational defaults:

| Setting | Recommendation |
|---|---|
| Photo input | 20 MiB maximum; validate decoded dimensions and reject decompression bombs |
| Video input | 100 MiB, 60 seconds maximum |
| Display output | JPEG/WebP photo and thumbnail; MP4 H.264/AAC compatibility verified on web, iOS and OpenSea |
| Upload URL | 30-minute scoped session; creator ownership and allowed origins checked |
| Creator quota | 3 processing jobs and 3 new public Moments per day during pilot |
| Draft retention | Delete abandoned staging after 7 days; completed unneeded originals after 24 hours |
| Job retries | 5 bounded exponential retries with jitter, then dead-letter queue and visible retry/support state |
| Processing target | 95% ready within 2 minutes for supported pilot files; not an advertised guarantee |
| Public pinning | Metadata/media retrievable through primary gateway; archive and CID manifest retained independently |
| Moderation | Review pilot creators/media before featured distribution; report and unfeature tools from day one |

Verify actual codec/metadata outputs rather than assuming transcoding strips sensitive location information. Normalize photos to remove EXIF/GPS. Do not attempt large video processing inside a normal request handler. Workers coordinate and stream provider operations under actual runtime limits; a queue message contains references rather than media bytes.

Queues provide at-least-once delivery, so every job and publication handler must be idempotent; configured retries need a dead-letter queue.[^12] For large uploads, resumability matters more than a visually elaborate upload screen. Never copy example permissive CORS policies without scoping them to the app.

### R22, R25–R26: identity, indexing and wallet continuity

Use `chainId + factory + creator + salt` as publication identity. Retries reuse the salt; a unique constraint prevents duplicate draft submission. Tickers and titles are display text, not identifiers. A duplicate-content hash warns a creator but does not automatically ban legitimate reuse. Attributable creator verification requires a signed social-profile link or manual pilot verification; a media hash is not authorship proof.

Use a scheduled indexer with a durable checkpoint, bounded log requests and advisory locking to avoid competing workers. Reconcile backing and fee totals against contracts. Store block hashes and roll back replayed derived records safely. Finalized state comes from the provider's verified finalized block tag and matching receipt block hash; treat a latest receipt as confirmed/pending finality until that check succeeds. Monad documents standard RPC tags, but verify each provider actually implements them rather than substituting a guessed number of seconds.[^13]

Add bounded owner-ID pagination to the collectible contract: owner arrays plus swap-and-pop index mappings, updated on mint/burn only. Cap each read at 100 IDs and pin multi-page reads to one block when possible. No global enumeration loop. The standalone recovery page can discover owned IDs and redeem through direct contract reads even without the indexer.

Persist transaction intent ID, wallet, chain, nonce and submitted hash. Distinguish replacement, cancellation, reverted transaction and delayed receipt. On account or network change, invalidate unsigned quotes and confirmations. A submitted transaction continues to be monitored for its original account; do not relabel it as belonging to the newly selected wallet.

Use existing self-custodial Privy wallet integration. Offer existing-wallet connection and clear funding instructions; do not introduce backend custody. Privy currently documents Monad gas sponsorship, but its EVM sponsorship involves account delegation and must be tested against the actual web/native SDKs.[^14] Make sponsorship an optional capped pilot enhancement after that integration test. Direct user-paid gas remains functional. Sponsorship never purchases the coins or silently authorizes unrelated actions.

### R24: operating budget

Use an initial **$300/month infrastructure planning envelope**, excluding labor, audits, legal work, deployment gas, paid acquisition and liquidity. This is a proposed budget, not authorized spend. Alert at 50%, 75% and 90%; at the cap suspend new subsidized uploads and sponsorship before impairing published holdings or redemption access. Keep a separate explicit archival-service runway.

Cloudflare's published Stream pricing lists $5 per 1,000 stored minutes and $1 per 1,000 delivered minutes. Thus 100,000 complete 30-second views represent 50,000 delivered minutes, approximately $50 for that delivery component; one million represent approximately $500. Other providers, API calls and archive costs are additional.[^15] Do not assume going viral is operationally free. Limit autoplay, use thumbnails in feeds, cache public read data and meter views and storage independently from transaction revenue.

## 6. OpenSea, native distribution and rights

### R27: OpenSea implementation

Implement ERC-721 metadata, ERC-5192 discovery, `Locked` on mint, `contractURI`, image and MP4 metadata, and a correct external Moment URL. OpenSea documents supported lock events as marking assets ineligible for trading.[^16] That is the desired behavior; no NFT listing, offer, royalty, Seaport campaign or custom marketplace redemption integration is needed.

Keep API keys on the server, use backoff/caching and verify real indexed items. Run one image case and one video case through collection, OpenSea viewing, attempted transfer rejection, and redemption/burn refresh. Test creator attribution separately from the creator's ability to administer protocol funds. A collection with no minted NFT may have no item to show. Deep-link only to verified item URLs; otherwise label external display pending. No OpenSea promotion or native redemption button is assumed.

### R28: native release decision

Web is the first public transaction surface. Native capture, browsing and portfolio work can proceed, but App Store release of coin acquisition and NFT collection awaits a storefront-specific review of the exact flow. Apple's rules address NFT services, ownership-unlocked functionality, crypto transactions and regional purchase links; an external link is not a universal workaround.[^17]

Keep the full native development capability behind an environment feature flag rather than remove it from scope. The public native build exposes only flows appropriate to its approved distribution. The website remains independently usable; do not make launching the web pilot depend on shipping every native transaction action. TestFlight or a hackathon installation is not evidence of App Store acceptance.

### R29–R30: rights, privacy and recovery

Choose a limited license: creators retain their rights; DYOR receives permission to host, process and display the submitted media; collectors receive personal display access to the collectible, with no automatic commercial exploitation rights. Final terms must match this product choice. Obtain permission for people prominently featured in sensitive/private events before public publication. No private-address wedding invitations or personal contact details in immutable media.

Provide reporting for impersonation, stolen media, harassment and privacy issues. Operators can remove content from app discovery or stop serving their copies, but cannot promise deletion from public IPFS or blockchain history. Plain redemption remains available for delisted Moments. Human review within one working day is a pilot service target; urgent privacy/security reports receive immediate triage during staffed hours.

There is no NFT account-migration feature in v1. Recommend recoverable wallet setup before substantial value is held. A holder can redeem, transfer the net coins and recollect in a new wallet, paying the disclosed fee and receiving a new serial. That does not restore a lost key. The contract prevents NFT transfers, not transfers of control over a smart wallet or credentials. Do not market a technically unenforceable promise that ownership can never be indirectly sold.

### R33: public availability

Launch a product demo and user research first; enable real-money public activity only for an explicitly reviewed operating entity, jurisdictions and distribution plan. The operating location cannot be inferred from a timezone alone. The design decision is to avoid an unreviewed worldwide financial promotion at launch, rather than invent a legal exemption for the word “Moment.”

If Ghana is an operating or marketing jurisdiction, official BoG/SEC materials are directly relevant: the regulator's virtual-assets page describes the VASP framework, and its February 2026 notice restricts unauthorized mass virtual-asset promotional campaigns by VASPs. Confirm applicability and any superseding rules before local campaigns.[^18] This report does not decide DYOR's legal classification. Invite-only use, self-custodial wallets and web distribution do not themselves eliminate applicable obligations.

## 7. Distribution designed around sharing

### R31: audience and initial launch

Start with **10 opt-in creators across three recurring community/event groups**, aiming for two Moments per creator. Prefer events whose participants already know each other, creator milestones, launches and travel-group experiences with consent. Defer wedding ticketing: volatile collection cost and refundable backing are poorly suited to financing an event or guaranteeing admission.

Give each creator a short publishing session, one sample Moment, a share-card kit and clear fee explanation. Promote a small set of well-made experiences together rather than thousands of empty token markets. No paid transaction-volume incentives, price contests, automated outreach or compensated referrals in v1. Creator compensation, if any, is a disclosed fixed content-production budget unrelated to trading volume.

The share loop is: creator publishes an experience → people recognize it → some collect → their personalized receipt links back to the Moment → others watch, collect or follow the creator → the creator returns with another experience. People may share without buying. Account creation is delayed until an action requires it.

Build these mechanics:

- Public mobile pages with a strong thumbnail, fast first render and no wallet wall.
- Native share-sheet and downloadable image cards in 1:1 and 9:16 formats.
- Creator name, actual media and collector's optional profile on the card; collectible status verified at generation time.
- Cards link to a live page so historical snapshots do not imply continuing ownership after redemption.
- Creator wall plus personal albums, with counts based on current unique collector wallets and historical first collections separately.
- Follow/save and opt-in notifications for the creator's next Moment; no notification for every tick in price.
- Event QR links point to public Moment pages and never themselves assert admission rights.

A classic study by Berger and Milkman linked sharing with emotionally activating content, including awe, and tested mechanisms in experiments. Its setting was news content, not Monad coins; it supports trying meaningful, surprising experiences, not a forecast of viral financial adoption.[^19] Design for joy, identity and recognition rather than manufactured outrage or promises of gains.

### Growth measurements and continuation decisions

These are proposed pilot targets, not empirical benchmarks:

| Measure | Pilot decision rule |
|---|---|
| Comprehension | At least 8 of 10 interviewed users can explain locking, non-transferability and net redemption unaided |
| Funded collection success | At least 95% of valid submitted collection attempts succeed; separate user cancellations and expired quotes |
| User completion | At least 80% of funded users starting collection complete within 2 minutes, excluding chain outages |
| Collection motivation | At least 5 of 15 interviews identify a non-price reason to collect; validate with real optional choices |
| External adoption | 50 external collecting wallets across at least 5 creators; report clustering and team exclusions |
| Creator repeat | At least 4 of the first 10 creators publish a second Moment within 30 days |
| Collector repeat | At least 20% collect another distinct Moment within 30 days; distinguish subsidized and organic users |
| Sharing | At least 25% of collectors use a sharing action; confirm downstream visits, not just button clicks |
| Financial correctness | Zero unexplained backing deficits, duplicate payouts or unauthorized transfers |

Instrument view → funded wallet → coin buy → collect → share → referred visit → referred collect, using consent-conscious referral IDs and no public wallet information in analytics URLs. Report each funnel separately: a trader choosing not to collect is not automatically an onboarding failure.

Define the observed collection reproduction factor as **attributable new collectors generated per collector over a fixed 30-day window**. For planning, decompose it into shares per collector × unique qualified visits per share × visitor-to-collector conversion, with deduplication and attribution rules. A sustained measured value above one suggests self-propagating collection growth; it is not a promise or a prerequisite to having a viable niche business. If it stays below one, grow through repeat creators and distribution partners rather than manipulating scarcity.

After the first cohort, keep the feature if people understand it and repeat use across creators. Rework collection utility if trading grows but collection is nearly absent. Stop paid expansion if fees do not cover variable costs or activity is concentrated in self-trading. Do not respond to weak demand by raising exit taxes or making misleading limited-edition claims.

## 8. Validation and implementation sequence

### R34: evidence needed

This report includes a reproducible Decimal model in `moments-analysis/economics.py` with 24 denomination/curve scenarios and 16 independent redemption scenarios. It checks allocation conservation and compares 0%, 1%, 2% and 5% redemption fees. It is not an exact finite-tick v4 simulator, a full market agent model or a proof of contract security. Swap fees, gas and exact tick rounding are excluded from those CSV market calculations.

Build and verify in this order:

1. **Protocol accounting:** immutable coin/vault/fee escrow, denomination, owner pagination, events and direct collect/redeem; supply and liability invariants. Preserve unrelated repository work and existing Launchpad behavior.
2. **Markets:** curve, all fee paths, terminal buy refunds, permissionless retry, timed rescue, protected v4 initialization, actual PositionManager seed custody and surplus burn. Verify price continuity within 10 bps against actual rounded reserve amounts; explain any tighter or looser tolerance before deployment.
3. **LP incentives:** custody, warm-up, activation, withdrawal, two-asset streams, empty-stake pauses, queued rewards, dust and constrained ordinary-fee collection. Model adversarial participant timing and compare contract outputs with an independent implementation.
4. **External proof early:** deploy only with a separately approved environment/budget; record Monad bytecode, image/video OpenSea display, lock state and rejected transfers. Integrate direct route quoting with the deployed hook.
5. **Product flow:** media, published pages, wallet transaction recovery, portfolio, creator claims, LP staking/claims and sharing. Public web first; native rollout follows the distribution decision.
6. **Pilot release:** independent contract review, critical/high findings resolved, verified source/ABI manifests, operational alerts, media budget and named support/security owners. Then recruit the consented cohort and measure outcomes.

Required additional scenarios: zero demand; never-graduating curve; 10/25/50% of available live backing redeemed and sold; extreme denominations; repeated collect/redeem by a fee beneficiary; all LPs withdrawing; reward funding at activation boundaries; queue delivery duplicates; stale indexer; failed metadata pin; wallet switch mid-flow; replacement tx; migration/rescue race; direct pool donations; and bogus LP positions. All stress inputs must be reachable under the supply allocation, not imaginary backing exceeding total supply.

For production contracts require no known critical/high defects, successful independent review and documented invariant/fork results; do not substitute “tests passed” for an audit. For the hackathon, show the complete lifecycle in a test environment with explicit simulated economics. Public LP rewards and OpenSea integration are not complete until demonstrated with their actual adapters.

Engineering can implement the selected interfaces and prototype profile without waiting for proof of virality. Production configuration still requires current MON affordability checks, real beneficiary addresses, service accounts, release budget, target jurisdictions and successful verification. These are external facts and authorization inputs, not unresolved product mechanics that research can invent.

## 9. Closure map for every review question

| Review ID | Recommended decision | Remaining evidence/input |
|---|---|---|
| R01 | Collector identity/provenance and opt-in creator wall; trading remains optional | Pilot choice and repeat-use data |
| R02 | Concurrent theoretical ceiling, unique lifetime serials, no lifetime edition cap | UI comprehension tests |
| R03 | All supply on curve; burn actual price-preserving migration surplus | Integer allocation/fork tests |
| R04 | Constant product, T/V=4, 1,000/4,000 MON candidate | Current affordability and depth review |
| R05 | Atomic migration subcall plus permissionless retry | Custody/failure/race tests |
| R06 | No expiry; permissionless terminal rescue after 24h pending | Timer/state tests |
| R07 | 2% redemption; 1% curve; 0.3% LP + 0.7% input hook | Four swap-path fee fixtures and pilot behavior |
| R08 | Immutable beneficiaries; account-level signer recovery | Real verified addresses |
| R09 | Locked PositionManager seed; external providers own separately staked positions | Actual position ownership proof |
| R10 | 24h warm-up, fixed L weights, independent seven-day asset streams | Solvency/timing tests |
| R11 | Queued backlog; no active stake pauses emission; no treasury reassignment | Empty-period and first-staker tests |
| R12 | Full-range v1; constrained fee-only seed collection; no rebalancing | No principal-withdrawal path |
| R13 | Native MON, fee 3,000, spacing 60, registered hook | Pinned addresses, bytecode, router/fork evidence |
| R14 | Protected canonical initialization; no privileged exemptions or global pool restriction | MEV/alternative-pool scenarios |
| R15 | Guided two-step execution with phase-aware requoting | Graduation-boundary UX tests |
| R16 | Atomic routers deferred; typed and contract-wallet authorization if added | Future router security design |
| R17 | Vault/executor burn only their own balances | Supply invariants |
| R18 | Caller pays, owns and redeems; batch cap 20 | Operator/callback/duplicate-ID tests |
| R19 | Factory publication pause only; immutable instances; 2-of-3 governance + 48h future-policy delay | Role/deployment review |
| R20 | Whole-coin and base-unit getters distinct; generated ABI fixtures | Web/Swift equivalence |
| R21 | Confirm terms before immutable metadata and public pinning | Stale-policy and failed-publication tests |
| R22 | Creator-bound salt/idempotency; ticker not identity | Duplicate/race tests |
| R23 | Supabase, Stream, Queues/Workers, Pinata, R2 | Provisioned providers and integration checks |
| R24 | Explicit quotas, retry/DLQ, staging retention and $300 planning envelope | Cost/latency measurement and budget authorization |
| R25 | Bounded owner-ID pagination with direct-chain recovery page | Backend-outage exercise |
| R26 | Durable wallet/chain-bound intent; finalized block verification; optional sponsorship | Provider/SDK compatibility proof |
| R27 | Display-only OpenSea with real item and burn evidence | Actual image/video indexing |
| R28 | Web transactions first; native release feature-gated by storefront review | Distribution assessment |
| R29 | Limited display license, consent, moderation and permanence disclosure | Final terms and operational staffing |
| R30 | Wallet recovery, no NFT migration; redemption/recollect changes serial and incurs fee | Recovery UX tests |
| R31 | Curated 10-creator/three-community cohort, sharing/return loops, no trade prizes | Opt-in participants and real behavior |
| R32 | MON-first executable quotes, supply distinctions, no double counting | Stale quote and slippage tests |
| R33 | Explicit entity/region review before real-money promotion | Operating jurisdiction and applicable permission review |
| R34 | Independent review plus invariants, fork, external display and operational proof | Completed release evidence |

## Sources and evidence boundaries

Primary sources were accessed September 12, 2026. Standards and provider docs establish capabilities and constraints, not successful DYOR deployment. Product defaults, fee choices, pilot targets, stream design and budget are recommendations, not source-derived guarantees. Documentation can change; pin dependency versions and verify provider/network support at implementation time. Zora support pages contain differing reward presentations across product/version pages; this report uses them only for category precedent and market-scoped fee attribution, not to copy an unverified exact payout split.

[^1]: POAP, [Welcome to POAP](https://poap.xyz/) and [Issuer Responsibilities](https://curation.poap.xyz/guidelines/issuer-responsibilities). Community memory and participant eligibility precedent; no claim of comparative adoption or investment outcomes.
[^2]: Zora, [Understanding Rewards on Zora](https://support.zora.co/en/articles/2509953), updated August 12, 2026; [legacy market-scoped rewards explanation](https://support.zora.co/en/articles/5776961). Product/version differences retained; not a recommendation to use Zora contracts on Monad.
[^3]: Uniswap, [IPoolManager interface](https://raw.githubusercontent.com/Uniswap/v4-core/main/src/interfaces/IPoolManager.sol). Fee units and pool interface; pin a reviewed release rather than importing moving main.
[^4]: Ethereum, [ERC-5192](https://eips.ethereum.org/EIPS/eip-5192). Locked NFT transfer semantics. Wallet-control limitation is architectural inference.
[^5]: Ethereum, [EIP-712](https://eips.ethereum.org/EIPS/eip-712) and [ERC-1271](https://eips.ethereum.org/EIPS/eip-1271). Typed signatures and contract-wallet signature validation.
[^6]: Uniswap, [Collect Fees](https://developers.uniswap.org/docs/protocols/v4/guides/managing-liquidity/collect-fees). PositionManager zero-liquidity decrease and take-pair flow.
[^7]: Uniswap, [v4 Deployments](https://developers.uniswap.org/docs/protocols/v4/deployments) and [Hooks](https://developers.uniswap.org/docs/protocols/v4/concepts/hooks). Monad deployments, hook behavior and frontend-routing boundary.
[^8]: Cloudflare, [Direct creator uploads](https://developers.cloudflare.com/stream/uploading-videos/direct-creator-uploads/), updated May 7, 2026. Scoped uploads and resumability.
[^9]: Cloudflare, [Download video or audio](https://developers.cloudflare.com/stream/viewing-videos/download-videos/). Controlled MP4 export; actual output must be tested.
[^10]: Pinata, [Presigned URLs](https://docs.pinata.cloud/files/presigned-urls). Expiry/size/MIME-scoped upload authorization.
[^11]: Supabase, [Storage Access Control](https://supabase.com/docs/guides/storage/security/access-control). RLS-backed storage authorization.
[^12]: Cloudflare, [Delivery guarantees](https://developers.cloudflare.com/queues/reference/delivery-guarantees/) and [Dead Letter Queues](https://developers.cloudflare.com/queues/configuration/dead-letter-queues/). At-least-once processing and exhausted-retry handling.
[^13]: Monad, [JSON-RPC API Reference](https://docs.monad.xyz/reference/json-rpc/api). RPC capabilities; no provider-specific uptime or finality-latency assertion.
[^14]: Privy, [Gas sponsorship overview](https://docs.privy.io/wallets/gas-and-asset-management/gas/overview) and [EIP-7702 authorization support](https://docs.privy.io/wallets/using-wallets/ethereum/sign-7702-authorization). Monad support and SDK/account-delegation considerations; existing Swift compatibility unproven.
[^15]: Cloudflare, [Stream pricing](https://developers.cloudflare.com/stream/pricing/). Published unit rates; arithmetic examples exclude other services and special agreements.
[^16]: OpenSea, [Locked and staked NFTs](https://docs.opensea.io/docs/locked-and-staked-nfts) and [metadata standards](https://docs.opensea.io/docs/metadata-standards) and [media and traits](https://docs.opensea.io/docs/media-and-traits). Documented display/lock compatibility; real indexing still required.
[^17]: Apple, [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), sections 3.1.1 and 3.1.5. Storefront/payment/NFT/crypto distinctions; no prediction of approval.
[^18]: Bank of Ghana, [Virtual Assets framework](https://www.bog.gov.gh/virtual-assets/); BoG/SEC, [Public notice on unauthorized advertising](https://www.bog.gov.gh/wp-content/uploads/2026/02/PRESS-RELEASE-PUBLIC-NOTICE-ON-UNAUTHORISED-ADVERTISING-OF-VIRTUAL-ASSET-AND-STABLECOIN-PRODUCTS-200226.pdf), February 20, 2026. Conditional relevance to Ghana, not a determination of DYOR's classification or a global legal survey.
[^19]: Jonah Berger and Katherine L. Milkman, [What Makes Online Content Viral?](https://jonahberger.com/wp-content/uploads/2013/02/ViralityB.pdf), Journal of Marketing Research study, author-hosted manuscript. Evidence on sharing mechanisms; context differs from a financial collectible product.
