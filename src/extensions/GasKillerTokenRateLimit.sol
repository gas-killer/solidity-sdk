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
///      unless it is `transfer`, `approve`, `increaseAllowance`, `decreaseAllowance` or a
///      `transferFrom` from or to this contract, or `_allowTokenCall` allows it: any other
///      function could grant an allowance the limit doesn't see, and a `transferFrom` between two
///      others moves tokens users approved this contract for, which its balance doesn't show.
abstract contract GasKillerTokenRateLimit is GasKillerOutgoingRateLimit {
    /// @param ethLimit Most wei signed programs may send in one `ethPeriod`.
    /// @param ethPeriod Seconds over which the full `ethLimit` refills.
    /// @dev Behind a proxy, pass `(0, 0)` and set the ETH limit and the token limits from the
    ///      initializer (see `GasKillerOutgoingRateLimit`'s constructor).
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

    /// @notice Override to let signed programs make a call the limit doesn't recognize to the
    ///         listed `token`: `selector` is `data`'s first four bytes, zero when it is shorter.
    ///         Rejects all by default. Allow only calls that can't grant an allowance or otherwise
    ///         let tokens leave later: what they move during the program is charged through the
    ///         balance, but what they authorize for afterwards is not. Check `data`'s arguments
    ///         where the selector alone isn't enough.
    function _allowTokenCall(address token, bytes4 selector, bytes memory data) internal view virtual returns (bool) {}

    /// @notice Override, in place of `_beforeProgram`, to act right before a signed program runs.
    ///         The program has begun, so token limits can't be set or cleared here.
    function _beforeLimitedProgram() internal virtual {}

    /// @notice Override, in place of `_afterProgram`, to act right after a signed program ran;
    ///         revert to reject it. Runs before the program's tokens are charged, so token limits
    ///         can't be set or cleared here either.
    function _afterLimitedProgram() internal virtual {}

    /// @dev Final, so a consumer can't drop the token charge from `limitsOutflow`.
    function _beginTokenOutflow() internal override {
        TokenRateLimit.begin();
        TokenRateLimit.snapshot(_tokenLimits());
    }

    /// @dev Final, as `_beginTokenOutflow`.
    function _endTokenOutflow() internal override {
        TokenRateLimit.endProgram(_tokenLimits());
    }

    function _beforeProgram() internal override {
        super._beforeProgram();
        TokenRateLimit.begin();
        _beforeLimitedProgram();
    }

    function _rateLimitOp(uint256 index, StateUpdateType kind, address target, bytes memory data) internal override {
        if (TokenRateLimit.beforeOp(_tokenLimits(), kind, target, data)) {
            bytes4 selector = bytes4(data);
            require(
                _allowTokenCall(target, selector, data), TokenRateLimit.UnrecognizedTokenCall(index, target, selector)
            );
        }
    }

    function _afterProgram() internal override {
        // Read first, so tokens the hook receives don't offset what the program sent.
        TokenRateLimit.checkpoint(_tokenLimits());
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
    /// @dev Behind a proxy, pass `(0, 0)` and set the limits from the initializer, as for
    ///      `GasKillerTokenRateLimit`.
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
    function _allowTokenCall(address token, bytes4 selector, bytes memory data) internal view virtual returns (bool) {}

    /// @notice As `GasKillerTokenRateLimit._beforeLimitedProgram`.
    function _beforeLimitedProgram() internal virtual {}

    /// @notice As `GasKillerTokenRateLimit._afterLimitedProgram`.
    function _afterLimitedProgram() internal virtual {}

    /// @dev Final, so a consumer can't drop the token charge from `limitsOutflow`.
    function _beginTokenOutflow() internal override {
        TokenRateLimit.begin();
        TokenRateLimit.snapshot(_tokenLimits());
    }

    /// @dev Final, as `_beginTokenOutflow`.
    function _endTokenOutflow() internal override {
        TokenRateLimit.endProgram(_tokenLimits());
    }

    function _beforeProgram() internal override {
        super._beforeProgram();
        TokenRateLimit.begin();
        _beforeLimitedProgram();
    }

    function _rateLimitOp(uint256 index, StateUpdateType kind, address target, bytes memory data) internal override {
        if (TokenRateLimit.beforeOp(_tokenLimits(), kind, target, data)) {
            bytes4 selector = bytes4(data);
            require(
                _allowTokenCall(target, selector, data), TokenRateLimit.UnrecognizedTokenCall(index, target, selector)
            );
        }
    }

    function _afterProgram() internal override {
        // Read first, so tokens the hook receives don't offset what the program sent.
        TokenRateLimit.checkpoint(_tokenLimits());
        _afterLimitedProgram();
        TokenRateLimit.endProgram(_tokenLimits());
        super._afterProgram();
    }
}
