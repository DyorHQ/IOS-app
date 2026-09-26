# Rules for every session in this repository

- **Never commit a secret.** No env files, private keys, seed phrases, API keys or tokens, keyed RPC URLs or signing
  material. Values live in git-ignored files, a password manager or the platform's secret store.
- **Never print a secret value.** Do not cat, grep, echo or diff env files, `Secrets.xcconfig` or key files. For
  variable names only: `scripts/dev/env-names.sh <file>`. Tools that need a value read it themselves.
- **Internal documents never go in this repository.** Audit reports and checklists, security reviews, runbooks and owner
  procedures, handoffs, incident and relaunch notes, plans and decision logs go to the private repository
  **DyorHQ/internal**, under `ios-app/`. `docs/` holds developer docs only.
- **The leak guard must pass.** `scripts/dev/install-hooks.sh` turns on the git hooks (the SessionStart hook runs it);
  the `leak-guard` workflow re-checks every push. Never use `--no-verify`. A false positive is fixed in `.leakguard` or
  `.gitleaks.toml` with a reason, never by bypassing the check.
- **Public repositories** (website, docs, accounts-domain): push only when their leak guard passes, and never describe
  open vulnerabilities, incidents or key history in them.
