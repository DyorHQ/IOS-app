import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from "viem";

const MESSAGES: Record<string, string> = {
  SlippageExceeded: "The price moved past your slippage limit. Try again.",
  CurveIsCompleted: "This curve is complete. Trading continues on Uniswap v4.",
  CurveNotTrading: "This curve is not trading right now.",
  InsufficientRealReserve: "The curve does not hold enough of the pair asset for that sale.",
  ZeroAmount: "Enter an amount.",
  NativeValueMismatch: "The MON sent does not match the amount.",
  UnexpectedNativeValue: "This pair is an ERC-20 token; do not send MON.",
  LaunchFeeNotPaid: "The launch fee was not covered.",
  LaunchEconomicsMismatch: "Launch settings changed while you were editing. Reload and try again.",
  CreatorTaxTooHigh: "The creator tax is above the protocol maximum.",
  PairTokenNotApproved: "That pair asset is not approved on the launchpad.",
  NotWhitelisted: "Launching is currently limited to whitelisted wallets.",
  ExemptionListTooLong: "Up to 32 snipe-tax exemptions are allowed.",
  ModulesNotSet: "The launchpad is not fully configured yet.",
  LaunchConfigDisabled: "This launch configuration is disabled.",
  NothingToClaim: "Nothing to claim yet.",
  InsufficientBalance: "Insufficient token balance.",
  InsufficientAllowance: "Token allowance is too low.",
  NotStuck: "This launch is not stuck.",
  WrongGraduationPhase: "This launch is not in a phase that allows that.",
  UnknownLaunch: "That token was not launched here.",
  TransferFailed: "A token transfer failed. Check your balance and allowance, then try again.",
  NativeTransferFailed: "Sending MON failed.",
  // Moments
  NotCollecting: "This Moment is no longer collecting.",
  CollectWindowClosed: "The collect window for this Moment has closed.",
  BadQuantity: "Choose between 1 and 20 editions.",
  WrongToken: "Collects are paid in USDC.",
  NotExpirable: "This Moment cannot be wound down yet.",
  WrongState: "This Moment is not in a state that allows that.",
  NotBeneficiary: "Only the beneficiary wallet can withdraw this.",
  NothingToWithdraw: "Nothing to withdraw.",
  InsufficientGasForGraduation: "Not enough gas was provided for graduation. Retry with more gas.",
  AlreadyGraduated: "This Moment has already graduated.",
  NotGraduated: "This Moment has not graduated yet.",
  NotPending: "This Moment is not waiting for graduation.",
  SupplyInvariant: "Supply check failed; the transaction was rejected.",
  PriceOutOfRange: "The opening price is out of range; graduation cannot proceed.",
  TooSoon: "A buyback ran less than an hour ago.",
  BelowMinimum: "Less than 1 USDC of buyback fees has accrued.",
  Slippage: "The buyback would receive less coin than your minimum.",
  PriceTooLow: "The collect price is below the minimum.",
  AllocTooHigh: "The creator allocation is above the maximum.",
  BadWindow: "The collect window must be between 1 hour and 30 days.",
  Paused: "Publishing is paused right now.",
  BadRoyalty: "The royalty is above the maximum.",
  ZeroAddress: "An address was empty.",
  InvalidPolicy: "That policy is not valid.",
  NotGovernance: "Only governance can do that.",
  UnknownMoment: "That Moment does not exist.",
  InvalidSigner: "The Permit2 signature did not match your wallet.",
  SignatureExpired: "The Permit2 signature expired; try again.",
  InvalidNonce: "That Permit2 nonce was already used; try again.",
  InvalidAmount: "The Permit2 amount does not cover this collect.",
};

/** Turns wallet and contract errors into one readable sentence. */
export function describeError(error: unknown): string {
  if (error instanceof BaseError) {
    if (error.walk((e) => e instanceof UserRejectedRequestError)) return "Request cancelled in your wallet.";
    const revert = error.walk((e) => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    const name = revert?.data?.errorName ?? revert?.reason;
    if (name) return MESSAGES[name] ?? `Transaction reverted: ${name}`;
    if (/insufficient funds/i.test(error.shortMessage)) return "Not enough MON to cover the amount and gas.";
    return error.shortMessage;
  }
  if (error && typeof error === "object" && "message" in error && typeof (error as { message: unknown }).message === "string") {
    const message = (error as { message: string }).message;
    if (/user rejected|user denied/i.test(message)) return "Request cancelled in your wallet.";
    return message.length > 220 ? message.slice(0, 220) + "…" : message;
  }
  return String(error);
}
