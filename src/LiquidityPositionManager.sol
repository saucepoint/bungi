// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {ERC6909} from "ERC-6909/ERC6909.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Position, PositionId, PositionIdLibrary} from "./types/PositionId.sol";
import {Position as PoolPosition} from "@uniswap/v4-core/contracts/libraries/Position.sol";

contract LiquidityPositionManager is ERC6909 {
    using CurrencyLibrary for Currency;
    using PositionIdLibrary for Position;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable manager;

    struct CallbackData {
        address sender;
        address owner;
        PoolKey key;
        IPoolManager.ModifyPositionParams params;
        bytes hookData;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function modifyExistingPosition(
        address owner,
        Position memory position,
        int256 existingLiquidityDelta,
        IPoolManager.ModifyPositionParams memory params,
        bytes calldata hookDataOnBurn,
        bytes calldata hookDataOnMint
    ) external {
        BalanceDelta delta = abi.decode(
            manager.lock(
                abi.encodeCall(
                    this.handleModifyExistingPosition,
                    (msg.sender, owner, position, existingLiquidityDelta, params, hookDataOnBurn, hookDataOnMint)
                )
            ),
            (BalanceDelta)
        );

        // adjust 6909 balances

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    function handleModifyExistingPosition(
        address sender,
        address owner,
        Position memory position,
        int256 existingLiquidityDelta,
        IPoolManager.ModifyPositionParams memory params,
        bytes memory hookDataOnBurn,
        bytes memory hookDataOnMint
    ) external returns (BalanceDelta delta) {
        PoolKey memory key = position.poolKey;

        // unwind the old position
        BalanceDelta deltaBurn = manager.modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDelta: existingLiquidityDelta
            }),
            hookDataOnBurn
        );
        BalanceDelta deltaMint = manager.modifyPosition(key, params, hookDataOnMint);

        delta = deltaBurn + deltaMint;

        if (delta.amount0() > 0) {
            if (key.currency0.isNative()) {
                manager.settle{value: uint128(delta.amount0())}(key.currency0);
            } else {
                IERC20(Currency.unwrap(key.currency0)).transferFrom(sender, address(manager), uint128(delta.amount0()));
                manager.settle(key.currency0);
            }
        }
        if (delta.amount1() > 0) {
            if (key.currency1.isNative()) {
                manager.settle{value: uint128(delta.amount1())}(key.currency1);
            } else {
                IERC20(Currency.unwrap(key.currency1)).transferFrom(sender, address(manager), uint128(delta.amount1()));
                manager.settle(key.currency1);
            }
        }

        if (delta.amount0() < 0) {
            manager.take(key.currency0, sender, uint128(-delta.amount0()));
        }
        if (delta.amount1() < 0) {
            manager.take(key.currency1, sender, uint128(-delta.amount1()));
        }
    }

    function handleModifyPosition(bytes memory rawData) external returns (BalanceDelta delta) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        delta = manager.modifyPosition(data.key, data.params, data.hookData);

        if (delta.amount0() > 0) {
            if (data.key.currency0.isNative()) {
                manager.settle{value: uint128(delta.amount0())}(data.key.currency0);
            } else {
                IERC20(Currency.unwrap(data.key.currency0)).transferFrom(
                    data.sender, address(manager), uint128(delta.amount0())
                );
                manager.settle(data.key.currency0);
            }
        }
        if (delta.amount1() > 0) {
            if (data.key.currency1.isNative()) {
                manager.settle{value: uint128(delta.amount1())}(data.key.currency1);
            } else {
                IERC20(Currency.unwrap(data.key.currency1)).transferFrom(
                    data.sender, address(manager), uint128(delta.amount1())
                );
                manager.settle(data.key.currency1);
            }
        }

        if (delta.amount0() < 0) {
            manager.take(data.key.currency0, data.sender, uint128(-delta.amount0()));
        }
        if (delta.amount1() < 0) {
            manager.take(data.key.currency1, data.sender, uint128(-delta.amount1()));
        }
    }

    function modifyPosition(
        address owner,
        PoolKey memory key,
        IPoolManager.ModifyPositionParams memory params,
        bytes calldata hookData
    ) public {
        bytes memory result = manager.lock(
            abi.encodeCall(
                this.handleModifyPosition, abi.encode(CallbackData(msg.sender, owner, key, params, hookData))
            )
        );
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        // for now assume that modifyPosition is for ADD
        require(delta.amount0() > 0, "Must add amount0");
        require(delta.amount1() > 0, "Must add amount1");

        PositionId positionId =
            Position({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper}).toId();

        // TODO: guarantee that k is less than int256 max
        // TODO: proper book keeping to avoid double-counting
        uint256 liquidity =
            uint256(manager.getPosition(key.toId(), address(this), params.tickLower, params.tickUpper).liquidity);
        _mint(owner, uint256(PositionId.unwrap(positionId)), liquidity);

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));

        (bool success, bytes memory returnData) = address(this).call(data);
        if (success) return returnData;
        if (returnData.length == 0) revert("LockFailure");
        // if the call failed, bubble up the reason
        /// @solidity memory-safe-assembly
        assembly {
            revert(add(returnData, 32), mload(returnData))
        }
    }

    // --- ERC-6909 ---
    function _mint(address owner, uint256 tokenId, uint256 amount) internal {
        balanceOf[owner][tokenId] += amount;
        emit Transfer(msg.sender, address(this), owner, tokenId, amount);
    }
}
