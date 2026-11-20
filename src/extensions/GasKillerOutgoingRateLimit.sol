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
///      `_maxOutgoingValue` still caps each program on its own. To combine it with the call
///      allow-list, inherit this contract and run `CallAllowList.check` from
///      `_authorizeLimitedCall` (see `GasKillerCallAllowList`); don't inherit both.
abstract contract GasKillerOutgoingRateLimit is GasKillerSDK {
    /// @param limit Most wei signed programs may send in one `period`; zero sends none.
    /// @param period Seconds over which the full `limit` refills.
    /// @dev Sets the budget in the deploying contract's own storage. **Behind a proxy that is the
    ///      implementation, not the proxy**: pass `(0, 0)`, which sets nothing, and call
    ///      `_setOutgoingRateLimit` from the initializer, or the proxy's budget stays empty and
    ///      every op that sends value reverts.
    constructor(uint256 limit, uint256 period) {
        if (limit != 0 || period != 0) OutgoingRateLimit.set(_outgoingBucket(), limit, period);
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
    ///         are `_authorizeCall`'s, including that `data` must not be written. Runs before
    ///         the op is charged to the limit. Allows everything by default.
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

    /// @notice Wrap each of this contract's own functions that can pay out ETH (or, in the token
    ///         drop-in, a listed token) in this modifier. What the function sends out, net of what
    ///         it receives, spends from the same budget as signed programs.
    /// @dev Signed programs are limited by their ops, but a malicious quorum can also `STORE`
    ///      itself a balance in this contract's state and withdraw it through an ordinary
    ///      `withdraw()` later. Limiting the payout functions too bounds that route: honest
    ///      withdrawals then share the budget, so size `limit` for normal traffic. Measured by
    ///      balance, so every route out of the function counts, including callbacks. The call's
    ///      `msg.value` is in the balance before the function runs, so it doesn't offset what the
    ///      function sends. A limited function that calls another, directly or through a callback, is
    ///      charged for both windows: conservative, never under-counted. Reverts with
    ///      `OutgoingRateLimit.NativeOutflowRateLimitExceeded` (or
    ///      `TokenRateLimit.TokenRateLimitExceeded`) after the function, rolling it back. In the
    ///      token drop-in the function runs as a program does, so it can't set or clear token
    ///      limits (`TokenRateLimit.TokenRateLimitChangedMidProgram`), and every window reads
    ///      `balanceOf` on every listed token: one whose `balanceOf` reverts blocks every
    ///      limited function, ETH-only payouts included, until it is cleared.
    ///
    ///      **Never on a `trackState` function.** The window writes the budget, which is protected
    ///      storage, so a program carrying that write can never settle (`ProtectedSlotWrite`), as
    ///      with the config setters. Limit the plain functions that pay out.
    ///
    ///      **Net, so inflows hide payouts.** Anything the contract receives during the window
    ///      offsets what it sends: ETH or tokens a third party pays in (rewards a public
    ///      `harvest()` or claim sends here, a repayment, a protocol's payout) and tokens this
    ///      contract pulls with `transferFrom`. If the recipient's callback (an ETH `receive`, an
    ///      ERC-777 or ERC-1155 hook) can trigger such an inflow, a credited balance can leave
    ///      uncharged, covered by funds that belonged to others. Keep such inflows out of reach
    ///      of the window, or pay out without a callback that can reach them (a pull pattern).
    ///      Charging gross outflow instead is tracked in #117.
    modifier limitsOutflow() {
        uint256 ethBaseline = OutgoingRateLimit.beginNative();
        _beginTokenOutflow();
        _;
        _endTokenOutflow();
        OutgoingRateLimit.endNative(_outgoingBucket(), ethBaseline);
    }

    /// @dev For `GasKillerTokenRateLimit`, which opens and closes its token window here, inside
    ///      the ETH one. Not meant for consumers: the modifier itself can't be overridden, so the
    ///      ETH charge can't be dropped by an override that forgets `super`.
    function _beginTokenOutflow() internal virtual {}

    /// @dev As `_beginTokenOutflow`: closes the token window and charges it.
    function _endTokenOutflow() internal virtual {}

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
    /// @dev Behind a proxy, pass `(0, 0)` and call `_setOutgoingRateLimit` from the
    ///      initializer, as for `GasKillerOutgoingRateLimit`.
    constructor(uint256 limit, uint256 period) {
        if (limit != 0 || period != 0) OutgoingRateLimit.set(_outgoingBucket(), limit, period);
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

    /// @notice Wrap each of this contract's own functions that can pay out ETH (or, in the token
    ///         drop-in, a listed token) in this modifier. What the function sends out, net of what
    ///         it receives, spends from the same budget as signed programs.
    /// @dev Signed programs are limited by their ops, but a malicious quorum can also `STORE`
    ///      itself a balance in this contract's state and withdraw it through an ordinary
    ///      `withdraw()` later. Limiting the payout functions too bounds that route: honest
    ///      withdrawals then share the budget, so size `limit` for normal traffic. Measured by
    ///      balance, so every route out of the function counts, including callbacks. The call's
    ///      `msg.value` is in the balance before the function runs, so it doesn't offset what the
    ///      function sends. A limited function that calls another, directly or through a callback, is
    ///      charged for both windows: conservative, never under-counted. Reverts with
    ///      `OutgoingRateLimit.NativeOutflowRateLimitExceeded` (or
    ///      `TokenRateLimit.TokenRateLimitExceeded`) after the function, rolling it back. In the
    ///      token drop-in the function runs as a program does, so it can't set or clear token
    ///      limits (`TokenRateLimit.TokenRateLimitChangedMidProgram`), and every window reads
    ///      `balanceOf` on every listed token: one whose `balanceOf` reverts blocks every
    ///      limited function, ETH-only payouts included, until it is cleared.
    ///
    ///      **Never on a `trackState` function.** The window writes the budget, which is protected
    ///      storage, so a program carrying that write can never settle (`ProtectedSlotWrite`), as
    ///      with the config setters. Limit the plain functions that pay out.
    ///
    ///      **Net, so inflows hide payouts.** Anything the contract receives during the window
    ///      offsets what it sends: ETH or tokens a third party pays in (rewards a public
    ///      `harvest()` or claim sends here, a repayment, a protocol's payout) and tokens this
    ///      contract pulls with `transferFrom`. If the recipient's callback (an ETH `receive`, an
    ///      ERC-777 or ERC-1155 hook) can trigger such an inflow, a credited balance can leave
    ///      uncharged, covered by funds that belonged to others. Keep such inflows out of reach
    ///      of the window, or pay out without a callback that can reach them (a pull pattern).
    ///      Charging gross outflow instead is tracked in #117.
    modifier limitsOutflow() {
        uint256 ethBaseline = OutgoingRateLimit.beginNative();
        _beginTokenOutflow();
        _;
        _endTokenOutflow();
        OutgoingRateLimit.endNative(_outgoingBucket(), ethBaseline);
    }

    /// @dev For `GasKillerTokenRateLimit`, which opens and closes its token window here, inside
    ///      the ETH one. Not meant for consumers: the modifier itself can't be overridden, so the
    ///      ETH charge can't be dropped by an override that forgets `super`.
    function _beginTokenOutflow() internal virtual {}

    /// @dev As `_beginTokenOutflow`: closes the token window and charges it.
    function _endTokenOutflow() internal virtual {}

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
