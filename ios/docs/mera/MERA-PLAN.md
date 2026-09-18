# Mera on DyorHQ — passkey accounts as the account layer

Status: plan, 2026-09-17. Sources read: mera.category.xyz (getting started, passkeys & PRF, signing sessions,
passkey accounts, entropy/keys/accounts, security model, secret vaults, React Native recipe, create-passkey-accounts
recipe), `category-labs/mera` source (`passkey.ts`, `secret.ts`, `chains/evm.ts`, `demos/mobile`), the bounty brief.

## 1. What Mera is (verified)

- A TypeScript library (`@category-labs/mera`, preview, API may change before 1.0). No Swift SDK. The React Native
  recipe uses `react-native-passkey`; iOS 18+ is required (PRF).
- Identity = a **passkey with the WebAuthn PRF extension**. One ceremony returns 32 secret bytes that are the same on
  every sign-in and every synced device: `PRF(credential, rpId, salt)` with the fixed salt
  `sha256("mera.prf.salt.v1")`. Discoverable credential, user verification required, ES256/RS256, attestation none.
- Accounts: the 32 bytes are BIP-39 entropy → 24-word mnemonic → BIP-39 seed (empty passphrase) → BIP-32 at the BIP-44
  Ethereum path `m/44'/60'/0'/0/{index}` → EIP-55 address. Nothing is stored; the address is recomputed each time.
- **Signing sessions**: an in-memory secp256k1 key that signs digests until `end()` zeroes it. "Prompt-free" means
  no authenticator prompt while the session lives; the next signature after `end()` needs a fresh ceremony.
- **Secret vaults**: AES-256-GCM with a key from HKDF-SHA-256(PRF(random 32-byte salt), info `mera.v1.encrypt.secret`);
  the ciphertext can live anywhere (localStorage, a backend, iCloud) because tampering fails decryption. This is the
  "untrusted storage" the stateless test allows.
- Relying party: the passkey is bound to an `rpId` domain. iOS needs `https://<rpId>/.well-known/apple-app-site-association`
  with `webcredentials` listing `TEAMID.fun.dyorhq.app`, and the `webcredentials:<rpId>` associated-domain entitlement.
  A web app and the native app can share the same passkey and accounts when they share the rpId.
- Threats the docs name: whoever controls the rpId domain can run a ceremony and obtain the PRF output; a live session
  signs for any code that reaches it; losing the passkey without an export loses the accounts; migrating domains
  invalidates accounts. Recommendations: end sessions promptly, add expiry, offer export/backup.

## 2. How it fits DyorHQ

DyorHQ is native SwiftUI. There is no JS runtime to host `@category-labs/mera`, and a WebView bridge would put the
account layer in the least trustworthy place. The right move is a **native implementation of the Mera scheme**:

- `AuthenticationServices` passkeys with PRF (present in the iOS 26.5 SDK: `ASAuthorizationPublicKeyCredentialPRF
  RegistrationInput/Output` and `…PRFAssertionInput/Output`). Same rpId, same salt, same derivation, so the address a
  user gets on iPhone equals the one Mera's JS gives them on the web app later (stack composability, and it makes the
  bounty's "same accounts across platforms" claim true for us).
- DyorKit already has BIP-39 validation, BIP-32 (`HDNode`), `Secp256k1Account` and the `Wallet` protocol used by
  Privy and imported wallets. Add `Mnemonic.phrase(fromEntropy:)` (256-bit entropy → 24 words) and a `MeraWallet`
  signer. Keys never leave the process; the runner, swaps, perps and strategies use `Wallet` unchanged.
- Sign-in method becomes a fourth option next to Apple / Google / Email (Privy) and Import: **Continue with passkey**.
  Privy stays for people who want email/social; Mera is the no-account, no-seed path.

## 3. Onboarding and time-to-first-transaction

Target: landing → confirmed Monad transaction in **2 taps + Face ID** and under 20 seconds.

1. Landing: "Continue with passkey" → `createPasskeyWithPrfOutput` equivalent (one Face ID). The address is on screen
   before the sheet closes. No email, no OTP, no phrase.
2. Returning: "Continue with passkey" → assertion with PRF → same address. Fresh device: the passkey is in iCloud
   Keychain, so the same tap reconstructs the same address with zero local state (the stateless test).
3. First transaction needs gas. Options, cheapest first: (a) a relayer that drips a few cents of MON to a freshly
   created Mera address once (owner-funded, rate limited, address must be new); (b) EIP-7702 delegation of the Mera
   EOA to a minimal smart-account implementation on Monad so a paymaster sponsors gas and session keys get on-chain
   scope (the bounty's bonus). Ship (a) for the demo; design (b) as phase 2.
4. The demo transaction: a small swap on the Trade tab (USDC→MON) or a Moments collect, confirmed in the activity log
   with the explorer link.

## 4. Session design (prompt-free vs re-prompt)

Keep the Mera private key in memory only, inside a `MeraSession` with an explicit scope shown in the UI:

| Action | Behaviour |
|---|---|
| Swaps, perps orders, strategy slices, Perpl deposits, Moments collects | prompt-free while the session lives and the running total stays under the session cap (default $250, user-set) |
| Send / withdraw to an external address, Perpl withdrawals, anything over the cap, exporting the phrase, changing session settings | always a fresh passkey ceremony |
| Session lifetime | 15 minutes of activity, ends on app background > 2 minutes, app termination, or Lock. Clear "Session ends in mm:ss" pill and a Lock button in Profile. Ending zeroes the key. |
| Read-only | address, balances and history never need a prompt |

Perpl already has a trade-scoped Ed25519 key; register it once per session so perps stay prompt-free for the same
window. Strategy runs (TWAP entry/exit) need the session alive; the runner requests a re-prompt when it expires
mid-run instead of failing.

## 5. The stateless test

Identity: fully reconstructed from the passkey (above). App state: strategies, notifications, watchlists, alerts and
copy-trading records live in UserDefaults today. Move them behind a per-address sync to Supabase (already the backend
for social/alerts/sync) so a fresh device shows the same positions after one ceremony. Secrets that are not the
passkey — the Perpl trade key, an optional exported phrase — go into a **Mera secret vault** stored in Supabase; the
vault decrypts only with the passkey, so Supabase stays untrusted storage.

## 6. Work plan

1. Domain and relying party (blocker for everything): host `https://dyorhq.fun/.well-known/apple-app-site-association`
   (`webcredentials` → `TEAMID.fun.dyorhq.app`) and add `webcredentials:dyorhq.fun` to the entitlements. Decide rpId
   now; it cannot change later without losing accounts. Recommendation: `dyorhq.fun` (the future web app lives there).
2. DyorKit: `Mnemonic.phrase(fromEntropy:)`, `MeraDerivation` (salt constant, entropy→seed→`m/44'/60'/0'/0/i`),
   tests against vectors produced by the JS library (run `@category-labs/mera` once in Node to capture address
   vectors for fixed PRF bytes).
3. App: `PasskeyAccount` (create / assert with PRF, credential id stored in Keychain, no secret stored), `MeraWallet`
   (`Wallet` conformance, session with scope, cap and expiry), "Continue with passkey" onboarding, session pill and
   Lock, re-prompt sheet.
4. Gas drip relayer for new Mera addresses (Supabase edge function + owner-funded hot wallet with a small float and
   per-address/per-day limits).
5. State sync per address (strategies, alerts, notifications) and the secret vault for the Perpl key.
6. Demo script for judges: fresh device → passkey → drip → swap → clear storage → passkey → same address and history.
7. Phase 2 (bonus): EIP-7702 delegation + paymaster on Monad, on-chain session-key scopes, recovery via a second
   passkey or vault export.

Estimate: steps 1–3 two days, 4–5 one day, 6 half a day, once the domain is live.

## 7. Bounty two: the passkey as a key factory (non-wallet uses)

The second bounty rewards the most creative use of PRF namespaces for anything that is *not* signing wallet
transactions: every salt is an isolated namespace, so one passkey can mint unlimited unrelated keys for encryption,
identities or capabilities, all reconstructible from the passkey alone, with no secret stored anywhere. Judges look
for novelty, correct use of the primitives (derivation for identities and capabilities, encryption for state,
genuinely namespaced salts, nothing sensitive persisted), and a live cross-device test.

How DyorHQ uses the primitive (implemented in `DyorKit/Services/Mera`): one ceremony evaluates **two PRF salts** —
Mera's default salt for the wallet, and `sha256("dyorhq.utility.v1")` for everything else — so the authenticator
itself keeps the wallet secret unrelated to every utility key, and one Face ID yields both. Under the utility output,
per-purpose keys come from HKDF-SHA-256 with the purpose string as `info`; the purpose strings are part of the key
and never change. Secrets that must wrap existing material use Mera's secret-vault format (fresh random PRF salt per
vault, AES-256-GCM), byte-compatible with the JS library.

Namespaces, in order of build:

1. **Perpl trading capability** (`dyorhq.perpl-trading.v1`, built). Perpl needs an Ed25519 API key enrolled against the
   wallet. DyorHQ derives it from the passkey instead of generating and storing it: enrol once, and the same key
   reappears on any device — the trading session survives a lost phone with no backup, and there is no key to leak.
2. **Device-independent app state** (`dyorhq.state.v1`). Strategies, alerts, notification history and copy-trading
   settings encrypted client-side and stored in Supabase as ciphertext keyed by address. A fresh device shows the same
   positions after one ceremony; the server never sees a watchlist or a strategy. This is also what makes the first
   bounty's stateless test complete.
3. **Unlinkable social identity** (`dyorhq.social-identity.v1`). The profile, follows, reports and copy-trading
   signals are signed by an Ed25519 identity that cannot be linked to the trading wallet unless the user opts to
   verify a wallet. Same passkey, same handle on every device; the backend authenticates the identity, not the wallet.
4. **Vaulted imports** (Mera secret vaults). An imported private key or a recovery phrase is wrapped in a vault under
   the passkey and kept in Supabase (untrusted); a fresh device restores it with one ceremony. This is the "wrap
   existing credentials" starting point, kept optional and explicit.

Further ideas that fit the product and are worth a demo if time allows: per-conversation keys for encrypted trader
DMs and copy-trading group chats; a passkey-encrypted trade journal or assistant memory (the strategy runner's notes
and an AI review of a position, readable by no one else); a "sealed Moment" whose media unlocks for holders via keys
derived from their passkeys; short-lived per-strategy capabilities (a runner key that can only place hedges for one
strategy) once EIP-7702 session keys land on Monad.

The submission story: one passkey, three lives — a wallet that signs, a Perpl capability that trades, a social identity
that speaks — plus state that follows the user to any device and is readable by no server. The live test: clear the
app on one phone, open a second device, one Face ID, and the wallet, the trading session, the handle and the running
strategies are all back.

## 8. Judging criteria, mapped

- Time-to-first-transaction: 2 taps + Face ID, gas dripped, swap confirmed in the activity log.
- Session design: scoped, capped, timed sessions with visible expiry and explicit re-prompt classes.
- Stateless test: no secret on disk; address from the passkey, state from Supabase, secrets from a vault.
- Composability (bonus): gas drip now, 7702 + paymaster + session keys next; Privy remains the alternative on-ramp.
- Bounty two: two PRF salts per ceremony, HKDF purposes under the utility salt, vaults for wrapped secrets, nothing on disk; cross-device test = same trading key, same state, same handle on a second device.

## 9. Needed from the owner

- Apple Team ID (for the AASA file) and hosting access for dyorhq.fun (it is parked at Hostinger today).
- rpId decision (`dyorhq.fun` recommended) and testnet vs mainnet for the demo.
- The bounty deadline and whether the submission goes through the Metropolis hackathon portal.
- A small MON float for the gas drip and the limits you are comfortable with.
