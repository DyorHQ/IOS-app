// Writes xstocks.ts from xstocks.json, the list of xStocks (tokenized stocks) oneinch-proxy may quote against USDC on
// Monad (chain 143). The JSON is the one place the list is edited; the app's own list is XStocks.curated in
// ios/DyorKit/Sources/DyorKit/Chain/Monad.swift, and the two must name the same tokens. The Edge Function bundles the
// generated module rather than importing JSON, as history_scans.ts does, so nothing depends on how the bundler handles
// JSON modules; xstocks_test.ts fails when the two differ.
//
//   deno run --allow-read --allow-write supabase/functions/_shared/gen_xstocks.ts
const here = new URL(".", import.meta.url);

export function generatedModule(json: string): string {
  const value = JSON.parse(json);
  return [
    "// GENERATED — do not edit. Source: supabase/functions/_shared/xstocks.json.",
    "// Regenerate: deno run --allow-read --allow-write supabase/functions/_shared/gen_xstocks.ts",
    `export const XSTOCKS: unknown = ${JSON.stringify(value, null, 2)};`,
    "",
  ].join("\n");
}

if (import.meta.main) {
  const json = await Deno.readTextFile(new URL("xstocks.json", here));
  await Deno.writeTextFile(new URL("xstocks.ts", here), generatedModule(json));
  console.log("wrote supabase/functions/_shared/xstocks.ts");
}
