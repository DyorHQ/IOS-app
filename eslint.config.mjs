import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  // Override default ignores of eslint-config-next.
  globalIgnores([
    // Default ignores of eslint-config-next:
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    // The Expo app is its own repository with its own lint setup.
    "mainstreet-app/**",
    // Foundry project: Solidity plus vendored JS test helpers inside git submodules.
    "contracts/**",
  ]),
]);

export default eslintConfig;
