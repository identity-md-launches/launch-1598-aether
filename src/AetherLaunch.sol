// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {AetherToken} from "./AetherToken.sol";
import {AetherReserve} from "./AetherReserve.sol";
import {AetherGame} from "./AetherGame.sol";
import {AetherHook} from "./AetherHook.sol";
import {AetherLPVault} from "./AetherLPVault.sol";
import {AetherAirdrop} from "./AetherAirdrop.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";

/// @title AETHER launcher
/// @notice Deploys and wires the whole game in ONE transaction, from its constructor:
///           1. AetherToken   - 10,000 AETHER minted to this launcher
///           2. AetherGame    - the game (deploys its AetherReserve)
///           3. AetherHook    - CREATE2 with a salt mined on the fly so the address carries the v4 flag bits
///           4. AetherLPVault - owner of the launch liquidity
///           5. AetherAirdrop - Merkle distributor for the NFT snapshot
///           then 1,000 -> airdrop, 8,000 -> Reserve, 1,000 -> vault, and, when a pool manager is present on
///           this chain, the pool is initialized and the single-sided liquidity added. On a chain without the
///           pool manager (launch dry-run on an empty chain), `vault.open()` stays callable by anyone, once.
///         The launcher keeps no power: every wiring call is one-shot and the launcher holds no tokens after.
contract AetherLaunch {
    AetherToken public immutable token;
    AetherGame public immutable game;
    AetherReserve public immutable reserve;
    AetherHook public immutable hook;
    AetherLPVault public immutable vault;
    AetherAirdrop public immutable airdrop;
    bytes32 public immutable hookSalt;

    /// @param merkleRoot        Root of the NFT-holder snapshot tree (account, amount) with 0.5 AETHER per NFT.
    /// @param imd               The IMD token (0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7 on Ethereum mainnet).
    /// @param poolManager       Uniswap v4 PoolManager on the launch chain.
    /// @param ethPoolFee        Fee of the existing ETH/IMD v4 pool used by the ETH entry route.
    /// @param ethPoolTickSpacing Tick spacing of that pool.
    /// @param ethPoolHooks      Hook address of that pool (zero when the pool has no hook).
    /// @param imdPerAetherWad   Opening price of the AETHER/IMD pool, IMD per AETHER, 1e18 fixed point.
    constructor(
        bytes32 merkleRoot,
        address imd,
        address poolManager,
        uint24 ethPoolFee,
        int24 ethPoolTickSpacing,
        address ethPoolHooks,
        uint256 imdPerAetherWad
    ) {
        token = new AetherToken(address(this));
        game = new AetherGame(
            token, IERC20Minimal(imd), IPoolManager(poolManager), ethPoolFee, ethPoolTickSpacing, IHooks(ethPoolHooks)
        );
        reserve = game.reserve();

        bytes memory initCode =
            abi.encodePacked(type(AetherHook).creationCode, abi.encode(IPoolManager(poolManager), token, game));
        bytes32 salt = _mineSalt(keccak256(initCode));
        hookSalt = salt;
        hook = new AetherHook{salt: salt}(IPoolManager(poolManager), token, game);

        vault = new AetherLPVault(
            IPoolManager(poolManager), token, IERC20Minimal(imd), IHooks(address(hook)), imdPerAetherWad
        );
        hook.wire(address(vault));
        game.wire(vault.poolKey());
        airdrop = new AetherAirdrop(token, game, merkleRoot);

        token.transfer(address(airdrop), airdrop.AIRDROP_AMOUNT());
        token.transfer(address(reserve), reserve.RESERVE_AMOUNT());
        token.transfer(address(vault), vault.LP_AMOUNT());

        if (poolManager.code.length > 0) vault.open();
    }

    /// @dev Finds a CREATE2 salt such that the hook address carries exactly the required flag bits.
    function _mineSalt(bytes32 initCodeHash) internal view returns (bytes32 salt) {
        uint160 required = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        uint160 mask = Hooks.ALL_HOOK_MASK;
        address self = address(this);
        uint256 s;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            // 0xff ++ address(this) ++ salt ++ initCodeHash  (85 bytes)
            mstore8(ptr, 0xff)
            mstore(add(ptr, 0x01), shl(96, self))
            mstore(add(ptr, 0x35), initCodeHash)
            for {} 1 { s := add(s, 1) } {
                mstore(add(ptr, 0x15), s)
                let addr := and(keccak256(ptr, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
                if eq(and(addr, mask), required) { break }
            }
        }
        salt = bytes32(s);
    }
}
