# Moments — decisions log (rulings that refine the frozen spec)

The spec (`docs/moments-spec.md`, frozen 2026-09-15) wins on everything it covers. The rulings below were made by
the owner during the build and take precedence where they refine or override spec wording. Each item names the
contract that implements it so a reviewer can check the code against the ruling.

## Phase 1 gate review — 2026-09-16

1. **Supply invariant (spec §6 / gate 1 wording).** The literal "Σ(entitlements) + reserve-implied pool + creator ≤ S"
   is not satisfiable exactly with integer clamping: the terminal collect's accepted gross is rounded UP so the
   reserve lands exactly on the threshold, which makes the rate-implied pool exceed the actual remainder by a few
   coin-wei. **Ruling:** the asserted law is the exact conservation identity `pool = S − creator − Σentitlements`
   (holds by construction at every step, asserted at graduation), plus the rigorous bound
   `impliedPool − remainderPool ≤ collects × ⌈rateNum/rateDen⌉`. Implemented in `MomentCollect.supplyCheck`,
   `MomentGraduation.graduate`, `test/moments/Invariant.t.sol`.

2. **"Refund" wording (spec §6, build plan gate 1).** There is no refund transfer. The terminal collect is clamped
   and **only the accepted amount is pulled** from the collector (approve path: `transferFrom(gross)`; Permit2 path:
   `requestedAmount = gross` against a larger permit). The `Quote.excess` field is informational: the part of the
   request that never left the wallet. Implemented in `MomentCollect._prepare` / `collectWithPermit2`.

3. **Collect window.** Each Moment has a creator-set collect window at publish, bounded to
   `[1 hour, 30 days]` (`MomentTypes.MIN_COLLECT_WINDOW` / `MAX_COLLECT_WINDOW`). Collecting is possible strictly
   before `deadline = publishedAt + window`; it also ends immediately at graduation (terminal collect). The 1-hour
   floor is a build choice (the ruling only fixed the 30-day maximum). Implemented in `MomentsFactory.publish`,
   `MomentCollect._prepare`.

4. **Wind-down of an un-graduated Moment (replaces spec §4 "Rescue: fee-free wind-down").** Once the deadline has
   passed without graduation, anyone may call `MomentCollect.expire`: the NFT collection closes (fixed edition),
   no coin is ever minted, entitlements never vest, and the reserve is booked **70% to the creator / 30% to the
   treasury** (policy `expiryCreatorBps = 7000`, snapshotted immutably per Moment), both pull-only by the immutable
   beneficiaries. The creator's 20% and the platform's 5% collect-time shares are unaffected. Nothing goes to the
   caller and nothing can go to an admin address that is not the Moment's snapshotted treasury.

5. **Stuck graduation (threshold reached, executor keeps failing).** Same wind-down as (4), but only once BOTH the
   deadline and a 7-day grace after the first failure (`MomentTypes.STUCK_GRACE`) have passed, so permissionless
   retries always come first. The grace period is a build choice. Incentive note for the auditor: the treasury
   benefits if graduation fails, so the graduation path must have — and has — no admin lever (no pause, no
   re-pointing; modules are wired once in `MomentsFactory.setModules`).

6. **Singletons.** `MomentCollect`, `MomentVesting`, `MomentGraduation`, `MomentLocker`, `MomentFeeHook` and
   `MomentBuyback` are singletons keyed by `momentId`; `MomentCoin` and `MomentNFT` are per-Moment (CREATE2).
   Confirmed at the Phase 1 gate.

7. **Other Phase 1 defaults confirmed at the gate:** the clamped terminal collect mints `⌈accepted/price⌉`
   editions; a vesting month is 30 days; the factory policy timelock is 48 hours; the creator's USDC share absorbs
   the ≤2-unit split rounding.

## Phase 2 gate review — 2026-09-16

8. **Pool LP fee ≥ 0.5%.** Every Moment pool is created with a 0.5% LP fee (`MomentGraduation.LP_FEE = 5_000`).
   The locked full-range position is the only LP, so the fee accrues to it; `MomentLocker` folds earned fees
   back into the position on every increase (zero-delta position update → fees taken to the locker itself →
   re-added as principal). The hook's 1% Moments fee (0.2/0.3/0.5) is charged on top, so a trade now costs 1.5%
   in total. Open for the owner: keep 1.5%, or drop the hook to 0.5% (0.2 creator / 0.3 platform) and let the
   0.5% LP fee BE the buyback-and-LP share (then `MomentBuyback` can be retired).

9. **Fee currency ("fees should be in MON").** Not implementable on a coin/USDC pool: a v4 hook can only charge
   the pool's own two currencies, and a third-currency debt cannot be imposed on a swapper going through the
   Universal Router. The options are (A) pair the coin with native MON instead of USDC — which reverses the
   spec's "USDC only" and, for price continuity, means collecting in MON too — or (B) keep USDC. Awaiting the
   owner's choice before Phase 3 (the fork lifecycle depends on the pair asset).

## Phase 2 gate review, second round — 2026-09-16

10. **Fee currency: Option B.** USDC stays the settlement and pair asset; all fees (0.5% LP + 1% hook) are in
    USDC / the pool's own currencies. Ruling 9 closed.

11. **Phase 3 runs against Monad mainnet.** The owner's instruction: "we are building on mainnet". Phase 3 is
    executed against Monad mainnet state — the real PoolManager `0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e`,
    real USDC `0x754704Bc059F8C67012fEd69BC8A327a5aafb603`, real Permit2 and the real Universal Router — as
    Foundry mainnet-fork tests (the adversarial matrix can only be run that way), with the deploy script and the
    live $10 lifecycle commands prepared for the owner to broadcast with their own key. Note for the record: the
    spec's §14 gate ("no real money before an independent audit") is the owner's rule; a live $10 lifecycle on
    mainnet puts roughly $13 of USDC plus gas on un-audited code, by the owner's decision.

12. **Total trading cost stays 1.5%** (0.5% LP + 1% hook) until the owner says otherwise (ruling 8's open point).

## Post-deployment — 2026-09-16

13. **The live lifecycle runs through the app, with dedicated wallets; the owner wallet is governance-only.** The
    forge-script walkthrough proposed at gate 3 (owner key in a shell, unlimited USDC approval, owner acting as
    creator + collector) was withdrawn on the owner's objection. `script/moments/Lifecycle.s.sol` is now a
    fork-only rehearsal (`FORK_REHEARSAL=1`, exact approvals). Sequence restored to the build plan: Phase 4 security
    self-review → Phase 5 app (verified on a fork) → Phase 6 validation launch through the app by ordinary,
    low-value wallets. Sourcify verification was submitted before any interaction; the spec §14 audit gate still
    stands before real money.

## Phase 4 — 2026-09-16

14. **v1.1 hardening is on the branch, not on mainnet.** Phase 4 found no Critical/High issue; four Lows are fixed
    on the branch (NFT metadata escaping, constructor zero-address checks, policy sanity floors, and a test-side
    rounding bound), which changes the bytecode of every module because the factory embeds the coin + NFT creation
    code and the modules hold the factory as an immutable. The live v1 (tag `moments-mainnet-v1`) has no Moments
    published. Decision pending with the owner: redeploy v1.1 now, or fold it into the post-audit redeploy
    (recommended). Report: `docs/moments-security-review-2026-09-16/REPORT.md`.

15. **Moments NFTs are transferable and marketplace-grade (OpenSea standards).** v1.1 `MomentNFT` implements ERC-2981
    (royalty to the immutable creator; policy `royaltyBps`, default **5%**, hard cap 10% — owner to confirm the
    rate), ERC-4906 metadata refresh when the edition is fixed, ERC-7572 `contractURI()`, the `owner()` collection-
    admin convention (returns the creator, no on-chain power), numeric Rank with `max_value`, `animation_url` for
    video Moments (`Provenance.animationURI`) and `external_url` / `external_link` built from a governance-set,
    metadata-only `externalBaseURI` on the factory. Transfers were never restricted. These land with the v1.1
    redeploy (the factory embeds the NFT creation code).

## Phase 5 — 2026-09-16

16. **Web app choices.** (a) Coin holder statistics are rebuilt client-side from Transfer logs on a wide-range RPC
    (`NEXT_PUBLIC_MONAD_LOGS_RPC`, default rpc1.monad.xyz) with per-coin incremental caching; a Supabase indexer can
    replace `app/lib/moments/holders.ts` later without touching the UI. (b) Media is fingerprinted in the browser
    (keccak-256 of the chosen file) and the hosted copy is a link the creator supplies (ipfs:// or https://); no
    upload service is wired yet, so without a file the link itself is hashed. (c) Collects default to a Permit2
    signature (Permit2 approved once, the canonical pattern); an exact-approval path is offered. (d) The trading fee
    is presented as 1.5% everywhere (0.5% pool + 1% hook) per ruling 12. (e) A dev-only in-page wallet
    (`app/lib/dev-wallet.ts`) exists solely for fork rehearsals; it is inert unless `NEXT_PUBLIC_DEV_WALLET_KEY` is
    set at build time and must never be set for production builds.

## Phase 6 — 2026-09-16

17. **Launch gates split by owner.** Engineering-side gates are closed: fork/live verification (Phase 3, 5),
    containment UI (Phase 5), on-ramp link slot (`NEXT_PUBLIC_ONRAMP_URL`), gas guidance ("user needs MON for gas"
    is the documented answer for the web surface), iOS web-first rule (no Moments in the binary), status monitor
    (`scripts/moments-status.mjs`) and governance ops (`PolicyOps.s.sol`). The validation launch run-of-show and
    the threshold-raise procedure are in `docs/moments-launch-gates.md`.

18. **No KYC, no legal determination, no geofence.** The owner rules that DyorHQ Moments is a decentralized,
    permissionless protocol: spec §14's legal/geofence/KYC gate is waived and spec §13 item 2 (securities/AML
    mitigations "required before real money") is superseded. The geofence route and UI gate built earlier in
    Phase 6 were removed. The independent audit (spec §14 gate 2) remains the only pre-launch gate; it is a
    security gate and stands unless the owner rules otherwise.

19. **Audit deferred: launch first, audit later.** The owner waives spec §14 gate 2 for the validation launch. The
    live v1.1 code carries only the Phase 4 self-review, Slither triage, invariant/fuzz suites and fork runs.
    Interim posture recorded in `docs/moments-launch-gates.md`: threshold stays at $10 (bounded exposure per
    Moment), small cohort, monitor before and after each step, audit before any threshold raise. Nothing in the
    contracts or the app blocks the launch any more.
