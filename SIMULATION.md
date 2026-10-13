# SIMULATION

`sim/aether_sim.py` is a pure-Python agent-based model of the whole emission span (365 days, 52,560 epochs)
using the contracts' constants. Run `python3 sim/aether_sim.py` (about 30 s); `--quick` runs 90 days.
The committed run (`sim/results.md`, seed 7) is reproduced below in summary. `sim/merkle_tool.py` builds the
airdrop root.

## What is modelled

- The AETHER/IMD pool as one concentrated-liquidity range [P0, 10,000 P0] holding 1,000 AETHER single-sided,
  0.3% LP fee compounded daily, hook fee 99% -> 5% on third-party swaps, game swaps fee-exempt.
- The Reserve schedule (geometric, half-life 120 days) and two alternatives (linear over 180 days, constant
  over 365 days).
- Energies at 0.01 AETHER each with real price impact, batches capped at 500; Shares 60/20/20/0 at random;
  binomial survival per batch; daily Harvest; 10% Tithe; claimers sell 40% of claims.
- Agents: 300 casuals (random machine, ~3 plays/day, $3/day), 40 Earth grinders (play while expected value
  beats the price, $25/day), 60 Air gamblers (chase the Harvest, $8/day), 1 or 3 whales ($2,000/day; in the
  whale scenario they buy 500-energy batches on all four machines for a day and dump 300 AETHER on day 12).
- Noise traders buying/selling on the pool, thinning out as the price runs above a few times the opening.
- Scenarios for IMD/USD: bull (+200% over the year), flat, crash (-80% over the first 30 days), whale attack.
- A launch sniper: 10,000 IMD in epoch 0 at the 99% fee, sold one hour later.

## Results (seed 7, 365 days, P0 = 100 IMD/AETHER, IMD = $0.10)

Emission curve comparison, flat scenario:

| curve | burned | final supply | avg energies/day | max drawdown |
|---|---|---|---|---|
| geometric (chosen) | 2,146 | 7,854 | 522 | 98% |
| linear 180 d | 4,521 | 5,479 | 1,109 | 98% |
| constant 365 d | 1,010 | 8,990 | 251 | 98% |

Scenarios, geometric curve:

| scenario | burned | final supply | LP liquidity growth | IMD left in pool | hook fees to Harvest | tithes |
|---|---|---|---|---|---|---|
| bull | 2,346 | 7,654 | x1.21 | 5.06 M | 321 AETHER | 923 |
| flat | 2,146 | 7,854 | x1.32 | 8.43 M | 319 | 924 |
| crash | 3,038 | 6,962 | x1.26 | 12.6 M | 308 | 757 |
| whale | 1,662 | 8,338 | x1.44 | 14.2 M | 304 | 920 |

Launch sniper: 10,000 IMD bought 0.907 AETHER; 89.8 AETHER went to the Harvest; sold back for 81 IMD.
Whale dump: 300 AETHER sold at once moved the price from 2,576 to 439 IMD and paid 15 AETHER to the Harvest.

Mechanics checked by the model (and by the Foundry tests): every tranche is fully paid or pooled, the Harvest
is emptied every night, the Reserve ends at exactly 0 on epoch 52,559 and the game switches to recycling, the
expected Share per energy is equal across machines while Harvest per energy grows with the fail rate (Air
gamblers' Harvest share is the largest in every run).

## Why these choices

**Emission over 365 days, geometric, half-life 120 days.** The linear 180-day curve burns more early but
empties the Reserve on epoch 25,759 and leaves half a year with recycling only; the constant curve pays so
little per epoch at launch (0.106 AETHER) that early play is thin. The geometric curve pays 0.364 AETHER per
epoch at launch (52 per day), still 6.4 per day on the last day, keeps 1,000+ AETHER of rewards for the
second half of the year, and the last epoch sweeps all rounding dust so the Reserve never leaks.

**Energy = 0.01 AETHER burned.** Pricing in AETHER rather than IMD keeps the energy price tied to the reward
value whatever IMD does, and makes the burn exactly equal to what was paid. At launch about 36 energies per
epoch break even on Shares alone; the Harvest adds the risk premium on top.

**LP range x10,000, single-sided.** A x100 range was tried first: under sustained buying the pool ran out of
AETHER within two months, the price pinned at the top of the range and energies became unbuyable (the
model's day-60 energies went to zero). Widening to x10,000 costs only ~10% of launch depth near P0 (the
liquidity for a given amount of token0 barely depends on the upper bound) and removes the cliff.

**Opening price.** Set at launch via `imdPerAetherWad`; the model uses 100 IMD. The key metric is that the
first hour's sniper nets less than 1% of what they paid, independent of P0.

**Randomness.** Next-block hash after a lock, permissionless, paged settlement. The per-epoch stake (~0.2
AETHER at launch) is far below the cost of withholding a block; see RISKS.md.

**Whale protection.** Price impact plus the 500-energy batch cap: in the whale scenario the whales' return is
the lowest of all agent types in every run, and their dump pays the Harvest.

## Limitations (read before relying on numbers)

- The external market is crude: noise traders with fixed dollar sizes and no valuation model. The price
  therefore drifts upward in every scenario, and drawdowns are mostly intra-run swings against that drift.
  The absolute ROI figures in `sim/results.md` are not forecasts; relative orderings between agent types and
  between curves are the meaningful output.
- Agents do not sybil, do not time the hook fee, and do not reason about other agents' crowding beyond last
  epoch's totals.
- Blocks, gas and keeper lag are not modelled: settlement is assumed instantaneous.
- One seed is committed; run with other seeds to see the variance (`--seed`).
