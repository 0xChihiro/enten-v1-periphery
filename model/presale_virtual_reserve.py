#!/usr/bin/env python3
"""
Model of the PresaleAuction virtual-liquidity-reserve mechanism.

Mirrors the EXACT integer math of src/policies/PresaleAuction.sol so the numbers
here match on-chain behaviour:

  - minimumPrice()  -> floor() below            (fee-grossed backing-per-token)
  - _premium()      -> premium_at() below       (linear Dutch-auction time decay)
  - _premiumQuote() -> _premium_quote() below   (constant-product AMM on the premium)
  - Dispatch._setPaymentCalls -> backing accrual in buy() below

Price paid per token = floor  +  premium-AMM marginal price.
VIRTUAL_TOKEN_RESERVE only ever enters the *premium* leg, via the reserve
  R = VIRTUAL_TOKEN_RESERVE + remaining
which is the constant-product token reserve that buys swap against.

Closed form (derived from _premiumQuote, all on the premium leg):
  Let R = VIRTUAL_TOKEN_RESERVE + remaining, dx = amount bought.
    marginal premium after buy : premium * (R / (R - dx))**2
    average premium price paid  : premium * (R / (R - dx))
So VIRTUAL_TOKEN_RESERVE sets the DEPTH: bigger reserve -> flatter curve ->
less price impact per token. Because `remaining` is part of R, the pool gets
THINNER as it sells down: the same clip size costs more slippage later.
"""

WAD = 10**18
BPS = 10_000
AUCTION_FEE_BPS = 250          # Dispatch.AUCTION_FEE_BPS (protocol fee, off the top)
TEAM_BPS = 0                   # TEAM_PERCENTAGE_SLOT  (set by deploy script)
TREASURY_BPS = 750             # TREASURY_PERCENTAGE_SLOT (set by deploy script)
BACKING_BPS = BPS - TEAM_BPS - TREASURY_BPS    # 9250 residual -> backing
POST_PROTOCOL_BPS = BPS - AUCTION_FEE_BPS      # 9750

# ---- launch constants (script/DeployPeriphery.s.sol) ----
PRESALE_SIZE = 1_000_000 * WAD
START_PRICE = 1 * WAD
VIRTUAL_TOKEN_RESERVE = 200_000 * WAD
DURATION = 5 * 24 * 3600
MIN_BID = 100 * WAD

# Assumed core state at open() (production-unknown; sweep below shows sensitivity).
GENESIS_PREMINE = 1_000 * WAD   # small unlocked genesis seed (shape A)
BACKING_SEED = 0.1 * WAD        # BACKING_SEED_AMOUNT


def cdiv(a, b):                       # ceil division
    return -(-a // b)


def muldiv_ceil(a, b, c):             # Math.mulDiv(_,_,_, Ceil)
    return cdiv(a * b, c)


def muldiv_floor(a, b, c):            # Math.mulDiv(_,_,_, Floor)
    return (a * b) // c


def gross_up(x):                      # _grossUpForFees
    req = muldiv_ceil(x, BPS, BACKING_BPS)
    return muldiv_ceil(req, BPS, POST_PROTOCOL_BPS)


class Presale:
    def __init__(self, genesis=GENESIS_PREMINE, backing_seed=BACKING_SEED,
                 virtual=VIRTUAL_TOKEN_RESERVE, start_price=START_PRICE,
                 presale_size=PRESALE_SIZE):
        self.supply = int(genesis)         # effectiveSupply
        self.backing = int(backing_seed)   # totalBacking of ASSET
        self.virtual = int(virtual)
        self.start_price = int(start_price)
        self.presale_size = int(presale_size)
        self.remaining = int(presale_size)
        self.sold = 0
        self.premium = 0                   # currentPremium
        self.premium_initialized = False
        self.last_update = 0               # seconds since open
        self.total_committed = 0

    # minimumPrice()
    def floor(self):
        bpt = muldiv_floor(self.backing, WAD, self.supply)
        return gross_up(bpt + 1)

    # _premium(minimum)
    def premium_at(self, t, minimum):
        if self.premium_initialized:
            anchor = self.premium
        else:
            anchor = self.start_price - minimum if self.start_price > minimum else 0
        elapsed = t - self.last_update
        if elapsed >= DURATION:
            return 0
        return anchor - muldiv_floor(anchor, elapsed, DURATION)

    # _premiumQuote(amount, premium)
    def _premium_quote(self, amount, premium):
        if premium == 0:
            return 0, 0
        token_reserve = self.virtual + self.remaining
        next_reserve = token_reserve - amount
        quote_reserve = muldiv_ceil(premium, token_reserve, WAD)
        premium_payment = muldiv_ceil(quote_reserve, amount, next_reserve)
        next_premium = muldiv_ceil(quote_reserve + premium_payment, WAD, next_reserve)
        return premium_payment, next_premium

    # quote(amount)
    def quote(self, amount, t):
        minimum = self.floor()
        premium = self.premium_at(t, minimum)
        prem_payment, prem_after = self._premium_quote(amount, premium)
        payment = muldiv_ceil(amount, minimum, WAD) + prem_payment
        spot = minimum + premium
        return payment, spot, prem_after, minimum, premium

    # _buy(amount) + Dispatch settlement
    def buy(self, amount, t):
        amount = int(amount)
        payment, spot, next_premium, minimum, premium = self.quote(amount, t)
        self.remaining -= amount
        self.sold += amount
        self.premium = next_premium
        self.premium_initialized = True
        self.last_update = t
        self.total_committed += payment
        # backing accrual (Dispatch._setPaymentCalls)
        protocol = cdiv(payment * AUCTION_FEE_BPS, BPS)
        net = payment - protocol
        team = net * TEAM_BPS // BPS
        treasury = net * TREASURY_BPS // BPS
        backing_add = net - team - treasury
        self.backing += backing_add
        self.supply += amount
        avg_price = muldiv_ceil(payment, WAD, amount) if amount else 0
        return dict(payment=payment, spot=spot, minimum=minimum, premium=premium,
                    next_premium=next_premium, avg_price=avg_price)


def f(wei, dp=4):
    return f"{wei / WAD:,.{dp}f}"


# ---------------------------------------------------------------------------
# 1. PRICE-IMPACT CURVE: a single buy off a fresh open (premium ~= START_PRICE)
# ---------------------------------------------------------------------------
def section_1():
    print("=" * 88)
    print("1. SINGLE-BUY PRICE IMPACT AT OPEN  (premium starts at ~START_PRICE = 1.0 mega)")
    print("   R = VIRTUAL_TOKEN_RESERVE + remaining =", f(VIRTUAL_TOKEN_RESERVE + PRESALE_SIZE, 0),
          "tokens at open")
    print("=" * 88)
    print(f"{'buy (tok)':>12} {'% of size':>9} {'avg price':>11} {'spot before':>12} "
          f"{'premium after':>14} {'impact x':>9} {'paid (mega)':>14}")
    for amt_h in (1_000, 10_000, 50_000, 100_000, 200_000, 500_000, 1_000_000):
        p = Presale()
        amt = amt_h * WAD
        r = p.buy(amt, t=0)
        impact = r['next_premium'] / r['premium'] if r['premium'] else 0
        print(f"{amt_h:>12,} {amt/PRESALE_SIZE*100:>8.1f}% {f(r['avg_price']):>11} "
              f"{f(r['spot']):>12} {f(r['next_premium']):>14} {impact:>8.2f}x "
              f"{f(r['payment'],0):>14}")
    print("   note: 'impact x' should equal (R/(R-dx))^2  ->  closed-form check below")
    R = (VIRTUAL_TOKEN_RESERVE + PRESALE_SIZE) / WAD
    for amt_h in (100_000, 500_000, 1_000_000):
        cf = (R / (R - amt_h)) ** 2
        print(f"      dx={amt_h:>9,}: (R/(R-dx))^2 = {cf:.2f}x")


# ---------------------------------------------------------------------------
# 2. SENSITIVITY TO VIRTUAL_TOKEN_RESERVE: fix the buy, vary the reserve
# ---------------------------------------------------------------------------
def section_2():
    print()
    print("=" * 88)
    print("2. SENSITIVITY TO VIRTUAL_TOKEN_RESERVE  (one 100k-token buy at open, 10% of size)")
    print("=" * 88)
    print(f"{'virtual (tok)':>14} {'R=virt+rem':>12} {'avg price':>11} "
          f"{'premium after':>14} {'impact x':>9} {'paid (mega)':>14}")
    for virt_h in (50_000, 100_000, 200_000, 400_000, 1_000_000, 2_000_000):
        p = Presale(virtual=virt_h * WAD)
        r = p.buy(100_000 * WAD, t=0)
        impact = r['next_premium'] / r['premium'] if r['premium'] else 0
        R = (virt_h * WAD + PRESALE_SIZE)
        print(f"{virt_h:>14,} {f(R,0):>12} {f(r['avg_price']):>11} "
              f"{f(r['next_premium']):>14} {impact:>8.2f}x {f(r['payment'],0):>14}")
    print("   smaller reserve -> steeper curve -> more slippage / higher raise per token,")
    print("   but easier to spike the premium; larger reserve -> closer to a flat fixed price.")


# ---------------------------------------------------------------------------
# 3. DEPTH DECAY: same clip size at different sell-through points (no time decay)
# ---------------------------------------------------------------------------
def section_3():
    print()
    print("=" * 88)
    print("3. DEPTH DECAYS AS THE BOOK SELLS DOWN  (100k-token clip, premium held at 1.0)")
    print("   demonstrates that R shrinks with `remaining`, so late clips slip more")
    print("=" * 88)
    print(f"{'remaining':>12} {'R':>12} {'impact x for 100k clip':>24} {'avg price':>11}")
    for sold_h in (0, 200_000, 400_000, 600_000, 800_000, 900_000):
        p = Presale()
        # fast-forward sold tokens without time decay by buying instantly at t=0
        if sold_h:
            p.buy(sold_h * WAD, t=0)
        # reset premium to a clean 1.0 to isolate the depth effect
        p.premium_initialized = True
        p.premium = WAD
        rem = p.remaining
        clip = min(100_000 * WAD, rem)
        r = p.buy(clip, t=0)
        impact = r['next_premium'] / r['premium'] if r['premium'] else 0
        R = p.virtual + rem
        print(f"{f(rem,0):>12} {f(R,0):>12} {impact:>22.2f}x {f(r['avg_price']):>11}")


# ---------------------------------------------------------------------------
# 4. FULL AUCTION TRAJECTORY: steady demand + time decay over the 5 days
# ---------------------------------------------------------------------------
def section_4():
    print()
    print("=" * 88)
    print("4. FULL 5-DAY TRAJECTORY  (a 50k-token clip bought every 4 hours, with decay)")
    print("=" * 88)
    print(f"{'hour':>6} {'remaining':>11} {'floor':>9} {'premium':>9} {'spot':>9} "
          f"{'avg paid':>9} {'cum raised':>13}")
    p = Presale()
    clip = 50_000 * WAD
    t = 0
    step = 4 * 3600
    hour = 0
    while p.remaining >= clip and t < DURATION:
        r = p.buy(clip, t)
        if hour % 12 == 0 or p.remaining < clip:   # print every 12h
            print(f"{hour:>6} {f(p.remaining,0):>11} {f(r['minimum']):>9} "
                  f"{f(r['premium']):>9} {f(r['spot']):>9} {f(r['avg_price']):>9} "
                  f"{f(p.total_committed,0):>13}")
        t += step
        hour += 4
    print(f"   sold {f(p.sold,0)} tokens, raised {f(p.total_committed,0)} mega, "
          f"final floor {f(p.floor())} mega/token")
    print("   premium decays between clips and is bumped up by each buy; floor rises as")
    print("   backing accrues faster than supply.")


# ---------------------------------------------------------------------------
# 5. FLOOR FEEDBACK vs GENESIS PREMINE: how big is the floor really?
# ---------------------------------------------------------------------------
def section_5():
    print()
    print("=" * 88)
    print("5. FLOOR SENSITIVITY TO GENESIS PREMINE  (floor at open, before any buys)")
    print("=" * 88)
    print(f"{'genesis (tok)':>14} {'floor at open (mega/token)':>28} {'premium headroom':>18}")
    for g_h in (100, 1_000, 10_000, 100_000):
        p = Presale(genesis=g_h * WAD)
        fl = p.floor()
        head = START_PRICE - fl
        print(f"{g_h:>14,} {f(fl, 8):>28} {f(head):>18}")
    print("   START_PRICE (1.0) must exceed the floor for open() to succeed; with the")
    print("   0.1-mega seed the floor is tiny for any reasonable genesis, so premium ~ 1.0.")


if __name__ == "__main__":
    section_1()
    section_2()
    section_3()
    section_4()
    section_5()
