// Minimal ABIs of the LIVE (deployed, v1) contracts — only the functions and events the keepers use. They are
// written out by hand on purpose: the keepers must match the deployed bytecode, not the v2 source in contracts/src
// (which adds functions the live contracts do not have). Every signature below was checked against the source at
// git commit 3fc1f47 (the deployed state).
import { parseAbi } from "viem";

export const momentsFactoryAbi = parseAbi([
  "function momentCount() view returns (uint256)",
  "function publishingPaused() view returns (bool)",
  "function getMoment(uint256 momentId) view returns ((address creator, address platform, address treasury, address coin, address nft, uint256 price, uint256 threshold, uint256 rateNum, uint256 rateDen, uint16 creatorBps, uint16 platformBps, uint16 reserveBps, uint16 creatorAllocBps, uint16 expiryCreatorBps, uint16 royaltyBps, uint64 publishedAt, uint64 deadline))",
]);

// Cohort 0 ("v1") predates `royaltyBps`; its Moment struct has one field fewer. Used as a fallback decoder.
export const momentsFactoryV1Abi = parseAbi([
  "function getMoment(uint256 momentId) view returns ((address creator, address platform, address treasury, address coin, address nft, uint256 price, uint256 threshold, uint256 rateNum, uint256 rateDen, uint16 creatorBps, uint16 platformBps, uint16 reserveBps, uint16 creatorAllocBps, uint16 expiryCreatorBps, uint64 publishedAt, uint64 deadline))",
]);

export const momentCollectAbi = parseAbi([
  "function state(uint256 momentId) view returns (uint8)",
  "function ledger(uint256 momentId) view returns ((uint8 state, uint64 completedAt, uint64 stuckSince, uint64 endedAt, uint256 reserve, uint256 creatorClaimable, uint256 platformClaimable, uint256 treasuryClaimable, uint256 totalGross, uint256 collects))",
  "event GraduationFailed(uint256 indexed momentId)",
  "event Graduated(uint256 indexed momentId)",
]);

// Permissionless retry: MomentGraduation.graduate(id) (MomentCollect only calls it from the terminal collect).
export const momentGraduationAbi = parseAbi([
  "function graduate(uint256 momentId)",
  "function isGraduated(uint256 momentId) view returns (bool)",
]);

export const momentFeeHookAbi = parseAbi(["function buybackAccrued(uint256 momentId) view returns (uint256)"]);

// Permissionless: MomentBuyback.execute(id, minCoinOut). At most once per MIN_INTERVAL per Moment.
export const momentBuybackAbi = parseAbi([
  "function execute(uint256 momentId, uint256 minCoinOut) returns ((uint256 budget, uint256 usdcSpent, uint256 coinBought, uint256 usdcToPool, uint128 liquidityAdded, uint256 carried))",
  "function carry(uint256 momentId) view returns (uint256)",
  "function lastRun(uint256 momentId) view returns (uint64)",
  "function MIN_AMOUNT() view returns (uint256)",
  "function MIN_INTERVAL() view returns (uint256)",
]);

export const launchpadFactoryAbi = parseAbi([
  "function launchCount() view returns (uint256)",
  "function getLaunches(uint256 offset, uint256 limit) view returns (address[])",
  "function getLaunchedToken(address token) view returns ((address token, address curve, address deployer, address creatorFeeRecipient, address pairToken, uint256 graduationThreshold, uint16 creatorTaxBps, uint16 poolFeeBps, int24 tickSpacing, bool holderFeeSharing, uint8 graduationVenue, uint8 phase, uint256 sweptQuote, uint256 sweptTokens, uint256 sweptAt, bytes32 poolId, bool exists))",
  "function stuckSince(address token) view returns (uint256)",
  "function mondayExecutor() view returns (address)",
  "function hook() view returns (address)",
  "function graduate(address token)",
  "function graduateFallback(address token)",
  "event AutoGraduationFailed(address indexed token)",
]);

export const bondingCurveAbi = parseAbi([
  "function completed() view returns (bool)",
  "function rescued() view returns (bool)",
  "function reservedTokens() view returns (uint256)",
  "function phantomQuote() view returns (uint256)",
  "function graduationThreshold() view returns (uint256)",
  "function realQuoteReserve() view returns (uint256)",
]);

export const mondayExecutorAbi = parseAbi([
  "function factory() view returns (address)",
  "function wmon() view returns (address)",
  "function FEE() view returns (uint24)",
]);

export const mondayFactoryAbi = parseAbi([
  "function getPool(address tokenA, address tokenB, uint24 fee) view returns (address)",
  "function feeAmountTickSpacing(uint24 fee) view returns (int24)",
]);

export const mondayPoolAbi = parseAbi([
  "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)",
  "function liquidity() view returns (uint128)",
  "function tickBitmap(int16 wordPosition) view returns (uint256)",
]);

// Permissionless: MemeHook.sweepPoolFees(poolId, currency) ("Anyone may call it").
export const memeHookAbi = parseAbi([
  "function pendingFees(bytes32 poolId, address currency) view returns (uint256)",
  "function pendingCreatorTax(bytes32 poolId, address currency) view returns (uint256)",
  "function sweepPoolFees(bytes32 poolId, address currency)",
]);

export const erc20Abi = parseAbi(["function balanceOf(address) view returns (uint256)"]);
