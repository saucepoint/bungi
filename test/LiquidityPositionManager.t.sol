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
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Position as PoolPosition} from "v4-core/src/libraries/Position.sol";
import {LiquidityHelpers} from "../src/lens/LiquidityHelpers.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

contract LiquidityPositionManagerTest is HookTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using PositionIdLibrary for Position;

    LiquidityPositionManager lpm;
    LiquidityHelpers helper;

    PoolKey poolKey;
    PoolId poolId;

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
    }

    function test_addLiquidity() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;
        lpm.modifyPosition(
            address(this),
            poolKey,
            IPoolManager.ModifyLiquidityParams({
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
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(liquidity)
            }),
            ZERO_BYTES
        );
        assertEq(lpm.balanceOf(address(this), position.toTokenId()), 0);
    }

    function test_removePartialLiquidity() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;
        addLiquidity(poolKey, tickLower, tickUpper, liquidity);

        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        uint256 balanceBefore = lpm.balanceOf(address(this), position.toTokenId());
        removeLiquidity(poolKey, tickLower, tickUpper, liquidity / 2); // remove half of the position

        assertEq(lpm.balanceOf(address(this), position.toTokenId()), balanceBefore / 2);
    }

    function test_addPartialLiquidity() public {
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint256 liquidity = 1e18;
        addLiquidity(poolKey, tickLower, tickUpper, liquidity);

        Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        uint256 balanceBefore = lpm.balanceOf(address(this), position.toTokenId());
        addLiquidity(poolKey, tickLower, tickUpper, liquidity / 2); // add half of the position

        assertEq(lpm.balanceOf(address(this), position.toTokenId()), balanceBefore + liquidity / 2);
    }

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

        assertEq(lpm.balanceOf(address(this), position.toTokenId()), uint256(liquidity));

        uint128 newLiquidity = helper.getNewLiquidity(position, -liquidity, newTickLower, newTickUpper);
        lpm.rebalancePosition(
            address(this),
            position,
            -liquidity, // fully unwind
            IPoolManager.ModifyLiquidityParams({
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

        // old position was unwound entirely
        assertEq(lpm.balanceOf(address(this), position.toTokenId()), 0);

        // new position was created
        Position memory newPosition = Position({poolKey: poolKey, tickLower: newTickLower, tickUpper: newTickUpper});
        assertEq(lpm.balanceOf(address(this), newPosition.toTokenId()), uint256(newLiquidity));
    }

    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) internal {
        lpm.modifyPosition(
            address(this),
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity)
            }),
            ZERO_BYTES
        );
    }

    function removeLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) internal {
        lpm.modifyPosition(
            address(this),
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
