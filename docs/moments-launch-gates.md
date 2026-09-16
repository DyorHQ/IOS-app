# Moments — Phase 6: launch gates and the curated $10 validation launch

Spec §14 lists the gates that must pass before real money. Status as of 2026-09-16, with the evidence or the
owner action each one needs. The contracts (v1.1) are live and verified; nothing below changes them.

## Gate status

| # | gate (spec §14) | status | evidence / what is left |
|---|---|---|---|
| 1 | Launchpad audit fixes (holder-reward drain + owner backdoors) | done | Launchpad redeployed 2026-09-16; Moments imports nothing from it |
| 2 | Independent audit of the clean-room Moments contracts; critical/high resolved | **deferred by the owner** (ruling 19): launch first, audit later | The live v1.1 code has had the Phase 4 self-review (no Critical/High found; four Lows fixed, two accepted), Slither triage, invariant and fuzz suites, and the mainnet-fork runs — but no independent audit. Hand-off package for when it happens: `docs/moments-security-review-2026-09-16/REPORT.md` §7 (scope tag `moments-mainnet-v1.1`). If the audit changes code, redeploy the whole set and pause publishing on the superseded set, as done for v1 |
| 3 | Fork test on Monad v4 with the real USDC pool: collect → graduate → trade → claim → buyback | done | Phase 3 mainnet-fork suites (10/10, reconciled to `economics.py`), `LiveDeployment.t.sol` through the deployed contracts, and the Phase 5 browser run (publish, collects, claimAll, Universal Router trade, fee accrual, withdrawal) |
| 4 | Legal determination per jurisdiction; geofencing + KYC'd on-ramp wired | **waived by the owner** (ruling 18) | DyorHQ Moments is a decentralized, permissionless protocol: no KYC, no legal determination, no geofence. The geofence mechanism built earlier in this phase was removed again; the contracts and the app are open to anyone with a wallet. Spec §13 item 2 and §14's legal line are superseded by the ruling |
| 5 | iOS: coin purchase off-binary; web-first transaction surface | done by construction | The iOS app has no Moments surface; Moments live on the web app. Rule for the iOS team: link out to `/moments`, never sell coins or editions inside the binary (Apple 3.1.5(b)) |
| 6 | Privy gas sponsorship validated, or "user needs MON for gas" documented | documented | The web app uses injected wallets, so users pay gas in MON; the collect panel says so when a wallet holds no MON. Privy sponsorship only matters for the iOS surface, which is out of scope for this launch |
| 7 | Small-cap containment: curated cohort, early/low-cap/validation labels, holder count + top-holder % shown, not marketed as investments; raise the threshold via policy later | done in the app; cohort is operational | Labels on every card and page, holder + edition statistics, mandatory plain-language disclosure, no "proven demand" badge anywhere, copy never calls the coins investments. Threshold raise: `PolicyOps` below |

**No gate blocks the launch.** The owner waived the legal/KYC line (ruling 18) and deferred the independent audit
(ruling 19). Interim posture while the code is unaudited: keep the policy at the $10 threshold (any Moment's pool
holds at most $10 of USDC plus trading proceeds), keep the cohort small, run `scripts/moments-status.mjs` before and
after every step, and schedule the audit before the threshold is raised.

## Validation launch — run of show

Cohort: one creator wallet and three to five collector wallets, all dedicated and low-value (a few USDC and a little
MON each), never the governance, platform or treasury wallets. Total exposure at the $10 policy is about $13.34.

1. **Before:** `node scripts/moments-status.mjs` (all invariants OK, 0 or the expected number of Moments); app
   deployed with `app/lib/moments-deployment.json` from `npm run sync:moments`; `NEXT_PUBLIC_ONRAMP_URL` set if
   there is a preferred place to get USDC; `NEXT_PUBLIC_DEV_WALLET_KEY` **unset**.
2. **Publish** from the creator wallet on `/moments/create`: $1 collect price, 10% allocation, a window of a few
   days, IPFS-hosted media with the original file fingerprinted. Then `contracts/script/moments/verify-moment.sh <id>`
   so the coin and the NFT are Sourcify-verified from the start.
3. **Collect** from the cohort on `/moments/<id>` (Permit2 signature): 13 collects of $1 and a 14th that the
   contract clamps to 0.333334 USDC and that graduates the Moment in the same transaction. Expect: state
   Graduated, pool locked, opening price 2.5926e-7 USDC per coin, 14 editions fixed, the holder panel populated.
4. **Verify:** `node scripts/moments-status.mjs` shows identity OK and solvency OK for the new Moment; the
   Moment page shows the pool id; the NFT collection appears on the marketplace once indexed (the creator can
   claim the collection page through `owner()`).
5. **Claim:** a collector claims the 60% tranche on `/moments/portfolio`; the creator claims 20%.
6. **Trade:** a small buy on `/swap` through the hooked pool; the Moment page shows the 0.2/0.3/0.5 accruals.
   The buyback button enables after about $200 of volume (1 USDC accrued) and can be run by anyone.
7. **Pull:** the creator withdraws the collect share and the trading-fee share from the Moment page; platform and
   treasury pull from their own wallets when they choose.
8. **Later:** month-1 and month-2 claims on the portfolio page; a second Moment that is allowed to expire proves
   the wind-down path (70/30) in production.

If graduation is pending after the terminal collect, anyone can retry from the Moment page; every cent stays in
the collect contract meanwhile. If it never succeeds, the wind-down becomes available after the deadline plus
seven days. The only governance switch is pausing publishing; nothing else is pausable, by design.

## Raising the threshold after the validation cohort

Policy changes apply to future Moments only and sit behind a 48-hour timelock:

```bash
cd /Users/jerry/Hackathon-moments/contracts && THRESHOLD_USDC=1000000000 ~/.foundry/bin/forge script script/moments/PolicyOps.s.sol:PolicyOps --rpc-url monad --broadcast --non-interactive --account owner --sig "proposePolicy()"
```

then, two days later, from any wallet:

```bash
cd /Users/jerry/Hackathon-moments/contracts && ~/.foundry/bin/forge script script/moments/PolicyOps.s.sol:PolicyOps --rpc-url monad --broadcast --non-interactive --account owner --sig "applyPolicy()"
```

`show()` prints the live policy without a key; `cancelPolicy()`, `setPaused()` (`PAUSED=true|false`) and `setBase()`
(`BASE=…`) cover the other governance calls.

## Monitoring

- `node scripts/moments-status.mjs [rpc]` — every Moment's state, reserve, entitlements, pool, fee accruals, and the
  supply-identity and USDC-solvency invariants; exit code 2 on any problem.
- The Moment page and portfolio page read the same contracts through multicall.
- Sourcify per Moment: `contracts/script/moments/verify-moment.sh <id>`.

## Web app deployment notes

`cd contracts && forge build` → `npm run abis` → `npm run sync:moments` → `npm run build` → deploy through the
existing hosting pipeline. Optional `NEXT_PUBLIC_MOMENTS_*` address overrides, `NEXT_PUBLIC_ONRAMP_URL` and
`NEXT_PUBLIC_MONAD_LOGS_RPC` (default rpc1.monad.xyz for holder statistics). Never set `NEXT_PUBLIC_DEV_WALLET_KEY`
for a production build.
