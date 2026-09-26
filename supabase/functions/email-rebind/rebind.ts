// What email-rebind does with an email that is already bound (security audit 2026-09-26, GE-1): it never silently
// moves a binding off another wallet. Both proofs have passed by the time this runs (the Privy token proves the email,
// the signature proves the new wallet); `current` is the wallet the email is bound to now (null if unbound).
//
//   no row                                   -> insert  (a first sign-up; unchanged)
//   bound to the recovered wallet            -> refresh (a same-wallet re-bind; unchanged)
//   bound to another wallet, and the request
//     carries replace == that wallet          -> replace (the client showed that wallet and the user confirmed)
//   bound to another wallet otherwise        -> conflict: 409 {"error":"email_already_bound","current":"<wallet>"}
//
// Returning the current address is safe: the caller has just proven ownership of the email. Addresses compare
// case-insensitively. refresh and replace are written as a compare-and-set on the wallet read here, so a binding that
// changes between the read and the write is re-read rather than overwritten.
export type RebindDecision =
  | { action: "insert" }
  | { action: "refresh"; from: string }
  | { action: "replace"; from: string }
  | { action: "conflict"; current: string };

export const REBIND_WINDOW_MS = 15 * 60 * 1000; // the signed challenge is only good for 15 minutes
// The Privy token must be as fresh as the challenge (SB-10): the app captures it from the one-time code moments before.
export const TOKEN_MAX_AGE_S = 15 * 60;

export function decideRebind(current: string | null, recovered: string, replace: string | undefined): RebindDecision {
  if (current === null) return { action: "insert" };
  if (current.toLowerCase() === recovered.toLowerCase()) return { action: "refresh", from: current };
  if (replace !== undefined && replace.toLowerCase() === current.toLowerCase()) return { action: "replace", from: current };
  return { action: "conflict", current };
}

// The optional "replace" body field: undefined when absent (or null), the address when it is one, else "invalid".
export function parseReplace(value: unknown): string | undefined | "invalid" {
  if (value === undefined || value === null) return undefined;
  return typeof value === "string" && /^0x[0-9a-fA-F]{40}$/.test(value) ? value : "invalid";
}

// Pulls `Field: value` lines out of the challenge the wallet signed.
export function field(message: string, key: string): string | null {
  const line = message.split("\n").find((l) => l.toLowerCase().startsWith(`${key.toLowerCase()}:`));
  return line ? line.slice(line.indexOf(":") + 1).trim() : null;
}
