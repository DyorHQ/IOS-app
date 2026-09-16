# Moments — critical review and implementation readiness

Reviewed September 12, 2026 against `moments-build-spec.md`, current repository source and the primary sources below. This is a design review, not a contract audit or evidence of deployed integration. Recommendations here are proposed decisions; they do not silently replace user-approved requirements.

The [launch recommendation](moments-launch-recommendation.md) now answers all 34 questions with concrete recommended decisions. This review remains the record of the criticisms and evidence requirements.

## Verdict

The product is coherent enough to start an isolated prototype. It is **not yet a complete production implementation contract**. The backing model is sound in principle: mint a non-transferable NFT only against actual deposited coins, and burn the NFT to release those coins minus disclosed fees. The weak points are collector motivation, market depth, LP accounting, migration failure behavior and distribution assumptions.

Keep: separate Moments feature; 100M initial coins per Moment; creator-selected immutable 10,000–1M denomination; freely traded individual coins; separate backing vault; owner-only redemption; curve-to-Uniswap-v4 lifecycle; OpenSea display without NFT trading.

Resolve architecture gates before implementing the affected modules. Numbers can remain development fixtures while protocol work proceeds, but final contract authority, reward ownership and asset custody cannot remain vague until deployment.

## 1. The strongest argument against the product

A buyer seeking price exposure can simply hold the coins. Collecting adds a redemption charge, removes transferability of the resulting NFT and introduces another transaction. Everyone can already view the public media. Financially, holding the same coins has the same underlying price exposure without the NFT exit charge. Collecting must therefore provide a valued experience or status beyond exposure.

The riskiest assumption is **people will voluntarily collect when coin holding is cheaper and more flexible**. There is no user evidence establishing this in the current plan. Raising the fee or making the denomination larger does not solve it.

Candidate benefits, with tradeoffs:

1. Creator-attributed collector wall and shareable collection receipt: simple, visible, and compatible with public media. Separate current holders from historical collectors.
2. Collection date and unique serial: meaningful provenance, but do not imply attendance or guaranteed valuable rarity. Serial IDs never repeat.
3. Creator acknowledgements and optional public messages: strengthens the relationship; requires consent and moderation.
4. Curated event/travel albums connecting separate Moments: improves discovery without changing token economics. Too many launches still fragment liquidity.
5. In-person benefits or invitations: tangible value, but needs eligibility, capacity, cancellation and check-in design; defer real admission from the first release.
6. Creator/community milestones: reasons to return without cash rewards; do not base them on trade volume or round-trip mints.
7. Remove collection from the default onboarding path: let people trade first and collect voluntarily. This tests whether NFT utility is independently compelling instead of forcing everyone through it.

Recommended first test: show 10–15 potential collectors the same Moment with three options—watch free, hold coins, or collect with the exact exit fee. Ask them to choose and explain the choice without leading with appreciation. Pilot collector wall plus provenance before introducing tickets. Record willingness and then actual behavior; interview enthusiasm alone is insufficient. If most choose coins and cannot name a reason to collect, revisit the collectible value proposition before adding more token mechanics.

## 2. Economic contradictions and concrete consequences

### A. Scarcity has three different meanings

- Collection lowers coins available outside backing; it does not destroy supply or directly change DEX reserve pricing.
- NFT redemption lowers outstanding NFT count but returns net coins and fee coins outside backing, where they may be sold.
- Only the designated true-burn component lowers ERC-20 total supply.

For gross redeemed backing `G` and burn fraction `b`, coins outside backing increase by `G * (1 - b)`, ignoring unrelated simultaneous actions. With the illustrative 1% true burn, redeeming 1M backing releases 990,000 coins outside the vault and destroys 10,000. A redemption wave can increase sell pressure even as total supply falls. This is already partly explained in the build spec; it must govern simulations and marketing.

### B. The denomination table does not promise an edition size

`floor(100M / R)` is an initial mathematical ceiling, not an achievable sold-out count. Curve inventory, LP inventory, permanently inaccessible leftovers and burns matter. Serial IDs are historical, so cumulative mints can exceed this ceiling through burn/recollect cycles.

The current example uses 1,000 MON virtual quote and 4,000 MON graduation reserve. At graduation: 80M coins have left the curve, 20M remain, approximately 16M enter the pool, and 4M are permanently locked outside it under the referenced executor/locker design.

| Coins per NFT | Initial mathematical ceiling | Ceiling after 4M inaccessible leftovers, before any burns |
|---:|---:|---:|
| 10,000 | 10,000 | 9,600 |
| 50,000 | 2,000 | 1,920 |
| 100,000 | 1,000 | 960 |
| 250,000 | 400 | 384 |
| 1,000,000 | 100 | 96 |

These revised ceilings still include coins needed by the live market and are not achievable issuance promises. Permanently locked leftovers are not NFT backing and are not true burns. Their treatment is a production decision: preserve the referenced lock, explicitly burn them, or redesign allocation/migration. Each choice changes accounting or economics. Do not casually send them to creators or NFT backing.

Recommendation: creator form prioritizes **Coins required per NFT** and shows **Initial theoretical maximum** as explanatory text. Do not market “100 limited editions” unless a separate lifetime edition mechanism is designed and approved. The target-count shortcut remains permitted, but its label must be honest.

### C. The ratio also sets affordability and exit concentration

At identical coin price, 1M coins per NFT costs 100 times as much as 10,000. It also makes each individual redemption 100 times larger. Preview acquisition cost at launch and near graduation, percentage of initial supply locked per NFT (0.01%–1%), and executable exit quotes. Never recommend a ratio using scarcity alone.

The current whole-coin input restriction rejects many target counts. For example, a target of 333 does not divide 100M into a whole-coin amount. Keep clear validation and nearby valid suggestions; no hidden rounding. Token trading still supports 18 decimals.

### D. A backing valuation is not executable cash

Using the illustrative post-graduation pool with 16M coins and 4,000 MON, ignoring swap fees, tick-boundary effects and rounding:

| Action | Spot reference | Approximate constant-product execution |
|---|---:|---:|
| Buy 1M coins | 250 MON | 266.67 MON paid |
| Redeem one 1M-backed NFT at 5%, then sell 950,000 coins | 237.50 MON net coin reference | 224.19 MON received |
| Redeem ten such NFTs, then sell 9.5M coins | 2,375 MON net coin reference | 1,490.20 MON received |

Each row independently starts from the same pool snapshot. These are illustrative idealized calculations, not v4 execution results. Actual fee-bearing v4 quotes are required. The pool can honor coin trading while providing much less cash than a spot-based portfolio value suggests.

### E. Fees compete with collection and with routing

The proposed 5% redemption fee is unapproved. Compare 0%, 1%, 2% and 5% through user tests and simulation, holding the comparison assumptions explicit. More exit revenue can reduce collection and retain users through friction rather than satisfaction. Creator income should depend primarily on eligible market activity, with redemption fees an additional disclosed stream.

A freely transferable ERC-20 can trade in another pool without the project's hook. Creator/project fees apply to eligible routes, not all global activity. Restricting transfers or introducing a token transfer tax to prevent bypass would change the agreed model. Accept this boundary and test whether the official pool remains attractive after all fees.

### F. Locking alone does not advance graduation

Graduation measures actual net quote reserves. Depositing already-owned coins into NFT backing raises no new MON. Launches may never graduate; collection and redemption must remain available indefinitely. Do not make an NFT's validity depend on migration or promise graduation because enough NFTs were minted.

## 3. Missing decision register

Gates: **A** = architecture/interface decision before implementing that component; **P** = required before production configuration/release; **E** = experiment needed to validate demand. Owners identify responsibilities, not assigned people. Proposed defaults require explicit recording in the build decision ledger before becoming production policy.

| ID / gate | Missing or insufficiently specified variable | Proposed resolution / required evidence | Owner |
|---|---|---|---|
| R01 E | Why collect instead of hold coins? | Collector wall + provenance pilot; measure actual choice with fee disclosed. | Product |
| R02 A | Edition meaning and recycled serials | Concurrent theoretical ceiling only; never reuse IDs; historical receipts do not confer live benefits. | Product/engineering |
| R03 A/P | Exact token allocation and inaccessible graduation surplus | Account for 100M at every phase; choose explicit surplus custody/burn policy; include revised ceiling. | Protocol/product |
| R04 P | Curve shape, V, T, starting price and useful depth | Choose a platform policy after stress simulation, not arbitrary creator market settings or headline FDV. | Protocol/product |
| R05 A | Migration state machine and custody on failure | Atomic migration attempt, permissionless retry, explicit pre-sweep exit recovery; see section 4. | Protocol |
| R06 A/P | Never-graduating launch, rescue conditions and expiry | No automatic expiry or fixed-price refund. Define narrowly scoped failed-migration rescue without using backing. | Protocol/product |
| R07 P | All fees and denominations | Fee matrix for curve buys/sells, four v4 swap paths, collect/redeem; distinguish bps from v4 fee units and define fee assets. | Protocol/product |
| R08 A/P | Creator/project payout authority | Recommended immutable beneficiary accounts per Moment; beneficiaries use controlled wallets for signer recovery. No admin redirection of accrued claims. | Protocol/product |
| R09 A | LP principal ownership | Separate locked seed principal from withdrawable external-LP positions; specify which positions accrue which fees. | Protocol |
| R10 A/P | LP reward eligibility and time calculation | Exact pool/range, epoch duration, deposits, withdrawal rules, checkpoints, accumulator and fund timing; simulation and invariants. | Protocol |
| R11 A/P | Pre-graduation and empty-epoch LP fees | Explicit per-Moment carry-forward reserve. Decide beneficiary eligibility before releasing backlog; prevent first-depositor windfall. | Protocol/product |
| R12 A | Rebalancing and fee collection from locked principal | Full-range v1 proposed; no arbitrary rebalancing. Implement fee-only collection without principal removal, plus owed-fee/dust accounting. | Protocol |
| R13 A/P | V4 pool details | PoolKey, hook code/hash, fee, tick spacing, full-range bounds, native currency, router, quoter and recipient settlement. | Protocol |
| R14 A/P | Early pools, bots and creator purchases | Accept external pools can exist; protect canonical initialization; disclose creator buy. No copied creator tax exemptions or claimed Sybil-proof limits. | Protocol/product |
| R15 A | Collect spanning graduation | Two-step buy/requote across phases; never silently underfund collection. Quotes bind phase and expire. | Web/native/protocol |
| R16 A | Atomic convenience authorization | Defer to P1; require EIP-712 domain/nonce/expiry and contract-wallet signature design if introduced. | Protocol |
| R17 A | Coin burn authority | Only burn caller's own coins; no arbitrary balance burn. Decide whether ordinary users can voluntarily burn in addition to the vault. | Protocol |
| R18 A | NFT mint recipient and approvals | Direct caller pays/receives; disable ordinary operator powers; no unsolicited minting. Router support is a separate interface version. | Protocol |
| R19 A/P | Admin and incident powers | Exact role/action matrix, factory pause vs per-instance collect pause, immutable redemption rules, multisig ownership and monitoring. | Security/operations |
| R20 A | Units and ABI schemas | Resolve whether `coinsPerNFT()` returns whole coins or base units; recommend `coinsPerNFT()` whole coins and `backingPerNFT()` base units. Export shared fixtures. | Protocol/web/native |
| R21 A | Publish terms/media ordering | Finalize denomination and fees before generating committed metadata; hash all terms and confirm irreversible public pinning. | Backend/web/native |
| R22 A | Duplicate publication / content identity | Creator-bound salt and idempotent draft submission; distinguish duplicate tx retries from intentional reposts. Ticker is not identity. | Protocol/backend |
| R23 A/P | Data hosting and background workers | Name upload/transcode/pinning providers, durable queue, worker runtime, scheduled indexer, credentials and retention policy. | Backend/operations |
| R24 A/P | Operational limits and budget | Timeouts, per-wallet upload quotas, retry caps, media/transcode/storage/egress cost, alert thresholds and operating budget. | Backend/product |
| R25 A/P | Ownership enumeration when backend fails | Bounded onchain owner-ID pagination or documented client log-scan fallback; no unbounded global mint loop. | Protocol/web/native |
| R26 A/P | Transaction finality and wallet continuity | Confirmed/final status, tx replacement/reorg handling, network switches, wallet-session changes, interrupted app recovery and gas funding. | Web/native |
| R27 P | OpenSea compatibility evidence | Real Monad NFT image/video, lock recognition, burn refresh and verified item URL; credentials/quotas/retry ownership. | Integration |
| R28 A/P | Native distribution and storefront constraints | Review actual release regions and payment/coin/NFT flows against current Apple rules; web transaction flow is a proposed fallback, not a scope change already approved. | Product/mobile |
| R29 P | Media rights and provenance | Define usage license, rights attestation, impersonation/report response, removal limits and sensitive-event consent. A timestamp proves publication, not attendance. | Product/operations |
| R30 P | Wallet recovery and account resale | Explain no NFT migration. Redeem/recollect costs fee and changes serial; key loss strands claims. Contract-wallet ownership changes can transfer control. | Product/security |
| R31 E/P | Acquisition channel and creator economics | Named pilot cohort, opt-in outreach, operating costs versus actually claimable fees, repeat use and concentration measurements. | Product |
| R32 A/P | UI metrics and price source | Define total/free/inaccessible/backing supply, no NFT double counting, per-route price timestamp, USD source and unavailable-price states. | Product/data |
| R33 P | Public availability and incident support | Target regions, terms and launch permissions reviewed for the actual model; named support and incident owner. No generic legal classification assumed here. | Product/operations |
| R34 A/P | Verification scope and release budget | Local invariants, real v4 fork tests, external display proof, independent security review, gas budgets and source verification. | Engineering/security |

This register includes already recognized but unresolved items; it does not claim every item was absent from the previous document. New findings include the inaccessible-supply ceiling, publication ordering, ABI units, LP backlog allocation and native distribution gate.

## 4. Market lifecycle that engineering must make explicit

Proposed states and semantics:

| State | Coin market | Collect / plain redeem | Allowed transition |
|---|---|---|---|
| CurveTrading | Curve buys and sells | Both available | Threshold buy commits; attempt graduation |
| GraduationPending | Curve trading stopped; real reserves remain in curve | Both available | Permissionless retry of atomic migration |
| V4Trading | Use registered v4 pool | Both available | Terminal successful market state |
| RescueSellOnly | Curve sells against real reserves; no new buys | Both available | Terminal fallback; no later migration or fee revival |

A successful migration must atomically sweep reserves, initialize the canonical pool, fund and lock the intended position, account for excess and record state. If any of those steps fails, the migration subtransaction reverts so funds remain in the curve. The threshold buy can remain committed only if the caller catches that subtransaction failure and records GraduationPending. Permissionless retry must be idempotent. No loose partial sweep followed by an offchain promise to finish later.

Rescue conditions remain a policy decision: define a delay, who activates it, whether the condition is mechanically provable and what precisely makes rescue terminal. Race rescue against retries in tests. A stuck migration must not give an administrator custody of either curve reserves or NFT backing. Do not promise unlimited cash redemption; rescue sells remain constrained by real quote reserves.

The repository already separates completion, sweep and rescue concepts; `BondingCurve.sol`, `LaunchpadFactory.sol` and `GraduationExecutor.sol` are references, not audited building blocks. Current unrelated working-tree changes must be preserved. The existing hook uses zero ordinary LP fees, and `LaunchLocker.sol` exposes liquidity addition but no ordinary fee-claim method. Copying them is insufficient for the proposed external LP reward product.

## 5. LP design needs its own specification

The existing recommendation of “same-range shares plus epochs” is an outline. Before implementing it, decide:

- Whether protocol seed liquidity earns redemption rewards. If it does, define its beneficiary; if it does not, keep it out of the eligibility denominator.
- How a deposit maps to actual liquidity units and how balanced token/MON contributions are enforced. Deposited dollar value from manipulable spot price is not a safe share oracle.
- Whether active-epoch withdrawals forfeit current-epoch rewards or earn pro-rata time; when stake stops earning and whether shares can transfer.
- When reward funds are assigned to an epoch, including fees accruing before graduation and before the first eligible LP. “Next epoch” alone does not prevent a depositor capturing a known backlog.
- What happens when no LP ever joins: reserve remains designated and visible, no treasury sweep disguised as LP income. Choose an explicit eventual policy before release.
- How rewards in Moment Coins and swap fees in either pool currency remain separate from principal and each other.
- How fee collection operates for a full-range position without opening a principal-withdrawal path, and how external LP withdrawals leave locked seed liquidity intact.
- Exact integer rounding, reward dust, minimum deposits, rounding attacks and bounded claim complexity.

A narrow alternate pilot could pay ordinary v4 LP fees and keep redemption allocations in a disclosed liquidity reserve, deferring public LP participation. That reduces scope, but changes the current P0 commitment and needs a product decision. Do not ship a mock adapter as real LP yield.

## 6. OpenSea, wallets and mobile reality

OpenSea documents using supported lock events to mark NFTs ineligible for trading. That supports the proposed display model, not guaranteed promotion, discovery volume or successful indexing of our contracts. Verify actual Monad items and burn handling. [OpenSea lock support](https://docs.opensea.io/docs/locked-and-staked-nfts)

ERC-5192 blocks token transfers; it cannot prevent someone transferring control of a wallet, changing smart-wallet owners or selling credentials. State the enforceable claim as “the NFT contract disables transfers,” not “nobody can ever sell access.” This is an inference from the transfer boundary, not a marketplace workaround to build. [ERC-5192](https://eips.ethereum.org/EIPS/eip-5192)

Uniswap documents Monad deployments and pool-specific hooks, but explicitly warns hook creation does not guarantee routing through its frontend. An alternate pool may omit our hook. Test the official route and accurately scope fee claims. [Deployments](https://developers.uniswap.org/docs/protocols/v4/deployments), [hooks](https://developers.uniswap.org/docs/protocols/v4/concepts/hooks)

Native distribution is a material missing gate. Apple's guidelines distinguish NFT viewing, minting-related services, ownership-unlocked functionality and crypto transactions; purchase-link rules also vary by storefront. The proposed in-app coin-to-NFT action and any gated benefits need an assessment for the actual distribution plan. A successful SwiftUI build is not App Store approval. Do not assume US link rules apply globally or that describing minting as redemption avoids review. [Apple App Review Guidelines, sections 3.1.1 and 3.1.5](https://developer.apple.com/app-store/review/guidelines/)

## 7. Scenario suite required before selecting economics

Build a deterministic simulator first; label it economic modeling, not contract verification. Then translate accounting cases into Foundry invariants and verify migration through the actual v4 adapter.

| Scenario | What must be measured or proven |
|---|---|
| No buyers / no graduation | Zero-revenue operating cost; no arbitrary timer confiscates funds; public media and exits behave honestly. |
| Steady small buying | First and later NFT cost by denomination; fee drag; inventory and quote depth. |
| Viral buying + high collection | Outstanding backing, graduation timing, exact terminal buy/refund and collection crossing market phases. |
| Large whale buys and exits | Holder concentration, executable proceeds, market impact and reserve conservation. |
| 10%, 25%, 50% of live backing redeemed and sold | Net fees/burns, free-coin supply increase, price/depth decline and successful plain redemption. |
| Mass collection without fresh buying | No fictitious new quote reserves or graduation progress. |
| Repeated collect/redeem / self-recipient fees | Correct supply loss; no profitable accounting loop, duplicate rewards or manipulated collector counts. |
| LP joins before large known reward allocation | Backlog/epoch fairness and no instant entitlement beyond intended policy. |
| Every external LP withdraws | Seed stays locked; past claims remain solvent; earned fees do not require remaining shares. |
| Failed migration, retry, rescue race | No double sweep, misplaced custody, state revival or impairment of NFT backing. |
| External pool or canonical initializer attack | Fee scope honest; canonical pool cannot be initialized incorrectly; no unsupported global trade restriction. |
| Media/indexer/API failure and wallet-session change | Ownership and plain redemption remain accessible; wrong wallet never receives another's signing context. |

For each simulated parameter set export initial allocation, V/T, fee matrix, ratio, pool inventory, permanently inaccessible supply, max theoretical live count, net user proceeds, accrued fees, burn totals and operational assumptions. Set explicit acceptable slippage/depth and concentration thresholds before calling a configuration suitable; this review does not invent those production thresholds.

## 8. Practical build order and completion gates

1. **Close interface decisions:** denomination units, immutable fields, event schemas, mint/redemption authority, asset accounting, token allocation and publication ordering. Safe scaffolding can proceed now.
2. **Build the accounting slice:** coin, backed NFT, fee escrow, direct collect/redeem and invariant harness. No media/indexer dependency in the ownership lifecycle.
3. **Model and build markets:** parameter sweep, phase transitions, failure recovery, full fee matrix and real Monad v4 fork integration. Select LP architecture before implementing its contracts.
4. **Prove external behavior early:** minimal image and video assets with lock events on an OpenSea-supported environment; wallet and route compatibility. Live transactions still need an explicit environment/budget.
5. **Build one end-to-end public web flow and native integration fixtures:** capture/upload, publish, buy, collect, view, redeem, claim, recover. Sequence native release scope after distribution assessment; do not drop the agreed native scope silently.
6. **Pilot collector motivation:** honest live terms, creator cohort and measured repeat behavior. No trading-volume prize or guaranteed returns narrative.
7. **Release only with evidence:** production parameters and recipients fixed, LP ownership/rewards resolved, migrations/RLS/indexer operational, security review and acceptance checks complete, OpenSea evidence recorded, incident ownership and hosting budget established.

Implementation-readiness means every architecture row in the register has a chosen answer and a testable result. Production-readiness additionally requires the P gates and real integration evidence. An experiment failing can invalidate the business hypothesis even when every contract test passes.

## 9. Claude handoff instruction

Read `moments-build-spec.md` together with this review. Preserve the agreed product decisions. Do not fill architecture gaps with hidden assumptions. First produce the missing interface/market/LP design decisions and an economic scenario report; implement the isolated accounting slice with documented development fixtures while those decisions are being resolved. Treat proposals in this review as recommendations, not approval to change product scope, deploy contracts, select production fees or move live funds. Report each gate with file/test evidence and leave unresolved items visible.
