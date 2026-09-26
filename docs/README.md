# docs

Internal documents do not live in this repository. Audit reports and checklists, security reviews, runbooks and owner
procedures, handoffs, relaunch notes, plans, product specs and decision logs are in **DyorHQ/internal (private)**,
under `ios-app/`. Write new ones there too. `.leakguard` rejects them here: `scripts/dev/forbidden-paths.sh` runs from
the git hooks (`scripts/dev/install-hooks.sh`) and the leak-guard workflow.

Developer docs kept here:

- [`app-wiring.md`](app-wiring.md): what every web screen reads and writes.
- [`swap-spec.md`](swap-spec.md): spot trading across the Monad venues.

Documents that code comments still cite by name, and where they are now:

| Cited as | DyorHQ/internal (private) |
|---|---|
| `MERA-PLAN §n` | `ios-app/ios/docs/mera/MERA-PLAN.md` |
| `docs/moments-mainnet-runbook.md` | `ios-app/docs/moments-mainnet-runbook.md` |
| `docs/moments-analysis/economics.py` | `ios-app/docs/moments-analysis/economics.py` |
| `contracts/CHANGELOG-v2.md` | `ios-app/contracts/CHANGELOG-v2.md` |
| `docs/env-setup.md` | `ios-app/docs/env-setup.md` |
| `contracts/keepers/README.md` (operating notes) | `ios-app/contracts/keepers/README.md` |
| `contracts/script/README.md` (deploy procedure) | `ios-app/contracts/script/README.md` |
