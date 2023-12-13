// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Position, PositionId, PositionIdLibrary} from "../types/PositionId.sol";
import {Position as PoolPosition} from "v4-core/src/libraries/Position.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LiquidityPositionManager} from "../LiquidityPositionManager.sol";

contract LiquidityHelpers {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable manager;
    LiquidityPositionManager public immutable lpm;

    constructor(IPoolManager _manager, LiquidityPositionManager _lpm) {
        manager = _manager;
        lpm = _lpm;
    }

    /// @notice Given an existing LP to pull tokens from, and a new desired range, calculate the liquidity amount
    function getNewLiquidity(
        Position calldata position,
        int256 existingLiquidityDelta,
        int24 newTickLower,
        int24 newTickUpper
    ) external view returns (uint128 newLiquidity) {
        require(existingLiquidityDelta < 0, "must withdraw from existing liquidity");

        (uint160 sqrtPriceX96, uint256 amount0, uint256 amount1) =
            _getAmountsAfterLiquidityChange(position, existingLiquidityDelta);

        newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(newTickLower),
            TickMath.getSqrtRatioAtTick(newTickUpper),
            amount0,
            amount1
        );
    }

    function _getAmountsAfterLiquidityChange(Position calldata position, int256 existingLiquidityDelta)
        internal
        view
        returns (uint160 sqrtPriceX96, uint256 amount0, uint256 amount1)
    {
        PoolId poolId = position.poolKey.toId();
        (sqrtPriceX96,,) = manager.getSlot0(poolId);

        // TODO: read the liquidity of the owner, not the LPM contract
        uint128 currentLiquidity =
            manager.getPosition(poolId, address(lpm), position.tickLower, position.tickUpper).liquidity;
        int256 liquidityChange = int256(uint256(currentLiquidity)) + existingLiquidityDelta;

        // amounts before the change
        (uint256 amount0Before, uint256 amount1Before) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(position.tickLower),
            TickMath.getSqrtRatioAtTick(position.tickUpper),
            currentLiquidity
        );

        // amounts after the change
        (uint256 amount0After, uint256 amount1After) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(position.tickLower),
            TickMath.getSqrtRatioAtTick(position.tickUpper),
            uint128(uint256(liquidityChange))
        );

        amount0 = amount0Before - amount0After;
        amount1 = amount1Before - amount1After;
    }
}
