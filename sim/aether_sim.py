#!/usr/bin/env python3
"""Agent-based simulation of the AETHER game over its whole emission span (365 days, 52,560 epochs).

Pure Python (no dependencies). Run:  python3 sim/aether_sim.py [--days N] [--seed S] [--quick]

Models, with the same constants as the contracts (see SPEC.md):
  * the AETHER/IMD Uniswap v4 pool as one concentrated range [P0, 10000*P0] holding 1,000 AETHER single-sided,
    with the 0.3% LP fee compounded into the range and the 99% -> 5% hook fee on third-party swaps;
  * the Reserve emission schedule (geometric, half-life 120 days, 365 days) and two alternatives for comparison;
  * energies: 1 energy = 0.01 AETHER bought and burned (fee-exempt), batches capped at 500;
  * machines Earth/Water/Fire/Air with fail rates 10/30/60/90 %, Shares 60/20/20/0 assigned at random,
    90/10 tranche split, daily Harvest split equally among the day's fails, 10% Tithe on claims;
  * agent types: casuals, Earth grinders, Air gamblers, whales, plus noise traders and launch snipers;
  * scenarios: bull, flat, crash (-80% IMD over 30 days), whale attack.
"""
import argparse
import math
import random
import sys

EPOCH = 600
EPOCHS_PER_DAY = 144
EMISSION_DAYS = 365
RESERVE = 8000.0
LP_AETHER = 1000.0
ENERGY_UNIT = 0.01
MAX_BATCH = 500
FAIL = [0.10, 0.30, 0.60, 0.90]
MACHINES = ["Earth", "Water", "Fire", "Air"]
SHARE_WEIGHTS = [0.60, 0.20, 0.20, 0.0]
LP_FEE = 0.003
Q_DAILY = 2 ** (-1 / 120)
D0 = RESERVE * (1 - Q_DAILY) / (1 - Q_DAILY ** EMISSION_DAYS)


def tranche(epoch, curve="geometric"):
    day = epoch // EPOCHS_PER_DAY
    if curve == "geometric":
        if day >= EMISSION_DAYS:
            return 0.0
        return D0 * Q_DAILY ** day / EPOCHS_PER_DAY
    if curve == "linear180":
        n = 180 * EPOCHS_PER_DAY
        if epoch >= n:
            return 0.0
        return 2 * RESERVE / n * (1 - epoch / n)
    if curve == "constant365":
        n = EMISSION_DAYS * EPOCHS_PER_DAY
        return RESERVE / n if epoch < n else 0.0
    raise ValueError(curve)


class Pool:
    """One concentrated-liquidity range. price = IMD per AETHER."""

    def __init__(self, p0):
        self.sa = math.sqrt(p0)
        self.sb = math.sqrt(p0 * 10000)
        self.sp = self.sa
        self.L = LP_AETHER / (1 / self.sa - 1 / self.sb)
        self.fee0 = 0.0  # AETHER fees waiting to compound
        self.fee1 = 0.0  # IMD fees waiting to compound
        self.aether_in_pool = LP_AETHER
        self.imd_in_pool = 0.0

    @property
    def price(self):
        return self.sp * self.sp

    def buy(self, imd_in, hook_fee=0.0):
        """Spend IMD, receive AETHER. Returns (aether_to_buyer, aether_to_hook)."""
        if imd_in <= 0:
            return 0.0, 0.0
        lp_fee = imd_in * LP_FEE
        dy = imd_in - lp_fee
        new_sp = min(self.sp + dy / self.L, self.sb)
        used = (new_sp - self.sp) * self.L
        dx = self.L * (1 / self.sp - 1 / new_sp)
        self.sp = new_sp
        self.fee1 += lp_fee * used / dy if dy > 0 else 0
        self.imd_in_pool += used
        self.aether_in_pool -= dx
        fee = dx * hook_fee
        return dx - fee, fee

    def sell(self, aether_in, hook_fee=0.0):
        """Sell AETHER, receive IMD. Hook fee is taken from the input. Returns (imd_out, aether_to_hook)."""
        if aether_in <= 0:
            return 0.0, 0.0
        hook = aether_in * hook_fee
        dx_gross = aether_in - hook
        lp_fee = dx_gross * LP_FEE
        dx = dx_gross - lp_fee
        inv_new = min(1 / self.sp + dx / self.L, 1 / self.sa)
        new_sp = 1 / inv_new
        dy = self.L * (self.sp - new_sp)
        used = (inv_new - 1 / self.sp) * self.L
        self.sp = new_sp
        self.fee0 += lp_fee
        self.aether_in_pool += used
        self.imd_in_pool -= dy
        return dy, hook

    def compound(self):
        x_per_l = max(1 / self.sp - 1 / self.sb, 0)
        y_per_l = max(self.sp - self.sa, 0)
        cands = []
        if x_per_l > 0:
            cands.append(self.fee0 / x_per_l)
        if y_per_l > 0:
            cands.append(self.fee1 / y_per_l)
        if not cands:
            return
        dl = min(cands) if len(cands) == 2 else cands[0]
        if dl <= 0:
            return
        self.L += dl
        self.fee0 -= dl * x_per_l
        self.fee1 -= dl * y_per_l
        self.aether_in_pool += dl * x_per_l
        self.imd_in_pool += dl * y_per_l


class Agent:
    def __init__(self, kind, rng, usd_budget):
        self.kind = kind
        self.rng = rng
        self.usd_spent = 0.0
        self.usd_claimed = 0.0
        self.unclaimed = 0.0
        self.wallet = 0.0  # AETHER held after claims
        self.budget = usd_budget  # USD per day
        self.spent_today = 0.0
        self.energies = 0
        self.fails = 0

    def decide(self, epoch, ctx):
        """Return list of (machine, imd_amount)."""
        rng = self.rng
        imd_usd = ctx["imd_usd"]
        if self.spent_today >= self.budget:
            return []
        ev = ctx["ev_per_energy_imd"]  # expected value of one energy in IMD (last epoch's crowd)
        cost = ctx["energy_cost_imd"]
        if self.kind == "casual":
            if rng.random() < 0.02:
                n = rng.randint(1, 5)
                return [(rng.randrange(4), n * cost)]
            return []
        if self.kind == "grinder":
            # plays Earth every epoch while the expected return beats the price
            if ev >= cost * 1.05:
                n = min(50, int(self.budget * 0.3 / imd_usd / cost) or 1)
                return [(0, n * cost)]
            return []
        if self.kind == "gambler":
            p = 0.10 + 0.20 * ctx["harvest_pull"]
            if rng.random() < p:
                n = rng.randint(2, 15)
                return [(3, n * cost)]
            return []
        if self.kind == "whale":
            if ctx["whale_attack"]:
                return [(m, MAX_BATCH * cost) for m in range(4)]
            if rng.random() < 0.05:
                return [(rng.randrange(4), 200 * cost)]
            return []
        return []


def binom(n, p, rng):
    return rng.binomialvariate(n, p)


def run(scenario, days=EMISSION_DAYS, seed=1, curve="geometric", p0=100.0, imd_usd0=0.1, verbose=False):
    rng = random.Random(seed)
    pool = Pool(p0)
    agents = []
    for i in range(300):
        agents.append(Agent("casual", random.Random(rng.random()), 3.0))
    for i in range(40):
        agents.append(Agent("grinder", random.Random(rng.random()), 25.0))
    for i in range(60):
        agents.append(Agent("gambler", random.Random(rng.random()), 8.0))
    n_whales = 3 if scenario == "whale" else 1
    for i in range(n_whales):
        agents.append(Agent("whale", random.Random(rng.random()), 2000.0))

    reserve = RESERVE
    supply = 10000.0
    burned = 0.0
    recycled_next = 0.0
    harvest_pot = 0.0
    tomorrow_pot = 0.0
    day_fails = 0
    ev = 0.0
    harvest_pull = 0.0
    hook_fees_total = 0.0
    tithes_total = 0.0
    history = []
    sniper_result = None
    whale_attack_days = set(range(10, 11)) if scenario == "whale" else set()
    whale_dump_day = 12 if scenario == "whale" else None
    total_epochs = days * EPOCHS_PER_DAY
    energies_today = 0
    price_path = []
    max_dd = 0.0
    peak = pool.price
    settled_reserve_empty_epoch = None

    for epoch in range(total_epochs):
        day = epoch // EPOCHS_PER_DAY
        t_min = epoch * 10
        hook_fee = max(0.05, (99 - t_min) / 100) if t_min < 94 else 0.05
        # IMD/USD path
        if scenario == "bull":
            imd_usd = imd_usd0 * (1 + 2.0 * day / EMISSION_DAYS)
        elif scenario == "crash":
            imd_usd = imd_usd0 * (1 - 0.8 * min(day, 30) / 30)
        else:
            imd_usd = imd_usd0
        cost = ENERGY_UNIT * pool.price  # IMD per energy at spot (before impact)
        ctx = {
            "imd_usd": imd_usd,
            "ev_per_energy_imd": ev,
            "energy_cost_imd": cost,
            "harvest_pull": harvest_pull,
            "whale_attack": day in whale_attack_days,
        }
        # launch sniper: 10,000 IMD buy in the first epoch, sold back one hour later
        if epoch == 0:
            got, fee = pool.buy(10_000.0, hook_fee)
            harvest_pot += fee
            hook_fees_total += fee
            sniper_result = {"spent_imd": 10_000.0, "got_aether": got, "fee_to_harvest": fee}
        if epoch == 6 and sniper_result and "sold_for" not in sniper_result:
            imd_out, fee = pool.sell(sniper_result["got_aether"], hook_fee)
            harvest_pot += fee
            hook_fees_total += fee
            sniper_result["sold_for"] = imd_out
        # noise traders (third-party buys/sells on the pool)
        sentiment = {"bull": 0.6, "flat": 0.5, "crash": 0.35, "whale": 0.5}[scenario]
        if rng.random() < 0.3:
            amt_usd = rng.uniform(5, 80)
            # buyers thin out as the price runs above a few times the opening price (value-sensitive flow)
            if rng.random() < sentiment * min(1.0, 3 * p0 / pool.price):
                got, fee = pool.buy(amt_usd / imd_usd, hook_fee)
                harvest_pot += fee
                hook_fees_total += fee
                noise_holdings = got
            else:
                sell_amt = min(amt_usd / imd_usd / pool.price, (supply - pool.aether_in_pool - reserve) * 0.001)
                if sell_amt > 0:
                    _, fee = pool.sell(sell_amt, hook_fee)
                    harvest_pot += fee
                    hook_fees_total += fee
        # whale dump: sells 300 AETHER in one go
        if whale_dump_day is not None and epoch == whale_dump_day * EPOCHS_PER_DAY:
            before = pool.price
            imd_out, fee = pool.sell(300.0, hook_fee)
            harvest_pot += fee
            hook_fees_total += fee
            dump = {"price_before": before, "price_after": pool.price, "imd_out": imd_out, "fee": fee}
        # energies
        batches = []
        tranche_now = tranche(epoch, curve)
        recycling = reserve <= 1e-12
        for a in agents:
            for machine, imd_amt in a.decide(epoch, ctx):
                imd_amt = min(imd_amt, (a.budget - a.spent_today) / imd_usd)
                if imd_amt <= 0:
                    continue
                got, _ = pool.buy(imd_amt, 0.0)  # game is fee-exempt
                n = int(got / ENERGY_UNIT)
                if n == 0:
                    continue
                n = min(n, MAX_BATCH)
                if recycling:
                    recycled_next += got
                else:
                    burned += got
                    supply -= got
                a.usd_spent += imd_amt * imd_usd
                a.spent_today += imd_amt * imd_usd
                a.energies += n
                batches.append((a, machine, n))
                energies_today += n
        # settlement
        t = tranche_now
        if t > reserve:
            t = reserve
        reserve -= t
        if reserve <= 1e-12 and settled_reserve_empty_epoch is None:
            settled_reserve_empty_epoch = epoch
        t += recycled_next if recycling else 0.0
        if recycling:
            recycled_next = 0.0
        to_shares = t * 0.9
        harvest_pot += t - to_shares
        perm = [0, 1, 2, 3]
        rng.shuffle(perm)
        share = [0.0] * 4
        for i, m in enumerate(perm):
            share[m] = to_shares * SHARE_WEIGHTS[i]
        surv = [0] * 4
        drawn = []
        for a, m, n in batches:
            s = binom(n, 1 - FAIL[m], rng)
            surv[m] += s
            drawn.append((a, m, n, s))
            day_fails += n - s
            a.fails += n - s
        for m in range(4):
            if surv[m] == 0:
                harvest_pot += share[m]
        total_energy = sum(n for _, _, n, _ in drawn)
        paid_shares = 0.0
        for a, m, n, s in drawn:
            if surv[m] > 0:
                pay = share[m] * s / surv[m]
                a.unclaimed += pay
                paid_shares += pay
        # expected value of one more energy next epoch, in IMD (shares part + harvest part estimate)
        if total_energy > 0:
            ev = (to_shares / total_energy + (harvest_pot / max(day_fails, 1)) * 0.5) * pool.price
        else:
            ev = (to_shares + 0.1 * t) * pool.price
        # day end
        if epoch % EPOCHS_PER_DAY == EPOCHS_PER_DAY - 1:
            hpf = harvest_pot / day_fails if day_fails > 0 else 0.0
            if day_fails > 0:
                for a in agents:
                    pass  # paid below per agent's fails of the day
                for a in agents:
                    a.unclaimed += a.fails * hpf
                    a.fails = 0
                harvest_pot = 0.0
            harvest_pull = min(1.0, hpf / ENERGY_UNIT * 10) if hpf > 0 else 0.0
            # claims: each agent claims with 50% prob, sells 40% of what it gets
            for a in agents:
                if a.unclaimed > 0 and a.rng.random() < 0.5:
                    amt = a.unclaimed
                    a.unclaimed = 0.0
                    tithe = amt * 0.10
                    tomorrow_pot += tithe
                    tithes_total += tithe
                    got = amt - tithe
                    sell = got * 0.4
                    imd_out, fee = pool.sell(sell, hook_fee)
                    harvest_pot += fee
                    hook_fees_total += fee
                    a.usd_claimed += imd_out * imd_usd + (got - sell) * pool.price * imd_usd
                    a.wallet += got - sell
                a.spent_today = 0.0
            harvest_pot += tomorrow_pot
            tomorrow_pot = 0.0
            pool.compound()
            peak = max(peak, pool.price)
            max_dd = max(max_dd, 1 - pool.price / peak)
            history.append(
                {
                    "day": day,
                    "price": pool.price,
                    "supply": supply,
                    "reserve": reserve,
                    "energies": energies_today,
                    "fails": day_fails,
                    "hpf": hpf,
                    "L": pool.L,
                    "imd_in_pool": pool.imd_in_pool,
                    "aether_in_pool": pool.aether_in_pool,
                }
            )
            energies_today = 0
            day_fails = 0
    roi = {}
    for kind in ["casual", "grinder", "gambler", "whale"]:
        ks = [a for a in agents if a.kind == kind]
        spent = sum(a.usd_spent for a in ks)
        back = sum(a.usd_claimed + (a.unclaimed + a.wallet) * pool.price * imd_usd for a in ks)
        roi[kind] = (spent, back, (back / spent - 1) if spent > 0 else 0.0)
    out = {
        "scenario": scenario,
        "curve": curve,
        "final_price": pool.price,
        "peak_price": peak,
        "max_drawdown": max_dd,
        "supply": supply,
        "burned": burned,
        "reserve": reserve,
        "reserve_empty_epoch": settled_reserve_empty_epoch,
        "L_growth": pool.L / (LP_AETHER / (1 / math.sqrt(p0) - 1 / math.sqrt(p0 * 10000))),
        "imd_in_pool": pool.imd_in_pool,
        "hook_fees": hook_fees_total,
        "tithes": tithes_total,
        "roi": roi,
        "sniper": sniper_result,
        "avg_energies_day": sum(h["energies"] for h in history) / len(history),
        "history": history,
    }
    if scenario == "whale":
        out["dump"] = dump
    return out


def fmt(x, d=2):
    return f"{x:,.{d}f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=EMISSION_DAYS)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--quick", action="store_true", help="90 days only")
    args = ap.parse_args()
    days = 90 if args.quick else args.days
    print(f"# AETHER simulation: {days} days, seed {args.seed}\n")
    print("## Emission curve comparison (flat scenario)\n")
    print("| curve | burned | final supply | reserve empty (epoch) | final price (IMD) | max drawdown | avg energies/day | casual ROI | grinder ROI | gambler ROI |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for curve in ["geometric", "linear180", "constant365"]:
        r = run("flat", days, args.seed, curve)
        print(
            f"| {curve} | {fmt(r['burned'])} | {fmt(r['supply'])} | {r['reserve_empty_epoch']} | {fmt(r['final_price'])} | "
            f"{fmt(r['max_drawdown']*100,1)}% | {fmt(r['avg_energies_day'],0)} | {fmt(r['roi']['casual'][2]*100,1)}% | "
            f"{fmt(r['roi']['grinder'][2]*100,1)}% | {fmt(r['roi']['gambler'][2]*100,1)}% |"
        )
    print("\n## Scenarios (geometric curve)\n")
    print("| scenario | burned | final supply | final price (IMD) | peak | max drawdown | LP liquidity x | IMD in pool | hook fees (AETHER) | tithes | avg energies/day | casual ROI | grinder ROI | gambler ROI | whale ROI |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    results = {}
    for sc in ["bull", "flat", "crash", "whale"]:
        r = run(sc, days, args.seed)
        results[sc] = r
        print(
            f"| {sc} | {fmt(r['burned'])} | {fmt(r['supply'])} | {fmt(r['final_price'])} | {fmt(r['peak_price'])} | "
            f"{fmt(r['max_drawdown']*100,1)}% | {fmt(r['L_growth'],3)} | {fmt(r['imd_in_pool'],0)} | {fmt(r['hook_fees'])} | "
            f"{fmt(r['tithes'])} | {fmt(r['avg_energies_day'],0)} | {fmt(r['roi']['casual'][2]*100,1)}% | "
            f"{fmt(r['roi']['grinder'][2]*100,1)}% | {fmt(r['roi']['gambler'][2]*100,1)}% | {fmt(r['roi']['whale'][2]*100,1)}% |"
        )
    s = results["flat"]["sniper"]
    print("\n## Launch sniper (10,000 IMD in epoch 0 at 99% fee, sold one hour later)\n")
    print(f"- spent {fmt(s['spent_imd'])} IMD, received {fmt(s['got_aether'],4)} AETHER, {fmt(s['fee_to_harvest'],4)} AETHER went to the Harvest, sold back for {fmt(s['sold_for'])} IMD")
    d = results["whale"]["dump"]
    print("\n## Whale dump (300 AETHER sold at once on day 12)\n")
    print(f"- price {fmt(d['price_before'])} -> {fmt(d['price_after'])} IMD, whale received {fmt(d['imd_out'])} IMD, {fmt(d['fee'],2)} AETHER fee to the Harvest")
    print("\n## Flat scenario, day by day (every 30 days)\n")
    print("| day | price | supply | reserve | energies | fails | harvest/fail | IMD in pool |")
    print("|---|---|---|---|---|---|---|---|")
    for h in results["flat"]["history"]:
        if h["day"] % 30 == 0 or h["day"] == days - 1:
            print(f"| {h['day']} | {fmt(h['price'])} | {fmt(h['supply'])} | {fmt(h['reserve'])} | {h['energies']} | {h['fails']} | {fmt(h['hpf'],5)} | {fmt(h['imd_in_pool'],0)} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
