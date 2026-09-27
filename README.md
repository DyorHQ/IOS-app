# DyorHQ

DyorHQ is a self-custodial iPhone app on Monad: spot swaps, Perpl perps, the Launchpad, Moments, and bridging. This
repository holds the app and everything it depends on. There is no web app.

| Path | What it is |
|---|---|
| `ios/` | The SwiftUI app (`DyorHQ`, generated with XcodeGen from `ios/project.yml`) and the `DyorKit` Swift package. Start with `ios/README.md`. |
| `supabase/` | The backend: migrations, Edge Functions and their tests. See `supabase/README.md`. |
| `contracts/` | The Foundry contracts (Launchpad, Moments), deployment records and keepers. |
| `brand/` | The brand guide and identity assets. |
| `scripts/dev/` | Developer tools: the leak guard, fork helpers, the launchpad address check. |

## Build and test

```bash
cd ios && xcodegen generate
cd ios/DyorKit && swift test
```

```bash
cd contracts && forge test --offline --code-size-limit 100000000
```

```bash
npm install
npm test
npm run keepers:test
```

## Security

Never commit secrets or internal documents. The leak guard (`scripts/dev/install-hooks.sh`, CI `leak-guard`) enforces
this; see `CLAUDE.md`. Audit reports, runbooks and handoffs live in the private repository DyorHQ/internal. Report
vulnerabilities to team@dyorhq.fun.
