/* Perpl's mainnet perpetual markets the app offers (ids are per network; docs.perpl.xyz). A plain module with no
   client or chain code, so the server-side Perpl proxy can check market ids against it. */

export const PERP_MARKETS = [
  { id: 1, symbol: "BTC", name: "Bitcoin" },
  { id: 10, symbol: "MON", name: "Monad" },
  { id: 20, symbol: "ETH", name: "Ether" },
  { id: 31, symbol: "SOL", name: "Solana" },
  { id: 40, symbol: "HYPE", name: "Hyperliquid" },
  { id: 50, symbol: "ZEC", name: "Zcash" },
] as const;
export type PerpMarket = (typeof PERP_MARKETS)[number];
