// What the keeper's sends cost, kept in the run state (build 17, K1): every mined transaction, reverted or not, and
// every send whose outcome is unknown (counted at its worst case, gas limit x gas price). The daily spend cap and the
// per-target backoff read this ledger.
//
// Times are unix seconds (numbers); amounts are wei, stored as decimal strings because JSON has no bigint.

export const DAY_S = 86_400;
/** Ledger entries are kept this long (a week of history for the digest and for audits), then dropped. */
export const SPEND_KEEP_S = 7 * DAY_S;

export function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

function budgetOf(state) {
  state.budget ??= {};
  state.budget.spend ??= [];
  return state.budget;
}

/**
 * Records one send's cost. `estimated` marks a worst-case entry (the receipt was never read). Returns the entry.
 */
export function recordSpend(state, { at = nowSeconds(), wei, job, target, tx, estimated = false }) {
  const b = budgetOf(state);
  const entry = { at, wei: BigInt(wei).toString(), job, target, ...(tx ? { tx } : {}), ...(estimated ? { estimated: true } : {}) };
  b.spend.push(entry);
  b.spend = b.spend.filter((e) => e.at > at - SPEND_KEEP_S);
  return entry;
}

/** Wei spent by sends recorded after `since` (unix seconds). */
export function spentSince(state, since) {
  let total = 0n;
  for (const e of state?.budget?.spend ?? []) if (e.at > since) total += BigInt(e.wei);
  return total;
}
