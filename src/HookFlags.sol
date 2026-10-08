// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Address flags used by the external launch factory's initialization guard.
library HookFlags {
    uint160 internal constant BEFORE_INITIALIZE = 1 << 13;
    uint160 internal constant ALL = (1 << 14) - 1;

    function matches(address hook, uint160 flags) internal pure returns (bool) {
        return uint160(hook) & ALL == flags;
    }
}
