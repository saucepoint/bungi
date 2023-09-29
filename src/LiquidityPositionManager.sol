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
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";

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

    /// @notice Given an existing position, readjust it to a new range, optionally using net-new tokens
    ///     This function supports partially withdrawing tokens from an LP to open up a new position
    /// @param owner The owner of the position
    /// @param position The position to rebalance
    /// @param existingLiquidityDelta How much liquidity to remove from the existing position
    /// @param params The new position parameters
    /// @param hookDataOnBurn the arbitrary bytes to provide to hooks when the existing position is modified
    /// @param hookDataOnMint the arbitrary bytes to provide to hooks when the new position is created
    function rebalancePosition(
        address owner,
        Position memory position,
        int256 existingLiquidityDelta,
        IPoolManager.ModifyPositionParams memory params,
        bytes calldata hookDataOnBurn,
        bytes calldata hookDataOnMint
    ) external returns (BalanceDelta delta) {
        if (!(msg.sender == owner || isOperator[owner][msg.sender])) revert InsufficientPermission();
        delta = abi.decode(
            manager.lock(
                abi.encodeCall(
                    this.handleRebalancePosition,
                    (msg.sender, owner, position, existingLiquidityDelta, params, hookDataOnBurn, hookDataOnMint)
                )
            ),
            (BalanceDelta)
        );

        // adjust 6909 balances
        _burn(owner, position.toTokenId(), uint256(-existingLiquidityDelta));
        uint256 newPositionTokenId =
            Position({poolKey: position.poolKey, tickLower: params.tickLower, tickUpper: params.tickUpper}).toTokenId();
        _mint(owner, newPositionTokenId, uint256(params.liquidityDelta));

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    function handleRebalancePosition(
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

        processBalanceDelta(sender, key.currency0, key.currency1, delta);
    }

    function handleModifyPosition(bytes memory rawData) external returns (BalanceDelta delta) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        delta = manager.modifyPosition(data.key, data.params, data.hookData);
        processBalanceDelta(data.sender, data.key.currency0, data.key.currency1, delta);
    }

    function modifyPosition(
        address owner,
        PoolKey memory key,
        IPoolManager.ModifyPositionParams memory params,
        bytes calldata hookData
    ) external returns (BalanceDelta delta) {
        if (!(msg.sender == owner || isOperator[owner][msg.sender])) revert InsufficientPermission();
        delta = abi.decode(
            manager.lock(
                abi.encodeCall(
                    this.handleModifyPosition, abi.encode(CallbackData(msg.sender, owner, key, params, hookData))
                )
            ),
            (BalanceDelta)
        );

        uint256 tokenId = Position({poolKey: key, tickLower: params.tickLower, tickUpper: params.tickUpper}).toTokenId();

        // burn 6909
        if (params.liquidityDelta < 0) {
            _burn(owner, tokenId, uint256(-params.liquidityDelta));
        } else {
            // TODO: guarantee that k is less than int256 max
            // TODO: proper book keeping to avoid double-counting
            _mint(owner, tokenId, uint256(params.liquidityDelta));
        }

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

    function processBalanceDelta(address sender, Currency currency0, Currency currency1, BalanceDelta delta) internal {
        if (delta.amount0() > 0) {
            if (currency0.isNative()) {
                manager.settle{value: uint128(delta.amount0())}(currency0);
            } else {
                IERC20(Currency.unwrap(currency0)).transferFrom(sender, address(manager), uint128(delta.amount0()));
                manager.settle(currency0);
            }
        }
        if (delta.amount1() > 0) {
            if (currency1.isNative()) {
                manager.settle{value: uint128(delta.amount1())}(currency1);
            } else {
                IERC20(Currency.unwrap(currency1)).transferFrom(sender, address(manager), uint128(delta.amount1()));
                manager.settle(currency1);
            }
        }

        if (delta.amount0() < 0) {
            manager.take(currency0, sender, uint128(-delta.amount0()));
        }
        if (delta.amount1() < 0) {
            manager.take(currency1, sender, uint128(-delta.amount1()));
        }
    }

    // --- ERC-6909 --- //
    function _mint(address owner, uint256 tokenId, uint256 amount) internal {
        balanceOf[owner][tokenId] += amount;
        emit Transfer(msg.sender, address(this), owner, tokenId, amount);
    }

    function _burn(address owner, uint256 tokenId, uint256 amount) internal {
        balanceOf[owner][tokenId] -= amount;
        emit Transfer(msg.sender, owner, address(this), tokenId, amount);
    }
}
