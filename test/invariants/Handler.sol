// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {LiquidityPositionManager} from "../../src/LiquidityPositionManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Position, PositionId, PositionIdLibrary} from "../../src/types/PositionId.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Position as PoolPosition} from "v4-core/src/libraries/Position.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolInitializeTest} from "v4-core/src/test/PoolInitializeTest.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract Handler is CommonBase, StdCheats, StdUtils {
    using CurrencyLibrary for Currency;
    using PositionIdLibrary for Position;
    using PoolIdLibrary for PoolKey;

    LiquidityPositionManager lpm;
    PoolSwapTest swapRouter;

    Currency currency0;
    Currency currency1;
    int24 TICK_SPACING = 60;
    PoolKey key;

    mapping(address user => Position[]) positions;

    bytes constant ZERO_BYTES = "";
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_RATIO + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_RATIO - 1;

    constructor(
        LiquidityPositionManager _lpm,
        PoolSwapTest _swapRouter,
        PoolInitializeTest _initializeRouter,
        Currency _currency0,
        Currency _currency1
    ) {
        lpm = _lpm;
        swapRouter = _swapRouter;
        currency0 = _currency0;
        currency1 = _currency1;

        // create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0x0)));
        _initializeRouter.initialize(key, Constants.SQRT_RATIO_1_1, ZERO_BYTES);

        // approvals for swaps
        IERC20(Currency.unwrap(currency0)).approve(address(_swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(_swapRouter), type(uint256).max);
    }

    function mint(int24 minTick, int24 maxTick, uint128 liquidity) public {
        minTick = int24(bound(int256(minTick), int256(minTick), int256(-TICK_SPACING)));
        maxTick = int24(bound(int256(maxTick), int256(TICK_SPACING), int256(maxTick)));
        liquidity = uint128(bound(uint256(liquidity), 1e18, 100_000e18));

        minTick = (minTick / TICK_SPACING) * TICK_SPACING;
        maxTick = (maxTick / TICK_SPACING) * TICK_SPACING;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(minTick),
            TickMath.getSqrtRatioAtTick(maxTick),
            liquidity
        );

        _pay(msg.sender, amount0, amount1);

        vm.startPrank(msg.sender);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
        lpm.modifyPosition(
            msg.sender,
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: minTick,
                tickUpper: maxTick,
                liquidityDelta: int256(uint256(liquidity))
            }),
            ZERO_BYTES
        );
        vm.stopPrank();
    }

    // function swap(int256 amountSpecified, bool zeroForOne) internal {
    //     amountSpecified = bound(-10e18, 10e18);

    //     IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    //         zeroForOne: zeroForOne,
    //         amountSpecified: amountSpecified,
    //         sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT // unlimited impact
    //     });

    //     PoolSwapTest.TestSettings memory testSettings =
    //         PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true, currencyAlreadySent: false});

    //     swapRouter.swap(key, params, testSettings, ZERO_BYTES);
    // }

    // function collectFees() public {
    //     vm.startPrank(msg.sender);
    //     lpm.collectFees(msg.sender, position, currency0);
    //     lpm.collectFees(msg.sender, position, currency1);
    //     vm.stopPrank();
    // }

    function _pay(address user, uint256 amount0, uint256 amount1) internal {
        currency0.transfer(user, amount0);
        currency1.transfer(user, amount1);
    }
}
