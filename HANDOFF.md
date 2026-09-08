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

## Good next steps
1. Wire screens to real data (markets, feed, launches, perps book) instead of the sample arrays
   in `app/ui/data.ts` and `public/preview.html`.
2. Keep `public/preview.html` and `app/` in sync: the preview is the design source the artifact is
   published from, and `app/globals.css` is generated from its stylesheet.
3. Decide whether the Expo app in `mainstreet-app/` adopts the same system (its code still says Mainstreet).

## Repo notes
- `~/Hackathon` had **no git history** before this session; the first commit captures the
  web app + the preview. No git remote is configured yet — add one (`git remote add origin …`)
  and push if you're moving to another machine (see the chat for the exact steps).
- `mainstreet-app/` and `mainstreet-repo.tar.gz` are `.gitignore`d here (the Expo app is its
  own repo; the tarball is a redundant snapshot).
