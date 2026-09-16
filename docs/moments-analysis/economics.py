#!/usr/bin/env python3
"""
Moments v1 economics model — REAL numbers for the reconciled per-moment design.

Design under test (as agreed in the design dialogue):
  - Per-moment coin, fixed supply S.
  - Collecting is a FIXED-price action, creator-set, min $0.10. Each collect:
        * mints a transferable NFT (media + provenance + early-collector rank)
        * BUNDLES coins to the collector (at a fixed coins-per-USDC rate, pre-graduation)
  - Every collect's proceeds split: creator% / platform% / reserve%.
  - The reserve accumulates USDC. When reserve >= graduation threshold (USD),
    the coin GRADUATES: reserve USDC + reserved coins seed a Uniswap v4 pool
    (Monad), full-range, locked. Coin becomes tradable.
  - Creator allocation <= 10% of S. If creator picks 10%: 20% of that bag unlocks
    at graduation, remaining 80% vests 16%-of-allocation per month for 5 months.
  - Non-graduating moments stay cheap keepsakes; no pool.
  - No vault, no redemption, no backing, no burn (deleted vs the original plan).

The bundle rate is derived for PRICE CONTINUITY ("no free jump"): the coins a
collector receives per USDC equal the pool's opening price, so graduation does not
instantly reprice collectors' coins up or down.

Everything here is a CANDIDATE parameter set, not a proven optimum. The point is
to expose the real magnitudes and the structural tensions before any code is written.
"""

from dataclasses import dataclass

# ----------------------------------------------------------------------------- #
# Parameters
# ----------------------------------------------------------------------------- #

USDC_USD = 1.00                # Moments settles in USDC (1 USDC = $1); no oracle needed
COLLECTOR_LIQUID_FRAC = 0.60   # fraction of a collector's bundled coins liquid at graduation;
                               # remaining 40% vests over 2 months (retention + anti-dump)

@dataclass
class Params:
    supply: float             # total coin supply S (per moment)
    creator_frac: float       # share of each collect's $ paid to creator
    platform_frac: float      # share of each collect's $ paid to platform
    reserve_frac: float       # share of each collect's $ that accumulates to seed the pool
    threshold_usd: float      # graduation: reserve must reach this USD value
    creator_alloc: float      # creator coin allocation as fraction of supply (<= 0.10)

    def check(self):
        assert abs(self.creator_frac + self.platform_frac + self.reserve_frac - 1.0) < 1e-9, \
            "collect $ split must sum to 1"
        assert self.creator_alloc <= 0.10 + 1e-9, "creator alloc capped at 10%"


def derive(p: Params):
    """Derive the emergent coin allocation + rate for price continuity."""
    p.check()
    threshold_mon = p.threshold_usd / USDC_USD          # reserve USDC needed to graduate
    # Total USDC that must be *collected* to accumulate `threshold_mon` in reserve:
    total_mon_collected = threshold_mon / p.reserve_frac
    # Price continuity: collector coins-per-USDC == pool opening coins-per-USDC.
    # => pool_coins = reserve_mon * rate ; collector_coins = total_mon_collected * rate
    # creator_alloc*S + collector_coins + pool_coins = S
    # rate * (total_mon_collected + threshold_mon) = S * (1 - creator_alloc)
    rate = p.supply * (1 - p.creator_alloc) / (total_mon_collected + threshold_mon)
    pool_coins = threshold_mon * rate
    collector_coins = total_mon_collected * rate
    creator_coins = p.creator_alloc * p.supply
    opening_price_mon = threshold_mon / pool_coins      # USDC per coin at pool open
    collector_price_mon = 1.0 / rate                    # USDC per coin a collector effectively pays
    return {
        "threshold_mon": threshold_mon,
        "total_mon_collected": total_mon_collected,
        "rate": rate,
        "pool_coins": pool_coins,
        "collector_coins": collector_coins,
        "creator_coins": creator_coins,
        "opening_price_mon": opening_price_mon,
        "collector_price_mon": collector_price_mon,
        "pool_mon": threshold_mon,
        "fdv_mon": opening_price_mon * p.supply,
    }


def price_impact_sell(pool_coins, pool_mon, coins_in):
    """Constant-product: sell `coins_in` coins into the pool, return (mon_out, pct_price_drop)."""
    k = pool_coins * pool_mon
    new_coins = pool_coins + coins_in
    new_mon = k / new_coins
    mon_out = pool_mon - new_mon
    p0 = pool_mon / pool_coins
    p1 = new_mon / new_coins
    return mon_out, (1 - p1 / p0)


def usd(mon):
    return mon * USDC_USD


def fmt_coins(x):
    if x >= 1e9: return f"{x/1e9:.3f}B"
    if x >= 1e6: return f"{x/1e6:.3f}M"
    if x >= 1e3: return f"{x/1e3:.2f}K"
    return f"{x:.2f}"


# ----------------------------------------------------------------------------- #
# Report
# ----------------------------------------------------------------------------- #

def report(p: Params, collect_prices_usd, label):
    d = derive(p)
    print("=" * 78)
    print(f"SCENARIO: {label}")
    print("=" * 78)
    print(f"  supply S               : {fmt_coins(p.supply)}")
    print(f"  collect $ split        : creator {p.creator_frac:.0%} / platform {p.platform_frac:.0%} / reserve {p.reserve_frac:.0%}")
    print(f"  graduation threshold   : ${p.threshold_usd:,.2f}  ({d['threshold_mon']:,.0f} USDC reserve)")
    print(f"  creator alloc          : {p.creator_alloc:.0%} of supply ({fmt_coins(d['creator_coins'])} coins)")
    print("-" * 78)
    print("  EMERGENT ALLOCATION AT GRADUATION (exact-threshold, no post-grad collects):")
    tot = d['collector_coins'] + d['pool_coins'] + d['creator_coins']
    print(f"    collectors (bundled) : {fmt_coins(d['collector_coins'])}  ({d['collector_coins']/p.supply:.1%})")
    print(f"    pool (locked LP)     : {fmt_coins(d['pool_coins'])}  ({d['pool_coins']/p.supply:.1%})")
    print(f"    creator (vested)     : {fmt_coins(d['creator_coins'])}  ({d['creator_coins']/p.supply:.1%})")
    print(f"    -- sum               : {tot/p.supply:.1%} of supply")
    print("-" * 78)
    print("  PROCEEDS AT GRADUATION:")
    total_usd = usd(d['total_mon_collected'])
    print(f"    total collected      : {d['total_mon_collected']:,.1f} USDC  (${total_usd:,.2f})")
    print(f"    -> creator earns     : ${total_usd * p.creator_frac:,.2f}")
    print(f"    -> platform earns    : ${total_usd * p.platform_frac:,.2f}")
    print(f"    -> pool reserve      : ${total_usd * p.reserve_frac:,.2f}  (= threshold)")
    print("-" * 78)
    print("  POOL AT OPEN:")
    print(f"    reserves             : {d['pool_mon']:,.1f} USDC  +  {fmt_coins(d['pool_coins'])} coins")
    print(f"    opening price        : {d['opening_price_mon']:.3e} USDC/coin  (${usd(d['opening_price_mon']):.3e})")
    print(f"    collector paid price : {d['collector_price_mon']:.3e} USDC/coin  (${usd(d['collector_price_mon']):.3e})")
    jump = d['opening_price_mon'] / d['collector_price_mon'] - 1
    print(f"    collector jump       : {jump:+.2%}   (target ~0% = price continuity)")
    print(f"    coin FDV             : ${usd(d['fdv_mon']):,.2f}")
    print("-" * 78)
    print("  COLLECT GRANULARITY (how the creator's price choice changes holders):")
    for cp in collect_prices_usd:
        cp_mon = cp / USDC_USD
        n_collects = d['total_mon_collected'] / cp_mon
        coins_per_collect = cp_mon * d['rate']
        val_at_open = coins_per_collect * d['opening_price_mon']
        print(f"    ${cp:>5.2f}/collect -> {n_collects:>8,.0f} collects to graduate | "
              f"each gets {fmt_coins(coins_per_collect)} coins (worth ${usd(val_at_open):.3f} at open)")
    print("-" * 78)
    print("  CREATOR GRADUATION-DAY UNLOCK DUMP (the rug-day vector):")
    grad_unlock = 0.20 * d['creator_coins']          # 20% of the bag unlocks at graduation
    monthly = 0.16 * d['creator_coins']              # 16% of alloc per month for 5 months
    mon_out, drop = price_impact_sell(d['pool_coins'], d['pool_mon'], grad_unlock)
    print(f"    grad-day unlock      : {fmt_coins(grad_unlock)} coins ({grad_unlock/p.supply:.2%} of supply, "
          f"{grad_unlock/d['pool_coins']:.1%} of pool coins)")
    print(f"    if dumped at open    : nets {mon_out:,.2f} USDC (${usd(mon_out):,.2f}), price drops {drop:.1%}")
    m_out, m_drop = price_impact_sell(d['pool_coins'], d['pool_mon'], monthly)
    print(f"    each monthly unlock  : {fmt_coins(monthly)} coins -> if dumped, price drops ~{m_drop:.1%}")
    print("-" * 78)
    print("  AVERAGE COLLECTOR EXIT (one $1 collector selling their bundle at open):")
    cp_mon = 1.0 / USDC_USD
    coins_1usd = cp_mon * d['rate']
    mon_out2, drop2 = price_impact_sell(d['pool_coins'], d['pool_mon'], coins_1usd)
    print(f"    $1 collector holds   : {fmt_coins(coins_1usd)} coins")
    print(f"    sells at open        : nets {mon_out2:,.3f} USDC (${usd(mon_out2):.3f}) vs $1 paid, price drops {drop2:.1%}")
    print("-" * 78)
    liquid_float = COLLECTOR_LIQUID_FRAC * d['collector_coins']
    print(f"  LAUNCH-DAY LIQUID FLOAT vs POOL  (collectors {COLLECTOR_LIQUID_FRAC:.0%} liquid at graduation):")
    print(f"    liquid collector float : {fmt_coins(liquid_float)}  ({liquid_float/p.supply:.1%} of supply)")
    print(f"    pool depth (coins)     : {fmt_coins(d['pool_coins'])}  ({d['pool_coins']/p.supply:.1%} of supply)")
    print(f"    liquid float : pool    : {liquid_float/d['pool_coins']:.2f}x  (vs {d['collector_coins']/d['pool_coins']:.2f}x with no collector vesting)")
    _, dr_all = price_impact_sell(d['pool_coins'], d['pool_mon'], liquid_float)
    print(f"    if ALL liquid dump     : price drops {dr_all:.0%}  (absolute worst case, every liquid collector sells)")
    _, dr_10 = price_impact_sell(d['pool_coins'], d['pool_mon'], 0.10 * liquid_float)
    print(f"    if 10% of liquid dump  : price drops {dr_10:.1%}")
    print()


if __name__ == "__main__":
    base = dict(supply=100_000_000, creator_frac=0.20, platform_frac=0.05,
                reserve_frac=0.75, creator_alloc=0.10)

    # 1) The mainnet PLUMBING TEST the user asked for: $10 threshold.
    report(Params(threshold_usd=10, **base),
           collect_prices_usd=[0.10, 1.00, 10.00],
           label="INITIAL LAUNCH — SMALL-CAP VALIDATION  (threshold = $10)")

    # 2) A small-but-real production candidate: $1,000 threshold.
    report(Params(threshold_usd=1_000, **base),
           collect_prices_usd=[0.10, 1.00, 5.00],
           label="PRODUCTION CANDIDATE  (threshold = $1,000)")

    # 3) A serious market: $10,000 threshold.
    report(Params(threshold_usd=10_000, **base),
           collect_prices_usd=[0.10, 1.00, 5.00],
           label="LATER COHORT CANDIDATE  (threshold = $10,000)")

    # 4) Creator-earns sensitivity: how much does the creator make at graduation
    #    as a function of the reserve split? (higher reserve% = deeper pool but less creator $)
    print("=" * 78)
    print("CREATOR EARNINGS AT GRADUATION vs COLLECT SPLIT (threshold = $10,000)")
    print("=" * 78)
    for creator_frac, reserve_frac in [(0.20, 0.70), (0.40, 0.50), (0.60, 0.30), (0.80, 0.10)]:
        p = Params(supply=100_000_000, creator_frac=creator_frac, platform_frac=0.10,
                   reserve_frac=reserve_frac, threshold_usd=10_000, creator_alloc=0.10)
        d = derive(p)
        total_usd = usd(d['total_mon_collected'])
        print(f"  creator {creator_frac:.0%} / reserve {reserve_frac:.0%}: "
              f"total collected ${total_usd:,.0f} | creator gets ${total_usd*creator_frac:,.0f} | "
              f"pool depth {fmt_coins(d['pool_coins'])} coins + {d['pool_mon']:,.0f} USDC")
    print()
