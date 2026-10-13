# Local validation

Validated with Foundry 1.8.3 and the unchanged `foundry.toml` compiler pin, Solidity 0.8.26.

| Command | Result |
|---|---|
| `forge build` | Pass; compiler succeeds, linter warnings remain |
| `forge test` | 100 passed, 0 failed, 0 skipped; original 70-test suite included |
| `forge fmt --check` | Pass |
| `python3 -m unittest discover -s test -p test_strategy_receipt.py` | 5 passed |
| `python3 sim/strategy_sim.py` | 10,000 exact-integer randomized rounds passed; output reproduces `sim/strategy_results.md` |
| `git diff --check` | Pass |

This Foundry version groups the two stateful invariant functions into one reported test. That campaign
executed 64 runs of 128 actions (8,192 calls), with zero reverts, checking token supply, escrow backing
and the sum of every unpaid entry. Unit fuzz cases use the project's 64-run default. Tests need no RPC,
environment values, external deployments or network access. Both the Solidity tests and receipt-tool
tests check the same independently recorded ABI/Keccak encoding vector.

The new module's build warnings were reviewed locally:

- Reentrancy warnings at token calls refer to the custom lock's reset after the call. Every mutating
  entry point uses the lock, which is set before the function body; payout effects precede transfer.
  Adversarial callbacks during funding, burning and claiming verify `Reentrancy` and unchanged liabilities.
- Timestamp comparisons enforce entry/reveal windows. Timestamps never select machines or draw prizes.
  Deadline inclusion and exclusion are tested. Validators can still affect inclusion near a deadline.
- Division before multiplication is deliberate: a machine pays the same integer wei amount per ticket,
  then the contract totals those payouts and rolls the remainder. Conservation and split-wallet tests
  verify the rounding behavior.
- The exact incoming-balance comparison intentionally rejects inexact token transfers. The module
  supports the existing AetherToken, not fee-charging or rebasing assets. A direct donation before the
  transfer is included in the baseline and does not fail this check.

Existing contracts also produce pre-existing linter warnings; this work does not claim a comprehensive
audit or repair of the original game. Protected build files, dependencies, the token and all original
contract sources are unchanged. No new package was installed or required.

No deployment, fork test, Slither/Mythril run or independent adversarial audit was performed. Before use,
the launch owner must verify and set the existing token address once; the operator must arrange gas,
reveal UX and independent review. The original blockhash randomness remains unresolved. See
[STRATEGY.md](STRATEGY.md), [RISKS.md](RISKS.md) and [RECOMMENDATIONS.md](RECOMMENDATIONS.md).
