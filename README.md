# 🅱️ungi
### **An experimental Liquidity Position Manager for Uniswap v4 🦄**

> The codebase is tested on happy paths only. This should not be used in any production capacity

Add it to your project
```bash
forge install saucepoint/bungi
```

---

# Features

Until Uniswap Labs provides a canonical liquidity position manager (i.e. v3's equivalent `NonfungiblePositionManager`), there was a growing need for a more advanced LP router over [PoolModifyPositionTest]


🅱️ungi's liquidity position manager (LPM) supports:


- [x] Semi-fungible LP tokens ([ERC-6909])

- [x] Gas efficient rebalancing. Completely (or partially) move assets from an existing position into a new range

- [x] Permissioned operators and managers. Delegate to a trusted party to manage your liquidity positions
    - **Allow a hook to modify and adjust your position(s)!**

- [ ] Fee accounting and collection (TODO)

- [ ] Swap-n-add (TODO)

- [ ] Fuzz testing (TODO)


---

# Usage

Deploy for tests

```solidity
// -- snip --
// (other imports)

import {Position, PositionId, PositionIdLibrary} from "bungi/src/types/PositionId.sol";
import {LiquidityPositionManager} from "bungi/src/LiquidityPositionManager.sol";

contract CounterTest is Test {
    using PositionIdLibrary for Position;
    LiquidityPositionManager lpm;

    function setUp() public {
        // -- snip --
        // (deploy v4 PoolManager)

        lpm = new LiquidityPositionManager(IPoolManager(address(manager)));
    }
}

```

Add Liquidity
```solidity
    // Mint 1e18 worth of liquidity on range [-600, 600]
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

    // recieved 1e18 LP tokens (6909)
    Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
    assertEq(lpm.balanceOf(address(this), position.toTokenId()), liquidity);
```

Remove Liquidity
```solidity
    // assume liquidity has been provisioned
    int24 tickLower = -600;
    int24 tickUpper = 600;
    uint256 liquidity = 1e18;

    // remove all liquidity
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
```

Rebalance Liquidity
```solidity
    // lens-style contract to help with liquidity math
    LiquidityHelpers helper = new LiquidityHelpers(IPoolManager(address(manager)), lpm);

    // assume existing position has liquidity already provisioned
    Position memory position = Position({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});

    // removing all `liquidity`` from an existing position and moving it into a new range
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
```



---

Additional resources:

[v4-periphery](https://github.com/uniswap/v4-periphery) contains advanced hook implementations that serve as a great reference

[v4-core](https://github.com/uniswap/v4-core)

