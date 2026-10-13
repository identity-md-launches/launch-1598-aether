// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AetherToken} from "./AetherToken.sol";

/// @title AETHER Reserve
/// @notice Holds the 8,000 AETHER Reserve and releases it to the game one epoch at a time, on a fixed,
///         decreasing schedule that nobody can change:
///
///           epoch          = 10 minutes, 144 per day
///           emission span  = 365 days = 52,560 epochs
///           daily amount   = D0 * q^day,  q = 2^(-1/120)  (emission half-life of 120 days)
///           D0             = 8,000 * (1 - q) / (1 - q^365)  ~= 52.4457 AETHER on day 0
///           tranche(epoch) = daily amount of that day / 144  (~0.3642 AETHER at launch, ~0.0445 on day 364)
///
///         The last epoch of the span sweeps whatever rounding dust is left so the Reserve ends at exactly 0.
///         The Reserve can never be overdrawn: a release never exceeds the balance, and only the game can call it.
contract AetherReserve {
    uint256 public constant RESERVE_AMOUNT = 8_000e18;
    uint256 public constant EPOCHS_PER_DAY = 144;
    uint256 public constant EMISSION_DAYS = 365;
    uint256 public constant EMISSION_EPOCHS = EMISSION_DAYS * EPOCHS_PER_DAY; // 52,560
    /// @dev q = 2^(-1/120) in 1e18 fixed point.
    uint256 public constant DAILY_DECAY_WAD = 994240423817547264;
    /// @dev D0 = RESERVE * (1 - q) / (1 - q^365), computed off-chain to the wei (see sim/emission.py).
    uint256 public constant DAY0_AMOUNT = 52445692658874265000;
    uint256 internal constant WAD = 1e18;

    AetherToken public immutable aether;
    address public immutable game;

    uint256 public released;
    uint256 public lastReleasedEpoch; // epoch + 1 of the last release (0 = none)

    event Released(uint256 indexed epoch, uint256 amount);

    error OnlyGame();
    error EpochOrder();

    constructor(AetherToken aether_, address game_) {
        aether = aether_;
        game = game_;
    }

    /// @notice Daily amount for a given day index (0-based), 0 after the emission span.
    function dailyAmount(uint256 day) public pure returns (uint256) {
        if (day >= EMISSION_DAYS) return 0;
        return DAY0_AMOUNT * _powWad(DAILY_DECAY_WAD, day) / WAD;
    }

    /// @notice Scheduled tranche for an epoch, before the balance cap and the final sweep.
    function scheduledTranche(uint256 epoch) public pure returns (uint256) {
        if (epoch >= EMISSION_EPOCHS) return 0;
        return dailyAmount(epoch / EPOCHS_PER_DAY) / EPOCHS_PER_DAY;
    }

    /// @notice AETHER still held by the Reserve.
    function remaining() external view returns (uint256) {
        return aether.balanceOf(address(this));
    }

    /// @notice Release the tranche of `epoch` to the game. Epochs must be released in order, once each.
    /// @return amount The AETHER transferred to the game (0 after the emission span).
    function release(uint256 epoch) external returns (uint256 amount) {
        if (msg.sender != game) revert OnlyGame();
        if (epoch != lastReleasedEpoch) revert EpochOrder();
        lastReleasedEpoch = epoch + 1;
        uint256 balance = aether.balanceOf(address(this));
        amount = scheduledTranche(epoch);
        if (epoch == EMISSION_EPOCHS - 1) amount = balance; // final sweep: Reserve ends at exactly zero
        if (amount > balance) amount = balance; // never overdrawn
        if (amount == 0) return 0;
        released += amount;
        aether.transfer(game, amount);
        emit Released(epoch, amount);
    }

    /// @dev Fixed-point exponentiation by squaring, 1e18 base, rounding down.
    function _powWad(uint256 base, uint256 exp) internal pure returns (uint256 result) {
        result = WAD;
        while (exp > 0) {
            if (exp & 1 == 1) result = result * base / WAD;
            base = base * base / WAD;
            exp >>= 1;
        }
    }
}
