# HANDOFF — DyorHQ

Context for continuing this work in a new Claude Code session (e.g. a different Claude
profile or machine). Read this first.

## What this repo is
**DyorHQ** — "The RWA HQ for social trading": a self-custodial mobile app on Monad for launching stock-backed memecoins, copying on-chain traders, and trading perps and swaps. Four pillars: a
**Launchpad** (launch a memecoin paired with a tokenized RWA stock), **Copy Trading**,
**Perps**, and **Swap**. This repo (`~/Hackathon`) is the **web app**: Next 16 + React 19 +
Tailwind 4, built/deployed with **vinext** on Cloudflare (Wrangler). A separate **Expo /
React Native** app lives in `mainstreet-app/` as its own git repo (not tracked here).

## What was built
- **The design system** lives in `public/preview.html` (standalone prototype, published as the
  Claude Artifact for review) and in the React web app under `app/`: `app/page.tsx` (shell:
  device frame, floating glass top bar and tab bar, side menu, order review sheet, toast),
  `app/ui/screens.tsx` (Home, Markets, Launchpad, Swap, Portfolio), `app/perps-screen.tsx`,
  `app/preview-controls.tsx` (studio + preferences store), `app/ui/{data,icons,charts,components,liquid-glass}`,
  and `app/globals.css` (generated from the preview's stylesheet with fonts switched to `next/font` variables).
- Light and dark themes on the DyorHQ palette, liquid-glass navigation (SVG displacement in
  Chromium, frosted blur elsewhere), SVG candlestick/area/sparkline charts, an order book, a
  review sheet, and the studio (theme, accent, typeface, corners, text size, glass strength, motion).

## How to view the preview
- Open `public/preview.html` directly in a browser, **or**
- Run the dev server and browse to `/preview.html`:
  ```
  npm install && npm run dev
  ```
- It was also published as a Claude **Artifact**. ⚠️ That link is tied to the claude.ai
  account it was published from — on a different profile it won't appear in your gallery.
  To get a fresh shareable link on the new profile, ask Claude to **publish
  `public/preview.html` as an artifact**; the file is self-contained and re-publishes as-is.

## Design system
DyorHQ palette (see `public/brand/dyorhq-brand-guide.md`): Signal `#B9F26B` accent (user-swappable in
the studio), Ink `#0C100D` / Graphite `#1B211D` for dark, Paper `#F2F5EE` for light, Positive `#27DB91`,
Negative `#FF507A`. Geist + Geist Mono. Liquid-glass navigation layer, borderless cards, light and dark themes.

## Launchpad backend (Monad mainnet + Uniswap v4) — built, NOT deployed
- `contracts/` is a Foundry project (solc 0.8.26, via-IR) with the Pons-style launchpad re-implemented for
  Monad's canonical Uniswap v4 PoolManager: `LaunchpadFactory`, `LaunchDeployer` (+`CurveDeployer`),
  `BondingCurve`, `LaunchToken`, `MemeHook`, `FeeEscrow`, `HolderFeeSharing`, `LaunchLocker`,
  `GraduationExecutor`, `LaunchAndBuyRouter`. 25 tests (`forge test`), all contracts under 24 KB.
- Read `docs/launchpad-spec.md` for mechanics, the Pons → DyorHQ module map, parameters, owner powers and
  what is not built yet. `contracts/script/README.md` is the deploy runbook (dry run, deploy, verify, fork rehearsal).
- **Nothing is deployed on any public chain.** The owner wallet runs `forge script script/Deploy.s.sol:Deploy
  --rpc-url monad --broadcast --private-key …`, then `npm run sync:deployment` copies the addresses into
  `app/lib/deployment.json` (or use the `NEXT_PUBLIC_*` variables in `.env.example`). Until then the launchpad
  pages show an empty state with a "contracts not configured" notice.
- The integration was rehearsed on a local `anvil --fork-url https://rpc.monad.xyz` fork (deploy + `scripts/dev/seed-fork.mjs`):
  launches, buys, sells and one graduation into the real PoolManager bytecode all succeeded.

## Launchpad web app
- Routes: `/launchpad` (explore), `/launchpad/create` (Pons-style create form with the "Your token" card),
  `/launchpad/[token]` (curve trading, graduation/refund states, claims). Shell with wallet + network + theme
  controls in `app/launchpad/shell.tsx`, shared pieces in `app/launchpad/ui.tsx`, styles in `app/launchpad/launchpad.css`.
- Library: `app/lib/chain.ts` (viem public client, addresses), `app/lib/wallet.tsx` (EIP-6963 discovery, no wagmi),
  `app/lib/launchpad.ts` (reads), `app/lib/actions.ts` (writes, simulate-then-send), `app/lib/abi.ts` (generated:
  `npm run abis` after `forge build`), `app/lib/use-async.ts`, `app/lib/use-tx.ts`, `app/lib/errors.ts`, `app/lib/format.ts`.
- Checks: `npm run typecheck`, `npm run lint` (0 errors; `<img>` warnings are accepted), `npm run build`, `npm test`.

## In-app swap (spot) — built, fork-tested
- `/swap` compares live quotes from **Kuru Flow** (aggregator API → KuruFlowEntrypoint), **Uniswap** (v3 via
  QuoterV2/SwapRouter02 and v4 via V4Quoter/Universal Router + Permit2, including graduated launchpad pools) and
  **Monday Trade** (Uniswap-v3-style QuoterV2/SwapRouter), ranks them, and executes the chosen route from the user's
  wallet. MON ↔ WMON wraps directly. Read `docs/swap-spec.md` for every address, ABI decision and behaviour.
- Code: `app/swap/`, `app/lib/swap/` (engine, per-venue adapters, tokens, config, abis), `scripts/dev/pool-inventory.mjs`.
- Verified on a local anvil fork of Monad mainnet with a test wallet: quotes from all three venues and swaps
  executed through their routers. Kuru quotes hit the live API (1 request/second per address).

## App wired to live data (2026-09-08)
- The phone-frame app at `/` now reads everything from Monad mainnet: pool prices with 24h change, wallet
  balances, launchpad state and events, Perpl perps (book, tape, positions, orders, collateral) and TradingView
  charts. See `docs/app-wiring.md` for the per-screen map, chart choices and the Perpl integration.
- Perps venue is **Perpl** (Monday's perps are paused per its docs). Its WebSocket is bridged by `worker/index.ts`.

## Good next steps
1. Owner deploys the contracts (runbook above), syncs the addresses, and approves tokenised-stock pairs with
   `script/AddPairToken.s.sol` + `NEXT_PUBLIC_PAIR_TOKENS`.
2. Exact-output swaps, limit orders on the Kuru/Monday order books, and a Kuru Flow referrer fee once a fee wallet is chosen.
3. An indexer (holders, trades, charts) and image hosting (R2 upload route) for the create form.
4. Wire the prototype screens (`app/page.tsx`, `public/preview.html`) to the same data; the Launchpad screen links to `/launchpad`.
5. Keep `public/preview.html` and `app/` in sync: the preview is the design source the artifact is published from.

## Repo notes
- `~/Hackathon` had **no git history** before this session; the first commit captures the
  web app + the preview. No git remote is configured yet — add one (`git remote add origin …`)
  and push if you're moving to another machine (see the chat for the exact steps).
- `mainstreet-app/` and `mainstreet-repo.tar.gz` are `.gitignore`d here (the Expo app is its
  own repo; the tarball is a redundant snapshot).
- `contracts/lib/forge-std` and `contracts/lib/v4-core` are git submodules (`git submodule update --init --recursive`).
- `.env.local` is ignored; never commit RPC URLs with keys or fork addresses.
