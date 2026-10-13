// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {AetherLaunch} from "../src/AetherLaunch.sol";
import {AetherToken} from "../src/AetherToken.sol";
import {AetherReserve} from "../src/AetherReserve.sol";
import {AetherGame} from "../src/AetherGame.sol";
import {AetherHook} from "../src/AetherHook.sol";
import {AetherLPVault} from "../src/AetherLPVault.sol";
import {AetherAirdrop} from "../src/AetherAirdrop.sol";

/// @dev Minimal mintable ERC-20 standing in for IMD. Deployed via etch at a chosen address so both currency
///      orderings of the AETHER/IMD pool can be exercised.
contract MockIMD {
    string public constant name = "Mock IMD";
    string public constant symbol = "IMD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }
}

abstract contract AetherBase is Test {
    uint256 internal constant OPENING_PRICE = 100e18; // 100 IMD per AETHER
    bytes32 internal constant TEST_ROOT = keccak256("not-a-real-root");
    uint24 internal constant ETH_POOL_FEE = 3000;
    int24 internal constant ETH_POOL_TS = 60;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    MockIMD internal imd;
    AetherLaunch internal launch;
    AetherToken internal token;
    AetherGame internal game;
    AetherReserve internal reserve;
    AetherHook internal hook;
    AetherLPVault internal vault;
    AetherAirdrop internal airdrop;
    PoolKey internal key;
    bool internal aetherIsZero;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    /// @dev Where the IMD mock lives. Subclasses pick a low or high address to flip the currency ordering.
    function imdAddress() internal pure virtual returns (address) {
        return address(0xEEEEEeeeeEeEEeeeeeEeEeeeeeeeEeEeEEEEeE01);
    }

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.roll(10_000);
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        MockIMD impl = new MockIMD();
        vm.etch(imdAddress(), address(impl).code);
        imd = MockIMD(imdAddress());
        _deploy(TEST_ROOT);
    }

    function _deploy(bytes32 root) internal {
        launch = new AetherLaunch(
            root, address(imd), address(manager), ETH_POOL_FEE, ETH_POOL_TS, address(0), OPENING_PRICE
        );
        token = launch.token();
        game = launch.game();
        reserve = launch.reserve();
        hook = launch.hook();
        vault = launch.vault();
        airdrop = launch.airdrop();
        key = vault.poolKey();
        aetherIsZero = Currency.unwrap(key.currency0) == address(token);
    }

    function _fund(address who, uint256 imdAmount) internal {
        imd.mint(who, imdAmount);
        vm.prank(who);
        imd.approve(address(game), type(uint256).max);
        vm.prank(who);
        imd.approve(address(swapRouter), type(uint256).max);
        vm.prank(who);
        token.approve(address(swapRouter), type(uint256).max);
    }

    function _buy(address who, uint8 machine, uint256 imdAmount) internal returns (uint256 batchId, uint256 energies) {
        vm.prank(who);
        return game.buyEnergies(machine, imdAmount, 0);
    }

    /// @dev Third-party buy of AETHER with IMD through the test router (pays the hook fee).
    function _routerBuy(address who, uint256 imdIn) internal returns (BalanceDelta) {
        bool zeroForOne = !aetherIsZero;
        vm.prank(who);
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(imdIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Third-party sell of AETHER for IMD through the test router (pays the hook fee).
    function _routerSell(address who, uint256 aetherIn) internal returns (BalanceDelta) {
        bool zeroForOne = aetherIsZero;
        vm.prank(who);
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(aetherIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Advance to just after the end of `epoch` and drive settlement through lock -> seed -> finalize.
    function _settleEpoch(uint256 epoch) internal {
        if (block.timestamp < game.epochEnd(epoch)) vm.warp(game.epochEnd(epoch));
        assertFalse(game.settle(1000), "first call locks");
        vm.roll(block.number + 2);
        while (!game.settle(1000)) {}
    }

    function _skipFeeDecay() internal {
        vm.warp(block.timestamp + 100 minutes);
    }
}
