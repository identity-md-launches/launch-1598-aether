// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AetherToken} from "../src/AetherToken.sol";
import {AetherStrategy} from "../src/AetherStrategy.sol";

contract AetherStrategyTest is Test {
    AetherToken internal token;
    AetherStrategy internal strategy;
    address internal owner = makeAddr("launch owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    bytes32 internal constant SALT = keccak256("local test secret, not a production salt");

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new AetherToken(address(this)); // local fixture only; production uses the existing token
        strategy = new AetherStrategy(owner);
        vm.prank(owner);
        strategy.setAether(token);
        token.transfer(alice, 100e18);
        token.transfer(bob, 100e18);
        token.transfer(carol, 100e18);
        token.transfer(dave, 100e18);
    }

    function _fund(uint256 amount) internal {
        token.approve(address(strategy), amount);
        strategy.fundNextRound(amount);
    }

    function _commit(address player, uint8 machine, uint256 tickets, bytes32 salt) internal returns (uint256 id) {
        uint256 roundId = strategy.currentRoundId();
        bytes32 hash = strategy.computeCommitment(roundId, player, tickets, machine, salt);
        vm.startPrank(player);
        token.approve(address(strategy), tickets * strategy.TICKET_PRICE());
        id = strategy.commit(roundId, hash, tickets);
        vm.stopPrank();
    }

    function _revealTime(uint256 roundId) internal {
        vm.warp(strategy.roundInfo(roundId).commitEnd);
    }

    function _finalize(uint256 roundId) internal {
        vm.warp(strategy.roundInfo(roundId).revealEnd);
        strategy.finalize(roundId);
    }

    function _assertAccounting() internal view {
        assertEq(token.balanceOf(address(strategy)), strategy.accountedBalance(), "all funds back named obligations");
        assertEq(
            strategy.totalEntered() + strategy.totalFunded(),
            strategy.totalBurned() + strategy.totalClaimed() + strategy.accountedBalance(),
            "inflows equal burns, payouts and liabilities"
        );
        assertEq(token.totalSupply(), token.MAX_SUPPLY() - strategy.totalBurned(), "only actual burns reduce supply");
    }

    function test_constructorUsesExplicitOwnerAndDoesNotCallExternalContracts() public {
        AetherStrategy fresh = new AetherStrategy(owner);
        assertEq(fresh.owner(), owner);
        assertEq(address(fresh.aether()), address(0));
        vm.expectRevert(AetherStrategy.ZeroAddress.selector);
        new AetherStrategy(address(0));
    }

    function test_configurationIsOwnerOnlyOneTimeAndEmitsEvent() public {
        AetherStrategy fresh = new AetherStrategy(owner);
        vm.expectRevert(AetherStrategy.OnlyOwner.selector);
        fresh.setAether(token);
        vm.startPrank(owner);
        vm.expectRevert(AetherStrategy.ZeroAddress.selector);
        fresh.setAether(AetherToken(address(0)));
        vm.expectRevert(AetherStrategy.InvalidToken.selector);
        fresh.setAether(AetherToken(alice));
        vm.expectEmit(true, false, false, true, address(fresh));
        emit AetherStrategy.AetherConfigured(address(token));
        fresh.setAether(token);
        vm.expectRevert(AetherStrategy.AlreadyConfigured.selector);
        fresh.setAether(token);
        vm.stopPrank();
        assertEq(address(fresh.aether()), address(token));
    }

    function test_unconfiguredValueMovingFunctionsFailClearly() public {
        AetherStrategy fresh = new AetherStrategy(owner);
        vm.expectRevert(AetherStrategy.NotConfigured.selector);
        fresh.openRound();
        vm.expectRevert(AetherStrategy.NotConfigured.selector);
        fresh.fundNextRound(1);
        vm.expectRevert(AetherStrategy.NotConfigured.selector);
        fresh.syncSurplus();
        vm.expectRevert(AetherStrategy.NotConfigured.selector);
        fresh.commit(1, SALT, 1);
        vm.expectRevert(AetherStrategy.NotConfigured.selector);
        fresh.reveal(1, 0, SALT);
        vm.expectRevert(AetherStrategy.NotConfigured.selector);
        fresh.finalize(1);
        vm.expectRevert(AetherStrategy.NotConfigured.selector);
        fresh.claim(1);
    }

    function test_commitBurnsFivePercentAndBacksPrizesWithRemainder() public {
        strategy.openRound();
        uint256 beforeBalance = token.balanceOf(alice);
        uint256 id = _commit(alice, 2, 20, SALT);
        AetherStrategy.Entry memory e = strategy.entryInfo(id);
        assertEq(e.player, alice);
        assertEq(e.roundId, 1);
        assertEq(e.tickets, 20);
        assertFalse(e.revealed);
        assertEq(beforeBalance - token.balanceOf(alice), 0.2e18);
        assertEq(strategy.totalBurned(), 0.01e18);
        assertEq(strategy.roundInfo(1).pot, 0.19e18);
        assertEq(strategy.roundInfo(1).committedTickets, 20);
        assertEq(token.allowance(alice, address(strategy)), 0);
        _assertAccounting();
    }

    function test_lessCrowdedMachinePaysMoreAndClaimsGoOnlyToPlayers() public {
        _fund(1e18 + 3);
        strategy.openRound();
        uint256[4] memory ids;
        ids[0] = _commit(alice, 0, 8, SALT);
        ids[1] = _commit(bob, 1, 4, SALT);
        ids[2] = _commit(carol, 2, 2, SALT);
        ids[3] = _commit(dave, 3, 1, SALT);
        _revealTime(1);
        for (uint8 m; m < 4; ++m) {
            strategy.reveal(ids[m], m, SALT); // third-party reveals cannot take ownership
        }
        _finalize(1);
        AetherStrategy.Round memory r = strategy.roundInfo(1);
        assertEq(r.revealedTickets, 15);
        assertGt(r.payoutPerTicket[3], r.payoutPerTicket[2]);
        assertGt(r.payoutPerTicket[2], r.payoutPerTicket[1]);
        assertGt(r.payoutPerTicket[1], r.payoutPerTicket[0]);
        uint256 callerBefore = token.balanceOf(address(this));
        uint256 liability = strategy.totalClaimable();
        uint256 totalPaid;
        for (uint8 m; m < 4; ++m) {
            AetherStrategy.Entry memory e = strategy.entryInfo(ids[m]);
            uint256 beforeBalance = token.balanceOf(e.player);
            uint256 paid = strategy.claim(ids[m]);
            assertEq(paid, e.tickets * r.payoutPerTicket[m]);
            assertEq(token.balanceOf(e.player), beforeBalance + paid);
            totalPaid += paid;
        }
        assertEq(token.balanceOf(address(this)), callerBefore);
        assertEq(totalPaid, liability);
        assertEq(strategy.totalClaimable(), 0);
        assertEq(totalPaid + strategy.carryover(), r.pot);
        assertTrue(strategy.entryInfo(ids[0]).claimed);
        _assertAccounting();
    }

    function test_sponsorshipDuringRevealOnlyFundsNextRound() public {
        strategy.openRound();
        _commit(alice, 0, 1, SALT);
        _revealTime(1);
        uint256 pot = strategy.roundInfo(1).pot;
        _fund(3e18);
        assertEq(strategy.roundInfo(1).pot, pot);
        assertEq(strategy.carryover(), 3e18);
        _finalize(1);
        strategy.openRound();
        assertEq(strategy.roundInfo(2).pot, 3e18 + pot);
        _assertAccounting();
    }

    function test_emptyMachinesAndDustRollOnceAndOldClaimsRemainBacked() public {
        _fund(1e18 + 7);
        strategy.openRound();
        uint256 id = _commit(alice, 2, 3, SALT);
        _revealTime(1);
        strategy.reveal(id, 2, SALT);
        _finalize(1);
        AetherStrategy.Round memory r = strategy.roundInfo(1);
        uint256 owed = r.payoutPerTicket[2] * 3;
        uint256 rolled = strategy.carryover();
        assertEq(owed + rolled, r.pot);
        assertEq(strategy.totalClaimable(), owed);
        _assertAccounting();
        vm.expectRevert(AetherStrategy.AlreadyFinalized.selector);
        strategy.finalize(1);
        strategy.openRound();
        assertEq(strategy.roundInfo(2).pot, rolled);
        assertEq(strategy.carryover(), 0);
        _finalize(2); // an empty round, without having collected the older claim
        assertEq(strategy.carryover(), rolled);
        assertEq(strategy.totalClaimable(), owed);
        assertEq(strategy.claim(id), owed);
        _assertAccounting();
    }

    function test_noRevealsForfeitsEntriesAndCannotBlockSettlement() public {
        strategy.openRound();
        uint256 id = _commit(alice, 3, 10, SALT);
        _finalize(1);
        assertTrue(strategy.roundInfo(1).finalized);
        assertEq(strategy.totalClaimable(), 0);
        assertEq(strategy.carryover(), 0.095e18);
        assertEq(strategy.totalBurned(), 0.005e18);
        vm.expectRevert(AetherStrategy.NotRevealed.selector);
        strategy.claim(id);
        vm.warp(block.timestamp + 400 days);
        strategy.openRound();
        assertEq(strategy.roundInfo(2).commitEnd, block.timestamp + strategy.COMMIT_DURATION());
        assertEq(strategy.roundInfo(2).pot, 0.095e18);
        _assertAccounting();
    }

    function test_emptyRoundCanFinalizeAndRollSponsorshipWithoutBurning() public {
        _fund(2e18);
        strategy.openRound();
        _finalize(1);
        assertEq(strategy.carryover(), 2e18);
        assertEq(strategy.totalBurned(), 0);
        _assertAccounting();
    }

    function test_deadlinesHaveNoOverlapAndCannotBeExtended() public {
        strategy.openRound();
        uint256 id = _commit(alice, 0, 1, SALT);
        AetherStrategy.Round memory r = strategy.roundInfo(1);
        vm.warp(r.commitEnd - 1);
        vm.expectRevert(AetherStrategy.RevealClosed.selector);
        strategy.reveal(id, 0, SALT);
        _commit(bob, 1, 1, SALT); // last valid commit second
        vm.warp(r.commitEnd);
        vm.expectRevert(AetherStrategy.CommitClosed.selector);
        strategy.commit(1, SALT, 1);
        strategy.reveal(id, 0, SALT);
        vm.warp(r.revealEnd - 1);
        strategy.reveal(2, 1, SALT); // last valid reveal second
        vm.expectRevert(AetherStrategy.RevealStillOpen.selector);
        strategy.finalize(1);
        vm.warp(r.revealEnd);
        vm.expectRevert(AetherStrategy.RevealClosed.selector);
        strategy.reveal(id, 0, SALT);
        strategy.finalize(1);
        assertTrue(strategy.roundInfo(1).finalized);
    }

    function test_invalidAndStaleRoundActionsRevert() public {
        vm.expectRevert(AetherStrategy.InvalidRound.selector);
        strategy.commit(0, SALT, 1);
        vm.expectRevert(AetherStrategy.InvalidRound.selector);
        strategy.finalize(1);
        strategy.openRound();
        vm.expectRevert(AetherStrategy.RoundActive.selector);
        strategy.openRound();
        vm.expectRevert(AetherStrategy.InvalidRound.selector);
        strategy.commit(2, SALT, 1);
        vm.expectRevert(AetherStrategy.InvalidRound.selector);
        strategy.finalize(0);
        vm.expectRevert(AetherStrategy.InvalidRound.selector);
        strategy.roundInfo(2);
        _finalize(1);
        vm.expectRevert(AetherStrategy.CommitClosed.selector);
        strategy.commit(1, SALT, 1);
        strategy.openRound();
        vm.expectRevert(AetherStrategy.InvalidRound.selector);
        strategy.commit(1, SALT, 1);
    }

    function test_invalidTicketAmountsZeroFundingAndCommitmentRevert() public {
        vm.expectRevert(AetherStrategy.ZeroAmount.selector);
        strategy.fundNextRound(0);
        strategy.openRound();
        vm.expectRevert(AetherStrategy.InvalidTickets.selector);
        strategy.commit(1, SALT, 0);
        vm.expectRevert(AetherStrategy.InvalidTickets.selector);
        strategy.commit(1, SALT, 501);
        vm.expectRevert(AetherStrategy.InvalidCommitment.selector);
        strategy.commit(1, bytes32(0), 1);
        _commit(alice, 0, 500, SALT); // inclusive upper bound
        _assertAccounting();
    }

    function test_duplicateCommitmentRejectedWithoutChargingAgain() public {
        strategy.openRound();
        uint256 id = _commit(alice, 0, 1, SALT);
        bytes32 hash = strategy.entryInfo(id).commitment;
        uint256 beforeBalance = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(AetherStrategy.DuplicateCommitment.selector);
        strategy.commit(1, hash, 1);
        assertEq(token.balanceOf(alice), beforeBalance);
        assertEq(strategy.entryCount(), 1);
    }

    function test_copiedCommitmentCannotGriefOrStealOriginalEntry() public {
        strategy.openRound();
        bytes32 hash = strategy.computeCommitment(1, alice, 1, 0, SALT);
        vm.startPrank(bob);
        token.approve(address(strategy), 0.01e18);
        uint256 copied = strategy.commit(1, hash, 1); // attacker front-runs, paying their own ticket
        vm.stopPrank();
        uint256 original = _commit(alice, 0, 1, SALT); // victim is not blocked by the copied hash
        _revealTime(1);
        vm.expectRevert(AetherStrategy.InvalidCommitment.selector);
        strategy.reveal(copied, 0, SALT);
        strategy.reveal(original, 0, SALT);
        assertEq(strategy.entryInfo(original).player, alice);
    }

    function test_wrongSaltMachineAndDuplicateRevealRevert() public {
        strategy.openRound();
        uint256 id = _commit(alice, 2, 1, SALT);
        _revealTime(1);
        vm.expectRevert(AetherStrategy.InvalidMachine.selector);
        strategy.reveal(id, 4, SALT);
        vm.expectRevert(AetherStrategy.InvalidCommitment.selector);
        strategy.reveal(id, 1, SALT);
        vm.expectRevert(AetherStrategy.InvalidCommitment.selector);
        strategy.reveal(id, 2, bytes32(uint256(123)));
        strategy.reveal(id, 2, SALT);
        vm.expectRevert(AetherStrategy.AlreadyRevealed.selector);
        strategy.reveal(id, 2, SALT);
        assertEq(strategy.roundInfo(1).tickets[2], 1);
    }

    function test_commitmentDomainBindsEveryChoiceField() public {
        bytes32 expected =
            keccak256(abi.encode(block.chainid, address(strategy), uint256(1), alice, uint256(5), uint8(2), SALT));
        bytes32 hash = strategy.computeCommitment(1, alice, 5, 2, SALT);
        assertEq(hash, expected);
        assertNotEq(hash, strategy.computeCommitment(2, alice, 5, 2, SALT));
        assertNotEq(hash, strategy.computeCommitment(1, bob, 5, 2, SALT));
        assertNotEq(hash, strategy.computeCommitment(1, alice, 4, 2, SALT));
        assertNotEq(hash, strategy.computeCommitment(1, alice, 5, 3, SALT));
        AetherStrategy other = new AetherStrategy(owner);
        assertNotEq(hash, other.computeCommitment(1, alice, 5, 2, SALT));
        vm.chainId(block.chainid + 1);
        assertNotEq(hash, strategy.computeCommitment(1, alice, 5, 2, SALT));
    }

    function test_wrongTicketCountCommitmentCannotReveal() public {
        strategy.openRound();
        bytes32 hash = strategy.computeCommitment(1, alice, 500, 2, SALT);
        vm.startPrank(alice);
        token.approve(address(strategy), 0.01e18);
        uint256 id = strategy.commit(1, hash, 1);
        vm.stopPrank();
        _revealTime(1);
        vm.expectRevert(AetherStrategy.InvalidCommitment.selector);
        strategy.reveal(id, 2, SALT);
    }

    function test_offlineReceiptEncodingMatchesOnchainCommitment() public {
        // Shared encoding vector with test_strategy_receipt.py; local fixture addresses only.
        address fixtureAddress = address(0x1111111111111111111111111111111111111111);
        address fixturePlayer = address(0x2222222222222222222222222222222222222222);
        bytes32 fixtureSalt = 0x3333333333333333333333333333333333333333333333333333333333333333;
        vm.etch(fixtureAddress, address(strategy).code);
        vm.chainId(1);
        assertEq(
            AetherStrategy(fixtureAddress).computeCommitment(7, fixturePlayer, 3, 2, fixtureSalt),
            0x50a948757244988133b44a399e3d5788278831470434857c4dddaf91775df20b
        );
    }

    function test_claimRequiresValidRevealedFinalizedEntryAndOnlyPaysOnce() public {
        vm.expectRevert(AetherStrategy.InvalidEntry.selector);
        strategy.entryInfo(0);
        vm.expectRevert(AetherStrategy.InvalidEntry.selector);
        strategy.reveal(1, 0, SALT);
        strategy.openRound();
        uint256 id = _commit(alice, 0, 1, SALT);
        vm.expectRevert(AetherStrategy.NotFinalized.selector);
        strategy.claim(id);
        _revealTime(1);
        strategy.reveal(id, 0, SALT);
        _finalize(1);
        vm.warp(block.timestamp + 10 * 365 days); // claims never expire
        strategy.claim(id);
        vm.expectRevert(AetherStrategy.AlreadyClaimed.selector);
        strategy.claim(id);
        vm.expectRevert(AetherStrategy.InvalidEntry.selector);
        strategy.claim(2);
        _assertAccounting();
    }

    function test_directDonationSyncDoesNotSweepOldClaimsOrActivePot() public {
        strategy.openRound();
        uint256 id = _commit(alice, 0, 1, SALT);
        _revealTime(1);
        strategy.reveal(id, 0, SALT);
        _finalize(1);
        uint256 owed = strategy.totalClaimable();
        strategy.openRound();
        uint256 pot = strategy.roundInfo(2).pot;
        token.transfer(address(strategy), 7e18);
        assertEq(strategy.syncSurplus(), 7e18);
        assertEq(strategy.carryover(), 7e18);
        assertEq(strategy.roundInfo(2).pot, pot);
        assertEq(strategy.totalClaimable(), owed);
        vm.expectRevert(AetherStrategy.ZeroAmount.selector);
        strategy.syncSurplus();
        strategy.claim(id);
        _assertAccounting();
    }

    function test_failedTransferFromRollsBackCommitAndAllowsRetry() public {
        strategy.openRound();
        bytes32 hash = strategy.computeCommitment(1, alice, 1, 0, SALT);
        vm.prank(alice);
        vm.expectRevert(AetherToken.InsufficientAllowance.selector);
        strategy.commit(1, hash, 1);
        assertEq(strategy.entryCount(), 0);
        assertEq(strategy.totalEntered(), 0);
        assertFalse(strategy.commitmentUsed(alice, hash));
        _commit(alice, 0, 1, SALT);
        _assertAccounting();
    }

    function test_falseReturningOrInexactTokenCannotCreateUnbackedRewards() public {
        strategy.openRound();
        vm.mockCall(address(token), abi.encodeWithSelector(token.transferFrom.selector), abi.encode(false));
        vm.expectRevert(AetherStrategy.TransferFailed.selector);
        strategy.fundNextRound(1e18);
        vm.expectRevert(AetherStrategy.TransferFailed.selector);
        strategy.commit(1, SALT, 1);
        vm.mockCall(address(token), abi.encodeWithSelector(token.transferFrom.selector), abi.encode(true));
        vm.expectRevert(AetherStrategy.InexactTransfer.selector);
        strategy.fundNextRound(1e18);
        vm.expectRevert(AetherStrategy.InexactTransfer.selector);
        strategy.commit(1, SALT, 1);
        vm.clearMockedCalls();
        assertEq(strategy.entryCount(), 0);
        assertEq(strategy.totalEntered(), 0);
        assertEq(strategy.carryover(), 0);
        assertEq(strategy.totalFunded(), 0);
        _assertAccounting();
    }

    function test_burnFailureRollsBackTransferAndCommit() public {
        strategy.openRound();
        uint256 beforeBalance = token.balanceOf(alice);
        bytes32 hash = strategy.computeCommitment(1, alice, 1, 0, SALT);
        vm.prank(alice);
        token.approve(address(strategy), 0.01e18);
        vm.mockCallRevert(address(token), abi.encodeWithSelector(token.burn.selector), "burn failure");
        vm.prank(alice);
        vm.expectRevert(bytes("burn failure"));
        strategy.commit(1, hash, 1);
        vm.clearMockedCalls();
        assertEq(token.balanceOf(alice), beforeBalance);
        assertEq(strategy.entryCount(), 0);
        assertEq(strategy.totalBurned(), 0);
        _assertAccounting();
    }

    function test_failedPayoutCanRetryWithoutBlockingFinalizationOrOtherClaims() public {
        strategy.openRound();
        uint256 a = _commit(alice, 0, 1, SALT);
        uint256 b = _commit(bob, 1, 1, SALT);
        _revealTime(1);
        strategy.reveal(a, 0, SALT);
        strategy.reveal(b, 1, SALT);
        vm.mockCall(address(token), abi.encodeWithSelector(token.transfer.selector, alice), abi.encode(false));
        _finalize(1); // no token interaction even when payout transfer fails
        uint256 owed = strategy.totalClaimable();
        vm.expectRevert(AetherStrategy.TransferFailed.selector);
        strategy.claim(a);
        assertFalse(strategy.entryInfo(a).claimed);
        assertEq(strategy.totalClaimable(), owed);
        assertEq(strategy.totalClaimed(), 0);
        strategy.claim(b);
        strategy.openRound();
        vm.clearMockedCalls();
        strategy.claim(a);
        _assertAccounting();
    }

    function testFuzz_conservationWithPartialRevealsAndRounding(
        uint16[4] memory rawTickets,
        uint8 revealMask,
        uint96 rawSponsor,
        bool reverseClaims
    ) public {
        uint256 sponsor = bound(rawSponsor, 1, 50e18);
        _fund(sponsor);
        strategy.openRound();
        address[4] memory players = [alice, bob, carol, dave];
        uint256[4] memory ids;
        uint256[4] memory tickets;
        for (uint8 m; m < 4; ++m) {
            tickets[m] = bound(rawTickets[m], 1, 500);
            ids[m] = _commit(players[m], m, tickets[m], SALT);
        }
        _assertAccounting();
        _revealTime(1);
        for (uint8 m; m < 4; ++m) {
            if (revealMask & (uint8(1) << m) != 0) strategy.reveal(ids[m], m, SALT);
        }
        _finalize(1);
        AetherStrategy.Round memory r = strategy.roundInfo(1);
        uint256 allocated;
        for (uint8 m; m < 4; ++m) {
            if (revealMask & (uint8(1) << m) != 0) {
                assertEq(r.payoutPerTicket[m], r.pot / 4 / tickets[m]);
                allocated += r.payoutPerTicket[m] * tickets[m];
            }
        }
        assertEq(strategy.totalClaimable(), allocated);
        assertEq(strategy.carryover(), r.pot - allocated);
        _assertAccounting();
        strategy.openRound(); // old claims remain independent of new round financing
        _fund(1e18);
        for (uint8 i; i < 4; ++i) {
            uint8 m = reverseClaims ? 3 - i : i;
            if (revealMask & (uint8(1) << m) != 0) strategy.claim(ids[m]);
        }
        assertEq(strategy.totalClaimable(), 0);
        _assertAccounting();
    }

    function testFuzz_splittingTicketsAcrossWalletsHasNoPayoutBonus(uint16 rawA, uint16 rawB) public {
        uint256 a = bound(rawA, 1, 250);
        uint256 b = bound(rawB, 1, 250);
        strategy.openRound();
        uint256 first = _commit(alice, 0, a, SALT);
        uint256 second = _commit(bob, 0, b, SALT);
        uint256 together = _commit(carol, 1, a + b, SALT);
        _revealTime(1);
        strategy.reveal(first, 0, SALT);
        strategy.reveal(second, 0, SALT);
        strategy.reveal(together, 1, SALT);
        _finalize(1);
        uint256 splitPayout = strategy.claim(first) + strategy.claim(second);
        assertEq(splitPayout, strategy.claim(together));
        _assertAccounting();
    }
}

/// @dev Deliberately adversarial token used only to exercise callback boundaries. Not a launch asset.
contract CallbackStrategyToken {
    mapping(address => uint256) public balanceOf;
    AetherStrategy public target;
    bytes public callback;
    bool public attackOnTransferFrom;
    bool public attackOnBurn;
    bool public attackOnTransfer;
    bool public callbackSucceeded;
    bytes public callbackResult;

    function setup(AetherStrategy target_) external {
        target = target_;
        balanceOf[msg.sender] = 100e18;
    }

    function arm(bytes calldata data, bool onPull, bool onBurn, bool onPush) external {
        callback = data;
        attackOnTransferFrom = onPull;
        attackOnBurn = onBurn;
        attackOnTransfer = onPush;
    }

    function _attack() private {
        (callbackSucceeded, callbackResult) = address(target).call(callback);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (attackOnTransferFrom) _attack();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function burn(uint256 amount) external {
        if (attackOnBurn) _attack();
        balanceOf[msg.sender] -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (attackOnTransfer) _attack();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract AetherStrategyReentrancyTest is Test {
    CallbackStrategyToken internal token;
    AetherStrategy internal strategy;
    bytes32 internal constant SALT = keccak256("test secret");

    function setUp() public {
        strategy = new AetherStrategy(address(this));
        token = new CallbackStrategyToken();
        token.setup(strategy);
        strategy.setAether(AetherToken(address(token)));
    }

    function _assertBlocked() internal view {
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(AetherStrategy.Reentrancy.selector));
        assertEq(token.balanceOf(address(strategy)), strategy.accountedBalance());
    }

    function test_reentrantPullCannotOpenRoundWhileFunding() public {
        token.arm(abi.encodeCall(strategy.openRound, ()), true, false, false);
        strategy.fundNextRound(1e18);
        assertEq(strategy.currentRoundId(), 0);
        assertEq(strategy.carryover(), 1e18);
        _assertBlocked();
    }

    function test_reentrantBurnCannotDoubleCommit() public {
        strategy.openRound();
        bytes32 hash = strategy.computeCommitment(1, address(this), 1, 0, SALT);
        token.arm(abi.encodeCall(strategy.commit, (1, SALT, 1)), false, true, false);
        strategy.commit(1, hash, 1);
        assertEq(strategy.entryCount(), 1);
        assertEq(strategy.totalBurned(), strategy.BURN_PER_TICKET());
        _assertBlocked();
    }

    function test_reentrantPayoutCannotDoubleClaimOrSyncBacking() public {
        strategy.openRound();
        for (uint8 m; m < 2; ++m) {
            bytes32 hash = strategy.computeCommitment(1, address(this), 1, m, SALT);
            strategy.commit(1, hash, 1);
        }
        vm.warp(strategy.roundInfo(1).commitEnd);
        strategy.reveal(1, 0, SALT);
        strategy.reveal(2, 1, SALT);
        vm.warp(strategy.roundInfo(1).revealEnd);
        strategy.finalize(1);
        uint256 owed = strategy.totalClaimable();
        token.arm(abi.encodeCall(strategy.claim, (1)), false, false, true);
        uint256 paid = strategy.claim(1);
        assertEq(strategy.totalClaimable(), owed - paid);
        _assertBlocked();
        token.arm(abi.encodeCall(strategy.syncSurplus, ()), false, false, true);
        strategy.claim(2);
        assertEq(strategy.totalClaimable(), 0);
        _assertBlocked();
    }
}
