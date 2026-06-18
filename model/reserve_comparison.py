#!/usr/bin/env python3
"""
Compare VIRTUAL_TOKEN_RESERVE in {200k, 250k, 500k, 1M} for the trade-off between
buyer slippage and protocol raise/backing.

Two complementary views:

  VIEW A  - pure slippage profile (demand-independent): the price impact of a
            standard clip at different sell-through points, plus full-sweep cost.
            Smaller reserve = steeper = worse slippage. No demand assumption.

  VIEW B  - realized raise under PRICE-SENSITIVE demand: rational buyers fill up
            to a willingness-to-pay cap each hour; the premium decays between
            rounds and the floor rises as backing accrues. This is where an
            optimum exists - too steep stalls the sale, too flat under-prices.

Reuses the exact integer-math model in presale_virtual_reserve.py.
"""

import copy
from presale_virtual_reserve import (
    Presale, WAD, PRESALE_SIZE, MIN_BID, DURATION, START_PRICE, f,
)

RESERVES = [200_000, 250_000, 500_000, 750_000, 1_000_000]


# ---------------------------------------------------------------------------
# VIEW A: slippage profile (premium pinned at 1.0 to isolate the depth effect)
# ---------------------------------------------------------------------------
def view_a():
    print("=" * 90)
    print("VIEW A - SLIPPAGE PROFILE  (50k-token clip, premium held at 1.0, by sell-through)")
    print("        value = price-impact multiplier on the premium for that clip")
    print("=" * 90)
    sell_through = [0, 250_000, 500_000, 750_000, 900_000]
    header = f"{'reserve':>10} | " + " | ".join(f"{int(s/1000)}k sold".rjust(9) for s in sell_through) + " | sweep@open"
    print(header)
    print("-" * len(header))
    for virt_h in RESERVES:
        cells = []
        for s in sell_through:
            p = Presale(virtual=virt_h * WAD)
            if s:
                p.buy(s * WAD, t=0)
            p.premium_initialized = True
            p.premium = WAD
            clip = min(50_000 * WAD, p.remaining)
            r = p.buy(clip, t=0)
            impact = r['next_premium'] / r['premium']
            cells.append(f"{impact:>8.2f}x")
        # full sweep from open
        p = Presale(virtual=virt_h * WAD)
        r = p.buy(PRESALE_SIZE, t=0)
        sweep = r['next_premium'] / r['premium']
        print(f"{virt_h:>10,} | " + " | ".join(cells) + f" | {sweep:>8.1f}x")
    print("  lower = flatter/safer for buyers. Note how the gap widens late in the book.")


# ---------------------------------------------------------------------------
# VIEW B: price-sensitive demand. Buyers fill to a willingness-to-pay cap.
# ---------------------------------------------------------------------------
def max_clip_to_cap(p, t, cap):
    """Largest amount whose post-buy marginal spot price stays <= cap (binary search)."""
    if p.remaining == 0:
        return 0
    # price floor() alone already over cap -> nothing can clear
    if p.floor() >= cap:
        return 0

    def spot_after(amount):
        q = copy.deepcopy(p)
        q.buy(amount, t)
        # marginal spot right after the buy: floor + currentPremium (elapsed 0)
        return q.floor() + q.premium_at(t, q.floor())

    if spot_after(p.remaining) <= cap:
        return p.remaining
    lo, hi = 0, p.remaining
    while hi - lo > WAD // 1000:          # ~0.001-token resolution
        mid = (lo + hi) // 2
        if spot_after(mid) <= cap:
            lo = mid
        else:
            hi = mid
    return lo


def simulate_demand(virt_h, cap_h, clip_interval_hours=1):
    cap = cap_h * WAD
    p = Presale(virtual=virt_h * WAD)
    t = 0
    step = clip_interval_hours * 3600
    worst_impact = 1.0
    sellout_hour = None
    while t < DURATION and p.remaining > 0:
        amt = max_clip_to_cap(p, t, cap)
        # enforce MIN_BID unless it's the dust tail
        if amt < MIN_BID and amt != p.remaining:
            amt = 0
        if amt > 0:
            before = p.premium_at(t, p.floor()) or 1
            r = p.buy(amt, t)
            if r['premium']:
                worst_impact = max(worst_impact, r['next_premium'] / r['premium'])
            if p.remaining == 0 and sellout_hour is None:
                sellout_hour = t // 3600
        t += step
    sold_pct = p.sold / PRESALE_SIZE * 100
    avg_price = (p.total_committed * WAD // p.sold) if p.sold else 0
    return dict(
        reserve=virt_h, cap=cap_h, sold=p.sold, sold_pct=sold_pct,
        raised=p.total_committed, backing=p.backing, avg_price=avg_price,
        final_floor=p.floor(), worst_impact=worst_impact, sellout_hour=sellout_hour,
    )


def view_b():
    print()
    print("=" * 90)
    print("VIEW B - REALIZED RAISE UNDER PRICE-SENSITIVE DEMAND")
    print("        buyers fill hourly up to a willingness-to-pay cap; premium decays, floor rises")
    print("=" * 90)
    best = {}
    for cap_h in (2, 3, 4, 5, 6, 8):
        print(f"\n  demand cap = {cap_h}.0 mega/token  "
              f"(buyers refuse to pay above {cap_h}x the opening price)")
        print(f"  {'reserve':>10} {'sold':>9} {'% book':>7} {'raised':>12} "
              f"{'backing':>12} {'avg price':>10} {'worst clip':>11} {'sellout':>9}")
        rows = []
        for virt_h in RESERVES:
            r = simulate_demand(virt_h, cap_h)
            rows.append(r)
            so = f"{int(r['sellout_hour'])}h" if r['sellout_hour'] is not None else "no"
            print(f"  {virt_h:>10,} {f(r['sold'],0):>9} {r['sold_pct']:>6.1f}% "
                  f"{f(r['raised'],0):>12} {f(r['backing'],0):>12} "
                  f"{f(r['avg_price']):>10} {r['worst_impact']:>9.2f}x {so:>9}")
        best[cap_h] = max(rows, key=lambda r: r['raised'])
    print("\n  raised = total mega committed; backing = mega actually credited to the token's"
          "\n  backing (~90% of raised). worst clip = largest single-buy premium impact seen.")

    print()
    print("=" * 90)
    print("REVENUE-MAXIMIZING RESERVE PER DEMAND LEVEL")
    print("=" * 90)
    print(f"  {'demand cap':>11} {'best reserve':>13} {'raised':>12} {'% book sold':>12} {'sold out?':>10}")
    for cap_h, r in best.items():
        so = "yes" if r['sellout_hour'] is not None else "no"
        print(f"  {cap_h:>9}.0 {r['reserve']:>13,} {f(r['raised'],0):>12} "
              f"{r['sold_pct']:>11.1f}% {so:>10}")


if __name__ == "__main__":
    view_a()
    view_b()
