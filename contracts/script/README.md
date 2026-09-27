# Deploy scripts

Foundry scripts for the Launchpad and Moments contracts on Monad (chain 143). A dry run needs no key:

```bash
cd contracts
forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc3.monad.xyz --sender <owner address>
```

Deploying signs as the contract owner, so it follows the owner procedure in DyorHQ/internal (private):
`ios-app/contracts/script/README.md`. Sign with a hardware wallet or a Foundry keystore (`--ledger`, `--account`),
never with a private key on the command line or in an env file.
