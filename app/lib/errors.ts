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
