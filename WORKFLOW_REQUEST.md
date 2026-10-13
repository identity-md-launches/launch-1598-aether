# workflow.open request — AETHER (evm_contracts)

Paste the block below into IMD `workflow.open`.

```
kind: evm_contracts
title: AETHER — on-chain machine game paired with IMD (Sepolia rehearsal, then Ethereum mainnet)
repo: <this repository>
contract_count: 1 launched contract (AetherLaunch) that deploys 5 others + the Reserve in its constructor (7 total, under the 8 limit, ONE transaction)

SUMMARY
AETHER is a 10,000-supply ERC-20 (name AETHER, symbol AETHER). All of it is minted in the launch
transaction and split by the launcher: 1,000 Merkle airdrop to identity.md NFT holders (0.5 per NFT),
1,000 single-sided liquidity in a Uniswap v4 AETHER/IMD pool, 8,000 Reserve emitted over 365 days on a
decreasing schedule to the game. Players buy energies with IMD (or ETH swapped to IMD); 100% of that IMD
buys AETHER on the pool and burns it. Four machines (fail 10/30/60/90%), random 60/20/20/0 Shares every
10-minute epoch, daily Harvest split among failed energies, 10% Tithe on claims, hook fee 99% -> 5%
(-1 point/minute) on buys and sells feeding the Harvest, 0.3% LP fee compounded into the permanent LP.
No owner, no admin, no upgrade. Specs: SPEC.md. Risks: RISKS.md. Simulation: SIMULATION.md, sim/.

DEPLOY: ONE CONTRACT, ONE TRANSACTION
Contract: AetherLaunch (src/AetherLaunch.sol). Its constructor deploys AetherToken, AetherGame
(+AetherReserve), AetherHook (CREATE2, salt mined in the constructor so the address carries the v4 hook
flags), AetherLPVault, AetherAirdrop; transfers 1,000 / 8,000 / 1,000; wires the pool key; and, because
the PoolManager has code on the target chain, initializes the AETHER/IMD pool and adds the 1,000 AETHER
single-sided. Gas: budget 25M for the transaction (hook salt mining is ~16k keccaks on average).
The 99% -> 5% fee clock starts at the block timestamp of this transaction.
Compiler: solc 0.8.26, optimizer 200, evm cancun (foundry.toml). Build: forge build. Tests: forge test (70).

CONSTRUCTOR ARGUMENTS (7)
1. merkleRoot (bytes32): root of the NFT snapshot tree. Generate with sim/merkle_tool.py from a
   holder->count CSV at the snapshot block: amount = 0.5e18 * count, leaf =
   keccak256(bytes.concat(keccak256(abi.encode(account, amount)))), sorted pairs. Publish the CSV, the
   snapshot block and the proofs JSON on the site.
2. imd (address): IMD token.
   - Sepolia: the mock IMD you deploy for the rehearsal (any mintable 18-decimal ERC-20).
   - Mainnet: 0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7
3. poolManager (address): Uniswap v4 PoolManager on the chain (from network.json / Uniswap deployments).
   The mainnet value in the eth-addresses reference is 0x000000000004444c5dc75cB358380D2e3dE08A90; verify with
   cast code before use.
4. ethPoolFee (uint24), 5. ethPoolTickSpacing (int24), 6. ethPoolHooks (address): the key of the EXISTING
   ETH/IMD Uniswap v4 pool (native ETH as currency0) the ETH entry route will swap through. Use 0x0 for
   ethPoolHooks only if that pool really has no hook. If no such pool exists on the chain, the ETH route
   reverts cleanly (EthRouteUnavailable) and the IMD route still works; pass the key of the pool you intend
   to seed. On Sepolia create a small ETH/mockIMD pool first.
7. imdPerAetherWad (uint256): opening price, IMD per AETHER, times 1e18. Choose it so that the 1,000 AETHER
   in the pool is worth roughly 5-10% of IMD's circulating value at launch (sim default: 100 IMD = 100e18).
   This is the only economic input; it is fixed forever.

SEPOLIA REHEARSAL (step 1)
- Deploy a mock IMD, mint to testers, create an ETH/mockIMD v4 pool with a little liquidity.
- Deploy AetherLaunch with the Sepolia PoolManager, a test Merkle root, imdPerAetherWad = 100e18.
- Check: token.totalSupply() == 10000e18; reserve holds 8000e18; airdrop holds 1000e18; vault.opened()
  == true; hook.currentFeePct() == 99 then decays; buyEnergies works; run settle() across a few epochs; a
  full day (144 epochs) then collect() and claim(); compound() after third-party swaps.
- Run the keeper for at least one full day.

MAINNET (step 2)
- Take the NFT snapshot (block number announced in advance), build the root, publish proofs.
- Deploy AetherLaunch with the mainnet IMD, PoolManager, ETH/IMD pool key and the chosen opening price.
- Verify all 7 contracts on Etherscan (forge verify-contract), record the addresses and hook salt
  (launch.hookSalt()).
- Announce: fee decays 99% -> 5% over 94 minutes from the launch block.

SITE
Static site using the copy in SITE_COPY.md: airdrop claim (proof lookup), buy energies (IMD or ETH, machine
picker, minEnergies slippage), epoch/day dashboard (settle status, Shares, Harvest), unclaimed balance,
collect + claim, pool stats. The site also runs the keeper: settle(200) twice per epoch, collect for
users on demand, compound() daily.

OPERATIONAL RESPONSIBILITIES (no admin exists)
- Keeper for settle()/compound() (permissionless; anyone can run it).
- Publishing the snapshot CSV + proofs.
- Legal assessment: game of chance paid in IMD (RISKS.md).
- Independent adversarial review before mainnet.
```
