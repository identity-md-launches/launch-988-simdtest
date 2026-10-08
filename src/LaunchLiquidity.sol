// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Internal launch settlement helpers, also used by the launch compatibility harness.
/// @dev Call only inside the caller's authenticated PoolManager unlock callback.
library LaunchLiquidity {
    struct Seed {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    error SettlementShortfall(uint256 expected, uint256 paid);

    function settleSeed(IPoolManager manager, bytes memory data) internal {
        Seed memory seed = abi.decode(data, (Seed));
        // The caller delta already includes accrued fees; the second return is informational.
        (BalanceDelta delta,) = manager.modifyLiquidity(
            seed.key,
            ModifyLiquidityParams(seed.tickLower, seed.tickUpper, int256(uint256(seed.liquidity)), bytes32(0)),
            ""
        );
        settle(manager, seed.key.currency0, delta.amount0());
        settle(manager, seed.key.currency1, delta.amount1());
    }

    function settle(IPoolManager manager, Currency currency, int128 delta) internal {
        if (delta > 0) {
            // Positive int128 values always fit in uint256.
            // forge-lint: disable-next-line(unsafe-typecast)
            manager.take(currency, address(this), uint256(int256(delta)));
        } else if (delta < 0) {
            // Widen before negating so even int128.min becomes a positive uint256.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 owed = uint256(-int256(delta));
            manager.sync(currency);
            uint256 paid;
            if (currency.isAddressZero()) {
                paid = manager.settle{value: owed}();
            } else {
                currency.transfer(address(manager), owed);
                paid = manager.settle();
            }
            if (paid != owed) revert SettlementShortfall(owed, paid);
        }
    }
}
