# HANDOFF — DyorHQ

Context for continuing this work in a new Claude Code session (e.g. a different Claude
profile or machine). Read this first.

## What this repo is
**DyorHQ** — "The RWA HQ for social trading": a self-custodial mobile app on Monad for launching stock-backed memecoins, copying on-chain traders, and trading perps and swaps. Four pillars: a
**Launchpad** (launch a memecoin paired with a tokenized RWA stock), **Copy Trading**,
**Perps**, and **Swap**. This repo (`~/Hackathon`) is the **web app**: Next 16 + React 19 +
Tailwind 4, built/deployed with **vinext** on Cloudflare (Wrangler). A separate **Expo /
React Native** app lives in `mainstreet-app/` as its own git repo (not tracked here).

## What was built in the last session
An **interactive preview** of the app — a self-contained, phone-frame prototype of every
screen, so we can *see* what we're building.

- **Source of truth for the preview:** the web app screens in `app/` — `app/page.tsx`
  (feed / markets / launchpad / swap / profile + side menu + bottom nav + studio panel),
  `app/perps-screen.tsx`, `app/preview-controls.tsx`, `app/globals.css`.
- **The deliverable:** [`public/preview.html`](public/preview.html) — one standalone HTML
  file (vanilla JS, inline SVG charts, Geist via Google Fonts; no build step, no deps).
  It reproduces all 6 screens faithfully and **elevates** the original:
  - real SVG **candlestick** chart on Perps (bodies + wicks + gridlines + last-price tag),
    smooth **sparklines** in the feed, an **area chart** for the portfolio & swap price panel;
  - **tabular monospaced numerics** everywhere prices/PnL/amounts align;
  - tightened Geist type scale, refined glass/orbs/spacing;
  - the signature **studio panel** preserved: accent color + swatches, corner radius, text
    size, motion toggle — persisted to `localStorage`.

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
1. **Fold the preview's upgrades back into the real React app** (`app/page.tsx`,
   `app/perps-screen.tsx`): the SVG candlestick/sparkline/area charts and tabular numerics
   are the highest-value diffs.
2. Wire screens to real data (markets, feed, launches) instead of the in-file sample arrays.
3. Keep `public/preview.html` in sync if the React screens change (it's a static mirror).

## Repo notes
- `~/Hackathon` had **no git history** before this session; the first commit captures the
  web app + the preview. No git remote is configured yet — add one (`git remote add origin …`)
  and push if you're moving to another machine (see the chat for the exact steps).
- `mainstreet-app/` and `mainstreet-repo.tar.gz` are `.gitignore`d here (the Expo app is its
  own repo; the tarball is a redundant snapshot).
