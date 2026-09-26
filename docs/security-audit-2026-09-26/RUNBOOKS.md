# Owner runbooks — security audit 2026-09-26

These are the audit items that code cannot fix, because they need a DyorHQ owner's keys, accounts or dashboards
(REPORT.md §3). Every address below is copied from `contracts/deployments/*.json` or `docs/relaunch-2026-09-23.md`.
Check each `cast call` result before you send anything.

```bash
export RPC=https://rpc.monad.xyz   # chain 143
export OLD_OWNER=0xCf7A9f1DE835a691f969B76e6eb4842BFaA7Fe10   # owner / governance of every stack below
```

---

## 1. Move contract ownership off the plaintext key (SEC-1, MO-8, LP-6) — High

The owner/governance key is kept in plaintext in a `.env` file and passed on the command line. Move every owner role
to a new owner `NEW` that never touches a plaintext file: a hardware wallet, or a multisig Safe with hardware-wallet
signers. First check at https://app.safe.global that Safe is deployed on Monad (chain 143) before you pick it.

**0. Stop using the plaintext key.** Import it once into an encrypted keystore, then delete it from `.env` and from
your shell history:
```bash
cast wallet import dyorhq-old-owner --interactive     # paste the key, set a password
cast wallet address --account dyorhq-old-owner        # must print $OLD_OWNER
```

**1. Pick `NEW`**, and confirm you can sign with it (`cast wallet address --ledger`, or the Safe address).

**2. Start the two-step transfer on every contract.** The pending transfer can be overwritten until it is accepted,
so a typo is recoverable.

| Contract | Address | Start | Accept (signed by NEW) | Check |
|---|---|---|---|---|
| Launchpad factory (live) | `0x6B1C8769a8d6745955aC35b91FF1F37AB76859dB` | `transferOwnership(address)` | `acceptOwnership()` | `owner()(address)` |
| Monday fee vault (live) | `0xfEEDF827c421f3a300630e680a367A42A1a26d50` | `transferOwnership(address)` | `acceptOwnership()` | `owner()(address)` |
| Moments factory cohort 3 (live) | `0x0FD4aC52bbf387DBB3156805769bFC0c260F7E26` | `transferGovernance(address)` | `acceptGovernance()` | `governance()(address)` |
| Launchpad factory (retired) | `0x10F34A174d9C393a90aFf94BDED7E1Db185446D7` | `transferOwnership(address)` | `acceptOwnership()` | `owner()(address)` |
| Launchpad factory (retired) | `0x2F02972E166dE71097EEAC8303cE7Fe6B6Ebe9f4` | same | same | same |
| Launchpad factory (retired) | `0xad3d3Cb821279E52cFD499D15b26f77976eBA1Ea` | same | same | same |
| Monday fee vault (retired 0x10F3 stack) | `0x42a1C1c1d6BC2544d3f478E4d42F5b5ec75888De` | `transferOwnership(address)` | `acceptOwnership()` | `owner()(address)` |
| Moments factory cohort 2 (retired) | `0xc12B6b6948185cef75F861c5327702c30CB8a581` | `transferGovernance(address)` | `acceptGovernance()` | `governance()(address)` |
| Moments factory cohort 1 (retired) | `0x64698c7702d85F87f43a6dFF7D495CDD2327C020` | same | same | same |
| Moments factory v1 (retired) | `0x47D989a54232D3bCdB7A7760D10E596647D986BA` | same | same | same |

Retired contracts still have owner functions (fee recipients, pause, links), so move them too. Before you send
anything to a row, read its current owner. Skip any row whose owner is not `$OLD_OWNER`, and any row whose function
does not exist. Check `docs/relaunch-2026-09-23.md` for the other retired Monday fee vaults and add them.
```bash
C=0x6B1C8769a8d6745955aC35b91FF1F37AB76859dB
cast call $C "owner()(address)" --rpc-url $RPC                      # must be $OLD_OWNER
cast send $C "transferOwnership(address)" $NEW --account dyorhq-old-owner --rpc-url $RPC
cast call $C "pendingOwner()(address)" --rpc-url $RPC               # must be $NEW
cast send $C "acceptOwnership()" --ledger --rpc-url $RPC            # or propose it in the Safe
cast call $C "owner()(address)" --rpc-url $RPC                      # must be $NEW
```
For Moments, use `transferGovernance` / `pendingGovernance()` / `acceptGovernance()` / `governance()`.

**3. When every row reads `NEW`:**
- Delete the keystore (`~/.foundry/keystores/dyorhq-old-owner`).
- Never fund `$OLD_OWNER` again.
- Update the `owner` / `governance` fields in `contracts/deployments/*.json` and the docs' contract registry.
- From now on, run scripts with `--ledger` or `--account`, never `--private-key` or `PRIVATE_KEY=`.

---

## 2. Escrow the email pepper key (OH-1) — High

Every v2 Email & Password wallet depends on `email_pepper_key` in Supabase Vault. If it is lost, those wallets
cannot be re-derived: only users who exported their key in-app keep access.

1. In the Supabase SQL editor, which runs as `postgres`:
   `select decrypted_secret from vault.decrypted_secrets where name = 'email_pepper_key';`
   Do not paste the value into chat, tickets or files. Copy it straight into step 2.
2. Make **two** offline, encrypted backups, and store them in separate places. For example:
   - an `age`- or GPG-encrypted file on two hardware-encrypted USB drives; or
   - a paper copy in each of two safes.
   Record who can access each copy.
3. **Check a backup restores the right key.** Migration 20 stores
   `HMAC-SHA256(key, "dyorhq/email-pepper/kcv")` in `public.email_pepper_key_check`. For a restored key `K` (hex):
   ```sql
   select exists (select 1 from public.email_pepper_key_check
     where kcv = encode(extensions.hmac(convert_to('dyorhq/email-pepper/kcv','UTF8'), decode('<K>','hex'), 'sha256'), 'hex'));
   ```
   It must return `true`. Run this in the SQL editor, not in any client app.
4. Write down the recovery and shutdown plan: who can restore the key, and how users are told to export their key
   if the service winds down.

---

## 3. Rotate the Aurora API key (SEC-3) and retire old builds (GP-2)

Builds up to 10 shipped the Aurora key in `Info.plist`. Since `92666a7`, only the `aurora-proxy` Edge Function
holds it.
1. In the Aurora dashboard, create a new key.
2. `supabase secrets set AURORA_API_KEY=<new>`, then `supabase functions deploy aurora-proxy`.
3. Bridge a small amount in the app to check it works, then **revoke the old key** in Aurora.
4. In App Store Connect → TestFlight, expire builds ≤ 12. If older App Store versions are live, use a minimum-version
   gate or a force-update prompt.

---

## 4. Sweep the leaked treasury wallet (SEC-7)

`0x5282cC04f2F17Cc296C5aEFa2576C4C0327cf045` is compromised. Follow `docs/relaunch-2026-09-23.md` → "Owner
follow-ups" §1:
- Read the balance right before signing.
- Send it, minus gas, to the new treasury `0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371`.
- Never fund `0x5282…` again.

Someone else may hold the key, so do it quickly and check the result on Monadscan.

---

## 5. Protect the passkey domain accounts.dyorhq.fun (SEC-2, IOSK-5, SEC-9) — High impact

Whoever can change what `accounts.dyorhq.fun` serves can run the WebAuthn ceremony for every Mera passkey wallet.
The site is the `DyorHQ/accounts-domain` repo on GitHub Pages.
1. **GitHub org → Settings → Pages → Verified domains:** add `dyorhq.fun`. This adds a DNS TXT record. Once verified,
   no other account can publish Pages on `*.dyorhq.fun`.
2. **Repo → Settings → Rules → New branch ruleset** on `main`:
   - require a pull request with at least 1 approval;
   - block force pushes;
   - restrict deletions;
   - add CODEOWNERS review if there is more than one maintainer.
3. **Org → Settings → Authentication security:** require two-factor authentication. Review who has write or admin
   access to the repo.
4. **Registrar:** turn on the transfer lock and registrar-level 2FA for `dyorhq.fun`, and restrict who can change DNS.
5. **Monitor** once a day (from a machine that can reach both hosts). Alert if either response differs from
   `accounts-domain/.well-known/apple-app-site-association`:
   ```bash
   curl -s https://accounts.dyorhq.fun/.well-known/apple-app-site-association
   curl -s https://app-site-association.cdn-apple.com/a/v1/accounts.dyorhq.fun   # what iOS actually uses (SEC-9)
   ```
6. Keep the repo limited to the AASA file, `CNAME` and `.nojekyll`. Do not add pages or scripts.

---

## 6. Sign app sessions with a dedicated key (OH-7)

`wallet-auth` mints app sessions with `APP_JWT_SECRET`. Move to Supabase's asymmetric JWT signing keys, so the
session key is separate from the project secret and can be rotated on its own. In the dashboard, go to
Project Settings → JWT Keys, create a key, and switch `wallet-auth` to sign with it. That code change will come as a
follow-up PR after the batch-1 backend changes land.

---

## 7. Deploy the fixes (merging does not deploy)

Supabase (project `fmnjqrguvopusfufmirs`):
```bash
supabase db push                       # applies pending migrations (23+), as postgres
supabase functions deploy wallet-auth email-rebind delete-account pin-media
```
- After `db push`, run each new migration's "Verify after apply" queries.
- Web app and worker: `npm run build`, then deploy with your usual wrangler command.
- Website: redeploy the Replit static site, which now publishes `public/`. Then check that `/terms/`, `/privacy/`
  and `/.well-known/security.txt` load.

---

## 8. Publish the legal pages (LR-1, LR-2)

The website branch adds `/privacy/` and `/terms/` as **drafts**.
1. Fill in every `[bracketed]` item: legal entity, address, restricted jurisdictions, retention, liability,
   governing law.
2. Have counsel review both pages.
3. Remove the "Draft for legal review" notice, then publish.
4. Add the privacy URL to App Store Connect.
