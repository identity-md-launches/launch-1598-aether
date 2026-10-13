// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AetherToken} from "./AetherToken.sol";
import {AetherGame} from "./AetherGame.sol";

/// @title AETHER airdrop distributor
/// @notice Holds the 1,000 AETHER airdrop for identity.md NFT holders (0.5 AETHER per NFT held at the snapshot).
///         Leaves are keccak256(bytes.concat(keccak256(abi.encode(account, amount)))) with sorted-pair hashing
///         (OpenZeppelin StandardMerkleTree layout). The root is a constructor input fixed at launch.
///         Claims stay open for 365 days; afterwards anyone can sweep what is left into the game's Harvest pot.
///         No owner.
contract AetherAirdrop {
    uint256 public constant AIRDROP_AMOUNT = 1_000e18;
    uint256 public constant CLAIM_WINDOW = 365 days;

    AetherToken public immutable aether;
    AetherGame public immutable game;
    bytes32 public immutable merkleRoot;
    uint256 public immutable claimDeadline;

    mapping(address => bool) public claimed;
    uint256 public totalClaimed;

    event Claimed(address indexed account, uint256 amount);
    event Swept(uint256 amount);

    error AlreadyClaimed();
    error InvalidProof();
    error ClaimWindowClosed();
    error ClaimWindowOpen();
    error NothingToSweep();
    error ZeroRoot();

    constructor(AetherToken aether_, AetherGame game_, bytes32 merkleRoot_) {
        if (merkleRoot_ == bytes32(0)) revert ZeroRoot();
        aether = aether_;
        game = game_;
        merkleRoot = merkleRoot_;
        claimDeadline = block.timestamp + CLAIM_WINDOW;
    }

    function leaf(address account, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function claim(address account, uint256 amount, bytes32[] calldata proof) external {
        if (block.timestamp > claimDeadline) revert ClaimWindowClosed();
        if (claimed[account]) revert AlreadyClaimed();
        if (!_verify(proof, leaf(account, amount))) revert InvalidProof();
        claimed[account] = true;
        totalClaimed += amount;
        aether.transfer(account, amount);
        emit Claimed(account, amount);
    }

    /// @notice After the claim window, send the unclaimed remainder to the game's Harvest pot. Anyone may call.
    function sweep() external {
        if (block.timestamp <= claimDeadline) revert ClaimWindowOpen();
        uint256 balance = aether.balanceOf(address(this));
        if (balance == 0) revert NothingToSweep();
        aether.approve(address(game), balance);
        game.donateToHarvest(balance);
        emit Swept(balance);
    }

    function _verify(bytes32[] calldata proof, bytes32 node) internal view returns (bool) {
        for (uint256 i; i < proof.length; ++i) {
            bytes32 p = proof[i];
            node = node < p ? keccak256(abi.encodePacked(node, p)) : keccak256(abi.encodePacked(p, node));
        }
        return node == merkleRoot;
    }
}
