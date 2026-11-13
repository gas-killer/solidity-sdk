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
/// @dev Spends in `_authorizeCall`, after `super._authorizeCall`. A consumer that writes its own
///      `_authorizeCall` must call `super._authorizeCall` too, and can't declare it `view`.
///      `_maxOutgoingValue` still caps each program on its own. To add the limit to a contract
///      that already inherits another `GasKillerSDK` base, call `OutgoingRateLimit` from that
///      contract's own `_authorizeCall` instead, as this one does.
abstract contract GasKillerOutgoingRateLimit is GasKillerSDK {
    /// @param limit Most wei signed programs may send in one `period`; zero sends none.
    /// @param period Seconds over which the full `limit` refills.
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

    function _authorizeCall(
        bytes4 targetFunction,
        uint256 index,
        StateUpdateType kind,
        address target,
        uint256 value,
        bytes memory data
    ) internal virtual override {
        super._authorizeCall(targetFunction, index, kind, target, value, data);
        OutgoingRateLimit.spend(_outgoingBucket(), index, value);
    }
}

/// @title GasKillerNestedOutgoingRateLimit
/// @notice `GasKillerOutgoingRateLimit` for nested settlement: inherit it instead of
///         `GasKillerNestedSDK`. Value a `NESTED` op forwards spends this contract's budget; a
///         callee with its own limit spends its own.
abstract contract GasKillerNestedOutgoingRateLimit is GasKillerNestedSDK {
    /// @param limit Most wei signed programs may send in one `period`; zero sends none.
    /// @param period Seconds over which the full `limit` refills.
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

    function _authorizeCall(
        bytes4 targetFunction,
        uint256 index,
        StateUpdateType kind,
        address target,
        uint256 value,
        bytes memory data
    ) internal virtual override {
        super._authorizeCall(targetFunction, index, kind, target, value, data);
        OutgoingRateLimit.spend(_outgoingBucket(), index, value);
    }
}
