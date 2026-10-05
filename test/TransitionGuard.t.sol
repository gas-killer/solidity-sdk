// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {TransitionGuard} from "../src/TransitionGuard.sol";

/// Drives the guard through the entry sequences nested settlement produces, re-entering
/// itself through external calls the way a callee frame re-enters its parent.
contract GuardHarness is TransitionGuard {
    bool public sawInTransition;
    bytes32 public sawActiveRoot;

    function exclusive(bytes32 root, bytes calldata inner) external {
        _enterExclusive(root);
        _reenter(inner);
        _exitTransition(bytes32(0));
    }

    function nested(bytes32 root, bytes calldata inner) external {
        bytes32 previous = _enterNested(root);
        _reenter(inner);
        _exitTransition(previous);
        sawActiveRoot = _activeRoot();
        sawInTransition = inTransition();
    }

    function legacy(bytes calldata inner) external guardTransition {
        _reenter(inner);
    }

    function activeRoot() external view returns (bytes32) {
        return _activeRoot();
    }

    function _reenter(bytes calldata inner) private {
        if (inner.length == 0) return;
        (bool ok, bytes memory data) = address(this).call(inner);
        if (!ok) {
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }
    }
}

contract TransitionGuardTest is Test {
    GuardHarness guard;
    bytes32 constant ROOT = keccak256("root");
    bytes32 constant OTHER = keccak256("other root");

    function setUp() public {
        guard = new GuardHarness();
    }

    function test_nestedReentryWithSameRootRestoresOuterLatch() public {
        guard.exclusive(ROOT, abi.encodeCall(GuardHarness.nested, (ROOT, "")));
        assertEq(guard.sawActiveRoot(), ROOT, "outer root survives the inner exit");
        assertTrue(guard.sawInTransition());
        assertEq(guard.activeRoot(), bytes32(0), "idle after the outer exit");
        assertFalse(guard.inTransition());
    }

    function test_nestedEntryWhileIdleReturnsToIdle() public {
        guard.nested(ROOT, "");
        assertEq(guard.sawActiveRoot(), bytes32(0));
        assertFalse(guard.sawInTransition());
    }

    function test_nestedReentryWithDifferentRootReverts() public {
        vm.expectRevert(TransitionGuard.ReentrantTransition.selector);
        guard.exclusive(ROOT, abi.encodeCall(GuardHarness.nested, (OTHER, "")));
    }

    function test_exclusiveEntryWhileActiveReverts() public {
        vm.expectRevert(TransitionGuard.ReentrantTransition.selector);
        guard.nested(ROOT, abi.encodeCall(GuardHarness.exclusive, (ROOT, "")));
    }

    function test_legacyEntryWhileNestedReverts() public {
        vm.expectRevert(TransitionGuard.ReentrantTransition.selector);
        guard.nested(ROOT, abi.encodeCall(GuardHarness.legacy, ("")));
    }

    function test_nestedEntryDuringLegacyTransitionReverts() public {
        vm.expectRevert(TransitionGuard.ReentrantTransition.selector);
        guard.legacy(abi.encodeCall(GuardHarness.nested, (ROOT, "")));
    }

    function test_deepCycleRestoresEachLevel() public {
        bytes memory innermost = abi.encodeCall(GuardHarness.nested, (ROOT, ""));
        bytes memory middle = abi.encodeCall(GuardHarness.nested, (ROOT, innermost));
        guard.exclusive(ROOT, middle);
        assertEq(guard.sawActiveRoot(), ROOT);
        assertFalse(guard.inTransition());
    }
}
