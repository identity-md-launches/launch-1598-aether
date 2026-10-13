# AETHER — final rules and constants

This document describes the original game. The optional deterministic companion is specified separately
in [STRATEGY.md](STRATEGY.md); adding it does not change these contracts or issue any new tokens.

Chain: Ethereum mainnet. Pair token: IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`).
Airdrop set: identity.md NFT holders (`0x0000ec93127baa929e58e97dd0095a2bfb38ec1d`, 2,000 NFTs).
Nothing below can be changed after launch: there is no owner, no admin and no upgrade path in any contract.

## 1. Supply (AetherToken)

| item | value |
|---|---|
| total supply | 10,000 AETHER, minted once in the constructor, no mint function |
| airdrop | 1,000 (10%) to `AetherAirdrop`, 0.5 AETHER per NFT at the snapshot, Merkle claim |
| launch liquidity | 1,000 (10%) to `AetherLPVault`, single-sided in the AETHER/IMD v4 pool |
| Reserve | 8,000 (80%) to `AetherReserve`, released per epoch |
| decimals | 18 |

Only the airdrop is in circulation at launch. Supply only ever decreases (`burn`).

## 2. Reserve emission (AetherReserve)

| constant | value |
|---|---|
| epoch | 600 s, 144 per day |
| emission span | 365 days = 52,560 epochs |
| curve | geometric by day: `daily(d) = D0 * q^d`, `q = 2^(-1/120)` (half-life 120 days) |
| D0 | 52.445692658874265 AETHER on day 0 (`8,000 * (1-q) / (1-q^365)`) |
| tranche(epoch) | `daily(epoch / 144) / 144`: 0.3642 AETHER at launch, 0.0445 on day 364 |
| last epoch | sweeps the remaining balance (rounding dust) so the Reserve ends at exactly 0 |
| after the span | releases 0; the game enters recycling mode |

Releases are callable only by the game, in epoch order, once per epoch, and never exceed the balance.
Rationale: see SIMULATION.md (section "Emission curve").

## 3. Energies (AetherGame)

| constant | value |
|---|---|
| ENERGY_UNIT | 0.01 AETHER bought on the pool and burned per energy |
| price | the IMD needed to buy 0.01 AETHER at the pool's current price (self-adjusting, same on all machines) |
| MAX_ENERGIES_PER_BATCH | 500 per purchase (bigger buys are split, each paying more slippage) |
| routes | `buyEnergies(machine, imdAmount, minEnergies)` and `buyEnergiesWithEth(machine, minEnergies)` (ETH -> IMD on the ETH/IMD v4 pool, then IMD -> AETHER) |

100% of the IMD is swapped for AETHER on the AETHER/IMD pool (the game is exempt from the hook fee) and the
AETHER is burned. Energies = AETHER bought / 0.01, rounded down (the dust is burned too). `minEnergies` is the
player's slippage guard. After the Reserve is empty, the AETHER is not burned but recycled into the next
epoch's tranche.

## 4. Machines

| machine | id | fail rate |
|---|---|---|
| Earth | 0 | 10% |
| Water | 1 | 30% |
| Fire | 2 | 60% |
| Air | 3 | 90% |

Each energy fails independently with its machine's rate. Draws: 32-bit samples from
`keccak256(seed, batchId, i/8)`, 8 per hash; fail iff `sample < failRate * 2^32`.

## 5. Shares (per epoch)

90% of the tranche is split 60 / 20 / 20 / 0 and assigned to the machines at random from the epoch seed (the
60 goes to `seed % 4`, the 0 to one of the three others chosen by `(seed >> 8) % 3`). Surviving energies of a
machine split its Share pro rata. A machine with no survivor sends its Share to the day's Harvest pot;
integer-division dust goes there too. Each machine has the same expected assigned Share under ideal
randomness; expected payout per energy also depends on crowding and the probability of no survivors.
The machines do not have identical expected returns per energy.

## 6. Harvest (per day)

The pot of day `d` receives: 10% of each of its 144 tranches, every hook fee collected during day `d`, every
Tithe paid during day `d-1` ("tomorrow's Harvest"), airdrop sweep and donations made during day `d`, and the
Shares of machines without survivors. When epoch 144 of the day is finalized, the whole pot is divided equally
among all of the day's failed energies, whatever the machine. If the day had zero failed energies (nobody
played) the pot rolls into the next day; otherwise nothing is carried except integer dust.

## 7. Claiming

Winnings of a batch are moved to the owner's unclaimed balance by `collect(batchIds)` (anyone may call it)
once the batch's day is finalized. `claim(amount)`: 10% Tithe to tomorrow's Harvest pot, 90% transferred to
the wallet as plain ERC-20. Claiming is the only exit.

## 8. Randomness and settlement

- Settlement is permissionless and sequential: `settle(maxBatches)` always works on the oldest unsettled epoch.
- First call after the epoch ends locks the current block number. A call two or more blocks later reads
  `blockhash(lockBlock + 1)` and derives `seed = keccak256(blockhash, epoch, game)`. If no call happens within
  256 blocks after that, the epoch is re-locked on the next call (no zero hash is ever used).
- The seed fixes the Share assignment and every energy's outcome. Batches are then processed in pages of
  `maxBatches`, so gas per call is bounded regardless of how many players there are.
- The tranche is pulled from the Reserve when the epoch is seeded.
- This is not verifiable randomness. Block producers can influence candidate block contents, and missed
  windows allow the seed source to change. No safe manipulation-cost bound has been established; the
  value at stake includes Harvest and other positions, not just one machine's Share. See RISKS.md.

## 9. Pool and hook (AetherLPVault, AetherHook)

| constant | value |
|---|---|
| pool | Uniswap v4, AETHER/IMD, LP fee 0.3% (3000), tick spacing 60, hook = `AetherHook` |
| opening price | constructor input `imdPerAetherWad` (IMD per AETHER, 1e18 fixed point) |
| range | single-sided AETHER from the opening tick up to +92,160 ticks (x10,000 in price) |
| hook fee | 99% at launch, -1 point per minute, floor 5% forever (reached at minute 94); clock = launch block timestamp |
| fee asset | AETHER: on a buy the hook keeps the fee share of the AETHER output (the buyer's IMD still buys AETHER inside the swap), on a sell the fee share of the AETHER input |
| fee destination | `game.donateToHarvest` (today's Harvest pot) |
| exempt | the game's own swaps and the vault |
| swap type | exact input only (exact output reverts) |
| LP fee | accrues to the vault's position; `compound()` (anyone) collects and re-adds it to the same range |

The vault has no owner, no withdraw and no transfer: the position is permanent. The hook refuses to be used by
any pool other than the one the vault initializes.

## 10. Airdrop (AetherAirdrop)

Leaf: `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))`, sorted-pair hashing (OpenZeppelin
StandardMerkleTree layout). `amount = 0.5e18 * NFTs held at the snapshot block`. Claims open for 365 days;
afterwards `sweep()` (anyone) sends the remainder to the Harvest pot.

## 11. Deployment (AetherLaunch)

One contract, one transaction. Constructor inputs (7):

| input | meaning |
|---|---|
| `merkleRoot` | NFT snapshot root |
| `imd` | IMD token |
| `poolManager` | Uniswap v4 PoolManager on the chain |
| `ethPoolFee`, `ethPoolTickSpacing`, `ethPoolHooks` | key of the existing ETH/IMD v4 pool used by the ETH route |
| `imdPerAetherWad` | opening price |

The constructor deploys token, game (+Reserve), hook (CREATE2, salt mined in-line so the address carries the v4
flag bits), vault, airdrop; splits the supply; wires the pool key; and, when the PoolManager has code,
initializes the pool and adds the 1,000 AETHER. On a chain without the PoolManager the launch still succeeds
and `vault.open()` stays callable once by anyone. The 99% -> 5% fee clock starts at the launch block.

## 12. Invariants (tested)

- `totalSupply <= 10,000` always, equal to `10,000 - burned`.
- Reserve releases are in order, capped by balance, sum to exactly 8,000 and end at 0.
- Every tranche is fully accounted: survivor payouts + Harvest pot increment == tranche.
- Every finalized day: `harvestPerFail = pot / fails`, dust to the next day.
- The game's AETHER balance equals unclaimed balances + unfinalized pots (+ recycled tranches).
- No function moves funds or changes constants after launch; wiring is one-shot.
