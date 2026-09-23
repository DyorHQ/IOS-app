import vinext from "vinext";
import { defineConfig, loadEnv } from "vite";
import hostingConfig from "./.openai/hosting.json";
import { sites } from "./build/sites-vite-plugin";

const SITE_CREATOR_PLACEHOLDER_DATABASE_ID =
  "00000000-0000-4000-8000-000000000000";

const { d1, r2 } = hostingConfig;

// macOS Seatbelt blocks FSEvents, so Codex previews need polling for HMR.
const isCodexSeatbeltSandbox = process.env.CODEX_SANDBOX === "seatbelt";

// vinext inlines every NEXT_PUBLIC_ value into the browser bundle, so a production build refuses to run with a private
// key in one: NEXT_PUBLIC_DEV_WALLET_KEY (the local-fork dev wallet, for `vinext dev` only) or any NEXT_PUBLIC_ value
// shaped like a 32-byte key. Only variable names are reported.
function refusePublicPrivateKeys(mode: string) {
  const offending = Object.entries(loadEnv(mode, process.cwd(), "NEXT_PUBLIC_"))
    .filter(([name, value]) => value.trim() !== "" && (name === "NEXT_PUBLIC_DEV_WALLET_KEY" || /^(0x)?[0-9a-fA-F]{64}$/.test(value.trim())))
    .map(([name]) => name);
  if (offending.length > 0) {
    throw new Error(`Refusing a production build: ${offending.join(", ")} would ship a private key in the browser bundle. Unset it; the dev wallet is for \`vinext dev\` against a local fork only.`);
  }
}

const localBindingConfig = {
  main: "./worker/index.ts",
  compatibility_flags: ["nodejs_compat"],
  d1_databases: d1
    ? [
        {
          binding: d1,
          database_name: "site-creator-d1",
          database_id: SITE_CREATOR_PLACEHOLDER_DATABASE_ID,
        },
      ]
    : [],
  r2_buckets: r2
    ? [
        {
          binding: r2,
          bucket_name: "site-creator-r2",
        },
      ]
    : [],
};

export default defineConfig(async ({ command, mode }) => {
  if (command === "build") refusePublicPrivateKeys(mode);

  // Keep Wrangler and Miniflare state project-local. These are non-secret tool
  // settings; application environment belongs in ignored `.env*` files.
  process.env.WRANGLER_WRITE_LOGS ??= "false";
  process.env.WRANGLER_LOG_PATH ??= ".wrangler/logs";
  process.env.MINIFLARE_REGISTRY_PATH ??= ".wrangler/registry";

  // Wrangler snapshots its log path while the Cloudflare plugin is imported.
  const { cloudflare } = await import("@cloudflare/vite-plugin");

  return {
    server: isCodexSeatbeltSandbox
      ? { watch: { useFsEvents: false, usePolling: true } }
      : undefined,
    plugins: [
      vinext(),
      sites(),
      cloudflare({
        viteEnvironment: { name: "rsc", childEnvironments: ["ssr"] },
        config: localBindingConfig,
      }),
    ],
  };
});
