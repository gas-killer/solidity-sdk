// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {GasKillerSDK} from "../GasKillerSDK.sol";
import {GasKillerNestedSDK} from "../GasKillerNestedSDK.sol";
import {StateUpdateType} from "../StateChangeHandlerLib.sol";
import {CallAllowList} from "../libraries/CallAllowList.sol";

/// @title GasKillerCallAllowList
/// @notice `GasKillerSDK` with a default-deny allow-list for signed programs: a `CALL` runs only
///         if `_isAllowedCall(target, selector)` says so, a `NESTED` op only if
///         `_isAllowedCall(target, IGasKillerNested.applyNested.selector)` does, and deployments
///         only if `_allowDeployments()` does (see `CallAllowList`). Inherit it instead of
///         `GasKillerSDK` and implement `_isAllowedCall`:
///         ```
///         function _isAllowedCall(address target, bytes4 selector) internal view override returns (bool) {
///             return (target == address(usdc) && selector == IERC20.transfer.selector)
///                 || (target == payee && selector == bytes4(0)); // plain ETH to the payee
///         }
///         ```
/// @dev Self-calls are governed by `_allowSelfCall` and aren't checked again here. The
///      rate-limit drop-ins make `_authorizeCall` final, so don't inherit this alongside one:
///      inherit the drop-in and run the same check from its `_authorizeLimitedCall`:
///      ```
///      contract Vault is GasKillerTokenRateLimit {
///          function _isAllowedCall(address target, bytes4 selector) internal view returns (bool) { ... }
///
///          function _authorizeLimitedCall(uint256 i, StateUpdateType k, address t, uint256, bytes memory d)
///              internal view override
///          {
///              CallAllowList.check(i, k, t, d, _isAllowedCall, false); // true to allow deployments
///          }
///      }
///      ```
abstract contract GasKillerCallAllowList is GasKillerSDK {
    /// @notice Whether a signed program may call `selector` on `target`. `selector` is zero for a
    ///         plain ETH transfer (empty calldata), and `IGasKillerNested.applyNested.selector`
    ///         for a `NESTED` op. Keep it `pure`, or reading immutables, where you can.
    /// @dev The list bounds which contracts and functions are reachable, not a call's arguments:
    ///      an allowed `transfer` sends wherever the quorum says. Pair it with a rate limit.
    function _isAllowedCall(address target, bytes4 selector) internal view virtual returns (bool);

    /// @notice Whether a signed program may run `CREATE` or `CREATE2`. Off by default.
    function _allowDeployments() internal view virtual returns (bool) {
        return false;
    }

    function _authorizeCall(uint256 index, StateUpdateType kind, address target, uint256 value, bytes memory data)
        internal
        virtual
        override
    {
        super._authorizeCall(index, kind, target, value, data);
        CallAllowList.check(index, kind, target, data, _isAllowedCall, _allowDeployments());
    }
}

/// @title GasKillerNestedCallAllowList
/// @notice `GasKillerCallAllowList` for nested settlement: inherit it instead of
///         `GasKillerNestedSDK`. A `NESTED` op to another frame contract must be allowed as
///         `(callee, IGasKillerNested.applyNested.selector)`.
abstract contract GasKillerNestedCallAllowList is GasKillerNestedSDK {
    /// @notice As `GasKillerCallAllowList._isAllowedCall`.
    function _isAllowedCall(address target, bytes4 selector) internal view virtual returns (bool);

    /// @notice As `GasKillerCallAllowList._allowDeployments`.
    function _allowDeployments() internal view virtual returns (bool) {
        return false;
    }

    function _authorizeCall(uint256 index, StateUpdateType kind, address target, uint256 value, bytes memory data)
        internal
        virtual
        override
    {
        super._authorizeCall(index, kind, target, value, data);
        CallAllowList.check(index, kind, target, data, _isAllowedCall, _allowDeployments());
    }
}
