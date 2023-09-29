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

contract LiquidityPositionManagerTest is HookTest, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using PositionIdLibrary for Position;

    LiquidityPositionManager lpm;
    LiquidityHelpers helper;

    PoolKey poolKey;
    PoolId poolId;

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
    }

    function test_addLiquidity() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;
        lpm.modifyPosition(
            address(this),
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(address(this), position.toTokenId()), liquidity);
    }

    function test_removeFullLiquidity() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;
        addLiquidity(poolKey, tickLower, tickUpper, liquidity);
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        assertEq(lpm.balanceOf(address(this), position.toTokenId()), liquidity);
        lpm.modifyPosition(
            address(this),
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(liquidity)
            }),
            ZERO_BYTES
        );
        assertEq(lpm.balanceOf(address(this), position.toTokenId()), 0);
    }

    function test_removePartialLiquidity() public {}
    function test_addPartialLiquidity() public {}

    function test_expandLiquidity() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        int256 liquidity = 1e18;
        addLiquidity(poolKey, tickLower, tickUpper, uint256(liquidity));
        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});

        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        int24 newTickLower = -1200;
        int24 newTickUpper = 1200;

        uint128 newLiquidity = helper.getNewLiquidity(position, -liquidity, newTickLower, newTickUpper);
        lpm.rebalancePosition(
            address(this),
            position,
            -liquidity, // fully unwind
            IPoolManager.ModifyPositionParams({
                tickLower: newTickLower,
                tickUpper: newTickUpper,
                liquidityDelta: int256(uint256(newLiquidity))
            }),
            ZERO_BYTES,
            ZERO_BYTES
        );

        // new liquidity position did not require net-new tokens
        assertEq(token0.balanceOf(address(this)), balance0Before);
        assertEq(token1.balanceOf(address(this)), balance1Before);
    }

    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) internal {
        lpm.modifyPosition(
            address(this),
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
    }
}
