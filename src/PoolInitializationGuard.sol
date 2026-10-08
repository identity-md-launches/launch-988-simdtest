// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice Launch infrastructure helper: only its deploying factory may initialize its pools.
/// @dev Not a token role or an application in launch.json. No post-initialization callbacks.
contract PoolInitializationGuard {
    address public immutable poolManager;
    address public immutable factory;

    error UnauthorizedInitialization();
    error InvalidPoolManager();

    constructor(address manager) {
        if (manager == address(0)) revert InvalidPoolManager();
        poolManager = manager;
        factory = msg.sender;
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160) external view returns (bytes4) {
        if (msg.sender != poolManager || sender != factory) revert UnauthorizedInitialization();
        return IHooks.beforeInitialize.selector;
    }
}
