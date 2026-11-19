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
///      pay for the token bookkeeping.
///
///      The program hooks are finalized, like `_authorizeCall`, so no override can skip the
///      bookkeeping: write the call policy in `_authorizeLimitedCall`, and program hooks in
///      `_beforeLimitedProgram` and `_afterLimitedProgram`.
///
///      A signed `CALL` to a listed token is rejected with `TokenRateLimit.UnrecognizedTokenCall`
///      unless it is `transfer`, `transferFrom`, `approve`, `increaseAllowance` or
///      `decreaseAllowance`, or `_allowTokenCall` allows it: any other function could grant an
///      allowance the limit doesn't see.
abstract contract GasKillerTokenRateLimit is GasKillerOutgoingRateLimit {
    /// @param ethLimit Most wei signed programs may send in one `ethPeriod`.
    /// @param ethPeriod Seconds over which the full `ethLimit` refills.
    /// @dev Behind a proxy, set the ETH limit and the token limits from the initializer (see
    ///      `GasKillerOutgoingRateLimit`'s constructor).
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

    /// @notice Override to let signed programs call `selector` on the listed `token`. Rejects all
    ///         by default. Allow only functions that can't grant an allowance or otherwise let
    ///         tokens leave later: what they move during the program is charged through the
    ///         balance, but what they authorize for afterwards is not.
    function _allowTokenCall(address token, bytes4 selector) internal view virtual returns (bool) {}

    /// @notice Override, in place of `_beforeProgram`, to act right before a signed program runs.
    function _beforeLimitedProgram() internal virtual {}

    /// @notice Override, in place of `_afterProgram`, to act right after a signed program ran;
    ///         revert to reject it. Runs before the program's tokens are charged.
    function _afterLimitedProgram() internal virtual {}

    function _beforeProgram() internal override {
        super._beforeProgram();
        TokenRateLimit.begin();
        _beforeLimitedProgram();
    }

    function _rateLimitOp(uint256 index, StateUpdateType kind, address target, bytes memory data) internal override {
        if (TokenRateLimit.beforeOp(_tokenLimits(), kind, target, data)) {
            bytes4 selector = bytes4(data);
            require(_allowTokenCall(target, selector), TokenRateLimit.UnrecognizedTokenCall(index, target, selector));
        }
    }

    function _afterProgram() internal override {
        _afterLimitedProgram();
        TokenRateLimit.endProgram(_tokenLimits());
        super._afterProgram();
    }
}

/// @title GasKillerNestedTokenRateLimit
/// @notice `GasKillerTokenRateLimit` for nested settlement: inherit it instead of
///         `GasKillerNestedSDK`. The same hooks and rules apply.
abstract contract GasKillerNestedTokenRateLimit is GasKillerNestedOutgoingRateLimit {
    /// @param ethLimit Most wei signed programs may send in one `ethPeriod`.
    /// @param ethPeriod Seconds over which the full `ethLimit` refills.
    /// @dev Behind a proxy, set the limits from the initializer, as for `GasKillerTokenRateLimit`.
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

    /// @notice As `GasKillerTokenRateLimit._allowTokenCall`.
    function _allowTokenCall(address token, bytes4 selector) internal view virtual returns (bool) {}

    /// @notice As `GasKillerTokenRateLimit._beforeLimitedProgram`.
    function _beforeLimitedProgram() internal virtual {}

    /// @notice As `GasKillerTokenRateLimit._afterLimitedProgram`.
    function _afterLimitedProgram() internal virtual {}

    function _beforeProgram() internal override {
        super._beforeProgram();
        TokenRateLimit.begin();
        _beforeLimitedProgram();
    }

    function _rateLimitOp(uint256 index, StateUpdateType kind, address target, bytes memory data) internal override {
        if (TokenRateLimit.beforeOp(_tokenLimits(), kind, target, data)) {
            bytes4 selector = bytes4(data);
            require(_allowTokenCall(target, selector), TokenRateLimit.UnrecognizedTokenCall(index, target, selector));
        }
    }

    function _afterProgram() internal override {
        _afterLimitedProgram();
        TokenRateLimit.endProgram(_tokenLimits());
        super._afterProgram();
    }
}
