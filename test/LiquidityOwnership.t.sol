// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {HookTest} from "./utils/HookTest.sol";
import {LiquidityPositionManager} from "../src/LiquidityPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {Position, PositionId, PositionIdLibrary} from "../src/types/PositionId.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Position as PoolPosition} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {LiquidityHelpers} from "../src/lens/LiquidityHelpers.sol";

contract LiquidityOwnershipTest is HookTest, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using PositionIdLibrary for Position;

    LiquidityPositionManager lpm;
    LiquidityHelpers helper;

    PoolKey poolKey;
    PoolKey poolKey2;
    PoolId poolId;

    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

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
        manager.initialize(poolKey, SQRT_RATIO_1_1, ZERO_BYTES);

        // Create a second pool
        poolKey2 =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 5000, 60, IHooks(address(0x0)));
        manager.initialize(poolKey2, SQRT_RATIO_1_1, ZERO_BYTES);

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

    // bob *can* create a position for alice
    function test_recipientAdd() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;

        uint256 token0Alice = token0.balanceOf(alice);
        uint256 token1Alice = token1.balanceOf(alice);
        vm.prank(bob);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);

        // bob paid for the LP, on behalf of alice
        assertEq(token0.balanceOf(alice), token0Alice);
        assertEq(token1.balanceOf(alice), token1Alice);
    }

    // bob can add to alice's position
    function test_recipientReadd() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;

        uint256 token0Alice = token0.balanceOf(alice);
        uint256 token1Alice = token1.balanceOf(alice);
        vm.prank(bob);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);

        // readd to the liquidity
        vm.prank(bob);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity * 2);

        // bob paid for the LP, on behalf of alice
        assertEq(token0.balanceOf(alice), token0Alice);
        assertEq(token1.balanceOf(alice), token1Alice);
    }

    // bob cannot remove from alice's position
    function test_ownershipRemove() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;

        vm.prank(alice);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);

        vm.startPrank(bob);
        vm.expectRevert();
        lpm.modifyPosition(
            alice, // bob, not the owner cannot modify without permission
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(liquidity)
            }),
            ZERO_BYTES
        );
        vm.stopPrank();

        // alice's LP still the same
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);
    }

    // bob cannot rebalance alice's position
    function test_ownershipRebalance() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;

        vm.prank(alice);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);

        vm.startPrank(bob);
        int24 newTickLower = -1200;
        int24 newTickUpper = 1200;
        uint128 newLiquidity = helper.getNewLiquidity(position, -int256(liquidity), newTickLower, newTickUpper);
        vm.expectRevert();
        lpm.rebalancePosition(
            alice, // bob cannot modify alice's position
            position,
            -int256(liquidity), // fully unwind
            IPoolManager.ModifyPositionParams({
                tickLower: newTickLower,
                tickUpper: newTickUpper,
                liquidityDelta: int256(uint256(newLiquidity))
            }),
            ZERO_BYTES,
            ZERO_BYTES
        );
        vm.stopPrank();

        // alice's LP still the same
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);
    }

    // with operator set, bob can add to alice's position
    function test_operatorRemove() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;

        vm.prank(alice);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);

        // alice allows bob as an operator
        vm.prank(alice);
        lpm.setOperator(bob, true);

        vm.startPrank(bob);
        lpm.modifyPosition(
            alice, // bob has operator permissions to close alice's LP
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(liquidity)
            }),
            ZERO_BYTES
        );
        vm.stopPrank();

        // alice's LP is closed
        assertEq(lpm.balanceOf(alice, position.toTokenId()), 0);

        // TODO: alice receives the underlying tokens
    }

    // with operator set, bob can add to alice's position
    function test_operatorRebalance() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;

        vm.prank(alice);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);

        // alice allows bob as an operator
        vm.prank(alice);
        lpm.setOperator(bob, true);

        vm.startPrank(bob);
        int24 newTickLower = -1200;
        int24 newTickUpper = 1200;
        uint128 newLiquidity = helper.getNewLiquidity(position, -int256(liquidity), newTickLower, newTickUpper);
        lpm.rebalancePosition(
            alice, // bob has permission to rebalance for alice
            position,
            -int256(liquidity), // fully unwind
            IPoolManager.ModifyPositionParams({
                tickLower: newTickLower,
                tickUpper: newTickUpper,
                liquidityDelta: int256(uint256(newLiquidity))
            }),
            ZERO_BYTES,
            ZERO_BYTES
        );
        vm.stopPrank();

        // alice's old LP is closed
        assertEq(lpm.balanceOf(alice, position.toTokenId()), 0);

        // alice has a new LP
        assertEq(
            lpm.balanceOf(
                alice, Position({poolKey: poolKey, tickLower: newTickLower, tickUpper: newTickUpper}).toTokenId()
            ),
            newLiquidity
        );
    }

    function test_operatorMigrate() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;

        vm.prank(alice);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);

        // alice allows bob as an operator
        vm.prank(alice);
        lpm.setOperator(bob, true);

        vm.prank(bob);
        lpm.migratePosition(
            alice, // bob has permission to migrate for alice
            position,
            poolKey2,
            ZERO_BYTES,
            ZERO_BYTES
        );

        // alice's old LP is closed
        assertEq(lpm.balanceOf(alice, position.toTokenId()), 0);

        // alice has a new LP
        assertEq(
            lpm.balanceOf(alice, Position({poolKey: poolKey2, tickLower: tickLower, tickUpper: tickUpper}).toTokenId()),
            liquidity
        );
    }

    function test_operatorMigrateRevert() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;

        vm.prank(alice);
        lpm.modifyPosition(
            alice, // alice, the owner
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);

        vm.startPrank(bob);
        vm.expectRevert();
        lpm.migratePosition(
            alice, // bob does NOT have permission to migrate for alice
            position,
            poolKey2,
            ZERO_BYTES,
            ZERO_BYTES
        );
        vm.stopPrank();

        // alice's old LP is unchanged
        assertEq(lpm.balanceOf(alice, position.toTokenId()), liquidity);
    }
}
