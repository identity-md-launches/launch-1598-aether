// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {AetherToken} from "./AetherToken.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";

/// @title AETHER/IMD liquidity vault
/// @notice Owns the launch liquidity: 1,000 AETHER, single-sided, in one concentrated range starting at the
///         opening price and spanning x10,000 (92,160 ticks). Buyers take AETHER out and leave IMD in. The position
///         is permanent: the vault has no owner, no withdraw and no transfer. The pool's 0.3% LP fee accrues to
///         the position; `compound()` (permissionless) collects it and re-adds it to the same range, so
///         liquidity grows with volume.
contract AetherLPVault is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 public constant LP_AMOUNT = 1_000e18;
    uint24 public constant LP_FEE = 3_000; // 0.3%
    int24 public constant TICK_SPACING = 60;
    int24 public constant RANGE_TICKS = 92_160; // ~ x10,000 in price, multiple of 60

    IPoolManager public immutable poolManager;
    AetherToken public immutable aether;
    IERC20Minimal public immutable imd;
    IHooks public immutable hook;
    uint256 public immutable imdPerAetherWad; // opening price, IMD per AETHER, 1e18 fixed point
    bool public immutable aetherIsCurrency0;

    bool public opened;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidity;

    uint8 private constant ACTION_OPEN = 0;
    uint8 private constant ACTION_COMPOUND = 1;

    event Opened(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event Compounded(uint256 amount0Fees, uint256 amount1Fees, uint128 liquidityAdded);

    error AlreadyOpened();
    error NotOpened();
    error OnlyPoolManager();
    error InsufficientAether();
    error ZeroPrice();

    constructor(
        IPoolManager poolManager_,
        AetherToken aether_,
        IERC20Minimal imd_,
        IHooks hook_,
        uint256 imdPerAetherWad_
    ) {
        if (imdPerAetherWad_ == 0) revert ZeroPrice();
        poolManager = poolManager_;
        aether = aether_;
        imd = imd_;
        hook = hook_;
        imdPerAetherWad = imdPerAetherWad_;
        aetherIsCurrency0 = address(aether_) < address(imd_);
    }

    function poolKey() public view returns (PoolKey memory) {
        (Currency c0, Currency c1) = aetherIsCurrency0
            ? (Currency.wrap(address(aether)), Currency.wrap(address(imd)))
            : (Currency.wrap(address(imd)), Currency.wrap(address(aether)));
        return PoolKey({currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: hook});
    }

    /// @notice Opening sqrt price (Q64.96) derived from the IMD-per-AETHER opening price.
    function openingSqrtPriceX96() public view returns (uint160) {
        // price = currency1 / currency0
        uint256 ratioX192 = aetherIsCurrency0
            ? FullMath.mulDiv(imdPerAetherWad, 1 << 192, 1e18)
            : FullMath.mulDiv(1e18, 1 << 192, imdPerAetherWad);
        return uint160(_sqrt(ratioX192));
    }

    /// @notice Initialize the pool and add the 1,000 AETHER single-sided. Callable once, by anyone (the launcher
    ///         does it in the launch transaction when the pool manager is present).
    function open() external {
        if (opened) revert AlreadyOpened();
        if (aether.balanceOf(address(this)) < LP_AMOUNT) revert InsufficientAether();
        opened = true;
        uint160 sqrtPriceX96 = openingSqrtPriceX96();
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        if (aetherIsCurrency0) {
            // range entirely above the price: position holds only currency0 (AETHER)
            int24 lower = _floorTick(tick) + TICK_SPACING;
            tickLower = lower;
            tickUpper = lower + RANGE_TICKS;
        } else {
            // range entirely below the price: position holds only currency1 (AETHER)
            int24 upper = _floorTick(tick);
            tickUpper = upper;
            tickLower = upper - RANGE_TICKS;
        }
        poolManager.initialize(poolKey(), sqrtPriceX96);
        poolManager.unlock(abi.encode(ACTION_OPEN));
        emit Opened(sqrtPriceX96, tickLower, tickUpper, liquidity);
    }

    /// @notice Collect the LP fees earned by the position and re-add them as liquidity in the same range.
    function compound() external {
        if (!opened) revert NotOpened();
        poolManager.unlock(abi.encode(ACTION_COMPOUND));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        uint8 action = abi.decode(data, (uint8));
        PoolKey memory key = poolKey();
        if (action == ACTION_OPEN) {
            uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
            uint128 l = aetherIsCurrency0
                ? LiquidityAmounts.getLiquidityForAmount0(sqrtA, sqrtB, LP_AMOUNT)
                : LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, LP_AMOUNT);
            l -= 1; // guard against the pool manager rounding the required amount up by 1 wei
            _addLiquidity(key, l);
        } else {
            // 1. collect fees owed to the position (modify with zero delta credits them to us)
            (BalanceDelta feeDelta,) = poolManager.modifyLiquidity(
                key, ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: 0}), ""
            );
            uint256 fees0 = feeDelta.amount0() > 0 ? uint256(uint128(feeDelta.amount0())) : 0;
            uint256 fees1 = feeDelta.amount1() > 0 ? uint256(uint128(feeDelta.amount1())) : 0;
            if (fees0 > 0) poolManager.take(key.currency0, address(this), fees0);
            if (fees1 > 0) poolManager.take(key.currency1, address(this), fees1);
            // 2. re-add everything the vault holds (fees + any leftover dust) at the current price
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
            uint128 l = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                _balance(key.currency0),
                _balance(key.currency1)
            );
            if (l > 1) {
                l -= 1;
                _addLiquidity(key, l);
            } else {
                l = 0;
            }
            emit Compounded(fees0, fees1, l);
        }
        return "";
    }

    function _addLiquidity(PoolKey memory key, uint128 l) internal {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(l)), salt: 0
            }),
            ""
        );
        liquidity += l;
        if (delta.amount0() < 0) _pay(key.currency0, uint256(uint128(-delta.amount0())));
        if (delta.amount1() < 0) _pay(key.currency1, uint256(uint128(-delta.amount1())));
    }

    function _pay(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        IERC20Minimal(Currency.unwrap(currency)).transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _balance(Currency currency) internal view returns (uint256) {
        return IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this));
    }

    function _floorTick(int24 tick) internal pure returns (int24) {
        int24 q = tick / TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) q -= 1;
        return q * TICK_SPACING;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }
}
