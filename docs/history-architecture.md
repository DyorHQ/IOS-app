# Wallet history: how the app reads it

The app has no indexer. Everything a screen says about a wallet's past — swaps, launchpad fills, fees received, Moments
proceeds, the activity feed — is reconstructed from `eth_getLogs` on Monad's public endpoints, plus the actions the app
itself recorded (`ActivityLog`, mirrored to Supabase `activity`).

## What the public endpoints answer (measured 2026-10-08)

| Endpoint | Widest range per `eth_getLogs` | Notes |
|---|---|---|
| rpc2.monad.xyz | 10,000 blocks | address lists and topic lists accepted; a batch of 6 ranges in one request; 12 requests at once answered in 0.6 s |
| rpc4.monad.xyz | 1,000 blocks | some nodes answer any range, most refuse over 1,000 (HTTP 413, -32614) |
| rpc3.monad.xyz | 1,000 blocks | a request's ranges count together |
| rpc1.monad.xyz | 100 blocks | answered any wallet-scoped range until 2026-10-08; now refuses over 100 ("block range too large", -32602); HTTP 429 after a burst |
| rpc.monad.xyz | 100 blocks | |

A wallet's whole history is about 111 million blocks. No endpoint answers that in one request any more, and at 100 or
1,000 blocks a request it is tens of thousands of requests. Build 21 and earlier asked rpc1 for the whole history on
every screen (about 40 scans at once when Home opened), split each refusal into smaller ranges, and had no time limit,
so on today's endpoints every history screen spun for minutes or hours and the Send sheet said part of the wallet
couldn't be read.

## The design

1. **One logs router, every endpoint** (`LogsRouter`). A scan is a window of blocks; the router cuts it into ranges of
   what the endpoint answers (learned from its refusals and remembered), sends them in batches, and moves to the next
   endpoint when one throttles or fails. Every `eth_getLogs` request in the app goes through one gate (`LogsGate`):
   a few in flight, a few a second, so the app never throttles itself. A scan has a budget (requests and time); past
   it, the router returns what it read, with how far it got (`through`), never a partial result passed off as the
   whole. A range refused for how many logs it holds is split, not taken for the endpoint's span.
2. **A history store per wallet** (`HistoryStore`). The wallet's history is five scans — transfers in, transfers out,
   launchpad (fills, escrow payments and claims), fee sharing, Moments — each kept on disk with the blocks it covers.
   A refresh reads only the blocks since the last one, then backfills older blocks while its budget lasts; the cursor
   never moves past a block that wasn't read. Screens read the store first (instant) and refresh it in the background.
   History older than the store's floor is not read: for the transfer scans the wallet's first transaction (found
   once by bisection over its nonce at past blocks) or 30 days back, whichever is earlier, so every swap the wallet
   ever made counts; for the rest each DyorHQ contract's deployment.
3. **Screens publish what they have.** The actions the app recorded show at once; chain history fills in as the store
   catches up ("Reading your history… 28%"); a source that couldn't be read says so with Retry, and never replaces
   what the last good read showed. The rounds of reading run behind the screens (`HistoryModel`): up to 40 requests
   per scan a round (five scans), a second apart while they read, every 90 seconds once the history is complete. A
   round that couldn't reach the chain or read nothing (every endpoint refusing or resting) is followed by a longer
   wait each time (20 seconds, doubling, up to 10 minutes), and from the third such round in a row the screens say
   what is left couldn't be read, with Retry, instead of "Reading…" for ever; a return to the app starts a round at
   once, and a pull or a Retry reads the new blocks in a short round of its own (12 requests, 8 seconds), the rounds
   going on after it if it read anything.
