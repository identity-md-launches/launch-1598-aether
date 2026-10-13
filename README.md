# AETHER

On-chain machine game paired with IMD on Ethereum mainnet: 10,000 AETHER, Uniswap v4 AETHER/IMD pool with a
99% -> 5% launch-decay hook, four machines, random Shares every 10 minutes, nightly Harvest, no admin.

| document | content |
|---|---|
| [SPEC.md](SPEC.md) | final rules and every constant |
| [SIMULATION.md](SIMULATION.md), [sim/](sim/) | agent-based simulation and the reasoning behind the chosen parameters |
| [RISKS.md](RISKS.md) | game of chance paid in IMD, IMD exposure, randomness, keeper, whales |
| [SITE_COPY.md](SITE_COPY.md) | English site text |
| [WORKFLOW_REQUEST.md](WORKFLOW_REQUEST.md) | ready-to-paste IMD `workflow.open` request (evm_contracts, Sepolia then mainnet) |

## Contracts (`src/`)

| contract | role |
|---|---|
| `AetherLaunch` | the one contract to deploy: its constructor deploys and wires everything below in one transaction |
| `AetherToken` | 10,000 AETHER, minted once, burn only |
| `AetherReserve` | 8,000 AETHER, geometric emission over 365 days, released per epoch to the game |
| `AetherGame` | energies, machines, settlement, Shares, Harvest, unclaimed balances, claims, buy-and-burn, ETH route |
| `AetherHook` | v4 hook: 99% -> 5% fee on buys and sells, forwarded to the Harvest |
| `AetherLPVault` | permanent single-sided LP position, fee compounding |
| `AetherAirdrop` | Merkle distributor, 0.5 AETHER per NFT, 365-day window then sweep to the Harvest |

Dependencies are vendored as plain files under `lib/` (Uniswap v4-core sources, the v4-periphery
`LiquidityAmounts` library, forge-std, solmate `Owned`). No submodules. Compiler pinned to 0.8.26 in
`foundry.toml`.

```
forge build
forge test
forge fmt --check
python3 sim/aether_sim.py --quick
```

## Tests (`test/`)

70 tests across both currency orderings of the pool (IMD below and above the AETHER address): launch
allocations and wiring, hook address flags, Reserve order / cap / final sweep / schedule sum, buy-and-burn,
whale price impact, revert paths, lock -> seed -> finalize settlement, missed-window relock, paged settlement,
Share accounting (whole tranche accounted), full-day Harvest with conservation of the game's balance, collect
and claim with Tithe, hook fee decay and buy/sell fee routing, exact-output rejection, hook pool restriction,
vault compounding, recycling mode after the Reserve is empty, ETH route (unavailable and working), airdrop
claim / double claim / bad proof / window / sweep.

## Assumptions and deployment parameters

- IMD is a standard 18-decimal ERC-20 without transfer fees or callbacks.
- Uniswap v4 PoolManager address and the ETH/IMD pool key are launch inputs (see WORKFLOW_REQUEST.md); the
  mainnet PoolManager address quoted there comes from the pinned reference table and must be checked with
  `cast code` before launch.
- The opening price `imdPerAetherWad` is the one economic launch input and is fixed forever.
- The NFT snapshot root is a constructor input; build it with `sim/merkle_tool.py`.
- The launcher's constructor mines the hook's CREATE2 salt in-line (~16k keccaks on average): budget ~25M
  gas for the launch transaction.
- On a chain without the PoolManager the launch still succeeds; `vault.open()` then stays callable once.

## Operational responsibilities (there is no admin)

- Run a keeper: `settle(maxBatches)` at least twice per epoch (lock, then seed/finalize; more pages when an
  epoch has many batches), `collect(batchIds)` for users, `compound()` on the vault regularly.
- Publish the snapshot CSV, block number and proofs.
- Independent adversarial review before mainnet; tests are not an audit.
