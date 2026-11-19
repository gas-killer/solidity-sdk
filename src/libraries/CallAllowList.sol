// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {StateUpdateType} from "../StateChangeHandlerLib.sol";
import {IGasKillerNested} from "../interface/IGasKillerNested.sol";

/// @title CallAllowList
/// @notice A default-deny check for the ops of a signed program: a `CALL` runs only if its
///         `(target, selector)` pair is allowed, a `NESTED` op only if `(target,
///         IGasKillerNested.applyNested.selector)` is, and `CREATE`/`CREATE2` only if the
///         consumer allows deployments.
/// @dev Call `check` from `_authorizeCall`; `GasKillerCallAllowList` does. The list itself is the
///      consumer's code (`isAllowed`), not storage: no setter to secure and no slot to protect,
///      and changing it takes a new deployment or an upgrade.
///
///      What the list bounds: which contracts this one can reach with its own authority, and
///      which functions. What it doesn't: a call's arguments (an allowed `transfer` still sends
///      wherever the quorum says), what an allowed function does next, and value paid out
///      through this contract's own functions after a program wrote its state. Pair it with the
///      rate limits for amounts.
library CallAllowList {
    /// @notice Op `index` calls `selector` on `target`, which the list doesn't allow. `selector`
    ///         is zero for a plain ETH transfer (empty calldata), and the zero-padded first bytes
    ///         of malformed calldata, which is never allowed.
    error CallNotAllowed(uint256 index, address target, bytes4 selector);

    /// @notice Op `index` is a `CREATE` or `CREATE2`, and the consumer doesn't allow deployments.
    error DeploymentNotAllowed(uint256 index);

    /// @notice Reverts unless the op is allowed.
    /// @dev A `CALL` to the running contract itself is skipped: the SDK's self-call check
    ///      (`_allowSelfCall`) has already allowed it. Calldata of 1 to 3 bytes, or of 4 or more
    ///      starting with `0x00000000`, is rejected without asking `isAllowed`, since it would land
    ///      in a fallback that allowing the ETH-transfer case (selector zero) or a selector its
    ///      zero-padding matches doesn't mean to open.
    /// @param isAllowed The consumer's list: whether `selector` may be called on `target`.
    /// @param allowDeployments Whether `CREATE` and `CREATE2` ops may run.
    function check(
        uint256 index,
        StateUpdateType kind,
        address target,
        bytes memory data,
        function(address, bytes4) view returns (bool) isAllowed,
        bool allowDeployments
    ) internal view {
        if (kind == StateUpdateType.CALL) {
            if (target == address(this)) return;
            uint256 length = data.length;
            bytes4 selector;
            if (length >= 4) {
                // One `mload` rather than `bytes4(data)`, which costs about 240 gas more per op.
                assembly ("memory-safe") {
                    selector := and(mload(add(data, 0x20)), shl(224, 0xffffffff))
                }
                if (selector == bytes4(0)) revert CallNotAllowed(index, target, selector);
            } else if (length != 0) {
                revert CallNotAllowed(index, target, bytes4(data)); // zero-padded
            }
            if (!isAllowed(target, selector)) revert CallNotAllowed(index, target, selector);
        } else if (kind == StateUpdateType.NESTED) {
            bytes4 selector = IGasKillerNested.applyNested.selector;
            if (!isAllowed(target, selector)) revert CallNotAllowed(index, target, selector);
        } else if (!allowDeployments) {
            revert DeploymentNotAllowed(index);
        }
    }
}
