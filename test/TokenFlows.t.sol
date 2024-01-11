// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {HookTest} from "./utils/HookTest.sol";
import {LiquidityPositionManager} from "../src/LiquidityPositionManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Position, PositionId, PositionIdLibrary} from "../src/types/PositionId.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Position as PoolPosition} from "v4-core/src/libraries/Position.sol";
import {LiquidityHelpers} from "../src/lens/LiquidityHelpers.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

contract TokenFlowsTest is HookTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using PositionIdLibrary for Position;

    LiquidityPositionManager lpm;
    LiquidityHelpers helper;

    PoolKey poolKey;
    PoolId poolId;

    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    bytes constant ZERO_BYTES = "";

    function setUp() public {
        HookTest.initHookTestEnv();

        lpm = new LiquidityPositionManager(IPoolManager(address(manager)));
        helper = new LiquidityHelpers(IPoolManager(address(manager)), lpm);

        token0.approve(address(lpm), type(uint256).max);
        token1.approve(address(lpm), type(uint256).max);

        // Create the pool
        poolKey =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, IHooks(address(0x0)));
        poolId = poolKey.toId();
        initializeRouter.initialize(poolKey, Constants.SQRT_RATIO_1_1, ZERO_BYTES);

        token0.mint(alice, 1_000_000e18);
        token1.mint(alice, 1_000_000e18);
        token0.mint(bob, 1_000_000e18);
        token1.mint(bob, 1_000_000e18);

        vm.startPrank(alice);
        token0.approve(address(lpm), type(uint256).max);
        token1.approve(address(lpm), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        token0.approve(address(lpm), type(uint256).max);
        token1.approve(address(lpm), type(uint256).max);
        vm.stopPrank();
    }

    // alice closes her position, she gets her tokens back
    function test_removeTokenRecipient() public {
        uint256 token0BalanceBefore = token0.balanceOf(address(alice));
        uint256 token1BalanceBefore = token1.balanceOf(address(alice));

        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;

        // alice adds liquidity
        vm.prank(alice);
        addLiquidity(alice, poolKey, tickLower, tickUpper, liquidity);

        assertLt(token0.balanceOf(address(alice)), token0BalanceBefore);
        assertLt(token1.balanceOf(address(alice)), token1BalanceBefore);
        assertEq(
            lpm.balanceOf(
                address(alice), Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper}).toTokenId()
            ),
            liquidity
        );

        // alice removes liquidity
        vm.prank(alice);
        removeLiquidity(alice, poolKey, tickLower, tickUpper, liquidity);

        // alice gets her tokens back
        assertApproxEqAbs(token0.balanceOf(address(alice)), token0BalanceBefore, 3 wei);
        assertApproxEqAbs(token1.balanceOf(address(alice)), token1BalanceBefore, 3 wei);
        assertEq(
            lpm.balanceOf(
                address(alice), Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper}).toTokenId()
            ),
            0
        );
    }

    // bob closes alice position, alice gets the tokens
    function test_operatorRemoveTokenRecipient() public {
        uint256 token0BalanceBefore = token0.balanceOf(address(alice));
        uint256 token1BalanceBefore = token1.balanceOf(address(alice));

        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;

        // alice adds liquidity
        vm.startPrank(alice);
        addLiquidity(alice, poolKey, tickLower, tickUpper, liquidity);
        lpm.setOperator(bob, true);
        vm.stopPrank();

        assertLt(token0.balanceOf(address(alice)), token0BalanceBefore);
        assertLt(token1.balanceOf(address(alice)), token1BalanceBefore);
        assertEq(
            lpm.balanceOf(
                address(alice), Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper}).toTokenId()
            ),
            liquidity
        );

        // bob removes liquidity
        vm.prank(bob);
        removeLiquidity(alice, poolKey, tickLower, tickUpper, liquidity);

        // alice gets her tokens back
        assertApproxEqAbs(token0.balanceOf(address(alice)), token0BalanceBefore, 3 wei);
        assertApproxEqAbs(token1.balanceOf(address(alice)), token1BalanceBefore, 3 wei);
        assertEq(
            lpm.balanceOf(
                address(alice), Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper}).toTokenId()
            ),
            0
        );
    }

    // alice rebalances her position, excess tokens are received as 1155
    function test_rebalanceTokenRecipient() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;

        // alice adds liquidity
        vm.prank(alice);
        addLiquidity(alice, poolKey, tickLower, tickUpper, liquidity);
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(address(alice), position.toTokenId()), liquidity);

        uint256 token0BalanceBefore = token0.balanceOf(address(alice));
        uint256 token1BalanceBefore = token1.balanceOf(address(alice));

        // alice rebalances liquidity
        int24 newTickLower = -1200;
        int24 newTickUpper = 1200;
        int256 liquidityAdjustment = -int256(liquidity / 2);
        uint128 newLiquidity = helper.getNewLiquidity(position, liquidityAdjustment, newTickLower, newTickUpper);
        vm.prank(alice);
        lpm.rebalancePosition(
            alice,
            position,
            liquidityAdjustment, // partially unwind
            IPoolManager.ModifyLiquidityParams({
                tickLower: newTickLower,
                tickUpper: newTickUpper,
                liquidityDelta: int256(uint256(newLiquidity) / 2)
            }),
            ZERO_BYTES,
            ZERO_BYTES
        );

        // alice gets excess tokens back
        assertGt(token0.balanceOf(address(alice)), token0BalanceBefore);
        assertGt(token1.balanceOf(address(alice)), token1BalanceBefore);
    }

    // bob rebalances alice position, alice gets the excess tokens
    function test_operatorRebalanceTokenRecipient() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;

        // alice adds liquidity
        vm.startPrank(alice);
        addLiquidity(alice, poolKey, tickLower, tickUpper, liquidity);
        lpm.setOperator(bob, true);
        vm.stopPrank();
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(address(alice), position.toTokenId()), liquidity);

        uint256 token0BalanceBefore = token0.balanceOf(address(alice));
        uint256 token1BalanceBefore = token1.balanceOf(address(alice));

        // bob rebalances alice's liquidity
        int24 newTickLower = -1200;
        int24 newTickUpper = 1200;
        int256 liquidityAdjustment = -int256(liquidity / 2);
        uint128 newLiquidity = helper.getNewLiquidity(position, liquidityAdjustment, newTickLower, newTickUpper);
        vm.prank(bob);
        lpm.rebalancePosition(
            alice,
            position,
            liquidityAdjustment, // partially unwind
            IPoolManager.ModifyLiquidityParams({
                tickLower: newTickLower,
                tickUpper: newTickUpper,
                liquidityDelta: int256(uint256(newLiquidity) / 2)
            }),
            ZERO_BYTES,
            ZERO_BYTES
        );

        // alice gets excess tokens back
        assertGt(token0.balanceOf(address(alice)), token0BalanceBefore);
        assertGt(token1.balanceOf(address(alice)), token1BalanceBefore);
    }

    function addLiquidity(address recipient, PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity)
        internal
    {
        lpm.modifyPosition(
            recipient,
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
    }

    function removeLiquidity(address owner, PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity)
        internal
    {
        lpm.modifyPosition(
            owner,
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(liquidity)
            }),
            ZERO_BYTES
        );
    }
}
