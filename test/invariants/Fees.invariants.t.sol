// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {LiquidityPositionManager} from "../../src/LiquidityPositionManager.sol";
import {Handler} from "./Handler.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

contract FeeInvariants is Test, Deployers {
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

    function invariant_fees() public {}

    function invariant_callSummary() public {
        handler.callSummary();
    }
}
