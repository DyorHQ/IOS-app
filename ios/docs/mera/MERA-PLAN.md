# Mera on DyorHQ: lean build spec (v3.1, 2026-09-25)

Status: this is the build spec. It replaces the v2 plan, which the owner found too heavy.

**Owner direction, 2026-09-25:** Mera is one more way to sign in or create an account, alongside Email & Password, Apple/Google/Email (Privy), import and watch-only. There is **no Mera-only variant**. The `MERA_ONLY` flag and every part of the design that only applied to it are removed.

Research behind it:
- Mera docs and source (`@category-labs/mera` 0.2.0, still the latest release)
- the Apple iOS 26.5 SDK
- Monad docs and client source
- the repo

Earlier findings are in memory (`mera-passkey-accounts`).

## 0. Principles

**Mera is a first-class sign-in method in the one app.**
- A passkey account needs no seed phrase, extension, email or one-time code.
- It lives next to the other methods, and nothing else is hidden or disabled.
- It is shown when `PASSKEYS_ENABLED=YES`. The rpId is live, so this is now on by default in Secrets.

**We keep the native Swift port.**
- It already matches Mera 0.2.0 byte for byte.
- A script in the repo proves it: `scripts/mera-parity` (`npm run parity`), pinned to 0.2.0. It runs the published package with a fake WebAuthn client and compares every vector in `MeraTests.swift`.
- The credit and Mera's MIT license text are in `THIRD_PARTY_NOTICES.md` at the repo root.
- The organisers will be asked whether a port counts.
- If they say no, plan B is the real library inside JavaScriptCore.

**The passkey is the only root secret, and it is never stored.**
- The device keeps only public hints: the credential ID and the address.
- Anything derived from the passkey lives in memory for the length of a session.

**Other sign-in methods are unchanged** (Social-logins commit 4ef4b26). The only thing Mera switches off is Privy's own passkey login, because it would share the rpId.

## 1. The rpId and the association file

**The rpId is `accounts.dyorhq.fun`.**
- It is irreversible once a real passkey exists.
- The Swift constant is `Mera.relyingParty = "accounts.dyorhq.fun"`.
- `project.yml` gets the entitlement `com.apple.developer.associated-domains: ["webcredentials:accounts.dyorhq.fun"]`, with no `?mode=developer`.
- `PASSKEY_RP_ID` is no longer read from xcconfig or Info.plist for Mera.

**It is not the apex `dyorhq.fun`.** The Replit site there injects `https://i.replit.com/script.js` on every HTML page, 404 pages included. A script on the rpId origin can run a passkey ceremony and read the PRF output, which is the keys.

**The host is GitHub Pages, from the public repo `DyorHQ/accounts-domain`.** The repo contains exactly three files:
- `.well-known/apple-app-site-association`, containing `{"webcredentials":{"apps":["96X7N58MVV.fun.dyorhq.app"]}}`
- `.nojekyll`
- `CNAME`, containing `accounts.dyorhq.fun`

It never contains `index.html`, workflows or `/.well-known/webauthn`.
- DNS: a CNAME at Hostinger, `accounts` → `dyorhq.github.io`. Also verify the org domain with a TXT record.
- HTTPS is provisioned automatically.
- Apple's CDN accepts the `application/octet-stream` content type that GitHub serves.
- To check: `https://app-site-association.cdn-apple.com/a/v1/accounts.dyorhq.fun`.
- After the CDN has cached it, the file is frozen.

**Rules:**
- Don't install a device build with this entitlement until the CDN serves the file. A failed fetch stays cached until the build number changes.
- Whoever can push to this repo can steal keys, so the org requires 2FA.

## 2. Onboarding

**The Get started screen offers passkeys among the other methods.** There are two buttons in the "or continue with" group: "Create account with a passkey" and "I already have a passkey". This follows Mera's own mobile-demo pattern.

**Create account:**
- It runs one ceremony that evaluates both PRF salts (the account salt and the utility salt).
- Each passkey gets a distinct name, `DyorHQ · <short date>`, and never an email address.
- It captures the `userID` and the credential ID.

| Registration result | What the app does |
|---|---|
| `prf.isSupported == false` | Throw `prfUnavailable` with no second prompt |
| `first` missing but supported | Run one pinned fallback assertion over both salts |
| `second` missing | Carry on; fetch the utility output lazily with a pinned assertion when it is first needed |

- If no address was ever derived, signal the new credential as unknown (orphan cleanup). Never signal after `adopt()` has succeeded.

**I already have a passkey:** a discoverable assertion with no `allowCredentials`. The system sheet also offers sign-in by QR from another phone.

**Error mapping:**

| Error | Meaning |
|---|---|
| `ASAuthorizationError.canceled` (1001) | Cancelled |
| `.failed` (1004) | `associationUnavailable`, with a clear "setup" message. `NSLocalizedFailureReason` goes to the log in DEBUG builds only |
| Anything else | Generic |

Remove the old `noCredential` string match. There is no error code for "no credential".

**Other rules:**
- Only one ceremony runs at a time. A second concurrent request fails.
- A cold launch shows no prompt: the account is restored locked, and read-only screens work.
- The backend (wallet-auth) sign-in runs inside `signInWithMera`, while the session is live. It never runs at launch for a locked Mera wallet (`RootView.swift:50`).
- App Lock never adds a second Face ID on top of a passkey prompt.
- PrivacyCover shows only on `.background`, not during a ceremony.
- When `hasMera`, Privy passkeys are disabled in every build: `createPasskey`, `signInWithPasskey` and the Settings "Add a Passkey" row. They would share the rpId.

**Restoring a session:**
- `loadStoredSession()` restores whichever account the device holds, as today. A Mera account's hint (credential ID and address, in UserDefaults) takes precedence.
- There is no reinstall purge.
- A Mera account keeps no secret on the device, so the stateless test comes down to this: after deleting the app or on a fresh device, "I already have a passkey" brings back the same address.

## 3. Signing session

The Swift equivalent of Mera's `createSecp256k1SigningSession` and `createEd25519SigningSession`.

**Opening and closing:**
- One ceremony opens a session. `expiresAt` is fixed when it opens.
- The length is 5, 15 or 60 minutes; the default is 15.
- Making the setting longer needs Face ID and never extends a session that is already live.
- A timer ends the session at expiry. The session also ends on `.background`, on Lock and on Sign out.

**`end()`:**
- zeroes the mutable key copies (best effort, as Mera says);
- drops the Perpl key;
- disconnects the Perpl socket and stops its keep-alive;
- is permanent. Any later signature throws `sessionEnded`.

**Key material:**
- It never leaves the session types. No public API returns key bytes.
- `MeraWallet` no longer conforms to a caller-facing raw-digest signer.
- Moments collect uses the exact-approval path.
- Perpl enrolment builds its own digest inside the session from validated typed data.

**Perpl for Mera accounts:**
- The Ed25519 trade secret is derived from the utility output at unlock and held in memory only. It is never passed to `PerplKeychain.save`.
- The token may be persisted, because the token alone can't sign in to the WebSocket.
- Each enrolment has a key of its own: Perpl registers a public key once (409 for any second enrolment, even after a revoke) and hands out its token once, so one fixed key could never be enrolled on a second device. An enrolment draws a random 16-byte nonce, stored with the token, and derives its key under `dyorhq.perpl-trading.v1/<nonce hex>` (`Mera.Purpose.perplTrading(nonce:)`). A token from before nonces keeps `dyorhq.perpl-trading.v1`. The nonce without the passkey signs nothing.
- `ensureConnected`, the keep-alive and RootView's reconnect on `.active` all require a live session.
- `submit` and `submitBracket` require a live session and a notional cap.
- Cancels and reduce-only closes are allowed only after a step-up.

### Scope: what is prompt-free while a session is live

An action is prompt-free only when every check below passes. Otherwise it asks for Face ID, runs a pinned ceremony that must derive the same address, signs that one action, and opens a new session.

1. **The sheet declares a session-OK intent.** The default is "ask", so untagged sheets fail closed. Session-OK intents:
   - swaps on Uniswap and Monday;
   - Kuru Flow swaps, only if minOut is at least quote × (1 − 1%), rounded down as Kuru rounds it; otherwise Face ID. A recipient other than the account, or tokens other than the declared swap's, are refused outright (below);
   - Launchpad buy and sell;
   - Moments collect, claim and withdraw-to-self;
   - Perpl deposit to own account, withdraw to own address, orders and brackets;
   - wrap and unwrap.
2. **The wallet's own check passes**, independently of the sheet:
   - `chainId == 143`;
   - `(to, selector)` is on the allowlist;
   - ERC-20 `approve` and Permit2 `approve`: the spender is in the allowed set, the amount is no more than the declared input, the Permit2 expiration is no later than the session's `expiresAt`, and the value is 0;
   - any MON sent is no more than the declared amount;
   - the launchpad curve address is verified on-chain against the known factories (current and retired stacks);
   - an unpriced input means Face ID.
3. **The caps hold:** at most $100 per action and $250 per session. Anything above asks. A perp order is valued at its worst fill: a market order at the mark moved by the whole slippage, a limit order at the higher of its limit and the mark (a short limited below the mark fills near it).

**Refused whatever the approval** (`SigningPolicy.refusal`, checked before any prompt on every transaction a passkey account signs, prompt-free or approved by a step-up; the badge reads "Blocked for your safety: <reason>" and the button is disabled):
- on Monad, a network fee out of bounds: more than 5 MON (gas limit × max fee), a gas limit over 15M, or a tip above the max fee. The RPC sets the fee and neither the sheet nor the caps show it. The largest transaction the app sends, a launch with its first buy, used ~5.2M gas on mainnet (~1.3 MON at the usual fees); a normal swap pays ~0.07 MON;
- a Kuru Flow swap paying its output to another address (any intent), or trading tokens other than the declared Kuru swap's;
- a declared launchpad buy or sell paying another address.

Kuru Flow's calldata is also checked when it is quoted, for every account type (`KuruFlowClient.quote`): it must pay this account, trade exactly the requested amount of the requested tokens, and enforce at least the requested slippage's minimum on the quoted output. The sheet shows that enforced minimum.

**Always asks:**
- Send, token transfer, Bridge, launch or create, withdraw to another address;
- export, deletion, lengthening the session;
- any raw digest;
- any message except the exact wallet-auth template (`"DyorHQ Sign-In\n\nWallet: …\nNonce: …\nIssued At: …"`) and the gas-drip template.

**Builder fixes:**
- Uniswap uses exact approvals. Today it uses `maxUint160` and a 30-day Permit2 allowance.
- Moments collect for Mera uses the exact-approval path.

**On screen:**
- A Home pill reads "Active · 12m" and turns amber in the last minute. It reads "Locked" once the session ends. Tapping it opens a scope sheet.
- Sheet badges read "No Face ID needed", "Face ID required: <reason>" or "Blocked for your safety: <reason>".
- When locked, the button reads "Confirm with Face ID".
- "Face ID" is the device's own prompt everywhere: Touch ID, Optic ID, or Passcode when no biometrics are enrolled (`BiometricGate.promptName`).
- The review sheet freezes the quote it opened with, so its details, its intent and the plan it signs never drift apart while quotes refresh.
- Bridge never prompts on open: a locked passkey account without a backend session sees "Unlock to bridge".
- Expiry never shows a pop-up, and the form is kept.
- A cancelled step-up shows "Not sent. Nothing left your account."

## 4. Funding the first transaction (no gas sponsorship — owner confirmed 2026-09-25)

**Sponsorship is not required.**
- The bounty's deliverables are:
  - real transactions and a live demo;
  - one-prompt onboarding;
  - prompt-free signing in a clearly scoped session;
  - the stateless test.
- None of them asks for sponsored gas.
- Gas sponsorship appears only as one example of the optional bonus ("stack composability … gas sponsorship, intents, recovery flows, smart-account patterns, cross-chain accounts").
- DyorHQ sponsors no gas today, and this build doesn't either.

**The trade-off.** Time-to-first-transaction is judged ("taps and seconds from landing page to confirmed Monad transaction"). A new account has 0 MON, so the first transaction waits for a deposit.

**Instead, the "Add funds" step is as fast as possible.**
- After Create, Home shows an "Add funds to start trading" card with:
  - the address;
  - a QR code;
  - Copy and Share;
  - "Bridge from another chain" (the existing Aurora bridge);
  - a live balance watch that polls every few seconds.
- The moment funds arrive, the card turns into "Make your first trade".
- The first trade is a single, prompt-free swap in the live session.

**How it's built** (`Home/AddFundsCard.swift`; the rules are in DyorKit `FirstFunding`, tested in `FirstFundingTests`):
- **Who sees it:** a passkey account only. One read decides. The card shows only when every known-token balance is dust and the account has no activity. Dust means under 0.001 MON, under $0.01 for a priced token, or any amount of an unpriced token that isn't curated, so an airdrop can't pass for a deposit.
- **Activity** means any of these:
  - a Monad nonce above 0 (pending included);
  - an entry in the app's activity log other than a bridge in, since the bridge is how the card funds the account;
  - launch coins, Moments or Perpl equity.
- **The watch:** the balances over the known tokens (Home's own source) every 4 s. It runs only while Home is on screen, the app is active and the card isn't done. The nonce isn't read while the account is still empty. Prices come from Home's last load.
- **Card phases:**
  - **Funds arrived:** shown for 1.5 s, so the deposit is 3 blocks old before the account can spend it. The balance above it refreshes right away.
  - **Make your first trade:** opens Swap on the pair and signs under the swap intent. The pair is MON → USDC, or USDC → MON when only USDC came (another curated token → MON, and WMON → USDC).
  - **Too little MON for the network fee** (under 0.1 MON, which covers what Max keeps back for a swap plus a token-in trade's approvals): the button waits, and the card asks for about 0.1 MON.
- **When it goes:** the card ends at the first activity, or when the first-trade card is closed. It never goes back to an earlier phase. A funded account with no activity doesn't see it again after a relaunch.
- The copy says "MON" and "Monad", and never says "gas".

**Bonus without a sponsor.** "Intents" and "cross-chain accounts" come from the Aurora bridge: the same address on every EVM chain, with any-chain funding. Recovery comes from phrase export.

**For the demo:**
1. Fund the new account from the owner's wallet by scanning the QR code, with a timer on screen.
2. Or show a pre-funded rehearsal account, and say so in the write-up.

**Optional later, if time allows:** a small gas drip. The design is kept in the v2 notes in memory (`mera-passkey-accounts`).
- The easiest version is a function in the existing Supabase project with a small float.
- A separate project would cost $10/mo.

## 5. Monad fee and reserve fixes (all builds)

**Done (uncommitted), all tested in DyorKit (`RPCFailoverTests`, `MonadReserveTests`):**
- **Fees.** `TransactionSender` takes the tip from `eth_maxPriorityFeePerGas` and sets maxFee = 2 × base + tip. It falls back to the gas price.
- **Reserve spacing.** In `TransactionSender.run` on Monad, a step with value > 0 from an account under 10 MON + value waits until the head is 3 blocks past the block that confirmed the run's previous step. A first step, a step without value, a well-funded account and every other chain go straight on. A balance that can't be read counts as under; a head that doesn't move gives up after 5 s and sends anyway (a local fork mines on demand). The at-risk case is an ERC-20-pair launch with a creator buy: approve → `launchAndBuy` with the 5 MON fee.
- **Funds still settling.** When Monad refuses a broadcast with "…insufficient balance" (funding under 3 blocks old), `send` resends the same signed bytes once after ~1 s, so there is no second signature or Face ID. If it is refused again, the message is "Your funds are still arriving. Try again in a moment." when the latest balance covers value + gas limit × max fee, and "Not enough MON to pay for gas." when it doesn't. Other chains keep the node's error.
- **Honest Max** (`NetworkFeeReserve`, `TransactionSender.maxValue`). The native Max keeps back gas limit × (2 × base + tip) from the RPC, × 5/4 on Monad and × 2 elsewhere (plus 0.00001 ETH for the L1 data fee on Base, Optimism and Scroll). The gas limit is estimated like `prepare` does (estimate + 20%) for the transaction when there is one, or budgeted: 300k for a swap, 25,200 for a transfer. When the fee can't be read: 0.06 MON on Monad, a per-chain amount elsewhere. The Max is zero when the fee takes the whole balance.
  - Swap (MON in): the value step of the route on screen, or the swap budget. Replaces the old 0.02 MON.
  - Bridge (native source, any chain): a transfer to the quote's deposit address, or to a code-less stand-in before there is one, on the source chain. Replaces keeping 0.
  - Send (MON): a transfer to the recipient once one is entered. Replaces keeping 0.

## 6. Stateless test

**Reconstructed from the passkey and the chain:**
- the address and key;
- the Supabase session, by re-signing wallet-auth;
- Perpl trading, by enrolling again (Profile › Perpl Trading › Connect): a new key from the passkey and a fresh nonce (§3), one Face ID at most and none inside a live session. Perpl refuses a key it has seen, and allows 16 active keys per account; a 423 says to remove old ones on app.perpl.xyz;
- balances, positions, launches and Moments.

**Restored from Supabase** (`BackendSync.restore`, rules in DyorKit `BackendRestore`):
- notifications, alerts and settings, into stores that are still empty (as before);
- activity: merged into the device's log on every restore, never doubling a row (same id or tx hash). Every local row is kept; restored rows only fill the room left under the 300 the local log holds, newest first, so however many there are they never push a device's own record out (a full log restores none). Rows are checked first: a UUID id, a kind and title, a real timestamp no more than 10 minutes ahead (`BackendRestore.Activity.futureSkew`), a 32-byte hash or none, non-negative dollar sizes;
- settings are checked: slippage only as one of the Trading Preferences choices (0.1/0.5/1/2 %, never above 300 bps) and leverage as a whole step in 1–50×; anything else present restores as the default (0.5 %, 2×), and a mistyped key is ignored.

**"Forget This Device"** (Profile, in place of Sign Out for a passkey account) runs `AccountDeletion.eraseThisDevice`: backend sign-out, the Perpl token dropped, notifications cleared, then `eraseLocalData()`. It never signals Apple. Footer: "Removes this account from this iPhone. Your passkey keeps it — sign in again anytime."

**Deleting and reinstalling** wipes the Mera hint (UserDefaults). The account comes back through "I already have a passkey".

## 7. Export (recovery phrase)

`MeraSession.revealPhrase()`:
- runs a fresh pinned ceremony every time;
- checks that the derived address matches;
- returns the 24 words.

The view:
- blanks the words while the screen is being captured (`sceneCaptureState` / `UIScreen.isCaptured`) and on background (PrivacyCover);
- auto-hides after 60 s;
- asks the user to confirm 3 of the words.

`WalletExportView` routes `.meraPasskey` here, and the Manage Wallets footer is fixed.

## 8. Account deletion removes the passkey

**API** (iOS 26.5 SDK):
- iOS ≥ 26.2: `ASCredentialDataManager().reportUnknownPublicKeyCredential(relyingPartyIdentifier:credentialID:)`
- iOS 26.0–26.1: `ASCredentialUpdater()` has the same method.
- iOS 18: no API.

**What it does and doesn't guarantee:**
- Apple doesn't confirm the result. The credential "may be removed or hidden".
- Apple Passwords was observed moving it to Recently Deleted for 30 days.
- Third-party managers act only if they opt in.
- A passkey used over QR from another phone isn't reached.

**Flow for `.meraPasskey`:**
1. **The screen:**
   - It shows the address and what could be lost: MON and tokens, Perpl collateral, NFTs and Moments, creator fees and vesting, and funds at the same address on other chains.
   - Copy: "Deleting removes your passkey, which is this wallet's only key. Assume this is permanent unless you export the recovery phrase first."
   - The primary buttons are **Export recovery phrase** and **Move funds out**.
   - Deleting without an export always needs the box "I understand I may permanently lose these funds" ticked. It is never skipped based on a balance read.
2. **Type DELETE** (as today).
3. **Delete with Face ID:**
   - This runs a forced pinned ceremony, even while a session is live.
   - The derived address must equal the one on screen.
   - It captures the credential ID in memory and opens the session used for the backend signature.
4. **Server rows are deleted.** Deleting the profile cascades to activity, device_tokens, notifications, alerts, user_settings and sessions. `email_accounts` is deleted explicitly, as today.
   - On failure, stop: "Nothing on this phone was changed."
5. **Signal:** `reportUnknownPublicKeyCredential(accounts.dyorhq.fun, credentialID)`, only after the server delete succeeds.
6. **Erase:** `eraseLocalData()`.
7. **Done:**
   - "Account deleted."
   - Conditional copy: "If your passkey is in iCloud Keychain, Passwords may keep it in Recently Deleted for up to 30 days."
   - Always the manual steps: Passwords app › Passkeys › search "dyorhq" › DyorHQ passkey › Edit › Delete. Delete it in 1Password or another app if it's stored there, or on the other phone if you used QR.
   - On iOS 18: "One step left: delete the passkey yourself", plus the same steps.

## 9. Build order

Agent work happens on branch `mera/bounty`. It is verified with `swift test`, a Simulator build and a DEBUG Simulator-only stub authenticator:
- the stub uses a random PRF per install, never a repo constant;
- it refuses non-localhost RPC;
- an account it derives is confined to the local fork where it signs (`MeraSession`, `Mera.Stub.permits`): transactions for chain 143 only, no messages, so no wallet-auth sign-in to the production backend (skipped quietly), no Perpl enrolment, and the Bridge screen reads "Not available in Simulator test mode";
- it is absent from Release.

1. Flags and config: the rpId constant, the entitlement, and disabling Privy passkeys when `hasMera`. (`MERA_ONLY` was built, then removed per the owner's direction.)
2. Ceremony: `prfUnavailable`, the lazy utility salt, serialisation, names, the error mapping, `userID`, the forced pinned assertion, the signal helper and orphan cleanup, and the stub authenticator.
3. Launch: no prompts, PrivacyCover on background only, no App Lock double prompt. Notification permission is asked at sign-in, as for every account.
4. Session lifetime: fixed `expiresAt`, the timer, `end()`, Face ID to lengthen, and the Perpl in-memory key and socket lifecycle.
5. Scope: intents, the wallet check, caps, Kuru decoding, exact approvals, Moments exact path, typed enrolment, and the UI (pill, badges, locked button).
6. Export.
7. Deletion.
8. Stateless: activity restore, settings clamp, Forget this device.
9. Reserve spacing and the Max buttons.
10. Parity script (`scripts/mera-parity`), and Mera's MIT license text in `THIRD_PARTY_NOTICES.md` (Mera is MIT OR Apache-2.0).
11. The "Add funds" card with a live balance watch that becomes "Make your first trade". There is no gas sponsorship (§4).

**The owner:**
- approves the rpId;
- allows the repo and DNS changes;
- turns on 2FA;
- enables Associated Domains on the App ID;
- asks the organisers whether a port counts;
- picks an OSI license;
- runs the device tests: prompt count, same address after reinstall and on a second device, QR, deletion moving the passkey to Recently Deleted.
