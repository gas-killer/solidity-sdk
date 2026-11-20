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
/// @dev Put extra policy in `_authorizeAllowedCall`: `_authorizeCall` is final here, so the list
///      can't be switched off by an override. Self-calls are governed by `_allowSelfCall` and aren't checked again here, nor are
///      `NESTED` ops to this contract (each op of the frame they open is). The
///      rate-limit drop-ins make `_authorizeCall` final, so don't inherit this alongside one:
///      inherit the drop-in and run the same check from its `_authorizeLimitedCall`:
///      ```
///      contract Vault is GasKillerTokenRateLimit {
///          function _isAllowedCall(address target, bytes4 selector) internal view returns (bool) { ... }
///
///          function _authorizeLimitedCall(uint256 i, StateUpdateType k, address t, uint256, bytes memory d)
///              internal view override
///          {
///              CallAllowList.check(i, k, t, d, _isAllowedCall, CallAllowList.noDeployments);
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

    /// @notice Override, in place of `_authorizeCall`, to add policy on top of the list; the
    ///         arguments and rules are `_authorizeCall`'s, including that `data` must not be
    ///         written. Runs after the list allowed the op. Allows everything by default.
    function _authorizeAllowedCall(
        uint256 index,
        StateUpdateType kind,
        address target,
        uint256 value,
        bytes memory data
    ) internal virtual {}

    /// @dev Final, so an override that left out `super` can't switch the list off.
    function _authorizeCall(uint256 index, StateUpdateType kind, address target, uint256 value, bytes memory data)
        internal
        override
    {
        super._authorizeCall(index, kind, target, value, data);
        CallAllowList.check(index, kind, target, data, _isAllowedCall, _allowDeployments);
        _authorizeAllowedCall(index, kind, target, value, data);
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

    /// @notice As `GasKillerCallAllowList._authorizeAllowedCall`.
    function _authorizeAllowedCall(
        uint256 index,
        StateUpdateType kind,
        address target,
        uint256 value,
        bytes memory data
    ) internal virtual {}

    /// @dev Final, as in `GasKillerCallAllowList`.
    function _authorizeCall(uint256 index, StateUpdateType kind, address target, uint256 value, bytes memory data)
        internal
        override
    {
        super._authorizeCall(index, kind, target, value, data);
        CallAllowList.check(index, kind, target, data, _isAllowedCall, _allowDeployments);
        _authorizeAllowedCall(index, kind, target, value, data);
    }
}
