// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AetherBase, MockIMD} from "./AetherBase.t.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {AetherGame} from "../src/AetherGame.sol";
import {AetherHook} from "../src/AetherHook.sol";
import {AetherReserve} from "../src/AetherReserve.sol";
import {AetherToken} from "../src/AetherToken.sol";
import {AetherLPVault} from "../src/AetherLPVault.sol";
import {AetherLaunch} from "../src/AetherLaunch.sol";

contract AetherGameTest is AetherBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------------ launch
    function test_launch_allocationsAndSupply() public view {
        assertEq(token.totalSupply(), 10_000e18);
        assertEq(token.MAX_SUPPLY(), 10_000e18);
        assertEq(token.balanceOf(address(airdrop)), 1_000e18);
        assertEq(token.balanceOf(address(reserve)), 8_000e18);
        assertEq(token.balanceOf(address(launch)), 0);
        // the 1,000 LP AETHER is in the pool (minus at most rounding dust left in the vault)
        assertLt(token.balanceOf(address(vault)), 1e12);
        assertEq(token.balanceOf(address(manager)) + token.balanceOf(address(vault)), 1_000e18);
        assertTrue(vault.opened());
        assertGt(vault.liquidity(), 0);
        assertTrue(game.wired());
        assertEq(game.hook(), address(hook));
        assertEq(hook.vault(), address(vault));
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(sqrtPriceX96, vault.openingSqrtPriceX96());
    }

    function test_launch_hookAddressCarriesFlags() public view {
        uint160 flags = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(flags, hook.requiredFlags());
        assertTrue(Hooks.isValidHookAddress(IHooks(address(hook)), 3000));
    }

    function test_launch_wiringIsOneShot() public {
        vm.expectRevert(AetherGame.AlreadyWired.selector);
        vm.prank(address(launch));
        game.wire(key);
        vm.expectRevert(AetherGame.OnlyLauncher.selector);
        game.wire(key);
        vm.expectRevert(AetherHook.AlreadyWired.selector);
        vm.prank(address(launch));
        hook.wire(alice);
        vm.expectRevert(AetherLPVault.AlreadyOpened.selector);
        vault.open();
    }

    function test_launch_onEmptyChainDefersPoolOpen() public {
        // deploy against an address with no code: constructor must still succeed, open() stays callable later
        address noManager = makeAddr("no-manager");
        AetherLaunch l = new AetherLaunch(TEST_ROOT, address(imd), noManager, 3000, 60, address(0), OPENING_PRICE);
        assertFalse(l.vault().opened());
        assertEq(l.token().balanceOf(address(l.vault())), 1_000e18);
        assertEq(l.token().totalSupply(), 10_000e18);
    }

    function test_token_noMintAndBurnOnlyDecreases() public {
        _fund(alice, 1_000e18);
        _buy(alice, 0, 100e18);
        assertLt(token.totalSupply(), 10_000e18);
        assertEq(token.totalSupply(), 10_000e18 - game.totalBurned());
        vm.expectRevert(AetherToken.InsufficientBalance.selector);
        vm.prank(alice);
        token.burn(1);
    }

    // ------------------------------------------------------------------ reserve
    function test_reserve_onlyGameAndInOrder() public {
        vm.expectRevert(AetherReserve.OnlyGame.selector);
        reserve.release(0);
        vm.prank(address(game));
        vm.expectRevert(AetherReserve.EpochOrder.selector);
        reserve.release(1);
    }

    function test_reserve_scheduleDecreasesAndNeverOverdraws() public view {
        assertApproxEqRel(reserve.dailyAmount(0), 52.4457e18, 1e14);
        assertApproxEqRel(reserve.dailyAmount(120), reserve.dailyAmount(0) / 2, 1e12); // half-life 120 days
        assertGt(reserve.scheduledTranche(0), reserve.scheduledTranche(144));
        assertEq(reserve.scheduledTranche(reserve.EMISSION_EPOCHS()), 0);
        uint256 total;
        for (uint256 d; d < 365; ++d) {
            total += reserve.dailyAmount(d);
        }
        assertLe(total, 8_000e18);
        assertApproxEqRel(total, 8_000e18, 1e9);
    }

    function test_reserve_fullEmissionEndsAtExactlyZero() public {
        uint256 n = reserve.EMISSION_EPOCHS();
        // first year of epochs released one by one (gas-bounded sample), then jump to the final sweep
        uint256 sum;
        vm.startPrank(address(game));
        for (uint256 e; e < 2 * 144; ++e) {
            sum += reserve.release(e);
        }
        assertEq(sum, reserve.released());
        assertLe(sum, 8_000e18);
        // jump the release cursor to the last epoch (storage slot 1 = lastReleasedEpoch)
        vm.store(address(reserve), bytes32(uint256(1)), bytes32(n - 1));
        uint256 last = reserve.release(n - 1);
        assertEq(last, 8_000e18 - sum, "final sweep releases the whole remainder");
        assertEq(reserve.release(n), 0); // after the span: nothing, never reverts
        vm.stopPrank();
        assertEq(reserve.remaining(), 0);
        assertEq(reserve.released(), 8_000e18);
        assertEq(token.balanceOf(address(game)), 8_000e18);
    }

    function test_reserve_scheduledSumNeverExceedsReserve() public view {
        uint256 n = reserve.EMISSION_EPOCHS();
        uint256 sum;
        for (uint256 d; d < 365; ++d) {
            sum += reserve.scheduledTranche(d * 144) * 144;
        }
        assertLe(sum, 8_000e18);
        assertGt(sum, 8_000e18 - 1e18); // rounding dust only, swept by the last epoch
        assertEq(reserve.scheduledTranche(n - 1), reserve.dailyAmount(364) / 144);
    }

    // ------------------------------------------------------------------ energies
    function test_buy_burnsAndRecordsBatch() public {
        _fund(alice, 1_000e18);
        uint256 supplyBefore = token.totalSupply();
        (uint256 id, uint256 energies) = _buy(alice, 2, 100e18);
        assertEq(id, 0);
        assertGt(energies, 0);
        uint256 burned = supplyBefore - token.totalSupply();
        assertEq(burned, game.totalBurned());
        assertEq(energies, burned / game.ENERGY_UNIT());
        assertEq(imd.balanceOf(alice), 900e18);
        assertEq(imd.balanceOf(address(game)), 0); // 100% of the IMD went to the pool
        assertEq(token.balanceOf(address(game)), 0); // nothing kept, all burned
        (address player, uint32 epoch, uint8 machine, uint32 n,,,) = game.batches(0);
        assertEq(player, alice);
        assertEq(epoch, 0);
        assertEq(machine, 2);
        assertEq(n, energies);
    }

    function test_buy_gameIsExemptFromHookFee() public {
        _fund(alice, 1_000e18);
        (, uint256 pot,,) = game.dayInfo(0);
        _buy(alice, 0, 100e18);
        (, uint256 potAfter,,) = game.dayInfo(0);
        assertEq(potAfter, pot); // no hook fee taken on the game's own swap even at 99%
    }

    function test_buy_reverts() public {
        _fund(alice, 100_000e18);
        vm.prank(alice);
        vm.expectRevert(AetherGame.ZeroAmount.selector);
        game.buyEnergies(0, 0, 0);
        vm.prank(alice);
        vm.expectRevert(AetherGame.InvalidMachine.selector);
        game.buyEnergies(4, 10e18, 0);
        vm.prank(alice);
        vm.expectRevert(AetherGame.TooFewEnergies.selector);
        game.buyEnergies(0, 1e12, 0); // dust: less than one energy
        vm.prank(alice);
        vm.expectRevert(AetherGame.TooFewEnergies.selector);
        game.buyEnergies(0, 10e18, 1_000_000); // slippage guard
        vm.prank(alice);
        vm.expectRevert(AetherGame.TooManyEnergies.selector);
        game.buyEnergies(0, 50_000e18, 0); // whale batch over the cap
    }

    function test_buy_whalePaysMorePerEnergy() public {
        _fund(alice, 10_000e18);
        _fund(bob, 10_000e18);
        _buy(alice, 0, 10e18);
        uint256 small = game.totalBurned();
        _buy(bob, 0, 400e18);
        uint256 big = game.totalBurned() - small;
        // 40x the IMD buys less than 40x the AETHER (hence energies): price impact is the whale tax
        assertLt(big, small * 40);
    }

    // ------------------------------------------------------------------ settlement and randomness
    function test_settle_requiresEpochOver() public {
        vm.expectRevert(AetherGame.EpochNotOver.selector);
        game.settle(10);
    }

    function test_settle_lockThenSeedFromNextBlockHash() public {
        _fund(alice, 1_000e18);
        _buy(alice, 1, 50e18);
        vm.warp(game.epochEnd(0));
        assertFalse(game.settle(10));
        (uint64 lockBlock,,,,,,,,,) = game.epochInfo(0);
        assertEq(lockBlock, block.number);
        vm.expectRevert(AetherGame.SeedNotReady.selector);
        game.settle(10); // same block
        vm.roll(block.number + 1);
        vm.expectRevert(AetherGame.SeedNotReady.selector);
        game.settle(10); // lock + 1: its hash is not known yet
        vm.roll(block.number + 1);
        assertTrue(game.settle(10));
        (, bytes32 seed, uint256 tranche, bool finalized,,,,,,) = game.epochInfo(0);
        assertEq(seed, keccak256(abi.encode(blockhash(lockBlock + 1), uint256(0), address(game))));
        assertEq(tranche, reserve.scheduledTranche(0));
        assertTrue(finalized);
        assertEq(game.nextEpochToSettle(), 1);
    }

    function test_settle_missedWindowRelocks() public {
        vm.warp(game.epochEnd(0));
        assertFalse(game.settle(10));
        (uint64 lockBlock,,,,,,,,,) = game.epochInfo(0);
        vm.roll(uint256(lockBlock) + 300); // blockhash(lock + 1) no longer available
        assertFalse(game.settle(10)); // relocks instead of using a zero hash
        (uint64 newLock, bytes32 seed,,,,,,,,) = game.epochInfo(0);
        assertEq(newLock, block.number);
        assertEq(seed, bytes32(0));
        vm.roll(block.number + 2);
        assertTrue(game.settle(10));
    }

    function test_settle_sharesSumToTrancheAndPaged() public {
        _fund(alice, 10_000e18);
        _fund(bob, 10_000e18);
        for (uint8 m; m < 4; ++m) {
            _buy(alice, m, 20e18);
            _buy(bob, m, 20e18);
        }
        vm.warp(game.epochEnd(0));
        game.settle(100);
        vm.roll(block.number + 2);
        assertFalse(game.settle(3)); // 8 batches, page of 3
        assertFalse(game.settle(3));
        assertTrue(game.settle(3));
        (
            ,,
            uint256 tranche,
            bool finalized,
            uint8 sixty,
            uint8 zero,,
            uint32[4] memory survivors,
            uint256[4] memory share,
            uint256[4] memory sps
        ) = game.epochInfo(0);
        assertTrue(finalized);
        assertTrue(sixty != zero);
        assertEq(share[sixty], tranche * 9000 / 10000 * 60 / 100);
        assertEq(share[zero], 0);
        uint256 paid;
        uint256 toPot;
        for (uint8 m; m < 4; ++m) {
            if (survivors[m] == 0) {
                toPot += share[m];
            } else {
                paid += sps[m] * survivors[m];
                toPot += share[m] - sps[m] * survivors[m];
            }
        }
        (uint256 pot,,,) = game.dayInfo(0);
        assertEq(paid + toPot + (tranche - tranche * 9000 / 10000), tranche, "whole tranche accounted");
        assertEq(pot, toPot + (tranche - tranche * 9000 / 10000), "pot holds the 10% plus dust and empty shares");
        // sum of batch payouts (share part) equals paid
        uint256 sumShare;
        for (uint256 i; i < 8; ++i) {
            (,, uint8 m,, uint32 s,,) = game.batches(i);
            sumShare += uint256(s) * sps[m];
        }
        assertEq(sumShare, paid);
    }

    function test_settle_noEnergiesSendsSharesToHarvest() public {
        _settleEpoch(0);
        (,, uint256 tranche,,,,,,,) = game.epochInfo(0);
        (uint256 pot,,,) = game.dayInfo(0);
        assertEq(pot, tranche);
        assertEq(token.balanceOf(address(game)), tranche);
    }

    function test_drawSurvivors_matchesFailRates() public view {
        bytes32 seed = keccak256("seed");
        uint256 n = 20_000;
        uint256 earth = game.drawSurvivors(seed, 1, n, 1000);
        uint256 air = game.drawSurvivors(seed, 2, n, 9000);
        assertApproxEqRel(earth, n * 9 / 10, 2e16);
        assertApproxEqRel(air, n / 10, 6e16);
        assertEq(game.drawSurvivors(seed, 1, n, 1000), earth); // deterministic
    }

    // ------------------------------------------------------------------ full day: harvest, collect, claim
    function test_fullDay_everyPotFullyDistributedAndConservation() public {
        _fund(alice, 100_000e18);
        _fund(bob, 100_000e18);
        _fund(carol, 100_000e18);
        uint256 batchCount;
        for (uint256 e; e < 144; ++e) {
            if (e % 7 == 0) {
                _buy(alice, 0, 5e18);
                _buy(bob, 3, 5e18);
                _buy(carol, uint8(e % 4), 3e18);
                batchCount += 3;
            }
            _settleEpoch(e);
        }
        (uint256 pot, uint256 fails, uint256 hpf, bool finalized) = game.dayInfo(0);
        assertTrue(finalized);
        assertGt(fails, 0);
        assertEq(hpf, pot / fails);
        // collect everything
        uint256[] memory ids = new uint256[](batchCount);
        for (uint256 i; i < batchCount; ++i) {
            ids[i] = i;
        }
        game.collect(ids);
        vm.expectRevert(AetherGame.AlreadyCollected.selector);
        game.collect(ids);
        uint256 owed = game.unclaimed(alice) + game.unclaimed(bob) + game.unclaimed(carol);
        assertEq(owed, game.totalUnclaimed());
        // conservation: everything the game received is owed to players or sits in the carried pot
        uint256 totalIn = reserve.released();
        (uint256 carried,,,) = game.dayInfo(1);
        assertEq(owed + carried, totalIn, "tranches fully distributed");
        assertEq(token.balanceOf(address(game)), owed + carried, "balance backs obligations");
        // claim: 90% out, 10% tithe to tomorrow
        uint256 a = game.unclaimed(alice);
        vm.prank(alice);
        game.claim(a);
        assertEq(token.balanceOf(alice), a - a / 10);
        (uint256 potNext,,,) = game.dayInfo(game.currentDay() + 1);
        assertEq(potNext, a / 10 + (game.currentDay() + 1 == 1 ? carried : 0));
        assertEq(game.unclaimed(alice), 0);
        vm.prank(alice);
        vm.expectRevert(AetherGame.InsufficientUnclaimed.selector);
        game.claim(1);
        // harvest premium: Air (bob) failed more and collected more harvest per energy than Earth (alice)
        assertGt(game.unclaimed(bob), 0);
    }

    function test_collect_requiresSettledAndFinalizedDay() public {
        _fund(alice, 1_000e18);
        _buy(alice, 0, 10e18);
        uint256[] memory ids = new uint256[](1);
        vm.expectRevert(AetherGame.BatchNotSettled.selector);
        game.collect(ids);
        _settleEpoch(0);
        vm.expectRevert(AetherGame.DayNotFinalized.selector);
        game.collect(ids);
    }

    function test_harvest_riskyMachineEarnsMoreHarvestPerEnergy() public {
        _fund(alice, 100_000e18);
        _fund(bob, 100_000e18);
        for (uint256 e; e < 144; ++e) {
            if (e < 20) {
                _buy(alice, 0, 5e18);
                _buy(bob, 3, 5e18);
            }
            _settleEpoch(e);
        }
        uint256 earthHarvest;
        uint256 airHarvest;
        uint256 earthN;
        uint256 airN;
        (,, uint256 hpf,) = game.dayInfo(0);
        for (uint256 i; i < 40; ++i) {
            (, uint32 ep, uint8 m, uint32 n, uint32 s,,) = game.batches(i);
            ep;
            if (m == 0) {
                earthHarvest += (n - s) * hpf;
                earthN += n;
            } else {
                airHarvest += (n - s) * hpf;
                airN += n;
            }
        }
        assertGt(airHarvest * earthN, earthHarvest * airN); // more harvest per energy on Air
    }

    // ------------------------------------------------------------------ hook fee
    function test_hook_feeDecays99to5() public {
        assertEq(hook.currentFeePct(), 99);
        vm.warp(block.timestamp + 60);
        assertEq(hook.currentFeePct(), 98);
        vm.warp(block.timestamp + 49 * 60);
        assertEq(hook.currentFeePct(), 49);
        vm.warp(block.timestamp + 44 * 60);
        assertEq(hook.currentFeePct(), 5);
        vm.warp(block.timestamp + 365 days);
        assertEq(hook.currentFeePct(), 5);
    }

    function test_hook_buyFeeGoesToHarvest() public {
        _fund(alice, 10_000e18);
        (uint256 potBefore,,,) = game.dayInfo(0);
        uint256 supply = token.totalSupply();
        BalanceDelta d = _routerBuy(alice, 100e18);
        int128 aetherOut = aetherIsZero ? d.amount0() : d.amount1();
        uint256 received = token.balanceOf(alice);
        (uint256 potAfter,,,) = game.dayInfo(0);
        uint256 fee = potAfter - potBefore;
        assertGt(fee, 0);
        assertEq(uint256(uint128(aetherOut)), received);
        // 99% of the gross AETHER output was kept as fee
        assertApproxEqRel(fee, (received + fee) * 99 / 100, 1e12);
        assertEq(token.balanceOf(address(game)), fee);
        assertEq(token.totalSupply(), supply); // fees are not burned, they feed the Harvest
    }

    function test_hook_sellFeeAtFloor() public {
        _fund(alice, 10_000e18);
        _skipFeeDecay();
        _routerBuy(alice, 1_000e18);
        uint256 have = token.balanceOf(alice);
        (uint256 potBefore,,,) = game.dayInfo(game.currentDay());
        _routerSell(alice, have);
        (uint256 potAfter,,,) = game.dayInfo(game.currentDay());
        assertEq(potAfter - potBefore, have * 5 / 100);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_hook_rejectsExactOutput() public {
        _fund(alice, 10_000e18);
        bool zeroForOne = !aetherIsZero;
        vm.prank(alice);
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: 1e18,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_hook_onlyVaultMayInitializeAnotherPool() public {
        PoolKey memory other = PoolKey({
            currency0: key.currency0, currency1: key.currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        uint160 price = vault.openingSqrtPriceX96();
        vm.expectRevert();
        manager.initialize(other, price);
    }

    function test_hook_onlyPoolManager() public {
        vm.expectRevert(AetherHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(vault), key, 0);
    }

    // ------------------------------------------------------------------ LP vault
    function test_vault_compoundGrowsLiquidity() public {
        _fund(alice, 100_000e18);
        _skipFeeDecay();
        uint128 before = vault.liquidity();
        _routerBuy(alice, 5_000e18);
        _routerSell(alice, token.balanceOf(alice) / 2);
        vault.compound();
        assertGt(vault.liquidity(), before);
        // position is still a single range owned by the vault: compounding twice with nothing new is a no-op
        uint128 after1 = vault.liquidity();
        vault.compound();
        assertEq(vault.liquidity(), after1);
    }

    function test_vault_singleSidedAtOpen() public view {
        int24 current = TickMath.getTickAtSqrtPrice(vault.openingSqrtPriceX96());
        if (aetherIsZero) assertGt(vault.tickLower(), current);
        else assertLe(vault.tickUpper(), current);
        assertEq(vault.tickUpper() - vault.tickLower(), vault.RANGE_TICKS());
        assertEq(imd.balanceOf(address(manager)), 0); // no IMD was needed
    }

    // ------------------------------------------------------------------ recycling mode
    function test_recycling_afterReserveEmptyEnergyAetherRefillsTranches() public {
        // jump both cursors to the last emission epoch (game slot 10 = nextEpochToSettle, reserve slot 1)
        uint256 n = reserve.EMISSION_EPOCHS();
        vm.store(address(game), bytes32(uint256(10)), bytes32(n - 1));
        vm.store(address(reserve), bytes32(uint256(1)), bytes32(n - 1));
        assertFalse(game.recyclingMode());
        _settleEpoch(n - 1); // final sweep: the whole Reserve is released
        assertEq(reserve.released(), 8_000e18);
        assertEq(reserve.remaining(), 0);
        assertTrue(game.recyclingMode());
        _fund(alice, 1_000e18);
        _skipFeeDecay();
        uint256 supply = token.totalSupply();
        uint256 burned = game.totalBurned();
        _buy(alice, 0, 50e18);
        assertEq(token.totalSupply(), supply); // nothing burned any more
        assertEq(game.totalBurned(), burned);
        uint256 epoch = game.currentEpoch();
        assertGt(game.recycledFor(epoch + 1), 0);
        assertEq(game.recycledFor(epoch + 1), game.totalRecycled());
        // the recycled AETHER becomes the tranche of the next epoch
        for (uint256 e = game.nextEpochToSettle(); e <= epoch + 1; ++e) {
            _settleEpoch(e);
        }
        (,, uint256 tranche,,,,,,,) = game.epochInfo(epoch + 1);
        assertEq(tranche, game.totalRecycled());
    }

    // ------------------------------------------------------------------ ETH route
    function test_ethRoute_unavailableWithoutPool() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(AetherGame.EthRouteUnavailable.selector);
        game.buyEnergiesWithEth{value: 1 ether}(0, 0);
    }

    function test_ethRoute_swapsEthToImdThenBuys() public {
        // create an ETH/IMD pool at 1 ETH = 1000 IMD with two-sided liquidity
        PoolKey memory ek = game.ethKey();
        uint160 p = uint160(_sqrt(1000e18 * 1e18) * (uint256(1) << 96) / 1e18);
        manager.initialize(ek, p);
        imd.mint(address(this), 10_000_000e18);
        imd.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 1000 ether);
        lpRouter.modifyLiquidity{value: 500 ether}(
            ek, ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e22, salt: 0}), ""
        );
        vm.deal(alice, 1 ether);
        uint256 supply = token.totalSupply();
        vm.prank(alice);
        (, uint256 energies) = game.buyEnergiesWithEth{value: 0.1 ether}(1, 1);
        assertGt(energies, 0);
        assertLt(token.totalSupply(), supply);
        assertEq(address(game).balance, 0);
        assertEq(imd.balanceOf(address(game)), 0);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }

    receive() external payable {}
}

/// @dev Same suite with IMD at a low address so AETHER is currency1 (the other ordering branch).
contract AetherGameImdLowTest is AetherGameTest {
    function imdAddress() internal pure override returns (address) {
        return address(0x0000000000000000000000000000000000001111);
    }
}
