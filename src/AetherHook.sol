// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {AetherToken} from "./AetherToken.sol";
import {AetherGame} from "./AetherGame.sol";

/// @title AETHER/IMD launch-decay fee hook
/// @notice Charges a hook fee on every buy and sell of the AETHER/IMD pool, collected in AETHER:
///         99% at launch, minus 1 point per minute, floored at 5% forever (reached 94 minutes after launch).
///         On a buy the whole IMD paid enters the pool (it buys AETHER inside the swap) and the hook keeps the fee
///         share of the AETHER output; on a sell the hook keeps the fee share of the AETHER input before the
///         swap. Every fee is forwarded to the game's Harvest pot. The game's own buy-and-burn swaps and the
///         LP vault are exempt. Only exact-input swaps are accepted. No admin, no parameters.
contract AetherHook is IHooks {
    uint256 public constant FEE_START_PCT = 99;
    uint256 public constant FEE_FLOOR_PCT = 5;
    uint256 public constant FEE_DECAY_SECONDS = 60; // 1 point per minute

    IPoolManager public immutable poolManager;
    AetherToken public immutable aether;
    AetherGame public immutable game;
    address public immutable launcher;
    uint256 public immutable launchTime;
    address public vault; // set once by the launcher

    event FeeCollected(address indexed sender, bool isBuy, uint256 feeAether, uint256 feePct);

    error OnlyPoolManager();
    error OnlyLauncher();
    error AlreadyWired();
    error OnlyVaultMayInitialize();
    error ExactInputOnly();
    error HookNotImplemented();

    constructor(IPoolManager poolManager_, AetherToken aether_, AetherGame game_) {
        poolManager = poolManager_;
        aether = aether_;
        game = game_;
        launcher = msg.sender;
        launchTime = block.timestamp;
        Hooks.validateHookPermissions(this, getHookPermissions());
        aether_.approve(address(game_), type(uint256).max);
    }

    function wire(address vault_) external {
        if (msg.sender != launcher) revert OnlyLauncher();
        if (vault != address(0)) revert AlreadyWired();
        vault = vault_;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Address flag bits this hook must carry (used by the launcher to mine the CREATE2 salt).
    function requiredFlags() external pure returns (uint160) {
        return Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }

    /// @notice Current hook fee in percent: max(5, 99 - minutes since launch).
    function currentFeePct() public view returns (uint256) {
        uint256 elapsedMinutes = (block.timestamp - launchTime) / FEE_DECAY_SECONDS;
        if (elapsedMinutes >= FEE_START_PCT - FEE_FLOOR_PCT) return FEE_FLOOR_PCT;
        return FEE_START_PCT - elapsedMinutes;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != vault || vault == address(0)) revert OnlyVaultMayInitialize();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_exempt(sender)) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        if (params.amountSpecified >= 0) revert ExactInputOnly();
        bool aetherIsZero = Currency.unwrap(key.currency0) == address(aether);
        bool aetherIsInput = params.zeroForOne == aetherIsZero;
        if (!aetherIsInput) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        // sell: keep the fee share of the AETHER input, the rest goes through the pool
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 pct = currentFeePct();
        uint256 fee = amountIn * pct / 100;
        if (fee > 0) {
            poolManager.take(Currency.wrap(address(aether)), address(this), fee);
            game.donateToHarvest(fee);
            emit FeeCollected(sender, false, fee, pct);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (_exempt(sender)) return (IHooks.afterSwap.selector, 0);
        bool aetherIsZero = Currency.unwrap(key.currency0) == address(aether);
        bool aetherIsInput = params.zeroForOne == aetherIsZero;
        if (aetherIsInput) return (IHooks.afterSwap.selector, 0);
        // buy: keep the fee share of the AETHER output
        int128 out = aetherIsZero ? delta.amount0() : delta.amount1();
        if (out <= 0) return (IHooks.afterSwap.selector, 0);
        uint256 pct = currentFeePct();
        uint256 fee = uint256(uint128(out)) * pct / 100;
        if (fee > 0) {
            poolManager.take(Currency.wrap(address(aether)), address(this), fee);
            game.donateToHarvest(fee);
            emit FeeCollected(sender, true, fee, pct);
        }
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    function _exempt(address sender) internal view returns (bool) {
        return sender == address(game) || sender == vault;
    }

    // ---- unused hooks (flags are off, the pool manager never calls them)
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
