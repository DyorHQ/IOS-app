import { erc20Abi, type Address, type Hex } from "viem";
import { publicClient } from "../chain";
import { describeError } from "../errors";
import { waitFor } from "../use-tx";
import type { Wallet } from "../wallet";
import { perplExchangeAbi } from "./abi";

/* Perpl: the fully on-chain perpetuals order book on Monad (https://docs.perpl.xyz). Positions, orders and
   collateral live in the Exchange contract; market data streams from Perpl's public WebSocket. Everything the
   user signs goes straight to the contract (no API keys). Addresses from docs.perpl.xyz/resources/for-developers/
   networks-and-configuration; ABI from github.com/PerplFoundation/dex-sdk. */

export const PERPL = {
  exchange: "0x34B6552d57a35a1D042CcAe1951BD1C370112a6F" as Address,
  collateral: "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a" as Address, // AUSD, 6 decimals
  collateralDecimals: 6,
  /** Browser origin is rejected by Perpl, so the app bridges through its own Worker (see worker/index.ts). */
  ws: "/api/perpl/ws",
  minDeposit: 10_000_000n, // 10 AUSD
} as const;

export const PERP_MARKETS = [
  { id: 1, symbol: "BTC", name: "Bitcoin", tv: "BINANCE:BTCUSDT.P" },
  { id: 10, symbol: "MON", name: "Monad", tv: "BINANCE:MONUSDT.P" },
  { id: 20, symbol: "ETH", name: "Ether", tv: "BINANCE:ETHUSDT.P" },
  { id: 31, symbol: "SOL", name: "Solana", tv: "BINANCE:SOLUSDT.P" },
  { id: 40, symbol: "HYPE", name: "Hyperliquid", tv: "BINANCE:HYPEUSDT.P" },
  { id: 50, symbol: "ZEC", name: "Zcash", tv: "BINANCE:ZECUSDT.P" },
] as const;
export type PerpMarket = (typeof PERP_MARKETS)[number];

/** OrderDesc.orderType as the SDK encodes it (RequestType as u8). */
export const ORDER_TYPE = { OpenLong: 0, OpenShort: 1, CloseLong: 2, CloseShort: 3, Cancel: 4, IncreasePositionCollateral: 5, Change: 6 } as const;
const MAX_NEG_PNL_COLLAT_BPS = 300n; // Perpl's default for new orders (context.order_max_neg_pnl_collat_bps)

const exchange = { address: PERPL.exchange, abi: perplExchangeAbi } as const;

export type PerpInfo = {
  id: number;
  symbol: string;
  priceDecimals: number;
  lotDecimals: number;
  basePricePNS: bigint;
  mark: number;
  last: number;
  oracle: number;
  markTimestamp: number;
  longOI: number;
  shortOI: number;
  fundingRatePct100k: number;
  status: number;
  initMarginFrac: number; // fraction of notional
  maintMarginFrac: number; // fraction of notional
  numOrders: number;
};
export type PerpAccount = { accountId: number; balance: bigint; locked: bigint; frozen: boolean; positionPerps: number[] };
export type PerpPosition = {
  perpId: number;
  symbol: string;
  side: "long" | "short";
  size: number;
  entry: number;
  mark: number;
  margin: number; // AUSD
  unrealized: number; // AUSD, mark-to-market
  premium: number; // AUSD, funding and settlement premium carried on the position
  leverage: number;
  liquidation: number | null;
  notional: number;
};
export type PerpOrder = { perpId: number; symbol: string; orderId: number; type: number; side: "buy" | "sell"; price: number; size: number; leverage: number; expiryBlock: number; reduceOnly: boolean };

const scale = (v: bigint, decimals: number) => Number(v) / 10 ** decimals;
export const fromCNS = (v: bigint) => Number(v) / 10 ** PERPL.collateralDecimals;
export const toCNS = (v: number) => BigInt(Math.round(v * 10 ** PERPL.collateralDecimals));

export async function fetchPerps(ids: readonly number[] = PERP_MARKETS.map((m) => m.id)): Promise<PerpInfo[]> {
  const [infos, margins] = await Promise.all([
    publicClient.multicall({ contracts: ids.map((id) => ({ ...exchange, functionName: "getPerpetualInfo", args: [BigInt(id)] }) as const), allowFailure: true }),
    publicClient.multicall({ contracts: ids.map((id) => ({ ...exchange, functionName: "getMarginFractions", args: [BigInt(id), 0n] }) as const), allowFailure: true }),
  ]);
  const out: PerpInfo[] = [];
  ids.forEach((id, i) => {
    const r = infos[i];
    if (r.status !== "success") return;
    const p = r.result;
    const pd = Number(p.priceDecimals);
    const m = margins[i].status === "success" ? margins[i].result : null;
    out.push({
      id,
      symbol: p.symbol,
      priceDecimals: pd,
      lotDecimals: Number(p.lotDecimals),
      basePricePNS: p.basePricePNS,
      mark: scale(p.markPNS, pd),
      last: scale(p.lastPNS, pd),
      oracle: scale(p.oraclePNS, pd),
      markTimestamp: Number(p.markTimestamp),
      longOI: scale(p.longOpenInterestLNS, Number(p.lotDecimals)),
      shortOI: scale(p.shortOpenInterestLNS, Number(p.lotDecimals)),
      fundingRatePct100k: Number(p.fundingRatePct100k),
      status: Number(p.status),
      // Margin requirement = notional / (value / 100): MON's 1000 / 2000 mean 10% initial and 5% maintenance.
      initMarginFrac: m && m[0] > 0n ? 100 / Number(m[0]) : 0.1,
      maintMarginFrac: m && m[1] > 0n ? 100 / Number(m[1]) : 0.05,
      numOrders: Number(p.numOrders),
    });
  });
  return out;
}

/** Perpetual ids that the account's position bitmap marks as open (bank1 bit i → perp i, later banks offset). */
function perpsWithPositions(bitmap: { bank1: bigint; bank2: bigint; bank3: bigint; bank4: bigint }): number[] {
  const banks: [number, bigint, number][] = [[0, bitmap.bank1, 253], [253, bitmap.bank2, 256], [509, bitmap.bank3, 256], [765, bitmap.bank4, 256]];
  const ids: number[] = [];
  for (const [offset, bank, bits] of banks) for (let i = 0; i < bits; i++) if ((bank >> BigInt(i)) & 1n) ids.push(offset + i);
  return ids;
}

export async function fetchAccount(address: Address): Promise<PerpAccount | null> {
  const info = await publicClient.readContract({ ...exchange, functionName: "getAccountByAddr", args: [address] });
  if (info.accountId === 0n) return null;
  return { accountId: Number(info.accountId), balance: info.balanceCNS, locked: info.lockedBalanceCNS, frozen: info.frozen !== 0, positionPerps: perpsWithPositions(info.positions) };
}

export function liquidationPrice(side: "long" | "short", entry: number, size: number, margin: number, premium: number, maintFrac: number): number | null {
  if (size <= 0) return null;
  const mmr = entry * size * maintFrac;
  const sign = side === "long" ? 1 : -1;
  return Math.max(0, entry + (sign * (mmr - margin - premium)) / size);
}

export async function fetchPositions(account: PerpAccount, perps: PerpInfo[]): Promise<PerpPosition[]> {
  if (account.positionPerps.length === 0) return [];
  const results = await publicClient.multicall({ contracts: account.positionPerps.map((id) => ({ ...exchange, functionName: "getPosition", args: [BigInt(id), BigInt(account.accountId)] }) as const), allowFailure: true });
  const out: PerpPosition[] = [];
  results.forEach((r, i) => {
    if (r.status !== "success") return;
    const [pos, markPNS] = r.result;
    const perp = perps.find((p) => p.id === account.positionPerps[i]);
    if (!perp || pos.lotLNS === 0n) return;
    const size = scale(pos.lotLNS, perp.lotDecimals);
    const entry = scale(pos.pricePNS, perp.priceDecimals);
    const mark = markPNS > 0n ? scale(markPNS, perp.priceDecimals) : perp.mark;
    const side = Number(pos.positionType) === 0 ? "long" : "short";
    const margin = fromCNS(pos.depositCNS);
    const premium = fromCNS(pos.premiumPnlCNS);
    const unrealized = (side === "long" ? mark - entry : entry - mark) * size + premium;
    const notional = size * mark;
    out.push({ perpId: perp.id, symbol: perp.symbol, side, size, entry, mark, margin, unrealized, premium, leverage: margin > 0 ? notional / margin : 0, liquidation: liquidationPrice(side, entry, size, margin, premium, perp.maintMarginFrac), notional });
  });
  return out;
}

/** Open orders of an account: walk the perp's order-id bitmap index, read each order, keep the account's own. */
export async function fetchOpenOrders(account: PerpAccount, perps: PerpInfo[]): Promise<PerpOrder[]> {
  const locks = await publicClient.multicall({ contracts: perps.map((p) => ({ ...exchange, functionName: "getPerpOrderLocks", args: [BigInt(account.accountId), BigInt(p.id)] }) as const), allowFailure: true });
  const active = perps.filter((_, i) => locks[i].status === "success" && (locks[i].result as readonly unknown[]).length > 0);
  const out: PerpOrder[] = [];
  for (const perp of active) {
    const [, leaves] = await publicClient.readContract({ ...exchange, functionName: "getOrderIdIndex", args: [BigInt(perp.id)] });
    const ids: number[] = [];
    leaves.forEach((bitmap, leaf) => {
      for (let bit = leaf === 0 ? 1 : 0; bit < 256; bit++) if ((bitmap >> BigInt(bit)) & 1n) ids.push(leaf * 256 + bit);
    });
    for (let start = 0; start < ids.length; start += 250) {
      const chunk = ids.slice(start, start + 250);
      const orders = await publicClient.multicall({ contracts: chunk.map((id) => ({ ...exchange, functionName: "getOrder", args: [BigInt(perp.id), BigInt(id)] }) as const), allowFailure: true });
      orders.forEach((r, k) => {
        if (r.status !== "success") return;
        const o = r.result;
        if (Number(o.accountId) !== account.accountId) return;
        const type = Number(o.orderType);
        out.push({
          perpId: perp.id,
          symbol: perp.symbol,
          orderId: chunk[k],
          type,
          side: type === ORDER_TYPE.OpenLong || type === ORDER_TYPE.CloseShort ? "buy" : "sell",
          price: scale(perp.basePricePNS + BigInt(o.priceONS), perp.priceDecimals),
          size: scale(BigInt(o.lotLNS), perp.lotDecimals),
          leverage: Number(o.leverageHdths) / 100,
          expiryBlock: Number(o.expiryBlock),
          reduceOnly: type === ORDER_TYPE.CloseLong || type === ORDER_TYPE.CloseShort,
        });
      });
    }
  }
  return out;
}

export async function collateralBalances(address: Address): Promise<{ wallet: bigint; allowance: bigint }> {
  const [wallet, allowance] = await publicClient.multicall({
    contracts: [
      { address: PERPL.collateral, abi: erc20Abi, functionName: "balanceOf", args: [address] },
      { address: PERPL.collateral, abi: erc20Abi, functionName: "allowance", args: [address, PERPL.exchange] },
    ],
    allowFailure: false,
  });
  return { wallet, allowance };
}

/* --------------------------------------------------------------------------------------------- transactions */

type OnSent = (hash: Hex) => void;

async function send<TArgs extends readonly unknown[]>(wallet: Wallet, functionName: "createAccount" | "depositCollateral" | "withdrawCollateral" | "execOrders", args: TArgs, onSent: OnSent): Promise<Hex> {
  // simulateContract is typed per function; a small cast keeps one code path for every write.
  const { request } = await publicClient.simulateContract({ ...exchange, functionName, args, account: wallet.account } as never);
  const hash = await wallet.writeContract(request as never);
  onSent(hash);
  await waitFor(hash);
  return hash;
}

/** Approves AUSD when needed, then opens the account (first deposit) or tops it up. */
export async function deposit(wallet: Wallet, amountCNS: bigint, hasAccount: boolean, onSent: OnSent): Promise<Hex> {
  const owner = wallet.account.address;
  const allowance = await publicClient.readContract({ address: PERPL.collateral, abi: erc20Abi, functionName: "allowance", args: [owner, PERPL.exchange] });
  if (allowance < amountCNS) {
    const { request } = await publicClient.simulateContract({ address: PERPL.collateral, abi: erc20Abi, functionName: "approve", args: [PERPL.exchange, amountCNS], account: wallet.account });
    const hash = await wallet.writeContract(request);
    onSent(hash);
    await waitFor(hash);
  }
  return send(wallet, hasAccount ? "depositCollateral" : "createAccount", [amountCNS] as const, onSent);
}

export const withdraw = (wallet: Wallet, amountCNS: bigint, onSent: OnSent) => send(wallet, "withdrawCollateral", [amountCNS] as const, onSent);

export type OrderInput = {
  perp: PerpInfo;
  side: "long" | "short";
  kind: "market" | "limit";
  size: number; // base units
  price?: number; // limit price; market orders derive it from the mark and slippage
  leverage: number;
  reduceOnly?: boolean;
  slippageBps?: number;
  postOnly?: boolean;
};

let lastDescId = 0n;
const nextDescId = () => {
  const now = BigInt(Date.now());
  lastDescId = now > lastDescId ? now : lastDescId + 1n;
  return lastDescId;
};

export function buildOrderDesc(input: OrderInput) {
  const { perp } = input;
  const reduce = !!input.reduceOnly;
  const orderType = input.side === "long" ? (reduce ? ORDER_TYPE.CloseShort : ORDER_TYPE.OpenLong) : reduce ? ORDER_TYPE.CloseLong : ORDER_TYPE.OpenShort;
  const slip = (input.slippageBps ?? 100) / 10_000;
  const price = input.kind === "limit" && input.price ? input.price : input.side === "long" ? perp.mark * (1 + slip) : perp.mark * (1 - slip);
  return {
    orderDescId: nextDescId(),
    perpId: BigInt(perp.id),
    orderType,
    orderId: 0n,
    pricePNS: BigInt(Math.round(price * 10 ** perp.priceDecimals)),
    lotLNS: BigInt(Math.round(input.size * 10 ** perp.lotDecimals)),
    expiryBlock: 0n,
    postOnly: !!input.postOnly && input.kind === "limit",
    fillOrKill: false,
    immediateOrCancel: input.kind === "market",
    maxMatches: 0n,
    leverageHdths: BigInt(Math.round(input.leverage * 100)),
    lastExecutionBlock: 0n,
    amountCNS: 0n,
    maxNegPnlCollatBPS: MAX_NEG_PNL_COLLAT_BPS,
  };
}

export const placeOrder = (wallet: Wallet, input: OrderInput, onSent: OnSent) => send(wallet, "execOrders", [[buildOrderDesc(input)], true] as const, onSent);

export function cancelOrder(wallet: Wallet, perpId: number, orderId: number, onSent: OnSent) {
  const desc = { orderDescId: nextDescId(), perpId: BigInt(perpId), orderType: ORDER_TYPE.Cancel, orderId: BigInt(orderId), pricePNS: 0n, lotLNS: 0n, expiryBlock: 0n, postOnly: false, fillOrKill: false, immediateOrCancel: false, maxMatches: 0n, leverageHdths: 0n, lastExecutionBlock: 0n, amountCNS: 0n, maxNegPnlCollatBPS: 0n };
  return send(wallet, "execOrders", [[desc], true] as const, onSent);
}

/** Closes a position with a reduce-only market order on the opposite side. */
export function closePosition(wallet: Wallet, perp: PerpInfo, position: PerpPosition, slippageBps: number, onSent: OnSent) {
  return placeOrder(wallet, { perp, side: position.side === "long" ? "short" : "long", kind: "market", size: position.size, leverage: Math.max(1, Math.round(position.leverage) || 1), reduceOnly: true, slippageBps }, onSent);
}

export const perpError = describeError;

/** Perpl's public market context through the app's proxy: 24h reference price and volume per market. */
export type MarketContext = { id: number; name: string; priceDecimals: number; sizeDecimals: number; mark: number; last: number; prev24h: number; volume24h: number; openInterest: number; fundingRate: number; isOpen: boolean };
export async function fetchPerplContext(): Promise<MarketContext[]> {
  const res = await fetch("/api/perpl/v1/pub/context");
  if (!res.ok) throw new Error(`Perpl context unavailable (${res.status})`);
  const json = (await res.json()) as { markets?: { id: number; name: string; config?: { price_decimals: number; size_decimals: number; is_open: boolean }; state?: { mrk: number; lst: number; prv: number; dv: number; oi: number }; funding?: { rate: number; div: number } }[] };
  return (json.markets ?? []).filter((m) => m.config && m.state).map((m) => {
    const pd = m.config!.price_decimals;
    const sd = m.config!.size_decimals;
    return { id: m.id, name: m.name, priceDecimals: pd, sizeDecimals: sd, mark: m.state!.mrk / 10 ** pd, last: m.state!.lst / 10 ** pd, prev24h: m.state!.prv / 10 ** pd, volume24h: m.state!.dv / 10 ** sd, openInterest: m.state!.oi / 10 ** sd, fundingRate: m.funding ? m.funding.rate / (m.funding.div || 1) / 100_000 : 0, isOpen: m.config!.is_open };
  });
}
