# AETHER Strategy: rules and operating guide

`src/AetherStrategy.sol` implements an optional companion game using the existing AETHER token. It does
not replace the original game, consume its Reserve, alter its hook, or deploy a token. This assignment
only delivers source, tests and tools; it performs no deployment or transactions.

## Rules

| Item | Implemented value |
|---|---|
| Machines | Earth = 0, Water = 1, Fire = 2, Air = 3 |
| Machine differences | Choice and crowding only; no failure rates or random draw in this mode |
| Ticket price | 0.01 AETHER, paid up front |
| Supply sink | 0.0005 AETHER burned per ticket (5%) |
| Reward funding | Remaining 0.0095 AETHER per ticket, prior carryover and actual sponsor deposits |
| Entry size | 1–500 tickets on one hidden machine; multiple entries allowed |
| Commit phase | 20 hours from `openRound()` |
| Reveal phase | The following 4 hours |
| Distribution | One quarter of the round pot per machine; equal payment per revealed ticket within that machine |
| Empty machine / dust | Rolled to the next round |
| Missing or invalid reveal | Zero payout; entry payment and its burn are irreversible |
| Claim | Full allocated payout to the original player, no further fee, no expiry |
| Administration | Launch owner selects the existing token once; no other owner functions |

The 20/4-hour cycle is a product choice that reduces transaction frequency relative to the existing
10-minute game and gives players a substantial reveal window. It is not a randomness mechanism.
The 5% burn keeps most entry value available to players; it is a starting design parameter, not an
empirically optimized rate. All these values are constants and cannot be changed after deployment.

Anyone can open a round after the preceding one is finalized. Its deadlines start at that transaction's
timestamp. No overlapping rounds and no backlog of expired rounds are possible. Finalizing at a later
time never reopens a reveal window. Previous claims remain payable throughout later rounds.

## Accounting and game theory

For a round with `N` committed tickets, opening funding `F`, and revealed counts `n[m]`:

```
burn = N * 0.0005 AETHER
pot = F + N * 0.0095 AETHER
machinePot = floor(pot / 4)
payoutPerTicket[m] = n[m] == 0 ? 0 : floor(machinePot / n[m])
entryPayout = entryTickets * payoutPerTicket[chosenMachine]
allocated = sum(n[m] * payoutPerTicket[m])
rolled = pot - allocated
```

All arithmetic is in token wei. The equal machine budgets reward predicting which machines other
players will avoid. Public history and total committed tickets are available, but individual machine
choices remain hidden until everyone has finished committing. This is a congestion game, not a lottery
or a source of verifiable randomness. There is no winner selection, seed, oracle or VRF request.

Payouts are linear in paid tickets. Dividing the same machine allocation among wallets does not improve
its aggregate reward or reduce its fee. There is no wallet cap or identity reward that can be multiplied
with sybils. Wealth still buys more tickets and more coverage; this is not equal influence per person.

Each machine has a fixed budget after commit closes. Withholding a reveal cannot redirect that budget
to the revealer's entries on another machine. Ignoring integer dust, revealing more of one's tickets on
the same machine weakly increases one's aggregate payout: `B*k/(k+others)`. Per-ticket rounding can
change that by sub-ticket-count wei amounts; no exact incentive theorem is claimed for integer dust.
Collusion, sponsorship farming, information leaks and transaction censorship remain possible.

A player covering all four machines alone gets 95% of their own entry payments back, before gas, when
there is no sponsorship or carryover. A player alone on just one machine gets only 23.75%; the other
three budgets roll forward. Sponsorship and rollovers are contestable prizes and may attract bots.
There is no guaranteed return. See [the reproducible scenarios](sim/strategy_results.md).

The contract tracks liabilities independently of its raw token balance:

```
accountedBalance = totalClaimable + carryover + activeRoundPot
totalEntered + totalFunded = totalBurned + totalClaimed + accountedBalance
```

With the real AetherToken, the actual balance equals `accountedBalance`, except for unsynchronized
direct donations. `syncSurplus()` adds only that excess to next-round funding. It cannot take claim
backing or the current pot. Burns call the token's actual `burn`, reducing total supply.

## Deployment parameters

Deploy only `AetherStrategy(address owner_)` on the same chain as the existing token. `owner_` is the
launch's designated owner (the named owner, otherwise the paying wallet as supplied by the launch
system); it is never inferred from the factory or transaction origin. No concrete owner or deployed
AETHER address was supplied in the project input, so no address is guessed or embedded here.

The constructor accepts one nonzero owner argument and calls no other contract. It works on an empty
chain. There is no new supply, launch manifest, token deployment, router, oracle, subscription or
external package to configure. Compiler and dependencies remain those of the existing project.

Before funds are accepted, independently review the new code and verify the deployed bytecode and
token identity. The module supports only the original, non-upgradeable `AetherToken` implementation:
18 decimals, exact transfers, fixed supply, and callable `burn`. A setter code-length check proves only
that code exists, not that it is the right asset. Configuring a malicious or incompatible token can
make the module unusable; the one-time choice is a real trust assumption.

## After launch

| Setting/action | Who | Value and source |
|---|---|---|
| `setAether(AetherToken)` | Launch owner, once | The **existing** project's AETHER address from its verified deployment record; compare runtime code with `src/AetherToken.sol`, its 18 decimals and supply history on the intended chain |
| `fundNextRound(amount)` | Any sponsor, optional | Existing AETHER from the sponsor's own balance; approve exactly `amount` first; no fabricated reserve or unbacked reward budget |
| `openRound()` | Anyone | No arguments; starts the next round and snapshots all current carryover |

Until `setAether` succeeds, all functions that move value or progress the game revert `NotConfigured`.
The owner cannot change the asset afterwards, mint, withdraw, pause, upgrade, change fees, alter
deadlines or redirect payouts. It has no continuing operational duties after configuration.

`fundNextRound` always funds the next round **at execution time** and is irrevocable. It can be called
before the first round or during any later round. To sponsor a specific upcoming round, coordinate
funding and verify the emitted events before announcing that budget: anyone can open rounds, and this
function does not reserve a named round. Donations during reveal never change that round's pot.

## Player workflow and local secret handling

1. Read `aether()`, `currentRoundId()` and `roundInfo(roundId)` from the verified deployment. Confirm the
   intended chain and the actual commit deadline. New entries require `timestamp < commitEnd`.
2. Choose tickets and machine. Generate a fresh cryptographically random 32-byte salt locally. Compute
   `keccak256(abi.encode(chainId, strategyAddress, roundId, player, tickets, uint8(machine), salt))`.
   Keep the salt and all other fields until reveal; publishing the salt defeats sealed choices.
3. Approve precisely `tickets * TICKET_PRICE` AETHER, then call `commit(roundId, commitment, tickets)`
   from `player`. Save the `entryId` from the `Committed` event. Check the receipt matches the on-chain
   entry; do not infer its ID from a pending transaction or a counter seen before mining.
4. During `commitEnd <= timestamp < revealEnd`, call `reveal(entryId, machine, salt)`. Anybody with the
   secret can relay this, but the original player remains the payout recipient.
5. After `revealEnd`, anyone calls `finalize(roundId)`, then `claim(entryId)`. Both may be called by a
   helper; the claim always pays the original player. There is no need to wait for a later round.

`script/strategy_receipt.py` performs steps 2 and the calldata encoding for step 4 **offline**, using
Python's standard library plus the already required Foundry `cast` executable. No package installation,
network connection, key or transaction submission is needed. Run:

```
python3 script/strategy_receipt.py prepare --help
python3 script/strategy_receipt.py reveal --help
```

`prepare` requires the real chain ID, contract, player, round, ticket count, machine and an output path.
It saves a new private receipt with mode 0600 and refuses to overwrite an existing file. Standard
output contains the approval amount, commitment and commit calldata, without the salt. Use a private
path outside this repository; keep an encrypted backup. `reveal` takes that receipt and the actual
entry ID, checks the saved commitment, then prints the reveal calldata. It does not query the chain
or verify that the supplied entry ID belongs to the receipt; verify that mapping against `entryInfo`.
Only publish reveal calldata once the commit phase is over. Loss of the receipt can mean total loss
of the entry. An on-chain `computeCommitment` view exists for testing, but sending secrets to a remote
RPC to call it before revealing compromises secrecy.

## Failures, refunds and operations

- There is **no refund or cancellation** of accepted tickets or sponsorship. Incorrectly encoded
  commitments, lost salts and missed reveals earn nothing. No owner can rescue them. Burned tokens
  cannot be restored. These terms must be displayed before signing an entry.
- No reveal is required to finalize: if nobody reveals, the entire remaining pot rolls forward.
  Empty rounds burn nothing and carry all funding. If nobody returns, carryover waits indefinitely;
  it is not a sponsor withdrawal claim.
- Finalization reads four counters and performs no token transfers, so its work does not grow with
  entry count and a failed claim cannot block it. An individual failed payout rolls back its claimed
  flag and accounting and can be retried. For the actual AetherToken, recipients need no callback.
- A keeper or players call `finalize` and `openRound`; helpers may relay reveals and claims. There are
  no keeper rewards. The site operator must budget gas externally and monitor deadlines. A keeper
  outage delays settlement, but does not reopen reveal or invalidate already revealed claims.
- The frontend must separate these rules from the original game's random shares, daily Harvest,
  10% claim Tithe, and IMD/ETH entry flow. This module takes AETHER directly; buying it externally may
  incur the original hook and LP fees. Neither those costs nor gas are included in the 95% figure.
- Monitor actual balance versus `accountedBalance`, unpaid claims, unrevealed tickets, sponsor inflows,
  carryover, real burns, player retention, and realized participation after sponsors stop funding.
  Holdings in the contract are temporary escrow, not destroyed supply or market buyback volume.

## Validation and limits

The delivered Foundry tests cover configuration, success and revert paths, deadlines, replay domains,
copied commitments, payout ownership, double actions, failed pulls/burns/payouts, all/partial/no reveals,
empty machines, wallet splitting, old claims across new rounds, direct donations and reentrancy. Two
stateful invariants exercise 64 sequences of 128 actions and compare solvency, supply and the full unpaid
entry ledger. `sim/strategy_sim.py` also checks 10,000 seeded rounds with exact integer accounting.
The receipt utility has offline success and failure tests. Run the commands listed in README.md.

This is a local implementation review and test suite, not an independent security audit. No Slither,
Mythril, chain-fork validation, deployment or production integration test is claimed. The original
game's randomness and market risks remain; this companion creates no token price guarantee.
