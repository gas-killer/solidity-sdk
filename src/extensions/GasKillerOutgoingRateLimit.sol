// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {GasKillerSDK} from "../GasKillerSDK.sol";
import {GasKillerNestedSDK} from "../GasKillerNestedSDK.sol";
import {StateUpdateType} from "../StateChangeHandlerLib.sol";
import {OutgoingRateLimit} from "../libraries/OutgoingRateLimit.sol";

/// @title GasKillerOutgoingRateLimit
/// @notice `GasKillerSDK` with a rate limit on the ETH signed programs send: at most `limit` wei
///         per `period`, refilling continuously (see `OutgoingRateLimit`). Inherit it instead of
///         `GasKillerSDK`; for per-token limits too, inherit `GasKillerTokenRateLimit`.
/// @dev **Write your call policy in `_authorizeLimitedCall`, not `_authorizeCall`.** This contract
///      finalizes `_authorizeCall`, so the limit is spent whatever an override does: an override
///      that left out `super` would otherwise switch the limit off without any error. Trying to
///      override `_authorizeCall` is a compile error.
///      `_maxOutgoingValue` still caps each program on its own. To add the limit to a contract
///      that already inherits another `GasKillerSDK` base, call `OutgoingRateLimit` from that
///      contract's own `_authorizeCall` instead.
abstract contract GasKillerOutgoingRateLimit is GasKillerSDK {
    /// @param limit Most wei signed programs may send in one `period`; zero sends none.
    /// @param period Seconds over which the full `limit` refills.
    /// @dev Sets the budget in the deploying contract's own storage. **Behind a proxy that is the
    ///      implementation, not the proxy**: call `_setOutgoingRateLimit` from the initializer, or
    ///      the proxy's budget stays empty and every op that sends value reverts.
    constructor(uint256 limit, uint256 period) {
        OutgoingRateLimit.set(_outgoingBucket(), limit, period);
    }

    /// @notice The budget: wei signed programs may send now, the limit and the period.
    function gasKillerOutgoingAllowance() external view returns (uint256 available, uint256 limit, uint256 period) {
        return OutgoingRateLimit.allowance(_outgoingBucket());
    }

    /// @dev See `OutgoingRateLimit.set`: never from a `trackState` function.
    function _setOutgoingRateLimit(uint256 limit, uint256 period) internal {
        OutgoingRateLimit.set(_outgoingBucket(), limit, period);
    }

    /// @notice Override, in place of `_authorizeCall`, to reject ops; the arguments and rules
    ///         are `_authorizeCall`'s. Runs before the op is charged to the limit. Allows
    ///         everything by default.
    function _authorizeLimitedCall(
        uint256 index,
        StateUpdateType kind,
        address target,
        uint256 value,
        bytes memory data
    ) internal virtual {}

    /// @dev For `GasKillerTokenRateLimit`, which adds its own per-op step here. Runs after the ETH
    ///      limit. Not meant for consumers: put policy in `_authorizeLimitedCall`.
    function _rateLimitOp(uint256 index, StateUpdateType kind, address target, bytes memory data) internal virtual {}

    /// @dev Final: see the contract's notes.
    function _authorizeCall(uint256 index, StateUpdateType kind, address target, uint256 value, bytes memory data)
        internal
        override
    {
        super._authorizeCall(index, kind, target, value, data);
        _authorizeLimitedCall(index, kind, target, value, data);
        OutgoingRateLimit.spend(_outgoingBucket(), index, target, value);
        _rateLimitOp(index, kind, target, data);
    }
}

/// @title GasKillerNestedOutgoingRateLimit
/// @notice `GasKillerOutgoingRateLimit` for nested settlement: inherit it instead of
///         `GasKillerNestedSDK`. Value a `NESTED` op forwards spends this contract's budget; a
///         callee with its own limit spends its own. As there, write the call policy in
///         `_authorizeLimitedCall`.
abstract contract GasKillerNestedOutgoingRateLimit is GasKillerNestedSDK {
    /// @param limit Most wei signed programs may send in one `period`; zero sends none.
    /// @param period Seconds over which the full `limit` refills.
    /// @dev Behind a proxy, call `_setOutgoingRateLimit` from the initializer, as for
    ///      `GasKillerOutgoingRateLimit`.
    constructor(uint256 limit, uint256 period) {
        OutgoingRateLimit.set(_outgoingBucket(), limit, period);
    }

    /// @notice The budget: wei signed programs may send now, the limit and the period.
    function gasKillerOutgoingAllowance() external view returns (uint256 available, uint256 limit, uint256 period) {
        return OutgoingRateLimit.allowance(_outgoingBucket());
    }

    /// @dev See `OutgoingRateLimit.set`: never from a `trackState` function.
    function _setOutgoingRateLimit(uint256 limit, uint256 period) internal {
        OutgoingRateLimit.set(_outgoingBucket(), limit, period);
    }

    /// @notice As `GasKillerOutgoingRateLimit._authorizeLimitedCall`.
    function _authorizeLimitedCall(
        uint256 index,
        StateUpdateType kind,
        address target,
        uint256 value,
        bytes memory data
    ) internal virtual {}

    /// @dev As `GasKillerOutgoingRateLimit._rateLimitOp`.
    function _rateLimitOp(uint256 index, StateUpdateType kind, address target, bytes memory data) internal virtual {}

    /// @dev Final, as in `GasKillerOutgoingRateLimit`.
    function _authorizeCall(uint256 index, StateUpdateType kind, address target, uint256 value, bytes memory data)
        internal
        override
    {
        super._authorizeCall(index, kind, target, value, data);
        _authorizeLimitedCall(index, kind, target, value, data);
        OutgoingRateLimit.spend(_outgoingBucket(), index, target, value);
        _rateLimitOp(index, kind, target, data);
    }
}
