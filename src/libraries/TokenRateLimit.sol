// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GasKillerSDK} from "../GasKillerSDK.sol";
import {StateUpdateType} from "../StateChangeHandlerLib.sol";

/// @title TokenRateLimit
/// @notice Per-token rate limits on the ERC-20 tokens signed programs move out of a `GasKillerSDK`
///         contract: for each listed token, at most `limit` per `period`, refilling continuously,
///         like `OutgoingRateLimit` for ETH. Up to `MAX_TOKENS` tokens; unlisted tokens are not
///         limited.
/// @dev Measured, not decoded. A token can leave through `transfer`, through `transferFrom` by a
///      contract holding an allowance (a router pulling during a signed `CALL`), or through
///      anything else the token implements, so the library reads `balanceOf(this)` for every
///      listed token right before the program's first op that runs code (`beforeOp`, from
///      `_authorizeCall`) and again when the program ends (`endProgram`), and charges the net
///      decrease. A program that runs no code can't move tokens and reads nothing.
///
///      An approval moves nothing until it is used, possibly after the program. So `beforeOp`
///      also records every `approve(spender, amount)` and `increaseAllowance(spender, amount)`
///      call to a listed token, with the spender's allowance before it, and `endProgram` charges
///      any allowance left above that. Approving a router that then pulls the tokens is charged
///      once, through the balance; an approval left standing is charged in full, so an unlimited
///      one always reverts. Other ways to grant an allowance aren't seen: another selector
///      (`approveAndCall`), or an allowance system outside the token, such as Permit2. Reject
///      those in `_authorizeCall`.
///
///      Wire it up with `begin` in `_beforeProgram`, `beforeOp` in `_authorizeCall` and
///      `endProgram` in `_afterProgram`; the drop-ins in `src/extensions/` do. Programs can nest on
///      one contract, so the per-program state is kept in transient storage per depth. A
///      program's charge is its net decrease, tokens it receives count against those it sends,
///      and a re-entered frame's decrease is charged both to itself and to the frame around it.
///
///      The budgets live in the SDK's protected config namespace (`GasKillerSDK._tokenLimits()`),
///      so a signed program can't refill them with a `STORE`. All of the contract's programs
///      share them. Only signed programs are charged: the contract's own functions, called
///      natively, are not.
library TokenRateLimit {
    /// @notice A program's net outflow of `token`, with allowances it left standing, exceeds the
    ///         token's budget.
    error TokenRateLimitExceeded(address token, uint256 amount, uint256 available);

    /// @notice A zero token, a limit above `type(uint128).max`, or a period of zero or above
    ///         `type(uint32).max`.
    error InvalidTokenRateLimit();

    /// @notice All `MAX_TOKENS` entries are in use.
    error TooManyRateLimitedTokens();

    event TokenRateLimitSet(address indexed token, uint256 limit, uint256 period);
    event TokenRateLimitCleared(address indexed token);

    /// @notice The most tokens one contract can limit; the length of `TokenLimits.buckets`.
    uint256 internal constant MAX_TOKENS = 8;

    bytes4 private constant _APPROVE = IERC20.approve.selector;
    bytes4 private constant _INCREASE_ALLOWANCE = bytes4(keccak256("increaseAllowance(address,uint256)"));

    /// @dev Transient storage. `_DEPTH` holds the depth of the running program, and each depth
    ///      has a region at `_DEPTH + (depth << 64)`:
    ///      - word 0, the head: bit 0 set once the snapshot is taken, bits 1-8 the number of
    ///        tokens in it, bits 16 and up the number of approvals recorded;
    ///      - three words per snapshotted token i, from word `1 + 3i`: the token, its balance at
    ///        the snapshot, and the allowance increases charged to it so far;
    ///      - three words per approval j, from word `_APPROVALS + 3j`: the token's index in the
    ///        snapshot, the spender, and the spender's allowance before the approval.
    ///      `endProgram` zeroes the head and every charge word, so the region is clean for the next
    ///      program at that depth.
    ///      `_DEPTH` is keccak256("gaskiller.TokenRateLimit.depth"), written out for assembly.
    bytes32 private constant _DEPTH = 0x4df36f89fc12c0e682f8b2d99add7fca126f9125095d9173ca32d3ee48882030;

    uint256 private constant _APPROVALS = 1 + 3 * MAX_TOKENS;

    // ------------------------------------------------------------------ configuration

    /// @notice Limits `token` to `limit` per `period` and fills its budget, adding it to the list
    ///         or updating it.
    /// @dev **Do not call from a `trackState` function**: the budgets are protected storage, so a
    ///      program carrying the write can never settle. Call it from a constructor, an
    ///      initializer or an admin function that is not `trackState`.
    function set(GasKillerSDK.TokenLimits storage t, address token, uint256 limit, uint256 period) internal {
        require(
            token != address(0) && limit <= type(uint128).max && period != 0 && period <= type(uint32).max,
            InvalidTokenRateLimit()
        );
        uint256 n = t.count;
        uint256 i = _find(t, token, n);
        if (i == n) {
            require(n < MAX_TOKENS, TooManyRateLimitedTokens());
            t.count = n + 1;
        }
        t.buckets[i] =
            GasKillerSDK.TokenBucket(token, uint32(period), uint32(block.timestamp), uint128(limit), uint128(limit));
        emit TokenRateLimitSet(token, limit, period);
    }

    /// @notice Stops limiting `token`. Same rule as `set`: never from a `trackState` function.
    function clear(GasKillerSDK.TokenLimits storage t, address token) internal {
        uint256 n = t.count;
        uint256 i = _find(t, token, n);
        if (i == n) return;
        uint256 last = n - 1;
        if (i != last) t.buckets[i] = t.buckets[last];
        delete t.buckets[last];
        t.count = last;
        emit TokenRateLimitCleared(token);
    }

    /// @notice What `token`'s budget holds now, its limit and its period. All zero for a token
    ///         that isn't limited.
    function allowance(GasKillerSDK.TokenLimits storage t, address token)
        internal
        view
        returns (uint256 available, uint256 limit, uint256 period)
    {
        uint256 i = _find(t, token, t.count);
        if (i == t.count) return (0, 0, 0);
        GasKillerSDK.TokenBucket memory b = t.buckets[i];
        return (_refilled(b), b.limit, b.period);
    }

    /// @notice Whether `token` is limited.
    function isLimited(GasKillerSDK.TokenLimits storage t, address token) internal view returns (bool) {
        uint256 n = t.count;
        return _find(t, token, n) != n;
    }

    // ------------------------------------------------------------------ settlement

    /// @notice Starts a program. Call from `_beforeProgram`.
    function begin() internal {
        assembly ("memory-safe") {
            tstore(_DEPTH, add(tload(_DEPTH), 1))
        }
    }

    /// @notice Call from `_authorizeCall`, before every op that runs code. Takes the snapshot on
    ///         the program's first such op and records approvals of listed tokens.
    function beforeOp(GasKillerSDK.TokenLimits storage t, StateUpdateType kind, address target, bytes memory data)
        internal
    {
        uint256 r = _region();
        uint256 head = _tload(r);
        if (head & 1 == 0) {
            uint256 count = t.count;
            for (uint256 i = 0; i < count; ++i) {
                address token = t.buckets[i].token;
                _tstore(r + 1 + 3 * i, uint160(token));
                _tstore(r + 2 + 3 * i, IERC20(token).balanceOf(address(this)));
            }
            head = 1 | (count << 1);
            _tstore(r, head);
        }
        if (kind != StateUpdateType.CALL || data.length < 0x44) return;
        bytes4 selector = bytes4(data);
        if (selector != _APPROVE && selector != _INCREASE_ALLOWANCE) return;
        uint256 n = (head >> 1) & 0xff;
        uint256 index;
        while (index < n && _tload(r + 1 + 3 * index) != uint160(target)) ++index;
        if (index == n) return;
        address spender;
        assembly ("memory-safe") {
            spender := and(mload(add(data, 0x24)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
        uint256 slot = r + _APPROVALS + 3 * (head >> 16);
        _tstore(slot, index);
        _tstore(slot + 1, uint160(spender));
        _tstore(slot + 2, IERC20(target).allowance(address(this), spender));
        _tstore(r, head + (1 << 16));
    }

    /// @notice Ends a program: charges each listed token's net outflow, plus allowances left
    ///         standing, and reverts with `TokenRateLimitExceeded` if a budget can't cover it. Call
    ///         from `_afterProgram`.
    function endProgram(GasKillerSDK.TokenLimits storage t) internal {
        uint256 r = _region();
        uint256 head = _tload(r);
        // `head == 1`: a snapshot of no tokens, so nothing to charge.
        if (head > 1) {
            // Allowances left above where they were, charged to their token's charge word.
            uint256 end = r + _APPROVALS + 3 * (head >> 16);
            for (uint256 slot = r + _APPROVALS; slot < end; slot += 3) {
                uint256 at = r + 1 + 3 * _tload(slot);
                address spender = address(uint160(_tload(slot + 1)));
                uint256 left = IERC20(address(uint160(_tload(at)))).allowance(address(this), spender);
                uint256 prior = _tload(slot + 2);
                if (left > prior) _tstore(at + 2, _add(_tload(at + 2), left - prior));
            }
            // Net outflow plus those charges, per token.
            uint256 n = (head >> 1) & 0xff;
            for (uint256 at = r + 1; at < r + 1 + 3 * n; at += 3) {
                address token = address(uint160(_tload(at)));
                uint256 before = _tload(at + 1);
                uint256 balance = IERC20(token).balanceOf(address(this));
                uint256 charge = _tload(at + 2);
                if (balance < before) charge = _add(charge, before - balance);
                if (charge != 0) {
                    _spend(t, token, charge);
                    _tstore(at + 2, 0);
                }
            }
        }
        if (head != 0) _tstore(r, 0);
        assembly ("memory-safe") {
            tstore(_DEPTH, sub(tload(_DEPTH), 1))
        }
    }

    /// @dev Saturating add: an unlimited allowance stays the largest charge.
    function _add(uint256 a, uint256 b) private pure returns (uint256) {
        unchecked {
            uint256 c = a + b;
            return c < a ? type(uint256).max : c;
        }
    }

    // ------------------------------------------------------------------ internals

    /// @dev Spends `amount` from `token`'s budget. A token cleared mid-program is skipped.
    function _spend(GasKillerSDK.TokenLimits storage t, address token, uint256 amount) private {
        uint256 n = t.count;
        uint256 i = _find(t, token, n);
        if (i == n) return;
        GasKillerSDK.TokenBucket storage s = t.buckets[i];
        GasKillerSDK.TokenBucket memory b = s;
        uint256 left = _refilled(b);
        if (amount > left) revert TokenRateLimitExceeded(token, amount, left);
        s.available = uint128(left - amount);
        s.updated = uint32(block.timestamp);
    }

    function _find(GasKillerSDK.TokenLimits storage t, address token, uint256 n) private view returns (uint256 i) {
        for (; i < n; ++i) {
            if (t.buckets[i].token == token) return i;
        }
    }

    /// @dev As `OutgoingRateLimit._refilled`, with 128-bit amounts.
    function _refilled(GasKillerSDK.TokenBucket memory b) private view returns (uint256 available) {
        unchecked {
            uint256 elapsed = uint32(block.timestamp) - uint256(b.updated);
            uint256 limit = b.limit;
            available = uint256(b.available) + (elapsed >= b.period ? limit : elapsed * limit / b.period);
            if (available > limit) available = limit;
        }
    }

    /// @dev `_DEPTH + depth << 64`: an add and a shift rather than a hash, since it runs on every
    ///      op. Regions are 2^64 words apart, far more than one program can use.
    function _region() private view returns (uint256 r) {
        assembly ("memory-safe") {
            r := add(_DEPTH, shl(64, tload(_DEPTH)))
        }
    }

    function _tload(uint256 slot) private view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }

    function _tstore(uint256 slot, uint256 v) private {
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }
}
