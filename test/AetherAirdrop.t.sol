// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AetherBase} from "./AetherBase.t.sol";
import {AetherAirdrop} from "../src/AetherAirdrop.sol";
import {AetherLaunch} from "../src/AetherLaunch.sol";

contract AetherAirdropTest is AetherBase {
    address internal h1 = address(0x1001);
    address internal h2 = address(0x1002);
    address internal h3 = address(0x1003);
    uint256 internal a1 = 0.5e18; // 1 NFT
    uint256 internal a2 = 1.5e18; // 3 NFTs
    uint256 internal a3 = 998e18; // the rest (sum = 1,000)
    bytes32 internal l1;
    bytes32 internal l2;
    bytes32 internal l3;
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        l1 = _leaf(h1, a1);
        l2 = _leaf(h2, a2);
        l3 = _leaf(h3, a3);
        bytes32 n12 = _pair(l1, l2);
        root = _pair(n12, l3);
        _deploy(root);
    }

    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proof1() internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = l2;
        p[1] = l3;
    }

    function test_claim_success() public {
        airdrop.claim(h1, a1, _proof1());
        assertEq(token.balanceOf(h1), a1);
        assertTrue(airdrop.claimed(h1));
        assertEq(airdrop.totalClaimed(), a1);
        bytes32[] memory p3 = new bytes32[](1);
        p3[0] = _pair(l1, l2);
        airdrop.claim(h3, a3, p3);
        assertEq(token.balanceOf(h3), a3);
    }

    function test_claim_rejectsDoubleAndBadProofAndWrongAmount() public {
        airdrop.claim(h1, a1, _proof1());
        vm.expectRevert(AetherAirdrop.AlreadyClaimed.selector);
        airdrop.claim(h1, a1, _proof1());
        vm.expectRevert(AetherAirdrop.InvalidProof.selector);
        airdrop.claim(h2, a2, _proof1());
        vm.expectRevert(AetherAirdrop.InvalidProof.selector);
        airdrop.claim(h3, a3 + 1, _proof1());
    }

    function test_claim_closesAfterWindowAndSweepFeedsHarvest() public {
        airdrop.claim(h1, a1, _proof1());
        vm.expectRevert(AetherAirdrop.ClaimWindowOpen.selector);
        airdrop.sweep();
        vm.warp(airdrop.claimDeadline() + 1);
        vm.expectRevert(AetherAirdrop.ClaimWindowClosed.selector);
        airdrop.claim(h3, a3, new bytes32[](0));
        uint256 left = token.balanceOf(address(airdrop));
        assertEq(left, 1_000e18 - a1);
        airdrop.sweep();
        assertEq(token.balanceOf(address(airdrop)), 0);
        (uint256 pot,,,) = game.dayInfo(game.currentDay());
        assertEq(pot, left);
        vm.expectRevert(AetherAirdrop.NothingToSweep.selector);
        airdrop.sweep();
    }

    function test_launch_rejectsZeroRoot() public {
        vm.expectRevert(AetherAirdrop.ZeroRoot.selector);
        new AetherLaunch(bytes32(0), address(imd), address(manager), 3000, 60, address(0), OPENING_PRICE);
    }
}
