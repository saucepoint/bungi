// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";

type PositionId is bytes32;

struct Position {
    PoolKey poolKey;
    int24 tickLower;
    int24 tickUpper;
}

/// @notice Library for computing the ID of a Position
library PositionIdLibrary {
    function toId(Position memory position) internal pure returns (PositionId) {
        return PositionId.wrap(keccak256(abi.encode(position)));
    }

    function toTokenId(Position memory position) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(position)));
    }
}
