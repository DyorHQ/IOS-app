/* Generates the calldata-parity and live-read fixtures for the Swift port of the swap engine and price service
   (ios/DyorKit/Tests/DyorKitTests/Fixtures/{swap,prices}.json).

   Run from the repository root:  npx tsx scripts/dev/ios-swap-fixtures.ts

   swap.json is produced by the very same builders the web app uses (imported from app/lib/swap) or, where a
   builder is module-private (Universal Router v4, Monday's router), by a verbatim copy of it. prices.json holds
   raw eth_call results from Monad mainnet so the Swift decoders are checked against real contract output. */

import { createPublicClient, encodeAbiParameters, encodeFunctionData, encodePacked, http, keccak256, type Address, type Hex } from "viem";
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { permit2Abi, quoterV2Abi, stateViewAbi, swapRouter02Abi, swapRouterV1Abi, universalRouterAbi, v3FactoryAbi, v3PoolAbi, v4QuoterAbi, wmonAbi } from "../../app/lib/swap/abis";
import { MONDAY, NATIVE, UNISWAP, WMON } from "../../app/lib/swap/config";
import { buildSwapRouter02Tx, describeV3, encodeV3Path, hopSymbol, impactBps } from "../../app/lib/swap/uniswap";
import { bpsToPct } from "../../app/lib/format";

const OUT_DIR = resolve(process.cwd(), "ios/DyorKit/Tests/DyorKitTests/Fixtures");
const RPC = "https://rpc.monad.xyz";

const USDC: Address = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603";
const WETH: Address = "0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242";
const ZERO = "0x0000000000000000000000000000000000000000" as const;
const ROUTER_THIS = "0x0000000000000000000000000000000000000002" as const;

const ACCOUNT: Address = "0x1111111111111111111111111111111111111111";
const DEADLINE = 1_800_000_000n;
const AMOUNT_IN = 10n ** 18n; // 1 MON / WMON
const MIN_OUT = 2_600_000n; // 2.6 USDC
const USDC_IN = 1_000_000n; // 1 USDC
const WMON_MIN_OUT = 10n ** 17n; // 0.1 WMON
const WETH_MIN_OUT = 3n * 10n ** 14n; // 0.0003 WETH

type PoolKey = { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };
type V4Hop = { key: PoolKey; zeroForOne: boolean };

const poolId = (key: PoolKey) => keccak256(encodeAbiParameters([{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }], [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]));
const otherSide = (hop: V4Hop) => (hop.zeroForOne ? hop.key.currency1 : hop.key.currency0);
const pathKeys = (hops: V4Hop[]) => hops.map((h) => ({ intermediateCurrency: otherSide(h), fee: h.key.fee, tickSpacing: h.key.tickSpacing, hooks: h.key.hooks, hookData: "0x" as Hex }));

/* Verbatim copy of app/lib/swap/uniswap.ts buildUniversalRouterV4Tx (module-private there). */
const V4_SWAP = "0x10";
const ACTION = { SWAP_EXACT_IN_SINGLE: 0x06, SWAP_EXACT_IN: 0x07, SETTLE_ALL: 0x0c, TAKE_ALL: 0x0f } as const;
function buildUniversalRouterV4Tx(cIn: Address, cOut: Address, hops: V4Hop[], amountIn: bigint, minOut: bigint, deadline: bigint) {
  const swap = hops.length === 1
    ? encodeAbiParameters(
        [{ type: "tuple", components: [{ type: "tuple", name: "poolKey", components: [{ type: "address", name: "currency0" }, { type: "address", name: "currency1" }, { type: "uint24", name: "fee" }, { type: "int24", name: "tickSpacing" }, { type: "address", name: "hooks" }] }, { type: "bool", name: "zeroForOne" }, { type: "uint128", name: "amountIn" }, { type: "uint128", name: "amountOutMinimum" }, { type: "bytes", name: "hookData" }] }],
        [{ poolKey: hops[0].key, zeroForOne: hops[0].zeroForOne, amountIn, amountOutMinimum: minOut, hookData: "0x" }],
      )
    : encodeAbiParameters(
        [{ type: "tuple", components: [{ type: "address", name: "currencyIn" }, { type: "tuple[]", name: "path", components: [{ type: "address", name: "intermediateCurrency" }, { type: "uint24", name: "fee" }, { type: "int24", name: "tickSpacing" }, { type: "address", name: "hooks" }, { type: "bytes", name: "hookData" }] }, { type: "uint128", name: "amountIn" }, { type: "uint128", name: "amountOutMinimum" }] }],
        [{ currencyIn: cIn, path: pathKeys(hops), amountIn, amountOutMinimum: minOut }],
      );
  const actions = encodePacked(["uint8", "uint8", "uint8"], [hops.length === 1 ? ACTION.SWAP_EXACT_IN_SINGLE : ACTION.SWAP_EXACT_IN, ACTION.SETTLE_ALL, ACTION.TAKE_ALL]);
  const params: Hex[] = [
    swap,
    encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [cIn, amountIn]),
    encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [cOut, minOut]),
  ];
  const input = encodeAbiParameters([{ type: "bytes" }, { type: "bytes[]" }], [actions, params]);
  return { to: UNISWAP.universalRouter, data: encodeFunctionData({ abi: universalRouterAbi, functionName: "execute", args: [V4_SWAP, [input], deadline] }), value: cIn.toLowerCase() === NATIVE ? amountIn : 0n };
}

/* Verbatim copy of app/lib/swap/monday.ts buildTx (module-private there). */
function buildMondayTx(route: { path: Address[]; fees: number[] }, amountIn: bigint, minOut: bigint, account: Address, nativeIn: boolean, nativeOut: boolean, deadline: bigint) {
  const recipient = nativeOut ? ZERO : account;
  const swap = route.fees.length === 1
    ? encodeFunctionData({ abi: swapRouterV1Abi, functionName: "exactInputSingle", args: [{ tokenIn: route.path[0], tokenOut: route.path[1], fee: route.fees[0], recipient, deadline, amountIn, amountOutMinimum: minOut, sqrtPriceLimitX96: 0n }] })
    : encodeFunctionData({ abi: swapRouterV1Abi, functionName: "exactInput", args: [{ path: encodeV3Path(route), recipient, deadline, amountIn, amountOutMinimum: minOut }] });
  const calls: Hex[] = [swap];
  if (nativeOut) calls.push(encodeFunctionData({ abi: swapRouterV1Abi, functionName: "unwrapWETH9", args: [minOut, account] }));
  if (nativeIn) calls.push(encodeFunctionData({ abi: swapRouterV1Abi, functionName: "refundETH" }));
  return { to: MONDAY.swapRouter, data: encodeFunctionData({ abi: swapRouterV1Abi, functionName: "multicall", args: [calls] }), value: nativeIn ? amountIn : 0n };
}

const routeSingle = { path: [WMON, USDC], fees: [500] };
const routeSingleMonday = { path: [WMON, USDC], fees: [300] };
const routeDouble = { path: [USDC, WETH, WMON], fees: [500, 3000] };

const keyNativeUsdc: PoolKey = { currency0: NATIVE, currency1: USDC, fee: 500, tickSpacing: 10, hooks: ZERO };
const keyNativeWeth: PoolKey = { currency0: NATIVE, currency1: WETH, fee: 3000, tickSpacing: 60, hooks: ZERO };
const singleHop: V4Hop[] = [{ key: keyNativeUsdc, zeroForOne: true }];
const twoHop: V4Hop[] = [{ key: keyNativeUsdc, zeroForOne: false }, { key: keyNativeWeth, zeroForOne: true }];

const impactCases = [
  { amountIn: AMOUNT_IN, amountOut: 2_620_000n, sliceIn: AMOUNT_IN / 1000n, sliceOut: 2_630n },
  { amountIn: 5n * 10n ** 18n, amountOut: 13_000_000n, sliceIn: 5n * 10n ** 15n, sliceOut: 13_100n },
  { amountIn: 1_000_000n, amountOut: 380_000_000_000_000_000n, sliceIn: 1_000n, sliceOut: 380_000_000_000_000n },
  { amountIn: 1_000_000n, amountOut: 1n, sliceIn: 1_000n, sliceOut: 0n },
].map((c) => ({ ...c, bps: impactBps(c.amountIn, c.amountOut, c.sliceIn, c.sliceOut) }));

const swapFixture = {
  inputs: {
    account: ACCOUNT, deadline: DEADLINE, amountIn: AMOUNT_IN, minOut: MIN_OUT, usdcIn: USDC_IN, wmonMinOut: WMON_MIN_OUT, wethMinOut: WETH_MIN_OUT,
    permit2Amount: USDC_IN, permit2Expiration: DEADLINE,
  },
  addresses: { usdc: USDC, weth: WETH, wmon: WMON, routerThis: ROUTER_THIS },
  feeLabels: Object.fromEntries([100, 300, 500, 3000, 10000].map((fee) => [String(fee), bpsToPct(fee / 100, 2)])),
  v3Path: { single: encodeV3Path(routeSingle), double: encodeV3Path(routeDouble) },
  describe: {
    v3Single: describeV3(routeSingle, ["MON", "USDC"]),
    v3Double: describeV3(routeDouble, ["USDC", hopSymbol(WETH), "MON"]),
    hopWETH: hopSymbol(WETH), hopUSDC: hopSymbol(USDC), hopUnknown: hopSymbol(ACCOUNT),
  },
  impact: impactCases,
  swapRouter02: {
    exactInputSingle: encodeFunctionData({ abi: swapRouter02Abi, functionName: "exactInputSingle", args: [{ tokenIn: WMON, tokenOut: USDC, fee: 500, recipient: ACCOUNT, amountIn: AMOUNT_IN, amountOutMinimum: MIN_OUT, sqrtPriceLimitX96: 0n }] }),
    exactInput: encodeFunctionData({ abi: swapRouter02Abi, functionName: "exactInput", args: [{ path: encodeV3Path(routeDouble), recipient: ROUTER_THIS, amountIn: USDC_IN, amountOutMinimum: WMON_MIN_OUT }] }),
    nativeInSingle: buildSwapRouter02Tx(routeSingle, AMOUNT_IN, MIN_OUT, ACCOUNT, true, false, DEADLINE),
    erc20Single: buildSwapRouter02Tx(routeSingle, AMOUNT_IN, MIN_OUT, ACCOUNT, false, false, DEADLINE),
    nativeOutDouble: buildSwapRouter02Tx(routeDouble, USDC_IN, WMON_MIN_OUT, ACCOUNT, false, true, DEADLINE),
  },
  monday: {
    exactInputSingle: encodeFunctionData({ abi: swapRouterV1Abi, functionName: "exactInputSingle", args: [{ tokenIn: WMON, tokenOut: USDC, fee: 300, recipient: ACCOUNT, deadline: DEADLINE, amountIn: AMOUNT_IN, amountOutMinimum: MIN_OUT, sqrtPriceLimitX96: 0n }] }),
    exactInput: encodeFunctionData({ abi: swapRouterV1Abi, functionName: "exactInput", args: [{ path: encodeV3Path(routeDouble), recipient: ZERO, deadline: DEADLINE, amountIn: USDC_IN, amountOutMinimum: WMON_MIN_OUT }] }),
    nativeInSingle: buildMondayTx(routeSingleMonday, AMOUNT_IN, MIN_OUT, ACCOUNT, true, false, DEADLINE),
    erc20Single: buildMondayTx(routeSingleMonday, AMOUNT_IN, MIN_OUT, ACCOUNT, false, false, DEADLINE),
    nativeOutDouble: buildMondayTx(routeDouble, USDC_IN, WMON_MIN_OUT, ACCOUNT, false, true, DEADLINE),
  },
  universalRouter: {
    singleHop: buildUniversalRouterV4Tx(NATIVE, USDC, singleHop, AMOUNT_IN, MIN_OUT, DEADLINE),
    twoHop: buildUniversalRouterV4Tx(USDC, WETH, twoHop, USDC_IN, WETH_MIN_OUT, DEADLINE),
  },
  permit2: {
    approve: encodeFunctionData({ abi: permit2Abi, functionName: "approve", args: [USDC, UNISWAP.universalRouter, USDC_IN, Number(DEADLINE)] }),
    allowance: encodeFunctionData({ abi: permit2Abi, functionName: "allowance", args: [ACCOUNT, USDC, UNISWAP.universalRouter] }),
  },
  wmon: {
    deposit: encodeFunctionData({ abi: wmonAbi, functionName: "deposit" }),
    withdraw: encodeFunctionData({ abi: wmonAbi, functionName: "withdraw", args: [AMOUNT_IN] }),
  },
  quoterV2: {
    quoteExactInputSingle: encodeFunctionData({ abi: quoterV2Abi, functionName: "quoteExactInputSingle", args: [{ tokenIn: WMON, tokenOut: USDC, amountIn: AMOUNT_IN, fee: 500, sqrtPriceLimitX96: 0n }] }),
    quoteExactInput: encodeFunctionData({ abi: quoterV2Abi, functionName: "quoteExactInput", args: [encodeV3Path(routeDouble), USDC_IN] }),
  },
  v4Quoter: {
    quoteExactInputSingle: encodeFunctionData({ abi: v4QuoterAbi, functionName: "quoteExactInputSingle", args: [{ poolKey: keyNativeUsdc, zeroForOne: true, exactAmount: AMOUNT_IN, hookData: "0x" }] }),
    quoteExactInput: encodeFunctionData({ abi: v4QuoterAbi, functionName: "quoteExactInput", args: [{ exactCurrency: USDC, path: pathKeys(twoHop), exactAmount: USDC_IN }] }),
  },
  stateView: {
    getSlot0: encodeFunctionData({ abi: stateViewAbi, functionName: "getSlot0", args: [poolId(keyNativeUsdc)] }),
    getLiquidity: encodeFunctionData({ abi: stateViewAbi, functionName: "getLiquidity", args: [poolId(keyNativeUsdc)] }),
  },
  v3Factory: { getPool: encodeFunctionData({ abi: v3FactoryAbi, functionName: "getPool", args: [WMON, USDC, 500] }) },
  v3Pool: { liquidity: encodeFunctionData({ abi: v3PoolAbi, functionName: "liquidity" }) },
  poolId: poolId(keyNativeUsdc),
  poolIdNativeWeth: poolId(keyNativeWeth),
};

const json = (value: unknown) => JSON.stringify(value, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n";
mkdirSync(OUT_DIR, { recursive: true });
writeFileSync(resolve(OUT_DIR, "swap.json"), json(swapFixture));
console.log("wrote swap.json");

/* ---------------------------------------------------------------------------------------- live reads */

async function livePrices() {
  const client = createPublicClient({ transport: http(RPC) });
  const blockNumber = await client.getBlockNumber();
  const block = await client.getBlock({ blockNumber });
  const raw = async (to: Address, data: Hex) => (await client.call({ to, data, blockNumber })).data ?? "0x";

  // v3: the WMON/USDC pool at the 500 tier, falling back to the other tiers only when it does not exist.
  let v3: { fee: number; getPool: Hex; pool: Address; slot0: Hex; liquidity: Hex; token0: Hex } | null = null;
  for (const fee of [500, ...UNISWAP.v3FeeTiers.filter((f) => f !== 500)]) {
    const getPoolData = encodeFunctionData({ abi: v3FactoryAbi, functionName: "getPool", args: [WMON, USDC, fee] });
    const result = await raw(UNISWAP.v3Factory, getPoolData);
    const pool = ("0x" + result.slice(-40)) as Address;
    if (pool.toLowerCase() === ZERO) continue;
    v3 = {
      fee,
      getPool: result,
      pool,
      slot0: await raw(pool, "0x3850c7bd"), // slot0()
      liquidity: await raw(pool, encodeFunctionData({ abi: v3PoolAbi, functionName: "liquidity" })),
      token0: await raw(pool, "0x0dfe1681"), // token0()
    };
    break;
  }
  const v4Id = poolId(keyNativeUsdc);
  const v4 = {
    poolId: v4Id,
    getSlot0: await raw(UNISWAP.stateView, encodeFunctionData({ abi: stateViewAbi, functionName: "getSlot0", args: [v4Id] })),
    getLiquidity: await raw(UNISWAP.stateView, encodeFunctionData({ abi: stateViewAbi, functionName: "getLiquidity", args: [v4Id] })),
  };
  return { rpc: RPC, block: blockNumber, timestamp: block.timestamp, v3, v4 };
}

livePrices()
  .then((fixture) => {
    writeFileSync(resolve(OUT_DIR, "prices.json"), json(fixture));
    console.log("wrote prices.json at block", fixture.block.toString(), fixture.v3 ? `(v3 fee ${fixture.v3.fee})` : "(no v3 WMON/USDC pool)");
  })
  .catch((error) => {
    console.error("live reads failed; prices.json not written:", error instanceof Error ? error.message : error);
    process.exitCode = 1;
  });
