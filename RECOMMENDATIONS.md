# AETHER: mechanics, sustainability and price support

My recommendation is to make AETHER interesting to play even when its price is flat: add strategic
choices, keep every reward fully funded, and treat token burns as a measured cost of play. Increasing
burns or restricting sellers does not create an enduring economy by itself.

The existing design has a distinctive loop: four machines, a second chance through Harvest, permanent
liquidity, a finite 8,000-token Reserve and no continuing mint. Its weaknesses are dependence on demand,
limited control over outcomes, a high transaction burden, and unsuitable randomness for valuable play.

## 1. Add a sealed-choice strategy mode — implemented

`AetherStrategy` is a companion using the same token. Players commit to Earth, Water, Fire or Air before
revealing their choices. Each machine receives one quarter of the funded pot; fewer tickets on a
machine means more payout per ticket. Players predict the crowd, diversify, or deliberately take a
contrarian position. There are no random deaths in this mode.

This introduces a clear strategic decision without increasing issuance or depending on a randomness
provider. Commitments prevent players from simply copying already revealed choices at the last moment.
The hash binds chain, contract, round, player, ticket count and secret. Reveals can be relayed, and
failure to reveal cannot hold settlement hostage. Payouts use paid ticket weight, so adding wallets
alone produces no bonus.

The implementation deliberately uses four fixed pools rather than a winner-takes-all minority prize.
Its incentives are easier to explain: hiding a ticket does not transfer its machine's prize to another
machine. Predicting the least crowded machine still matters. The tradeoffs are a second transaction,
secret management, losses on missed reveals, and disproportionate losses when some machines are empty.
It is not whale-proof; a wealthy player can buy tickets across all machines.

See [STRATEGY.md](STRATEGY.md) for complete rules and the offline commitment tool. The legacy game's
contracts and economics remain unchanged. There is no token replacement or re-mint.

## 2. Budget rewards from actual funds — implemented in the companion

Each 0.01-AETHER ticket burns 0.0005 and escrows 0.0095 for prizes. Previously unallocated pools and
optional sponsor deposits supply the rest. Every finalized claim is backed immediately and remains
independent of future deposits. There is no Reserve subsidy, APY, reward debt or emergency mint.

This achieves accounting sustainability, not perpetual profit for players. With balanced play and no
sponsorship or prior carryover, aggregate payouts are 95% of entry payments before gas. An uneven
allocation lets some players win at others' expense. Additional returns consume real sponsor money or
earlier carryover. Sponsors stop paying, the extra reward stops too.

The [exact-integer scenarios](sim/strategy_results.md) show:

| Scenario | Economic result |
|---|---|
| 400 tickets evenly distributed | 4 AETHER entered, 0.2 burned, 3.8 paid |
| Same tickets distributed 300/50/30/20 | Per-ticket payouts approximately 0.00317/0.019/0.03167/0.0475 AETHER |
| One player covers all four machines | Recovers 95% before gas without prior funding; cannot self-farm a profit |
| One ticket on only one machine | Recovers 23.75%; the other three machine pools roll forward |
| Nobody reveals | Zero payouts; the unburned pot rolls; finalization still succeeds |
| New participation disappears | No new entry burns or entry rewards; existing claims remain funded |

For the original game, preserve the disclosed declining Reserve schedule. Changing the schedule would
change a prior commitment and is not necessary for this companion. A future seasonal experience should
use explicit finite budgets and return unused allocations predictably, rather than restarting emissions.

## 3. Build demand and measure price support honestly

The companion creates another use for existing AETHER and permanently burns 5% of ticket spending.
For `N` tickets, the additional burn is exactly `0.0005*N` AETHER. Its other 95% is recycled value, not
a permanent supply reduction. Unlike the existing IMD entry route, this module does not execute a DEX
buy: players can spend tokens they already own. Increased buying demand is a possible user response,
not an on-chain guarantee.

I would prioritize repeat enjoyment, optional cosmetic achievements, public season history and
externally sponsored tournaments. These are future product recommendations, not delivered features.
Keep cosmetics outside the reward weights so they do not turn into compounding financial advantages.
Avoid rewarding wash volume, referrals or wallet counts with redeemable tokens.

If genuine external revenue eventually supports buybacks, restrict them to an explicit portion of
realized net revenue after operating expenses, with executable liquidity checks, slippage limits and
public accounting. That is a future proposal; no treasury, revenue, buyback contract, router or oracle
is invented in this assignment. Do not use players' claim backing or borrow against the token to buy it.

Permanent LP custody reduces withdrawal risk, but a finite concentrated-liquidity range does not
guarantee executable exits at every price. Uniswap documents that liquidity becomes inactive outside
its range. The project's x10,000 range moves its boundary further away; it does not eliminate it.
[Uniswap concentrated liquidity](https://developers.uniswap.org/docs/get-started/concepts/liquidity-providers/concentrated-liquidity)

Track depth and slippage in both directions, repeat players after rewards decline, burns versus tokens
released into circulation, net external revenue, and IMD exposure. Never equate lower supply, locked
liquidity or internal volume with a guaranteed rising price. The existing simulation already reports
98% maximum drawdown and admits a modeled upward price drift; that is not evidence of a price floor.

## 4. Correct the original fairness and randomness story before promotion

Equal expected machine allocations are not equal returns per energy. Under ideal independent draws,
with `n` entries on a machine and failure probability `f`, expected aggregate share payout is the
machine's expected allocation times `1 - f**n`. Per-energy return divides that by `n`. Crowding and the
chance that nobody survives both matter; Harvest introduces further dependencies. For a single energy,
Earth and Air plainly do not have identical expected survivor payouts. The corrected SPEC states this.

The original blockhash seed is not secure verifiable randomness. Block producers influence candidate
block contents, and the existing missed-window relock path changes the seed source. Its risk cannot be
bounded by the previously claimed cost of losing one block reward or by only the largest survivor
share: Harvest and other positions can also be at stake. The companion avoids this issue by being
deterministic, but does not fix legacy rounds.

Before expanding valuable random play, commission a separate design for verifiable randomness with
authenticated fulfillment, request/round binding, closed betting before requests, sufficient funding,
and a reviewed asynchronous failure policy. Chainlink's guidance specifically cautions against
re-requesting unfavorable randomness and requires non-reverting fulfillment handling. This needs a
concrete integration and review; no subscription or coordinator has been guessed here.
[Chainlink VRF security considerations](https://docs.chain.link/vrf/v2-5/security)

## 5. Prove retention before adding more financial machinery

Run a small, independently reviewed pilot of the companion with transparent, capped sponsorship and
publish outcomes including non-reveals and gas costs. Test whether users return after the subsidy ends.
Add useful strategy information: prior machine populations, total committed tickets, exact phase
deadlines, eventual per-ticket returns and a clear cost breakdown. Never display unrevealed choices
as known or a reward estimate as a guarantee.

Daily rounds reduce frequency, but mainnet gas may still outweigh a small ticket's value. Measure that
before promoting small purchases. A lower-cost deployment is a separate decision involving the existing
token and any bridge risks; this assignment does not move the token or presume a new launch chain.

The highest priorities remain independent adversarial review, a truthful randomness assessment of the
original game, reliable reveal handling, and evidence of entertainment demand. The new tests cover
solvency, supply, failure paths, reentrancy and multi-round claims, but do not prove adoption or audit safety.

The concept earns credit for a coherent token loop, finite supply and distinctive machines. I discount
it for demand-dependent economics, legacy randomness, mainnet friction and unproven retention. The new
strategy mode improves depth and funding discipline; it does not resolve those wider risks.

**Overall concept grade: 6/10.**
