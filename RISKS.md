# RISKS

## This is a game of chance paid in IMD

Energies are bought with IMD (or ETH swapped to IMD) and every IMD spent is irreversibly used to buy and burn
AETHER. Whether an energy earns anything depends on random draws (which machine gets the 60% Share, whether
the energy survives, how many others survived with it, how many fails share the Harvest). An energy can earn
nothing. Players should only spend IMD they can afford to lose. Depending on jurisdiction this may be regulated
as gambling; the operator of the site is responsible for that assessment. The contracts have no admin, so
nobody can refund, pause or reverse a purchase.

## AETHER is exposed to the IMD price

AETHER's only market is the AETHER/IMD pool. All rewards are AETHER, all entry is IMD. If IMD falls 80%, the
dollar value of every reward, every unclaimed balance and the whole LP position falls with it, whatever the
AETHER/IMD price does. The simulation's crash scenario shows play continuing in IMD terms while dollar returns
collapse. IMD holders also face the opposite: the game is a steady IMD sink into the pool, which only helps IMD
holders while people play.

## Liquidity and price

- The launch pool holds 1,000 AETHER and zero IMD. Early buys move the price a lot; the 99% -> 5% fee is the
  only sniper protection and it is time-based: a buyer at minute 94 pays 5%.
- The LP position is single-sided and permanent. It can never be withdrawn, by anyone. If the game dies, the
  IMD accumulated in the pool stays there.
- A whale can crash the AETHER/IMD price by selling (the simulation's 300 AETHER dump moved the price ~6x
  down before buyers returned). The 5% floor fee and the 0.3% LP fee are a cost, not a prevention.
- The ETH entry route depends on an external ETH/IMD v4 pool fixed at launch. If that pool is empty or
  removed, the ETH route reverts (`EthRouteUnavailable`) and only the IMD route works.

## Randomness (known limitation, documented choice)

The seed is the hash of the block after the lock block. This is not a VRF. The proposer of that block can see
the outcome before publishing and withhold the block to re-roll once, at the cost of the block reward. The
stake per epoch (the 60% Share of 90% of one tranche: about 0.2 AETHER at launch, less later) is far below a
block reward, so the attack does not pay unless AETHER becomes worth more than a block reward per 0.2 AETHER.
The locker cannot bias anything: the next block's hash is unknown when locking. If the 256-block window is
missed the epoch is re-locked; outcomes are delayed, never lost. A Chainlink VRF design was rejected because it
needs a funded subscription and an owner to manage it, and the brief forbids any admin.

## Keeper dependency

Settlement is permissionless but someone must call `settle()` (two calls per epoch, more pages for busy
epochs) and `collect()`, `compound()`. If nobody does, epochs queue up and are settled later in order; no
funds are lost. The site operator should run a keeper. Gas per call is bounded by `maxBatches`.

## Whales and sybils

Caps are per batch (500 energies), not per wallet, because wallet caps are trivially sybil-able. The real
whale tax is price impact: each energy costs the IMD needed to buy 0.01 AETHER at the current pool price, so
a 500-energy batch pays far more per energy than a 5-energy one, and all Shares and Harvest are strictly pro
rata. A whale cannot earn a superlinear return; they can dominate a machine's survivor pool, which the random
60/20/20/0 assignment partly offsets.

## Harvest variance premium

Risky machines collect more Harvest per energy (more fails per energy, equal slice per fail). Players crowd
toward risk until it balances. This is intentional and can make the Air machine the rational choice; it is not
an exploit.

## Smart contract risk

The code is new and unaudited. It integrates Uniswap v4 (PoolManager, hooks, return deltas), which is complex.
Tests cover the invariants listed in SPEC.md but tests are not an audit. An independent adversarial review is
required before mainnet. Specific points for reviewers: hook return-delta accounting, the vault's compounding
math, the game's unlock callback, and the launcher's in-constructor CREATE2 salt mining (expected ~16k
iterations, gas budget ~2-6M, unbounded in theory).

## Economic risks not covered by the simulation

The agent-based model is a first pass with simple agents and a crude external market (see SIMULATION.md,
"Limitations"). It does not price the token, it checks the mechanics. Real outcomes depend on how many people
play, how much they sell, and the IMD market.
