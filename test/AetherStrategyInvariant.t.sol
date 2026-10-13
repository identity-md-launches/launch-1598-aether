// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AetherToken} from "../src/AetherToken.sol";
import {AetherStrategy} from "../src/AetherStrategy.sol";

/// @dev Stateful, multi-round actor. All purchases and sponsorship use its finite initial token balance.
contract StrategyHandler is Test {
    AetherToken public immutable token;
    AetherStrategy public immutable strategy;
    mapping(uint256 => bytes32) public salts;
    mapping(uint256 => uint8) public machines;
    uint256 public deposits;
    uint256 public burns;
    uint256 public payouts;
    uint256 public successfulCommits;
    uint256 public successfulReveals;
    uint256 public successfulFinalizations;
    uint256 public successfulClaims;

    constructor(AetherToken token_, AetherStrategy strategy_) {
        token = token_;
        strategy = strategy_;
    }

    function enter(uint8 rawMachine, uint8 rawTickets) external {
        uint256 roundId = strategy.currentRoundId();
        if (roundId == 0) return;
        AetherStrategy.Round memory r = strategy.roundInfo(roundId);
        if (r.finalized || block.timestamp >= r.commitEnd) return;
        uint256 tickets = bound(rawTickets, 1, 50);
        uint256 cost = tickets * strategy.TICKET_PRICE();
        if (cost > token.balanceOf(address(this))) return;
        uint8 machine = rawMachine % 4;
        bytes32 salt = keccak256(abi.encode(strategy.entryCount(), "invariant secret"));
        bytes32 hash = strategy.computeCommitment(roundId, address(this), tickets, machine, salt);
        token.approve(address(strategy), cost);
        uint256 id = strategy.commit(roundId, hash, tickets);
        salts[id] = salt;
        machines[id] = machine;
        deposits += cost;
        burns += tickets * strategy.BURN_PER_TICKET();
        ++successfulCommits;
    }

    function sponsor(uint64 rawAmount, bool direct) external {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(rawAmount, 1, balance > 1e18 ? 1e18 : balance);
        if (direct) {
            token.transfer(address(strategy), amount);
            strategy.syncSurplus();
        } else {
            token.approve(address(strategy), amount);
            strategy.fundNextRound(amount);
        }
        deposits += amount;
    }

    function advance(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 25 hours));
    }

    function revealEntry(uint256 rawId) external {
        uint256 count = strategy.entryCount();
        if (count == 0) return;
        uint256 id = bound(rawId, 1, count);
        AetherStrategy.Entry memory e = strategy.entryInfo(id);
        AetherStrategy.Round memory r = strategy.roundInfo(e.roundId);
        if (e.revealed || block.timestamp < r.commitEnd || block.timestamp >= r.revealEnd) return;
        strategy.reveal(id, machines[id], salts[id]);
        ++successfulReveals;
    }

    function progressRound() external {
        uint256 id = strategy.currentRoundId();
        if (id == 0) {
            strategy.openRound();
            return;
        }
        AetherStrategy.Round memory r = strategy.roundInfo(id);
        if (!r.finalized && block.timestamp >= r.revealEnd) {
            strategy.finalize(id);
            ++successfulFinalizations;
        }
        if (strategy.roundInfo(id).finalized) strategy.openRound();
    }

    function claimEntry(uint256 rawId) external {
        uint256 count = strategy.entryCount();
        if (count == 0) return;
        uint256 id = bound(rawId, 1, count);
        AetherStrategy.Entry memory e = strategy.entryInfo(id);
        if (!e.revealed || e.claimed || !strategy.roundInfo(e.roundId).finalized) return;
        payouts += strategy.claim(id);
        ++successfulClaims;
    }
}

contract AetherStrategyInvariantTest is StdInvariant, Test {
    AetherToken internal token;
    AetherStrategy internal strategy;
    StrategyHandler internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new AetherToken(address(this));
        strategy = new AetherStrategy(address(this));
        strategy.setAether(token);
        handler = new StrategyHandler(token, strategy);
        token.transfer(address(handler), 10_000e18);
        strategy.openRound();
        // Seed a real revealed claim so every invariant trace begins with outstanding liability.
        handler.enter(0, 3);
        handler.enter(1, 7);
        vm.warp(strategy.roundInfo(1).commitEnd);
        handler.revealEntry(1);
        handler.revealEntry(2);
        vm.warp(strategy.roundInfo(1).revealEnd);
        handler.progressRound();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.enter.selector;
        selectors[1] = handler.sponsor.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.revealEntry.selector;
        selectors[4] = handler.progressRound.selector;
        selectors[5] = handler.claimEntry.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allRewardsAreBackedAndNoSupplyIsCreated() public view {
        assertEq(token.balanceOf(address(strategy)), strategy.accountedBalance());
        assertEq(handler.deposits(), handler.burns() + handler.payouts() + token.balanceOf(address(strategy)));
        assertEq(strategy.totalBurned(), handler.burns());
        assertEq(strategy.totalClaimed(), handler.payouts());
        assertEq(token.totalSupply(), token.MAX_SUPPLY() - handler.burns());
        assertEq(token.balanceOf(address(handler)) + token.balanceOf(address(strategy)), token.totalSupply());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_claimLedgerMatchesEveryUnpaidEntry() public view {
        uint256 expected;
        uint256 count = strategy.entryCount();
        for (uint256 id = 1; id <= count; ++id) {
            AetherStrategy.Entry memory e = strategy.entryInfo(id);
            AetherStrategy.Round memory r = strategy.roundInfo(e.roundId);
            if (e.revealed && !e.claimed && r.finalized) expected += r.payoutPerTicket[e.machine] * e.tickets;
        }
        assertEq(strategy.totalClaimable(), expected);
    }
}
