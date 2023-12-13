// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {HookTest} from "./utils/HookTest.sol";
import {LiquidityPositionManager} from "../src/LiquidityPositionManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Position, PositionId, PositionIdLibrary} from "../src/types/PositionId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Position as PoolPosition} from "v4-core/src/libraries/Position.sol";
import {LiquidityHelpers} from "../src/lens/LiquidityHelpers.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

contract FeeDistributionTest is HookTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using PositionIdLibrary for Position;

    LiquidityPositionManager lpm;
    LiquidityHelpers helper;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    PoolKey poolKey;
    PoolId poolId;
    Position position;
    uint256 positionTokenId;

    int24 minTick;
    int24 maxTick;

    bytes constant ZERO_BYTES = "";

    function setUp() public {
        HookTest.initHookTestEnv();

        lpm = new LiquidityPositionManager(IPoolManager(address(manager)));
        helper = new LiquidityHelpers(IPoolManager(address(manager)), lpm);

        token0.approve(address(lpm), type(uint256).max);
        token1.approve(address(lpm), type(uint256).max);

        // Create the pool
        poolKey =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 10_000, 60, IHooks(address(0x0)));
        poolId = poolKey.toId();
        initializeRouter.initialize(poolKey, Constants.SQRT_RATIO_1_1, ZERO_BYTES);

        minTick = TickMath.minUsableTick(60);
        maxTick = TickMath.maxUsableTick(60);

        position = Position({poolKey: poolKey, tickLower: minTick, tickUpper: maxTick});
        positionTokenId = position.toTokenId();

        uint256 m = 1_000_000e18;
        token0.mint(alice, m);
        token1.mint(alice, m);
        token0.mint(bob, m);
        token1.mint(bob, m);

        vm.startPrank(alice);
        token0.approve(address(lpm), type(uint256).max);
        token1.approve(address(lpm), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        token0.approve(address(lpm), type(uint256).max);
        token1.approve(address(lpm), type(uint256).max);
        vm.stopPrank();
    }

    function test_fee() public {
        vm.prank(alice);
        lpm.modifyPosition(
            alice,
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: minTick,
                tickUpper: maxTick,
                liquidityDelta: int256(10_000e18)
            }),
            ZERO_BYTES
        );

        swap(poolKey, 1e18, true, ZERO_BYTES);

        uint256 t0AliceBefore = token0.balanceOf(alice);

        // alice can collect fees
        vm.prank(alice);
        lpm.collectFees(alice, position, Currency.wrap(address(token0)));

        // fee is 0.01e18 in token0
        uint256 t0AliceAfter = token0.balanceOf(alice);
        assertApproxEqAbs(t0AliceAfter - t0AliceBefore, 0.01e18, 10000 wei);
    }

    function test_fee_not_shared() public {
        vm.prank(alice);
        lpm.modifyPosition(
            alice,
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: minTick,
                tickUpper: maxTick,
                liquidityDelta: int256(10_000e18)
            }),
            ZERO_BYTES
        );

        swap(poolKey, 1e18, true, ZERO_BYTES);

        vm.prank(bob);
        lpm.modifyPosition(
            bob,
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: minTick,
                tickUpper: maxTick,
                liquidityDelta: int256(10_000e18)
            }),
            ZERO_BYTES
        );

        swap(poolKey, 1e18, true, ZERO_BYTES);

        uint256 token0AliceBefore = token0.balanceOf(alice);
        uint256 token0BobBefore = token0.balanceOf(bob);

        // bob collects 0.005e18 in fees
        vm.prank(bob);
        lpm.collectFees(bob, position, Currency.wrap(address(token0)));
        uint256 token0BobAfter = token0.balanceOf(bob);

        // alice collects 0.015e18 in fees
        vm.prank(alice);
        lpm.collectFees(alice, position, Currency.wrap(address(token0)));

        uint256 token0AliceAfter = token0.balanceOf(alice);

        assertApproxEqAbs(token0AliceAfter - token0AliceBefore, 0.015e18, 20000 wei);
        assertApproxEqAbs(token0BobAfter - token0BobBefore, 0.005e18, 20000 wei);
    }
}
