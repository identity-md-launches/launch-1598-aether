# AETHER

On-chain machine game paired with IMD on Ethereum mainnet: 10,000 AETHER, Uniswap v4 AETHER/IMD pool with a
99% -> 5% launch-decay hook, four machines, random Shares every 10 minutes, nightly Harvest, no admin.

This follow-up adds an optional **AetherStrategy** companion: sealed machine choices, rewards determined
by crowding, a 5% ticket burn and fully funded payouts. It uses the existing AETHER token. No contracts
have been deployed by this work; do not rerun the original token launcher to add this module.

| document | content |
|---|---|
| [RECOMMENDATIONS.md](RECOMMENDATIONS.md) | mechanics and sustainability recommendations, implemented scope, economics and overall concept grade |
| [STRATEGY.md](STRATEGY.md) | companion rules, configuration, player workflow, deployment assumptions and operations |
| [sim/strategy_results.md](sim/strategy_results.md) | exact-integer scenarios, finite sponsorship and declining participation |
| [VALIDATION.md](VALIDATION.md) | local check results, warning review and remaining review limits |
| [SPEC.md](SPEC.md) | final rules and every constant |
| [SIMULATION.md](SIMULATION.md), [sim/](sim/) | agent-based simulation and the reasoning behind the chosen parameters |
| [RISKS.md](RISKS.md) | game of chance paid in IMD, IMD exposure, randomness, keeper, whales |
| [SITE_COPY.md](SITE_COPY.md) | English site text |
| [WORKFLOW_REQUEST.md](WORKFLOW_REQUEST.md) | historical original-launch instructions; do not use to add the companion to an existing token |

## Contracts (`src/`)

| contract | role |
|---|---|
| `AetherLaunch` | original launcher, retained for history/tests; do not redeploy the existing token |
| `AetherToken` | 10,000 AETHER, minted once, burn only |
| `AetherReserve` | 8,000 AETHER, geometric emission over 365 days, released per epoch to the game |
| `AetherGame` | energies, machines, settlement, Shares, Harvest, unclaimed balances, claims, buy-and-burn, ETH route |
| `AetherHook` | v4 hook: 99% -> 5% fee on buys and sells, forwarded to the Harvest |
| `AetherLPVault` | permanent single-sided LP position, fee compounding |
| `AetherAirdrop` | Merkle distributor, 0.5 AETHER per NFT, 365-day window then sweep to the Harvest |
| `AetherStrategy` | optional companion using existing AETHER; one-time token binding by the launch owner, then permissionless strategy rounds |

Dependencies are vendored as plain files under `lib/` (Uniswap v4-core sources, the v4-periphery
`LiquidityAmounts` library, forge-std, solmate `Owned`). No submodules. Compiler pinned to 0.8.26 in
`foundry.toml`.

```
forge build
forge test
forge fmt --check
python3 sim/aether_sim.py --quick
python3 sim/strategy_sim.py
python3 -m unittest discover -s test -p test_strategy_receipt.py
```

## Tests (`test/`)

The companion adds unit and fuzz tests for funded rewards, phase boundaries, configuration, failed
transfers, non-reveals, copied commitments, domain separation, wallet splitting and reentrancy. Two
stateful invariants check solvency, supply and all unpaid entries across 64 sequences of 128 actions.
The Python receipt tests exercise local secret generation, encoding, permissions and failure handling.

The original suite is retained:

70 tests across both currency orderings of the pool (IMD below and above the AETHER address): launch
allocations and wiring, hook address flags, Reserve order / cap / final sweep / schedule sum, buy-and-burn,
whale price impact, revert paths, lock -> seed -> finalize settlement, missed-window relock, paged settlement,
Share accounting (whole tranche accounted), full-day Harvest with conservation of the game's balance, collect
and claim with Tithe, hook fee decay and buy/sell fee routing, exact-output rejection, hook pool restriction,
vault compounding, recycling mode after the Reserve is empty, ETH route (unavailable and working), airdrop
claim / double claim / bad proof / window / sweep.

## Assumptions and deployment parameters

The following parameters describe the original launch. The companion takes only the launch owner as
a constructor argument; its existing token address is configured once after deployment, as below.

- IMD is a standard 18-decimal ERC-20 without transfer fees or callbacks.
- Uniswap v4 PoolManager address and the ETH/IMD pool key are launch inputs (see WORKFLOW_REQUEST.md); the
  mainnet PoolManager address quoted there comes from the pinned reference table and must be checked with
  `cast code` before launch.
- The opening price `imdPerAetherWad` is the one economic launch input and is fixed forever.
- The NFT snapshot root is a constructor input; build it with `sim/merkle_tool.py`.
- The launcher's constructor mines the hook's CREATE2 salt in-line (~16k keccaks on average): budget ~25M
  gas for the launch transaction.
- On a chain without the PoolManager the launch still succeeds; `vault.open()` then stays callable once.

## After launch

For the companion, the launch owner calls `AetherStrategy.setAether(token)` once with the project's
existing AETHER address from its verified deployment record. Verify that chain, address and runtime
implementation before setting it; no concrete deployed AETHER address was present in the supplied
project history. All funded activity reverts `NotConfigured` until this succeeds. The asset cannot
be changed afterwards. There is no token redeployment, extra mint, new external service or hidden
default address. Full instructions and responsibilities: [STRATEGY.md](STRATEGY.md).

## Operational responsibilities

- Run a keeper: `settle(maxBatches)` at least twice per epoch (lock, then seed/finalize; more pages when an
  epoch has many batches), `collect(batchIds)` for users, `compound()` on the vault regularly.
- Publish the snapshot CSV, block number and proofs.
- Independent adversarial review before mainnet; tests are not an audit.
- Companion: anyone can finalize and open rounds; players or relayers must reveal during the 4-hour
  window. The operator funds keeper gas, communicates forfeiture terms and monitors liabilities.
  The launch owner has no ongoing power after the one-time token setting. No keeper reward is promised.
