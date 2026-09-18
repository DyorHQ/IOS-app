# Deploying the DyorHQ launchpad to Monad mainnet

Nothing here is deployed yet. The wallet that runs `Deploy` becomes the owner of the
factory, which controls every policy knob (fees, launch templates, approved pairing
assets, whitelist, takeovers, the stuck-launch valve). Keep that key in a hardware
wallet or a multisig-controlled signer.

## Prerequisites

- Foundry 1.7+ (`forge --version`), submodules checked out: `git submodule update --init --recursive`
- Every contract fits the 24 KB EIP-170 limit (`forge build --sizes`), so no size overrides are needed
  even though Monad allows 128 KB.
- MON on Monad mainnet (chain id 143) for gas. Monad charges gas by the **limit** you set,
  not by what is used, so keep `--gas-estimate-multiplier` modest.
- `forge test` green from `contracts/`.

## Dry run

```bash
cd contracts
forge script script/Deploy.s.sol:Deploy --rpc-url monad
```

This simulates every transaction, mines the hook salt, and prints the addresses the
real run will produce (CREATE2 makes the hook address deterministic for a given salt).

## Deploy

```bash
cd contracts
export PROTOCOL_FEE_RECIPIENT=0x...      # TREASURY: launch fees + the protocol share of curve fees (defaults to the deployer)
export FEES=0x...                        # Monday LP swap-fee recipient (MondayFeeVault); must differ from owner and treasury
export LAUNCH_FEE_WEI=5000000000000000000 # 5 MON per launch (the script's default is 1 MON)
export MON_USD_E8=...                    # live MON price × 1e8 (sets MON's phantom reserve from LAUNCH_FDV_USD, default $2,000)
export ABIL_USD_E8=...                   # live aBIL price × 1e8 (Monday aBIL/USDC 0.3% pool 0xb8700E0D0Df2B0b09A1374FbCdCC85E2E14F7898)
forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc3.monad.xyz --sender $OWNER            # dry run first
forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc3.monad.xyz --broadcast --private-key $OWNER_KEY
```

The dry run needs no key: it simulates every transaction from `--sender`, prints the addresses the real run will
produce, the gas total, and writes `deployments/143.json` — restore that file (`git checkout -- deployments/143.json`)
if you are not broadcasting right away. Ignore forge's "above the contract size limit (… > 24576)" lint at the
end: Monad's limit is 128 KB and `foundry.toml` sets `code_size_limit` accordingly.

The script deploys, in order: `LaunchpadFactory`, `FeeEscrow`, `HolderFeeSharing`, `LaunchLocker`, the
`MemeHook` at a mined CREATE2 address, `GraduationExecutor`, `LaunchAndBuyRouter`, `LaunchDeployer` (which
creates its `CurveDeployer`), then wires them with `setModules`, adds launch config 0 and approves MON as a
pairing asset. About 24 M gas in total; Monad charges the gas **limit**, so budget roughly 5 MON at 200 gwei.

Addresses are written to `contracts/deployments/143.json` (commit it). Then, from the repo root:

```bash
npm run sync:deployment                       # app/lib/deployment.json + the iOS constant (LaunchpadAddresses.monadMainnet)
python3 scripts/dev/check-launchpad-addresses.py   # every copy agrees with contracts/deployments/143.json
```

Then rebuild both apps (`vinext deploy` for the web; `xcodegen generate` + an archive for iOS) and retire the previous
factory (`setWhitelistEnabled(true)`, `setLaunchConfigEnabled(0, false)`) so nothing new launches on it.

## Verify on Monadscan

Monadscan uses the Etherscan v2 API (chain id 143). With an Etherscan API key:

```bash
forge verify-contract --chain 143 --verifier etherscan --etherscan-api-key $ETHERSCAN_KEY \
  --constructor-args $(cast abi-encode "constructor(address,address,uint256,uint16,uint16)" 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e $PROTOCOL_FEE_RECIPIENT 1000000000000000000 5000 1000) \
  $FACTORY src/LaunchpadFactory.sol:LaunchpadFactory
```

Repeat for the other contracts (constructor arguments are in `broadcast/Deploy.s.sol/143/run-latest.json`), or
add `--verify --verifier etherscan --etherscan-api-key $ETHERSCAN_KEY` to the deploy command to verify as you go.

Other knobs (all optional): `PROTOCOL_FEE_SHARE_BPS` (5000 = half of the 1% base fee),
`MAX_CREATOR_TAX_BPS` (1000 = creators may add up to 10%), `SUPPLY`, `CURVE_FEE_BPS`,
`POOL_FEE_BPS`, `TICK_SPACING`, `POOL_MANAGER`.

## Add a custom pairing asset (tokenized stock, stablecoin)

```bash
FACTORY=0x... PAIR_TOKEN=0x... PHANTOM_QUOTE=1000000000 GRADUATION_THRESHOLD=4000000000 \
forge script script/AddPairToken.s.sol:AddPairToken --rpc-url monad --broadcast --private-key $OWNER_KEY
```

Amounts are in the pairing token's own units (the example is 1,000 / 4,000 of a 6-decimal token).

## Rehearse on a local fork first (optional, recommended)

```bash
anvil --fork-url https://rpc.monad.xyz --chain-id 143          # terminal 1
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil's first key
cd .. && node scripts/dev/seed-fork.mjs contracts/deployments/143.json              # launches, buys, graduates
```

Delete `contracts/deployments/143.json` afterwards so the fork addresses are never mistaken for mainnet ones.

## After deployment

- `factory.setWhitelistEnabled(true)` plus `setWhitelisted([...], true)` if launches should start
  closed, as Pons currently runs.
- `factory.transferOwnership(multisig)` then `acceptOwnership()` from the multisig once you are done configuring.
- The hook, locker, escrow and holder-fee-sharing contracts are fixed for life once the first token
  launches; the graduation executor and router can still be swapped.
