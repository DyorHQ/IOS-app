// Read-only research for xStocks through 1inch on Monad: the facts the venue waits on before anything is listed
// (docs/swap-spec.md, "xStocks through 1inch"). Nothing here signs or sends a transaction. The 1inch key, when a command
// needs it, is read from ONEINCH_API_KEY and never printed; RPC URLs (which can carry a provider's key) aren't either:
// every line and file goes through `redact`, and on-chain or API text through `printable`.
//
//   node scripts/research/xstocks/research.mjs router [--monad-rpc URL] [--ethereum-rpc URL]
//       R3a: the runtime code hash of the router, Aqua and SwapVM on Monad, compared with the router on Ethereum.
//   node scripts/research/xstocks/research.mjs discover [--blocks N] [--span N] [--monad-rpc URL]
//       R4 candidates: tokens moved through the router in the last N blocks (read SPAN blocks a request) whose name or
//       symbol looks like an xStock. Candidates only: an address is curated from the issuer's own list, never from this.
//   node scripts/research/xstocks/research.mjs fills [--blocks N] [--span N] [--txs N] [--monad-rpc URL]
//       R1/R3b: every log the router emitted (a Limit Order Protocol RFQ fill emits OrderFilled there while its tokens
//       move maker to taker, so `discover` can't see it), counted by event, and the tokens moved in the newest of those
//       transactions.
//   node scripts/research/xstocks/research.mjs fill HASH... [--monad-rpc URL]
//       R1/R3b: a transaction taken apart: its transfers, the router's order events, the Limit Order Protocol fills in its
//       calldata (maker, assets, amounts, traits), its internal calls when the RPC traces, and which parties are contracts.
//   node scripts/research/xstocks/research.mjs token ADDRESS... [--monad-rpc URL]
//       R4/R15: name, symbol, decimals, supply, EIP-1967 implementation and admin, and code hashes.
//   node scripts/research/xstocks/research.mjs feed ADDRESS... [--monad-rpc URL]
//       R11: a reference feed's description, decimals, latest answer and its age by the chain's clock.
//   node scripts/research/xstocks/research.mjs tx HASH... [--monad-rpc URL]
//       R3b: a real transaction to the router, decoded as the app decodes it, with its receipt.
//   ONEINCH_API_KEY=… node scripts/research/xstocks/research.mjs oneinch --stock ADDRESS --from WALLET
//         [--usdc 10,50,200] [--slippage-bps 100] [--out FILE]
//       R1: 1inch's quote and swap answers on chain 143 for USDC -> stock and back, asked exactly as the oneinch-proxy
//       asks, and checked as the app checks a firm quote. --out writes them as golden vectors (no key in them). Asks are
//       spaced 1.1 s apart (1inch's free tier allows about one a second).
//
// Behind an HTTPS proxy, Node's fetch needs NODE_USE_ENV_PROXY=1 (Node 22.21 or later) to use it.
import { createPublicClient, formatUnits, getAddress, http, isAddress, parseAbi, parseAbiItem } from "viem";
import { writeFileSync } from "node:fs";
import {
  EIP1967, LOP_EVENTS, MONAD_CHAIN_ID, MONAD_USDC, ONEINCH, STOCK_SLIPPAGE_CAP_BPS, SWAP_SELECTOR, WRAPPED_NATIVE, addressFromSlot, amountField,
  checkFirmAnswer, codeHash, decodeSwap, findOrderFills, maskAddress, printable, redact, slippagePercent, swapProblem, toJSON,
} from "./lib.mjs";

/** `--name value`; never takes another flag as the value. */
function option(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  const value = i > 0 ? process.argv[i + 1] : undefined;
  return value !== undefined && !value.startsWith("--") ? value : fallback;
}
/** The arguments after the command that aren't flags or flag values. */
function positional() {
  const args = process.argv.slice(3);
  return args.filter((a, i) => !a.startsWith("--") && !(i > 0 && args[i - 1].startsWith("--")));
}

const MONAD_RPC = option("monad-rpc", "https://rpc.monad.xyz");
const ETHEREUM_RPC = option("ethereum-rpc", "https://ethereum-rpc.publicnode.com");
/** What is never printed: the 1inch key, and each RPC URL's path and query (where a provider puts its key). */
const SECRETS = [process.env.ONEINCH_API_KEY, ...[MONAD_RPC, ETHEREUM_RPC].flatMap((url) => {
  try { const u = new URL(url); return [`${u.pathname}${u.search}`.length > 1 ? `${u.pathname}${u.search}` : "", u.search]; } catch { return [url]; }
})].filter(Boolean);
const say = (line = "") => console.log(redact(printable(line), SECRETS));

const monad = () => createPublicClient({ transport: http(MONAD_RPC, { timeout: 20_000, retryCount: 2 }) });
const ethereum = () => createPublicClient({ transport: http(ETHEREUM_RPC, { timeout: 20_000, retryCount: 2 }) });

const ERC20 = parseAbi([
  "function name() view returns (string)", "function symbol() view returns (string)", "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
]);
const FEED = parseAbi([
  "function description() view returns (string)", "function decimals() view returns (uint8)", "function version() view returns (uint256)",
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
]);
const TRANSFER = parseAbiItem("event Transfer(address indexed from, address indexed to, uint256 value)");
const TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";

/** A read's answer, or why it couldn't be read, so one bad address doesn't stop the rest. */
async function settle(promise) {
  try { return await promise; } catch (error) { return `unreadable (${String(error.shortMessage ?? "read failed").split("\n")[0]})`; }
}
const isText = (v) => typeof v === "string" && v.startsWith("unreadable");

async function router() {
  const [m, e] = [monad(), ethereum()];
  const chain = await m.getChainId();
  if (chain !== MONAD_CHAIN_ID) throw new Error(`the Monad RPC answers chain ${chain}, not ${MONAD_CHAIN_ID}`);
  const ethCode = await e.getCode({ address: ONEINCH.router });
  const ethRouter = codeHash(ethCode);
  say(`Ethereum AggregationRouterV6 ${ONEINCH.router} code hash: ${ethRouter ?? "no code"}, ${ethCode ? (ethCode.length - 2) / 2 : 0} bytes`);
  for (const [name, address] of Object.entries(ONEINCH)) {
    const code = await m.getCode({ address });
    const hash = codeHash(code);
    const note = name === "router" ? (hash && hash === ethRouter ? "SAME as Ethereum's router" : "DIFFERS from Ethereum's router") : "";
    say(`Monad ${name.padEnd(12)} ${address} code hash: ${hash ?? "NO CODE"}, ${code ? (code.length - 2) / 2 : 0} bytes ${note}`);
    if (name === "router" && code && ethCode) {
      // The router keeps its chain's wrapped native coin as an immutable: compare with it blanked on both sides.
      const eth = maskAddress(ethCode, WRAPPED_NATIVE.ethereum);
      const mon = maskAddress(code, WRAPPED_NATIVE.monad);
      const same = codeHash(eth.code) === codeHash(mon.code);
      say(`  with the wrapped native coin masked (${eth.count} occurrence(s) on Ethereum, ${mon.count} on Monad): ${same ? "SAME code" : "STILL DIFFERS"}`);
      if (!same && eth.code.length === mon.code.length) {
        const words = [];
        for (let i = 2; i < eth.code.length; i += 64) if (eth.code.slice(i, i + 64) !== mon.code.slice(i, i + 64)) words.push((i - 2) / 2);
        say(`  differing 32-byte windows at byte offsets: ${words.slice(0, 40).join(", ")}${words.length > 40 ? ` … (${words.length} in all)` : ""}`);
      }
    }
  }
}

async function discover() {
  const client = monad();
  const blocks = BigInt(option("blocks", "20000"));
  const span = BigInt(option("span", "1000"));
  if (blocks <= 0n || span <= 0n) throw new Error("--blocks and --span must be positive");
  const head = await client.getBlockNumber();
  const first = head + 1n > blocks ? head + 1n - blocks : 0n;
  const tokens = new Map();
  for (let to = head; to >= first; to -= span) {
    const from = to + 1n - span > first ? to + 1n - span : first;
    for (const args of [{ from: ONEINCH.router }, { to: ONEINCH.router }]) {
      const logs = await settle(client.getLogs({ event: TRANSFER, args, fromBlock: from, toBlock: to }));
      if (isText(logs)) { say(`blocks ${from}-${to}: ${logs}`); continue; }
      for (const log of logs) {
        const address = getAddress(log.address);
        const seen = tokens.get(address) ?? { transfers: 0, tx: log.transactionHash };
        tokens.set(address, { transfers: seen.transfers + 1, tx: seen.tx });
      }
    }
    if (from === 0n) break;
  }
  say(`${tokens.size} tokens moved through the router in blocks ${first}-${head}`);
  for (const [address, { transfers, tx: sample }] of tokens) {
    const [name, symbol] = await Promise.all([settle(client.readContract({ address, abi: ERC20, functionName: "name" })),
      settle(client.readContract({ address, abi: ERC20, functionName: "symbol" }))]);
    const looks = /xstock/i.test(String(name)) || /^[A-Z0-9.]{1,6}x$/.test(String(symbol));
    // The newest transaction that moved it through the router, for `tx` (research R3b).
    say(`${looks ? "CANDIDATE " : "          "}${address}  ${symbol}  ${name}  (${transfers} transfers, newest tx ${sample})`);
  }
}

/** Every log the router itself emitted in the window (a Limit Order Protocol fill emits `OrderFilled` there while the
    tokens move maker to taker, never through the router), counted by event, then the tokens moved in the newest of
    those transactions (`--txs`, default 300): xStocks traded as RFQ fills show up here and not in `discover`. */
async function fills() {
  const client = monad();
  const blocks = BigInt(option("blocks", "20000"));
  const span = BigInt(option("span", "1000"));
  const limit = Number(option("txs", "300"));
  if (blocks <= 0n || span <= 0n) throw new Error("--blocks and --span must be positive");
  const head = await client.getBlockNumber();
  const first = head + 1n > blocks ? head + 1n - blocks : 0n;
  const topics = new Map();
  const txs = new Map();
  for (let to = head; to >= first; to -= span) {
    const from = to + 1n - span > first ? to + 1n - span : first;
    const logs = await settle(client.getLogs({ address: ONEINCH.router, fromBlock: from, toBlock: to }));
    if (isText(logs)) { say(`blocks ${from}-${to}: ${logs}`); continue; }
    for (const log of logs) {
      const topic = log.topics[0] ?? "(anonymous)";
      topics.set(topic, (topics.get(topic) ?? 0) + 1);
      if (!txs.has(log.transactionHash)) txs.set(log.transactionHash, log.blockNumber);
    }
    if (from === 0n) break;
  }
  say(`router logs in blocks ${first}-${head}: ${[...topics.values()].reduce((a, b) => a + b, 0)} in ${txs.size} transactions`);
  for (const [topic, count] of topics) say(`  event ${topic}: ${count}`);
  const newest = [...txs.entries()].sort((a, b) => (a[1] > b[1] ? -1 : 1)).slice(0, limit).map(([hash]) => hash);
  const tokens = new Map();
  for (const hash of newest) {
    const receipt = await settle(client.getTransactionReceipt({ hash }));
    if (isText(receipt)) { say(`${hash}: ${receipt}`); continue; }
    for (const log of receipt.logs) {
      if (log.topics[0] !== "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" || log.topics.length !== 3) continue;
      const address = getAddress(log.address);
      const seen = tokens.get(address) ?? { transfers: 0, tx: hash };
      tokens.set(address, { transfers: seen.transfers + 1, tx: seen.tx });
    }
  }
  say(`${tokens.size} tokens moved in the newest ${newest.length} of those transactions`);
  for (const [address, { transfers, tx: sample }] of tokens) {
    const [name, symbol] = await Promise.all([settle(client.readContract({ address, abi: ERC20, functionName: "name" })),
      settle(client.readContract({ address, abi: ERC20, functionName: "symbol" }))]);
    const looks = /xstock/i.test(String(name)) || /^[A-Z0-9.]{1,6}x$/.test(String(symbol));
    say(`${looks ? "CANDIDATE " : "          "}${address}  ${symbol}  ${name}  (${transfers} transfers, newest tx ${sample})`);
  }
}

async function token() {
  const client = monad();
  for (const [i, raw] of positional().entries()) {
    if (i > 0) await new Promise((resolve) => setTimeout(resolve, 400));
    if (!isAddress(raw, { strict: false })) { say(`${raw}: not an address`); continue; }
    const address = getAddress(raw);
    const read = (functionName) => settle(client.readContract({ address, abi: ERC20, functionName }));
    const [name, symbol, decimals, supply, code, impl, admin] = await Promise.all([read("name"), read("symbol"), read("decimals"), read("totalSupply"),
      settle(client.getCode({ address })), settle(client.getStorageAt({ address, slot: EIP1967.implementation })),
      settle(client.getStorageAt({ address, slot: EIP1967.admin }))]);
    const implementation = isText(impl) ? null : addressFromSlot(impl);
    const implementationCode = implementation ? await settle(client.getCode({ address: implementation })) : null;
    say(toJSON({
      address, name, symbol, decimals,
      totalSupply: typeof supply === "bigint" && typeof decimals === "number" ? formatUnits(supply, decimals) : supply,
      codeHash: isText(code) ? code : codeHash(code), implementation,
      implementationCodeHash: implementationCode && !isText(implementationCode) ? codeHash(implementationCode) : implementationCode,
      admin: isText(admin) ? admin : addressFromSlot(admin),
    }));
  }
}

async function feed() {
  const client = monad();
  const block = await client.getBlock();
  for (const raw of positional()) {
    if (!isAddress(raw, { strict: false })) { say(`${raw}: not an address`); continue; }
    const address = getAddress(raw);
    const read = (functionName) => settle(client.readContract({ address, abi: FEED, functionName }));
    const [description, decimals, version, round] = await Promise.all([read("description"), read("decimals"), read("version"), read("latestRoundData")]);
    const answer = Array.isArray(round) && typeof decimals === "number" ? formatUnits(round[1], decimals) : round;
    const age = Array.isArray(round) ? `${block.timestamp - round[3]} s` : "unknown";
    say(toJSON({ address, description, decimals, version, answer, updatedAgo: age, roundId: Array.isArray(round) ? round[0] : null }));
  }
}

async function tx() {
  const client = monad();
  for (const hash of positional()) {
    if (!/^0x[0-9a-fA-F]{64}$/.test(hash)) { say(`${hash}: not a transaction hash`); continue; }
    const [transaction, receipt] = await Promise.all([settle(client.getTransaction({ hash })), settle(client.getTransactionReceipt({ hash }))]);
    if (isText(transaction)) { say(`${hash}: ${transaction}`); continue; }
    const toRouter = transaction.to && getAddress(transaction.to) === getAddress(ONEINCH.router);
    const selector = transaction.input.slice(0, 10);
    const swap = toRouter ? decodeSwap(transaction.input) : null;
    say(toJSON({
      hash, from: transaction.from, to: transaction.to, value: transaction.value,
      status: isText(receipt) ? receipt : receipt.status, block: isText(receipt) ? null : receipt.blockNumber, gasUsed: isText(receipt) ? null : receipt.gasUsed,
      selector, selectorIsGenericSwap: selector === SWAP_SELECTOR, readsAsAppSwap: swap !== null,
      problem: swap ? swapProblem(swap, { account: transaction.from, value: transaction.value }) : null,
      swap, logs: isText(receipt) ? null : receipt.logs.length,
      logEmitters: isText(receipt) ? null : [...new Set(receipt.logs.map((l) => getAddress(l.address)))],
    }));
  }
}

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function oneinch() {
  const key = process.env.ONEINCH_API_KEY;
  if (!key) throw new Error("set ONEINCH_API_KEY (it is never printed)");
  if (key.length < 8) throw new Error("ONEINCH_API_KEY is too short to be a key (and too short to redact safely)");
  const stockArg = option("stock", "");
  const fromArg = option("from", "");
  if (!isAddress(stockArg, { strict: false }) || !isAddress(fromArg, { strict: false })) throw new Error("--stock and --from must be addresses");
  const stock = getAddress(stockArg);
  const from = getAddress(fromArg);
  const bps = Number(option("slippage-bps", String(STOCK_SLIPPAGE_CAP_BPS)));
  const slippage = slippagePercent(bps);
  const sizes = option("usdc", "10,50,200").split(",").map((s) => {
    const n = Number(s);
    if (!Number.isFinite(n) || n <= 0) throw new Error(`--usdc: ${s} is not a positive amount`);
    return BigInt(Math.round(n * 1e6));
  });
  const base = `https://api.1inch.dev/swap/v6.0/${MONAD_CHAIN_ID}`;
  let asked = 0;
  // Asked exactly as the proxy asks (supabase/functions/oneinch-proxy/request.ts, `upstreamURL`).
  const ask = async (path, params) => {
    if (asked++ > 0) await pause(1_100);
    const url = `${base}/${path}?${new URLSearchParams({ ...params, includeProtocols: "true" })}`;
    try {
      const response = await fetch(url, { headers: { Authorization: `Bearer ${key}`, Accept: "application/json" }, redirect: "error", signal: AbortSignal.timeout(20_000) });
      const text = await response.text();
      let body;
      try { body = JSON.parse(text); } catch { body = text.slice(0, 500); }
      return { status: response.status, path, params, body };
    } catch (error) {
      return { status: 0, path, params, body: `request failed: ${String(error?.message ?? error).split("\n")[0]}` };
    }
  };
  const swapParams = (src, dst, amount) => ({ src, dst, amount: amount.toString(), from, origin: from, receiver: from, slippage,
    disableEstimate: "true", allowPartialFill: "false", usePermit2: "false" });
  const vectors = [];
  try {
    for (const usdc of sizes) {
      vectors.push({ kind: "quote", direction: "buy", ...(await ask("quote", { src: MONAD_USDC, dst: stock, amount: usdc.toString() })) });
      const buy = await ask("swap", swapParams(MONAD_USDC, stock, usdc));
      vectors.push({ kind: "swap", direction: "buy", ...buy, check: checkFirmAnswer(buy, { tokenIn: MONAD_USDC, tokenOut: stock, amountIn: usdc }, from, bps) });
      const shares = amountField(buy.body?.dstAmount);
      if (shares !== null) {
        const sell = await ask("swap", swapParams(stock, MONAD_USDC, shares));
        vectors.push({ kind: "swap", direction: "sell", ...sell, check: checkFirmAnswer(sell, { tokenIn: stock, tokenOut: MONAD_USDC, amountIn: shares }, from, bps) });
      }
    }
  } finally {
    for (const v of vectors) say(`${v.kind} ${v.direction} ${v.params.amount}: HTTP ${v.status} ${v.check ? toJSON(v.check) : toJSON(v.body).slice(0, 400)}`);
    const out = option("out", "");
    if (out) {
      writeFileSync(out, `${redact(toJSON({ chainId: MONAD_CHAIN_ID, stock, from, slippageBps: bps, vectors }), SECRETS)}\n`);
      say(`wrote ${vectors.length} vectors to ${out}`);
    }
  }
}

/** Each transaction taken apart: every log (transfers with token, sides and amount; the router's order events by name),
    the Limit Order Protocol fills inside its calldata, its internal calls when the RPC can trace, and whether each
    party is a contract. For the fills `fills` finds, to tell an intent (the user is the maker) from an RFQ (a market
    maker is). */
async function fill() {
  const client = monad();
  const symbols = new Map();
  const tokenInfo = async (address) => {
    if (!symbols.has(address)) {
      const [symbol, decimals] = await Promise.all([settle(client.readContract({ address, abi: ERC20, functionName: "symbol" })),
        settle(client.readContract({ address, abi: ERC20, functionName: "decimals" }))]);
      symbols.set(address, { symbol: isText(symbol) ? "?" : symbol, decimals: typeof decimals === "number" ? decimals : null });
    }
    return symbols.get(address);
  };
  const kinds = new Map();
  const kind = async (address) => {
    if (!kinds.has(address)) {
      const code = await settle(client.getCode({ address }));
      kinds.set(address, isText(code) ? code : !code || code === "0x" ? "no code (EOA)" : `contract, ${(code.length - 2) / 2} bytes, ${codeHash(code).slice(0, 18)}…`);
    }
    return kinds.get(address);
  };
  for (const hash of positional()) {
    if (!/^0x[0-9a-fA-F]{64}$/.test(hash)) { say(`${hash}: not a transaction hash`); continue; }
    const [transaction, receipt] = await Promise.all([settle(client.getTransaction({ hash })), settle(client.getTransactionReceipt({ hash }))]);
    if (isText(transaction) || isText(receipt)) { say(`${hash}: ${isText(transaction) ? transaction : receipt}`); continue; }
    say(`=== ${hash} block ${receipt.blockNumber} ${receipt.status}`);
    say(`from ${getAddress(transaction.from)} to ${getAddress(transaction.to)} selector ${transaction.input.slice(0, 10)} input ${(transaction.input.length - 2) / 2} bytes value ${transaction.value}`);
    const parties = new Set([getAddress(transaction.from), getAddress(transaction.to)]);
    for (const log of receipt.logs) {
      const emitter = getAddress(log.address);
      const topic = log.topics[0];
      if (topic === TRANSFER_TOPIC && log.topics.length === 3) {
        const from = getAddress(`0x${log.topics[1].slice(26)}`);
        const to = getAddress(`0x${log.topics[2].slice(26)}`);
        const { symbol, decimals } = await tokenInfo(emitter);
        const value = BigInt(log.data);
        parties.add(from); parties.add(to);
        say(`  Transfer ${symbol} ${decimals === null ? value : formatUnits(value, decimals)}  ${from} -> ${to}`);
      } else if (emitter === getAddress(ONEINCH.router) && LOP_EVENTS[topic]) {
        say(`  router ${LOP_EVENTS[topic]} topics ${log.topics.slice(1).join(" ")} data ${log.data}`);
      } else {
        say(`  log ${emitter} topic0 ${topic ?? "none"} (${log.topics.length} topics, ${(log.data.length - 2) / 2} data bytes)`);
      }
    }
    const orders = findOrderFills(transaction.input);
    say(orders.length ? `  ${orders.length} order fill(s) in the calldata:` : "  no Limit Order Protocol fill in the calldata");
    for (const found of orders) {
      say(toJSON(found));
      parties.add(found.order.maker);
    }
    const trace = await settle(client.request({ method: "debug_traceTransaction", params: [hash, { tracer: "callTracer" }] }));
    if (isText(trace)) {
      say(`  trace: ${trace}`);
    } else {
      const walk = (call, depth) => {
        say(`  ${"  ".repeat(depth)}${call.type} ${call.from} -> ${call.to} ${call.input?.slice(0, 10) ?? ""}${call.value && call.value !== "0x0" ? ` value ${BigInt(call.value)}` : ""}${call.error ? ` ERROR ${call.error}` : ""}`);
        if (call.to && getAddress(call.to) === getAddress(ONEINCH.router)) for (const inner of findOrderFills(call.input)) say(toJSON(inner));
        for (const child of call.calls ?? []) walk(child, depth + 1);
      };
      walk(trace, 0);
    }
    for (const party of parties) say(`  ${party}: ${await kind(party)}`);
  }
}

const commands = { router, discover, fills, fill, token, feed, tx, oneinch };
const command = commands[process.argv[2]];
if (!command) {
  console.error("usage: research.mjs router|discover|fills|fill|token|feed|tx|oneinch … (see the header of this file)");
  process.exit(2);
}
try {
  await command();
} catch (error) {
  console.error(redact(printable(`error: ${error.shortMessage ?? error.message}`), SECRETS));
  process.exit(1);
}
