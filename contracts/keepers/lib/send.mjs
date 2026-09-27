// Transactions go out ONLY through Foundry's `cast send`, with a keystore, a named Foundry account, or a Ledger.
// This module never sees key material: it refuses raw private keys (flags and environment variables alike) and
// by default (dry run) only prints the exact `cast` command it would run. The RPC URL reaches cast through its
// ETH_RPC_URL environment variable, never argv: a keyed URL would otherwise show in `ps` and in every printed command.
import { spawnSync } from "node:child_process";

const FORBIDDEN_ENV = ["PRIVATE_KEY", "KEEPER_PRIVATE_KEY", "ETH_PRIVATE_KEY", "DEPLOYER_PRIVATE_KEY"];

/**
 * Signer config from CLI options (never from a key):
 *   { keystore: "/path/to/keystore.json", passwordFile?: "/path" }   -> --keystore [--password-file]
 *   { account: "keeper" }                                          -> --account (a ~/.foundry/keystores entry)
 *   { ledger: true, hdPath?: "m/44'/60'/0'/0/0" }                  -> --ledger [--mnemonic-derivation-path]
 *   { unlocked: "0x..." }  (local anvil ONLY; requires allowUnlocked) -> --unlocked --from
 */
export function signerArgs(signer = {}, { allowUnlocked = false } = {}) {
  for (const k of Object.keys(signer)) {
    if (/private/i.test(k) || /mnemonic$/i.test(k)) throw new Error(`refusing signer option "${k}": raw keys are never accepted`);
  }
  if (signer.keystore) return ["--keystore", signer.keystore, ...(signer.passwordFile ? ["--password-file", signer.passwordFile] : [])];
  if (signer.account) return ["--account", signer.account, ...(signer.passwordFile ? ["--password-file", signer.passwordFile] : [])];
  if (signer.ledger) return ["--ledger", ...(signer.hdPath ? ["--mnemonic-derivation-path", signer.hdPath] : [])];
  if (signer.unlocked) {
    if (!allowUnlocked) throw new Error("--unlocked is for a local anvil only; pass --allow-unlocked to confirm");
    return ["--unlocked", "--from", signer.unlocked];
  }
  throw new Error("sending needs a signer: --keystore <file> | --account <name> | --ledger");
}

export function assertNoKeyEnv(env = process.env) {
  const hit = FORBIDDEN_ENV.filter((k) => env[k]);
  if (hit.length) throw new Error(`refusing to run with ${hit.join(", ")} set: unset it; the keepers sign only via keystore/Ledger`);
}

/** The exact `cast send` argv for one call. `args` are already-stringified Solidity arguments. The RPC URL is not in
    it: `castEnv` hands it to cast as ETH_RPC_URL. */
export function castSendArgv({ to, signature, args = [], gasLimit, signer, allowUnlocked }) {
  const argv = ["send", to, signature, ...args.map(String)];
  if (gasLimit) argv.push("--gas-limit", String(gasLimit));
  argv.push(...signerArgs(signer, { allowUnlocked }));
  return argv;
}

/** The environment cast runs with: the caller's, plus the RPC URL as ETH_RPC_URL. */
export function castEnv(rpcUrl, env = process.env) {
  return { ...env, ETH_RPC_URL: rpcUrl };
}

function quote(a) {
  return /^[\w@%+=:,./-]+$/.test(a) ? a : `'${a.replace(/'/g, `'\\''`)}'`;
}

/**
 * A sender bound to one run. In dry-run mode (the default) it records and prints the commands; with
 * `send: true` it executes them with cast (inheriting stdin, so a keystore password prompt or Ledger
 * confirmation works interactively), stopping at the first failure.
 */
export function makeSender({ send = false, rpcUrl, signer, allowUnlocked = false, castBin = process.env.CAST_BIN || "cast", log = console.log, spawn = spawnSync }) {
  if (send) {
    assertNoKeyEnv();
    signerArgs(signer, { allowUnlocked }); // validate once, up front
  }
  const sent = [];
  return {
    sent,
    async call({ to, signature, args = [], gasLimit, label }) {
      const argv = send
        ? castSendArgv({ to, signature, args, gasLimit, signer, allowUnlocked })
        : ["send", to, signature, ...args.map(String), ...(gasLimit ? ["--gas-limit", String(gasLimit)] : []), "<signer>"];
      const printable = `ETH_RPC_URL=<rpc> ${[castBin, ...argv].map(quote).join(" ")}`;
      if (!send) {
        log(`[dry-run] ${label ?? signature}: ${printable}`);
        sent.push({ dryRun: true, argv });
        return { dryRun: true };
      }
      log(`[send] ${label ?? signature}: ${printable}`);
      const r = spawn(castBin, argv, { stdio: ["inherit", "pipe", "pipe"], encoding: "utf8", env: castEnv(rpcUrl) });
      const ok = r.status === 0;
      sent.push({ dryRun: false, argv, ok, stdout: r.stdout, stderr: r.stderr });
      if (!ok) throw new Error(`cast send failed (${r.status}): ${(r.stderr || "").trim()}`);
      return { dryRun: false, stdout: r.stdout };
    },
  };
}
