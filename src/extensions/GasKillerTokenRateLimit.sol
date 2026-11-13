// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {StateUpdateType} from "../StateChangeHandlerLib.sol";
import {TokenRateLimit} from "../libraries/TokenRateLimit.sol";
import {GasKillerOutgoingRateLimit, GasKillerNestedOutgoingRateLimit} from "./GasKillerOutgoingRateLimit.sol";

/// @title GasKillerTokenRateLimit
/// @notice `GasKillerOutgoingRateLimit` plus per-token limits: for each ERC-20 listed with
///         `_setTokenRateLimit`, signed programs may move out at most its limit per its period
///         (see `TokenRateLimit` for what is measured). Inherit it instead of `GasKillerSDK`. To
///         limit tokens only, pass `type(uint96).max` as the ETH limit.
/// @dev Separate from `GasKillerOutgoingRateLimit` so that a contract limiting only ETH doesn't
///      pay for the token bookkeeping. A consumer overriding `_authorizeCall`, `_beforeProgram` or
///      `_afterProgram` must call `super`.
abstract contract GasKillerTokenRateLimit is GasKillerOutgoingRateLimit {
    /// @param ethLimit Most wei signed programs may send in one `ethPeriod`.
    /// @param ethPeriod Seconds over which the full `ethLimit` refills.
    constructor(uint256 ethLimit, uint256 ethPeriod) GasKillerOutgoingRateLimit(ethLimit, ethPeriod) {}

    /// @notice The budget for `token`: what signed programs may move out now, the limit and the
    ///         period. All zero for a token that isn't limited.
    function gasKillerTokenAllowance(address token)
        external
        view
        returns (uint256 available, uint256 limit, uint256 period)
    {
        return TokenRateLimit.allowance(_tokenLimits(), token);
    }

    /// @dev Limits `token` to `limit` per `period` (see `TokenRateLimit.set`): never from a
    ///      `trackState` function. At most `TokenRateLimit.MAX_TOKENS` tokens.
    function _setTokenRateLimit(address token, uint256 limit, uint256 period) internal {
        TokenRateLimit.set(_tokenLimits(), token, limit, period);
    }

    /// @dev Stops limiting `token`. Same rule: never from a `trackState` function.
    function _clearTokenRateLimit(address token) internal {
        TokenRateLimit.clear(_tokenLimits(), token);
    }

    function _beforeProgram(bytes4 targetFunction) internal virtual override {
        super._beforeProgram(targetFunction);
        TokenRateLimit.begin();
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
        TokenRateLimit.beforeOp(_tokenLimits(), kind, target, data);
    }

    function _afterProgram(bytes4 targetFunction) internal virtual override {
        TokenRateLimit.endProgram(_tokenLimits());
        super._afterProgram(targetFunction);
    }
}

/// @title GasKillerNestedTokenRateLimit
/// @notice `GasKillerTokenRateLimit` for nested settlement: inherit it instead of
///         `GasKillerNestedSDK`.
abstract contract GasKillerNestedTokenRateLimit is GasKillerNestedOutgoingRateLimit {
    /// @param ethLimit Most wei signed programs may send in one `ethPeriod`.
    /// @param ethPeriod Seconds over which the full `ethLimit` refills.
    constructor(uint256 ethLimit, uint256 ethPeriod) GasKillerNestedOutgoingRateLimit(ethLimit, ethPeriod) {}

    /// @notice The budget for `token`: what signed programs may move out now, the limit and the
    ///         period. All zero for a token that isn't limited.
    function gasKillerTokenAllowance(address token)
        external
        view
        returns (uint256 available, uint256 limit, uint256 period)
    {
        return TokenRateLimit.allowance(_tokenLimits(), token);
    }

    /// @dev Limits `token` to `limit` per `period` (see `TokenRateLimit.set`): never from a
    ///      `trackState` function. At most `TokenRateLimit.MAX_TOKENS` tokens.
    function _setTokenRateLimit(address token, uint256 limit, uint256 period) internal {
        TokenRateLimit.set(_tokenLimits(), token, limit, period);
    }

    /// @dev Stops limiting `token`. Same rule: never from a `trackState` function.
    function _clearTokenRateLimit(address token) internal {
        TokenRateLimit.clear(_tokenLimits(), token);
    }

    function _beforeProgram(bytes4 targetFunction) internal virtual override {
        super._beforeProgram(targetFunction);
        TokenRateLimit.begin();
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
        TokenRateLimit.beforeOp(_tokenLimits(), kind, target, data);
    }

    function _afterProgram(bytes4 targetFunction) internal virtual override {
        TokenRateLimit.endProgram(_tokenLimits());
        super._afterProgram(targetFunction);
    }
}
