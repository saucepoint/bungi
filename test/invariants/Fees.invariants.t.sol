// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {LiquidityPositionManager} from "../../src/LiquidityPositionManager.sol";
import {Handler} from "./Handler.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

contract FeeInvariants is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    LiquidityPositionManager lpm;
    Handler handler;

    function setUp() public {
        Deployers.deployFreshManagerAndRouters();
        (currency0, currency1) = Deployers.deployMintAndApprove2Currencies();

        lpm = new LiquidityPositionManager(IPoolManager(address(manager)));
        handler = new Handler(lpm, swapRouter, initializeRouter, currency0, currency1);

        targetContract(address(handler));
    }

    function invariant_fees() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: handler.FEE(),
            tickSpacing: handler.TICK_SPACING(),
            hooks: IHooks(address(0))
        });
        Pool.State storage poolState = manager.pools(key.toId());
        uint256 collectedFees0 = handler.collectedFees0();
        uint256 collectedFees1 = handler.collectedFees1();
        console2.log(collectedFees0, collectedFees1, poolState.feeGrowthGlobal0X128, poolState.feeGrowthGlobal1X128);
    }

    function invariant_callSummary() public {
        handler.callSummary();
    }
}
