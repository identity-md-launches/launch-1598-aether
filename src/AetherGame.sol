// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {AetherToken} from "./AetherToken.sol";
import {AetherReserve} from "./AetherReserve.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";

/// @title AETHER game: energies, machines, Shares, Harvest, claims
/// @notice Rules (all constants fixed at deployment, no admin):
///  - Players buy energies with IMD (or ETH, swapped to IMD first) on one of 4 machines. 100% of the IMD buys
///    AETHER on the AETHER/IMD v4 pool, and that AETHER is burned (or, once the Reserve is empty, recycled into
///    the next epoch's tranche). One energy = ENERGY_UNIT (0.01 AETHER) bought and burned.
///  - Machines differ only by fail rate: Earth 10%, Water 30%, Fire 60%, Air 90%.
///  - Each epoch (10 min) the Reserve releases a tranche. 90% is cut into 4 Shares (60/20/20/0) assigned to the
///    machines at random; the surviving energies of a machine split its Share pro rata. 10% goes to the day's
///    Harvest pot together with every Tithe and every hook fee.
///  - After epoch 144 of a day, the whole pot is split equally among all of the day's failed energies.
///  - Winnings sit in an unclaimed balance; claiming sends 90% to the wallet and 10% (Tithe) to tomorrow's pot.
///  - Randomness: the first settlement call after an epoch ends locks a block; the hash of the NEXT block seeds
///    the epoch. Settlement is permissionless and paged, so gas is bounded per call.
contract AetherGame is IUnlockCallback {
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------- constants
    uint256 public constant EPOCH_LENGTH = 10 minutes;
    uint256 public constant EPOCHS_PER_DAY = 144;
    uint256 public constant ENERGY_UNIT = 0.01e18; // AETHER burned per energy
    uint256 public constant MAX_ENERGIES_PER_BATCH = 500;
    uint256 public constant SHARE_BPS = 9_000; // 90% of a tranche to Shares, 10% to Harvest
    uint256 public constant TITHE_BPS = 1_000; // 10% of every claim to tomorrow's Harvest
    uint256 public constant BPS = 10_000;
    uint256 public constant SEED_WINDOW = 256; // blocks during which blockhash(lockBlock + 1) is readable
    uint8 public constant MACHINE_COUNT = 4;

    // ---------------------------------------------------------------- immutables
    AetherToken public immutable aether;
    IERC20Minimal public immutable imd;
    AetherReserve public immutable reserve;
    IPoolManager public immutable poolManager;
    address public immutable launcher;
    uint256 public immutable launchTime;
    uint24 public immutable ethPoolFee;
    int24 public immutable ethPoolTickSpacing;
    IHooks public immutable ethPoolHooks;

    // ---------------------------------------------------------------- storage
    PoolKey public aetherKey; // set once by the launcher (the hook address is not known at construction)
    bool public wired;
    bool internal aetherIsCurrency0;
    address public hook;

    struct Batch {
        address player;
        uint32 epoch;
        uint8 machine;
        uint32 energies;
        uint32 survivors;
        bool settled;
        bool collected;
    }

    struct EpochInfo {
        uint64 lockBlock;
        bytes32 seed;
        uint256 tranche;
        bool finalized;
        uint8 sixtyMachine;
        uint8 zeroMachine;
        uint32[4] energies;
        uint32[4] survivors;
        uint256[4] share;
        uint256[4] sharePerSurvivor;
    }

    struct DayInfo {
        uint256 pot;
        uint256 fails;
        uint256 harvestPerFail;
        bool finalized;
    }

    Batch[] public batches;
    mapping(uint256 => EpochInfo) internal epochs;
    mapping(uint256 => DayInfo) internal dayInfos;
    mapping(uint256 => uint256) public recycledFor; // AETHER recycled into the tranche of a future epoch
    mapping(address => uint256) public unclaimed;
    uint256 public totalUnclaimed;
    uint256 public nextEpochToSettle;
    uint256 public settleCursor; // next batch index to settle
    uint256 public totalBurned;
    uint256 public totalRecycled;
    uint256 public totalHarvestIn; // hook fees + tithes + donations entering pots

    uint256 private _lock = 1;

    // ---------------------------------------------------------------- events
    event Wired(PoolKey key, address hook);
    event EnergiesBought(
        uint256 indexed batchId,
        address indexed player,
        uint256 indexed epoch,
        uint8 machine,
        uint256 energies,
        uint256 aetherSpent
    );
    event EpochLocked(uint256 indexed epoch, uint256 lockBlock);
    event EpochSeeded(uint256 indexed epoch, bytes32 seed, uint256 tranche);
    event BatchSettled(uint256 indexed batchId, uint256 survivors);
    event EpochFinalized(uint256 indexed epoch, uint8 sixtyMachine, uint8 zeroMachine, uint256[4] sharePerSurvivor);
    event DayFinalized(uint256 indexed day, uint256 pot, uint256 fails, uint256 harvestPerFail);
    event Collected(uint256 indexed batchId, address indexed player, uint256 amount);
    event Claimed(address indexed player, uint256 amount, uint256 tithe);
    event HarvestFunded(address indexed from, uint256 indexed day, uint256 amount);

    // ---------------------------------------------------------------- errors
    error Reentrancy();
    error OnlyLauncher();
    error AlreadyWired();
    error NotWired();
    error OnlyPoolManager();
    error InvalidMachine();
    error ZeroAmount();
    error TooFewEnergies();
    error TooManyEnergies();
    error EthRouteUnavailable();
    error EpochNotOver();
    error SeedNotReady();
    error NothingToSettle();
    error BatchNotSettled();
    error DayNotFinalized();
    error AlreadyCollected();
    error InsufficientUnclaimed();
    error EthTransferFailed();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(
        AetherToken aether_,
        IERC20Minimal imd_,
        IPoolManager poolManager_,
        uint24 ethPoolFee_,
        int24 ethPoolTickSpacing_,
        IHooks ethPoolHooks_
    ) {
        aether = aether_;
        imd = imd_;
        poolManager = poolManager_;
        launcher = msg.sender;
        launchTime = block.timestamp;
        ethPoolFee = ethPoolFee_;
        ethPoolTickSpacing = ethPoolTickSpacing_;
        ethPoolHooks = ethPoolHooks_;
        reserve = new AetherReserve(aether_, address(this));
    }

    /// @notice One-shot wiring by the launcher, in the launch transaction: the AETHER/IMD pool key and hook.
    function wire(PoolKey calldata key) external {
        if (msg.sender != launcher) revert OnlyLauncher();
        if (wired) revert AlreadyWired();
        wired = true;
        aetherKey = key;
        hook = address(key.hooks);
        aetherIsCurrency0 = Currency.unwrap(key.currency0) == address(aether);
        emit Wired(key, address(key.hooks));
    }

    // ---------------------------------------------------------------- time
    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - launchTime) / EPOCH_LENGTH;
    }

    function currentDay() public view returns (uint256) {
        return currentEpoch() / EPOCHS_PER_DAY;
    }

    function epochEnd(uint256 epoch) public view returns (uint256) {
        return launchTime + (epoch + 1) * EPOCH_LENGTH;
    }

    /// @notice True once the Reserve has released its last epoch: energy IMD then refills rewards instead of burning.
    function recyclingMode() public view returns (bool) {
        return reserve.lastReleasedEpoch() >= reserve.EMISSION_EPOCHS();
    }

    // ---------------------------------------------------------------- buying energies
    /// @notice Buy energies on `machine` with `imdAmount` IMD. All of it buys AETHER on the pool; the AETHER is
    ///         burned (or recycled after the Reserve is empty). Energies = AETHER bought / 0.01, rounded down.
    function buyEnergies(uint8 machine, uint256 imdAmount, uint256 minEnergies)
        external
        nonReentrant
        returns (uint256 batchId, uint256 energies)
    {
        if (!wired) revert NotWired();
        if (imdAmount == 0) revert ZeroAmount();
        imd.transferFrom(msg.sender, address(this), imdAmount);
        bytes memory result = poolManager.unlock(abi.encode(uint8(0), imdAmount));
        uint256 aetherOut = abi.decode(result, (uint256));
        return _recordBatch(machine, aetherOut, minEnergies);
    }

    /// @notice Buy energies with ETH: the ETH is swapped to IMD on the ETH/IMD v4 pool, then exactly as above.
    function buyEnergiesWithEth(uint8 machine, uint256 minEnergies)
        external
        payable
        nonReentrant
        returns (uint256 batchId, uint256 energies)
    {
        if (!wired) revert NotWired();
        if (msg.value == 0) revert ZeroAmount();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(PoolId.wrap(keccak256(abi.encode(ethKey()))));
        if (sqrtPriceX96 == 0) revert EthRouteUnavailable();
        bytes memory result = poolManager.unlock(abi.encode(uint8(1), msg.value));
        uint256 aetherOut = abi.decode(result, (uint256));
        return _recordBatch(machine, aetherOut, minEnergies);
    }

    /// @notice The ETH/IMD pool key used by the ETH entry route (native ETH is currency0 in v4).
    function ethKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(imd)),
            fee: ethPoolFee,
            tickSpacing: ethPoolTickSpacing,
            hooks: ethPoolHooks
        });
    }

    function _recordBatch(uint8 machine, uint256 aetherOut, uint256 minEnergies)
        internal
        returns (uint256 batchId, uint256 energies)
    {
        if (machine >= MACHINE_COUNT) revert InvalidMachine();
        energies = aetherOut / ENERGY_UNIT;
        if (energies == 0 || energies < minEnergies) revert TooFewEnergies();
        if (energies > MAX_ENERGIES_PER_BATCH) revert TooManyEnergies();
        uint256 epoch = currentEpoch();
        if (recyclingMode()) {
            recycledFor[epoch + 1] += aetherOut;
            totalRecycled += aetherOut;
        } else {
            aether.burn(aetherOut);
            totalBurned += aetherOut;
        }
        batchId = batches.length;
        batches.push(
            Batch({
                player: msg.sender,
                epoch: uint32(epoch),
                machine: machine,
                energies: uint32(energies),
                survivors: 0,
                settled: false,
                collected: false
            })
        );
        epochs[epoch].energies[machine] += uint32(energies);
        emit EnergiesBought(batchId, msg.sender, epoch, machine, energies, aetherOut);
    }

    /// @dev Pool manager callback: performs the swaps for a purchase.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (uint8 route, uint256 amountIn) = abi.decode(data, (uint8, uint256));
        uint256 imdIn = amountIn;
        if (route == 1) {
            // ETH -> IMD (ETH is currency0, so zeroForOne)
            BalanceDelta d0 = poolManager.swap(
                ethKey(),
                SwapParams({
                    zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
            imdIn = uint256(uint128(d0.amount1()));
            poolManager.settle{value: amountIn}();
        }
        bool zeroForOne = !aetherIsCurrency0; // IMD in, AETHER out
        BalanceDelta d = poolManager.swap(
            aetherKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(imdIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        uint256 aetherOut = aetherIsCurrency0 ? uint256(uint128(d.amount0())) : uint256(uint128(d.amount1()));
        if (route == 0) {
            poolManager.sync(Currency.wrap(address(imd)));
            imd.transfer(address(poolManager), imdIn);
            poolManager.settle();
        }
        poolManager.take(Currency.wrap(address(aether)), address(this), aetherOut);
        return abi.encode(aetherOut);
    }

    // ---------------------------------------------------------------- settlement
    /// @notice Settle the next epoch, processing at most `maxBatches` batches. Permissionless. Call repeatedly.
    ///         First call after an epoch ends locks a block; a later call (2+ blocks later) seeds the epoch,
    ///         pulls the tranche and starts drawing. Returns true when the epoch is finalized.
    function settle(uint256 maxBatches) external returns (bool) {
        if (!wired) revert NotWired();
        uint256 epoch = nextEpochToSettle;
        if (block.timestamp < epochEnd(epoch)) revert EpochNotOver();
        EpochInfo storage ep = epochs[epoch];
        if (ep.seed == bytes32(0)) {
            if (ep.lockBlock == 0 || block.number > uint256(ep.lockBlock) + 1 + SEED_WINDOW) {
                ep.lockBlock = uint64(block.number);
                emit EpochLocked(epoch, block.number);
                return false;
            }
            if (block.number < uint256(ep.lockBlock) + 2) revert SeedNotReady();
            bytes32 h = blockhash(uint256(ep.lockBlock) + 1);
            ep.seed = keccak256(abi.encode(h, epoch, address(this)));
            uint256 tranche = reserve.release(epoch) + recycledFor[epoch];
            ep.tranche = tranche;
            uint256 toShares = tranche * SHARE_BPS / BPS;
            dayInfos[epoch / EPOCHS_PER_DAY].pot += tranche - toShares;
            // random assignment of the 60 / 20 / 20 / 0 Shares
            uint256 r = uint256(ep.seed);
            uint8 sixty = uint8(r % 4);
            uint8 zeroSlot = uint8((r >> 8) % 3);
            uint8 zero = zeroSlot >= sixty ? zeroSlot + 1 : zeroSlot;
            ep.sixtyMachine = sixty;
            ep.zeroMachine = zero;
            uint256 assigned;
            for (uint8 m = 0; m < MACHINE_COUNT; ++m) {
                uint256 w = m == sixty ? 60 : (m == zero ? 0 : 20);
                ep.share[m] = toShares * w / 100;
                assigned += ep.share[m];
            }
            dayInfos[epoch / EPOCHS_PER_DAY].pot += toShares - assigned; // rounding dust
            emit EpochSeeded(epoch, ep.seed, tranche);
        }
        uint256 cursor = settleCursor;
        uint256 len = batches.length;
        uint256 processed;
        while (cursor < len && processed < maxBatches) {
            Batch storage b = batches[cursor];
            if (b.epoch != epoch) break;
            uint256 survivors = drawSurvivors(ep.seed, cursor, b.energies, failBps(b.machine));
            b.survivors = uint32(survivors);
            b.settled = true;
            ep.survivors[b.machine] += uint32(survivors);
            dayInfos[epoch / EPOCHS_PER_DAY].fails += b.energies - survivors;
            emit BatchSettled(cursor, survivors);
            unchecked {
                ++cursor;
                ++processed;
            }
        }
        settleCursor = cursor;
        if (cursor < len && batches[cursor].epoch == epoch) return false; // more pages needed
        _finalizeEpoch(epoch, ep);
        return true;
    }

    function _finalizeEpoch(uint256 epoch, EpochInfo storage ep) internal {
        uint256 day = epoch / EPOCHS_PER_DAY;
        DayInfo storage di = dayInfos[day];
        for (uint8 m = 0; m < MACHINE_COUNT; ++m) {
            uint256 s = ep.survivors[m];
            uint256 share = ep.share[m];
            if (s == 0) {
                di.pot += share; // a machine with no survivors sends its Share to the Harvest
            } else {
                uint256 per = share / s;
                ep.sharePerSurvivor[m] = per;
                di.pot += share - per * s; // rounding dust
            }
        }
        ep.finalized = true;
        nextEpochToSettle = epoch + 1;
        emit EpochFinalized(epoch, ep.sixtyMachine, ep.zeroMachine, ep.sharePerSurvivor);
        if (epoch % EPOCHS_PER_DAY == EPOCHS_PER_DAY - 1) {
            if (di.fails > 0) {
                di.harvestPerFail = di.pot / di.fails;
                uint256 dust = di.pot - di.harvestPerFail * di.fails;
                if (dust > 0) dayInfos[day + 1].pot += dust;
            } else {
                dayInfos[day + 1].pot += di.pot; // nobody failed: nothing to split, the pot rolls into tomorrow
            }
            di.finalized = true;
            emit DayFinalized(day, di.pot, di.fails, di.harvestPerFail);
        }
    }

    /// @notice Deterministic per-energy draws from the epoch seed: 8 draws of 32 bits per keccak.
    function drawSurvivors(bytes32 seed, uint256 batchId, uint256 energies, uint256 failBps_)
        public
        pure
        returns (uint256 survivors)
    {
        uint256 threshold = (failBps_ << 32) / BPS;
        uint256 word;
        for (uint256 i; i < energies; ++i) {
            if (i & 7 == 0) word = uint256(keccak256(abi.encodePacked(seed, batchId, i >> 3)));
            uint256 sample = (word >> ((i & 7) * 32)) & 0xffffffff;
            if (sample >= threshold) ++survivors;
        }
    }

    function failBps(uint8 machine) public pure returns (uint256) {
        if (machine == 0) return 1_000; // Earth
        if (machine == 1) return 3_000; // Water
        if (machine == 2) return 6_000; // Fire
        if (machine == 3) return 9_000; // Air
        revert InvalidMachine();
    }

    // ---------------------------------------------------------------- collecting and claiming
    /// @notice Move the winnings of settled batches into their owners' unclaimed balances. Anyone may call.
    function collect(uint256[] calldata batchIds) external {
        for (uint256 i; i < batchIds.length; ++i) {
            uint256 id = batchIds[i];
            Batch storage b = batches[id];
            if (!b.settled) revert BatchNotSettled();
            if (b.collected) revert AlreadyCollected();
            uint256 day = uint256(b.epoch) / EPOCHS_PER_DAY;
            if (!dayInfos[day].finalized) revert DayNotFinalized();
            b.collected = true;
            uint256 amount = batchPayout(id);
            unclaimed[b.player] += amount;
            totalUnclaimed += amount;
            emit Collected(id, b.player, amount);
        }
    }

    /// @notice Winnings of a settled batch: survivors x Share per survivor + fails x Harvest per fail.
    function batchPayout(uint256 batchId) public view returns (uint256) {
        Batch storage b = batches[batchId];
        if (!b.settled) return 0;
        uint256 day = uint256(b.epoch) / EPOCHS_PER_DAY;
        uint256 fails = uint256(b.energies) - b.survivors;
        return uint256(b.survivors) * epochs[b.epoch].sharePerSurvivor[b.machine] + fails * dayInfos[day].harvestPerFail;
    }

    /// @notice Claim from the unclaimed balance: 10% Tithe to tomorrow's Harvest, 90% to the wallet.
    function claim(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (unclaimed[msg.sender] < amount) revert InsufficientUnclaimed();
        unclaimed[msg.sender] -= amount;
        totalUnclaimed -= amount;
        uint256 tithe = amount * TITHE_BPS / BPS;
        uint256 day = currentDay() + 1;
        dayInfos[day].pot += tithe;
        totalHarvestIn += tithe;
        aether.transfer(msg.sender, amount - tithe);
        emit HarvestFunded(msg.sender, day, tithe);
        emit Claimed(msg.sender, amount, tithe);
    }

    /// @notice Add AETHER to today's Harvest pot. Used by the hook for swap fees and by the airdrop sweep.
    function donateToHarvest(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        aether.transferFrom(msg.sender, address(this), amount);
        uint256 day = currentDay();
        dayInfos[day].pot += amount;
        totalHarvestIn += amount;
        emit HarvestFunded(msg.sender, day, amount);
    }

    // ---------------------------------------------------------------- views
    function epochInfo(uint256 epoch)
        external
        view
        returns (
            uint64 lockBlock,
            bytes32 seed,
            uint256 tranche,
            bool finalized,
            uint8 sixtyMachine,
            uint8 zeroMachine,
            uint32[4] memory energies,
            uint32[4] memory survivors,
            uint256[4] memory share,
            uint256[4] memory sharePerSurvivor
        )
    {
        EpochInfo storage ep = epochs[epoch];
        return (
            ep.lockBlock,
            ep.seed,
            ep.tranche,
            ep.finalized,
            ep.sixtyMachine,
            ep.zeroMachine,
            ep.energies,
            ep.survivors,
            ep.share,
            ep.sharePerSurvivor
        );
    }

    function dayInfo(uint256 day)
        external
        view
        returns (uint256 pot, uint256 fails, uint256 harvestPerFail, bool finalized)
    {
        DayInfo storage di = dayInfos[day];
        return (di.pot, di.fails, di.harvestPerFail, di.finalized);
    }

    function batchCount() external view returns (uint256) {
        return batches.length;
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
    }
}
