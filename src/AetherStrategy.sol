// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AetherToken} from "./AetherToken.sol";

/// @title AETHER sealed-choice strategy rounds
/// @notice Optional companion for the EXISTING AETHER token. Four equally funded machines compete for
///         tickets: a less crowded machine pays more per ticket. There is no random draw or new issuance.
///         Entry is irreversible, including when a player fails to reveal. Only configured AetherToken
///         semantics (18 decimals, exact transfers, burn) are supported. See STRATEGY.md.
contract AetherStrategy {
    uint256 public constant TICKET_PRICE = 0.01e18;
    uint256 public constant BURN_PER_TICKET = 0.0005e18; // 5%; the other 95% backs prizes
    uint256 public constant MAX_TICKETS_PER_ENTRY = 500; // gas/UX bound, not a wallet/whale cap
    uint256 public constant COMMIT_DURATION = 20 hours;
    uint256 public constant REVEAL_DURATION = 4 hours;
    uint8 public constant MACHINE_COUNT = 4;

    /// @notice The launch's owner may bind the existing token once, and has no other power.
    address public immutable owner;
    AetherToken public aether;

    struct Round {
        uint256 commitEnd;
        uint256 revealEnd;
        uint256 pot;
        uint256 committedTickets;
        uint256 revealedTickets;
        uint256[4] tickets;
        uint256[4] payoutPerTicket;
        bool finalized;
    }

    struct Entry {
        address player;
        uint256 roundId;
        bytes32 commitment;
        uint256 tickets;
        uint8 machine;
        bool revealed;
        bool claimed;
    }

    mapping(uint256 => Round) private _rounds;
    mapping(uint256 => Entry) private _entries;
    mapping(address => mapping(bytes32 => bool)) public commitmentUsed;
    uint256 public currentRoundId;
    uint256 public entryCount;
    uint256 public carryover;
    uint256 public totalClaimable;
    uint256 public totalEntered;
    uint256 public totalFunded;
    uint256 public totalBurned;
    uint256 public totalClaimed;
    uint256 private _lock = 1;

    event AetherConfigured(address indexed token);
    event NextRoundFunded(address indexed from, uint256 amount);
    event SurplusSynced(uint256 amount);
    event RoundOpened(uint256 indexed roundId, uint256 commitEnd, uint256 revealEnd, uint256 openingPot);
    event Committed(
        uint256 indexed entryId,
        uint256 indexed roundId,
        address indexed player,
        bytes32 commitment,
        uint256 tickets,
        uint256 burned
    );
    event Revealed(uint256 indexed entryId, uint256 indexed roundId, uint8 machine, uint256 tickets);
    event RoundFinalized(uint256 indexed roundId, uint256 allocated, uint256 rolled, uint256[4] payoutPerTicket);
    event Claimed(uint256 indexed entryId, address indexed player, uint256 amount);

    error OnlyOwner();
    error ZeroAddress();
    error NotConfigured();
    error AlreadyConfigured();
    error InvalidToken();
    error Reentrancy();
    error ZeroAmount();
    error RoundActive();
    error InvalidRound();
    error CommitClosed();
    error RevealClosed();
    error RevealStillOpen();
    error AlreadyFinalized();
    error NotFinalized();
    error InvalidTickets();
    error InvalidCommitment();
    error DuplicateCommitment();
    error InvalidEntry();
    error InvalidMachine();
    error AlreadyRevealed();
    error NotRevealed();
    error AlreadyClaimed();
    error TransferFailed();
    error InexactTransfer();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier configured() {
        if (address(aether) == address(0)) revert NotConfigured();
        _;
    }

    /// @dev No external calls or external code requirements in the constructor. Never infers the owner
    ///      from msg.sender or tx.origin, so deployment through a factory preserves launch ownership.
    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
    }

    /// @notice Bind the verified, already deployed AETHER token. Irreversible; no token is created here.
    /// @dev A code check is not an identity check: the owner must verify the project's token independently.
    function setAether(AetherToken token) external nonReentrant {
        if (msg.sender != owner) revert OnlyOwner();
        if (address(aether) != address(0)) revert AlreadyConfigured();
        if (address(token) == address(0)) revert ZeroAddress();
        if (address(token).code.length == 0) revert InvalidToken();
        aether = token;
        emit AetherConfigured(address(token));
    }

    /// @notice Irrevocably sponsor the NEXT round. Funding never changes the current round's payout pool.
    function fundNextRound(uint256 amount) external nonReentrant configured {
        if (amount == 0) revert ZeroAmount();
        carryover += amount;
        totalFunded += amount;
        emit NextRoundFunded(msg.sender, amount);
        _pull(amount);
    }

    /// @notice Direct token transfers become next-round donations, without sweeping any claim backing.
    function syncSurplus() external nonReentrant configured returns (uint256 amount) {
        amount = aether.balanceOf(address(this)) - accountedBalance();
        if (amount == 0) revert ZeroAmount();
        carryover += amount;
        totalFunded += amount;
        emit SurplusSynced(amount);
    }

    /// @notice Anyone can open the next round after the previous one is finalized. Deadlines are relative
    ///         to this call, so keeper downtime never forces players to catch up through expired rounds.
    function openRound() external nonReentrant configured returns (uint256 roundId) {
        if (currentRoundId != 0 && !_rounds[currentRoundId].finalized) revert RoundActive();
        roundId = ++currentRoundId;
        Round storage r = _rounds[roundId];
        r.commitEnd = block.timestamp + COMMIT_DURATION;
        r.revealEnd = r.commitEnd + REVEAL_DURATION;
        r.pot = carryover;
        carryover = 0;
        emit RoundOpened(roundId, r.commitEnd, r.revealEnd, r.pot);
    }

    /// @notice Hash locally with a fresh cryptographically random 32-byte salt; do not send secrets to a
    ///         public RPC before reveal. Chain, contract, round, player and ticket count bind the choice.
    function computeCommitment(uint256 roundId, address player, uint256 tickets, uint8 machine, bytes32 salt)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), roundId, player, tickets, machine, salt));
    }

    /// @notice Pay for sealed tickets on one machine. Supplying roundId prevents a stale transaction from
    ///         entering a different round. Reusing a commitment is disallowed per player, not globally,
    ///         so another wallet cannot grief an entry by copying its hash from the mempool.
    function commit(uint256 roundId, bytes32 commitment, uint256 tickets)
        external
        nonReentrant
        configured
        returns (uint256 entryId)
    {
        if (roundId == 0 || roundId != currentRoundId) revert InvalidRound();
        Round storage r = _rounds[roundId];
        if (block.timestamp >= r.commitEnd || r.finalized) revert CommitClosed();
        if (tickets == 0 || tickets > MAX_TICKETS_PER_ENTRY) revert InvalidTickets();
        if (commitment == bytes32(0)) revert InvalidCommitment();
        if (commitmentUsed[msg.sender][commitment]) revert DuplicateCommitment();

        uint256 cost = tickets * TICKET_PRICE;
        uint256 burned = tickets * BURN_PER_TICKET;
        entryId = ++entryCount;
        _entries[entryId] = Entry(msg.sender, roundId, commitment, tickets, 0, false, false);
        commitmentUsed[msg.sender][commitment] = true;
        r.committedTickets += tickets;
        r.pot += cost - burned;
        totalEntered += cost;
        totalBurned += burned;
        emit Committed(entryId, roundId, msg.sender, commitment, tickets, burned);
        _pull(cost);
        aether.burn(burned);
    }

    /// @notice Anyone holding the correct secret may reveal for the player; the payout owner cannot change.
    ///         Missed reveals earn zero. There is no extension, fallback randomness or dependence on all
    ///         players cooperating. The reveal window includes commitEnd and excludes revealEnd.
    function reveal(uint256 entryId, uint8 machine, bytes32 salt) external nonReentrant configured {
        Entry storage e = _entry(entryId);
        Round storage r = _rounds[e.roundId];
        if (block.timestamp < r.commitEnd || block.timestamp >= r.revealEnd) revert RevealClosed();
        if (e.revealed) revert AlreadyRevealed();
        if (machine >= MACHINE_COUNT) revert InvalidMachine();
        if (e.commitment != computeCommitment(e.roundId, e.player, e.tickets, machine, salt)) {
            revert InvalidCommitment();
        }
        e.revealed = true;
        e.machine = machine;
        r.tickets[machine] += e.tickets;
        r.revealedTickets += e.tickets;
        emit Revealed(entryId, e.roundId, machine, e.tickets);
    }

    /// @notice Fix all payouts in four iterations, regardless of entry count. No token transfers or
    ///         callbacks occur during finalization. Unoccupied pools and integer dust roll forward.
    function finalize(uint256 roundId) external nonReentrant configured {
        Round storage r = _round(roundId);
        if (r.finalized) revert AlreadyFinalized();
        if (block.timestamp < r.revealEnd) revert RevealStillOpen();
        uint256 machinePot = r.pot / MACHINE_COUNT;
        uint256 allocated = 0;
        for (uint8 m; m < MACHINE_COUNT; ++m) {
            uint256 n = r.tickets[m];
            if (n != 0) {
                uint256 perTicket = machinePot / n;
                r.payoutPerTicket[m] = perTicket;
                allocated += perTicket * n;
            }
        }
        r.finalized = true;
        totalClaimable += allocated;
        uint256 rolled = r.pot - allocated;
        carryover += rolled;
        emit RoundFinalized(roundId, allocated, rolled, r.payoutPerTicket);
    }

    /// @notice Permissionless claim to the original player, with no expiry or additional fee. A failed
    ///         transfer reverts all effects and can be retried; it cannot stop other players or rounds.
    function claim(uint256 entryId) external nonReentrant configured returns (uint256 amount) {
        Entry storage e = _entry(entryId);
        if (!_rounds[e.roundId].finalized) revert NotFinalized();
        if (!e.revealed) revert NotRevealed();
        if (e.claimed) revert AlreadyClaimed();
        amount = _rounds[e.roundId].payoutPerTicket[e.machine] * e.tickets;
        e.claimed = true;
        totalClaimable -= amount;
        totalClaimed += amount;
        emit Claimed(entryId, e.player, amount);
        if (amount != 0 && !aether.transfer(e.player, amount)) revert TransferFailed();
    }

    /// @notice All token liabilities: finalized claims, next-round funding and the active round's pot.
    ///         With the real AetherToken this equals balanceOf(this), except for unsynced direct donations.
    function accountedBalance() public view returns (uint256) {
        Round storage r = _rounds[currentRoundId];
        return totalClaimable + carryover + (r.finalized ? 0 : r.pot);
    }

    function roundInfo(uint256 roundId) external view returns (Round memory) {
        return _round(roundId);
    }

    function entryInfo(uint256 entryId) external view returns (Entry memory) {
        return _entry(entryId);
    }

    function _round(uint256 roundId) private view returns (Round storage r) {
        if (roundId == 0 || roundId > currentRoundId) revert InvalidRound();
        return _rounds[roundId];
    }

    function _entry(uint256 entryId) private view returns (Entry storage e) {
        if (entryId == 0 || entryId > entryCount) revert InvalidEntry();
        return _entries[entryId];
    }

    function _pull(uint256 amount) private {
        uint256 beforeBalance = aether.balanceOf(address(this));
        if (!aether.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        if (aether.balanceOf(address(this)) != beforeBalance + amount) revert InexactTransfer();
    }
}
