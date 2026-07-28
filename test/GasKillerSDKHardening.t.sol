// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";

import {GasKillerSDKExposed} from "./exposed/GasKillerSDKExposed.sol";
import {TransitionGuard} from "../src/TransitionGuard.sol";
import {StateChangeHandlerLib, StateUpdateType} from "../src/StateChangeHandlerLib.sol";

/// BLS checker stub that approves every submission with full stake — the guard/latch and
/// value-forwarding control flow under test is independent of real BLS verification.
contract MockBLSSignatureChecker {
    function checkSignatures(
        bytes32,
        bytes calldata quorumNumbers,
        uint32,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature calldata
    ) external pure returns (IBLSSignatureCheckerTypes.QuorumStakeTotals memory totals, bytes32) {
        uint256 quorumCount = quorumNumbers.length;
        totals.signedStakeForQuorum = new uint96[](quorumCount);
        totals.totalStakeForQuorum = new uint96[](quorumCount);
        for (uint256 i = 0; i < quorumCount; ++i) {
            totals.signedStakeForQuorum[i] = 100;
            totals.totalStakeForQuorum[i] = 100;
        }
        return (totals, bytes32(0));
    }
}

/// Re-entry attacker: invoked mid-transition via a CALL state update, it attempts to
/// submit the *next* transition (which the mock checker would approve) while transition N
/// is still applying. Without the guard this interleaves two signed transitions; with it,
/// the re-entrant call must revert `ReentrantTransition`.
contract ReentrantAttacker {
    GasKillerSDKExposed public sdk;
    bool public sawInTransition;
    bytes4 public caughtSelector;
    bool public reentrySucceeded;

    // Pre-staged arguments for the re-entrant verifyAndUpdate (transition N+1).
    bytes32 public msgHash;
    bytes public quorumNumbers;
    uint32 public refBlock;
    bytes public storageUpdates;
    uint256 public transitionIndex;
    bytes4 public targetFunction;

    constructor(GasKillerSDKExposed _sdk) {
        sdk = _sdk;
    }

    function stage(
        bytes32 _msgHash,
        bytes calldata _quorumNumbers,
        uint32 _refBlock,
        bytes calldata _storageUpdates,
        uint256 _transitionIndex,
        bytes4 _targetFunction
    ) external {
        msgHash = _msgHash;
        quorumNumbers = _quorumNumbers;
        refBlock = _refBlock;
        storageUpdates = _storageUpdates;
        transitionIndex = _transitionIndex;
        targetFunction = _targetFunction;
    }

    /// The CALL-update target. Records the latch state, then tries to re-enter.
    function attack() external {
        sawInTransition = sdk.inTransition();
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nsss;
        try sdk.verifyAndUpdate(
            msgHash, quorumNumbers, refBlock, storageUpdates, transitionIndex, targetFunction, nsss
        ) {
            reentrySucceeded = true;
        } catch (bytes memory reason) {
            caughtSelector = bytes4(reason);
        }
    }
}

/// Passive mid-transition reader: records what the latch reports when it is called via a
/// CALL state update.
contract LatchReader {
    GasKillerSDKExposed public sdk;
    bool public sawInTransition;
    uint256 public sawTransitionCount;

    constructor(GasKillerSDKExposed _sdk) {
        sdk = _sdk;
    }

    function observe() external {
        sawInTransition = sdk.inTransition();
        sawTransitionCount = sdk.stateTransitionCount();
    }
}

/// Payable CALL-update target for the value-forwarding tests.
contract ValueSink {
    uint256 public value;

    function setValue(uint256 _value) external payable {
        value = _value;
    }
}

contract GasKillerSDKHardeningTest is Test {
    GasKillerSDKExposed sdk;

    bytes constant QUORUMS = hex"00";

    function setUp() public {
        vm.roll(1000);
        sdk = new GasKillerSDKExposed(makeAddr("AVS"), address(new MockBLSSignatureChecker()));
    }

    // ---- helpers -----------------------------------------------------------------

    function _digest(uint256 transitionIndex, bytes4 targetFn, bytes memory updates) internal view returns (bytes32) {
        return sha256(abi.encode(transitionIndex, address(sdk), targetFn, updates));
    }

    function _storeUpdate(bytes32 slot, bytes32 val) internal pure returns (bytes memory) {
        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.STORE;
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(slot, val);
        return abi.encode(types, args);
    }

    function _callUpdate(address target, uint256 val, bytes memory callData) internal pure returns (bytes memory) {
        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.CALL;
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(target, val, callData);
        return abi.encode(types, args);
    }

    /// Submit `updates` as the next transition through the real entrypoint. Operators sign
    /// for the counter value *before* the `trackState` bump, i.e. the current count.
    function _submit(bytes memory updates, uint256 value) internal {
        uint256 transitionIndex = sdk.stateTransitionCount();
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nsss;
        sdk.verifyAndUpdate{value: value}(
            _digest(transitionIndex, bytes4(0), updates),
            QUORUMS,
            uint32(block.number - 1),
            updates,
            transitionIndex,
            bytes4(0),
            nsss
        );
    }

    // ---- value forwarding through the real entrypoint ----------------------------

    function test_verifyAndUpdate_ForwardsMsgValue() public {
        ValueSink target = new ValueSink();
        uint256 forwarded = 0.13 ether;
        // Fund the caller only: the SDK starts at zero balance, so the signed CALL update
        // can only be paid out of msg.value.
        vm.deal(address(this), forwarded);

        _submit(_callUpdate(address(target), forwarded, abi.encodeCall(ValueSink.setValue, (7))), forwarded);

        assertEq(address(target).balance, forwarded);
        assertEq(target.value(), 7);
        assertEq(address(sdk).balance, 0);
        assertEq(sdk.stateTransitionCount(), 1);
    }

    function test_verifyAndUpdate_UnderFundedCallReverts() public {
        ValueSink target = new ValueSink();
        vm.deal(address(this), 0.1 ether);
        bytes memory callData = abi.encodeCall(ValueSink.setValue, (7));
        bytes memory updates = _callUpdate(address(target), 0.2 ether, callData);

        uint256 transitionIndex = sdk.stateTransitionCount();
        // Precomputed: sha256 inside _digest is a precompile staticcall, which would
        // otherwise be the "next call" expectRevert arms against.
        bytes32 digest = _digest(transitionIndex, bytes4(0), updates);
        uint32 refBlock = uint32(block.number - 1);
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nsss;
        vm.expectRevert(
            abi.encodeWithSelector(
                StateChangeHandlerLib.RevertingContext.selector, 0, address(target), bytes(""), callData
            )
        );
        sdk.verifyAndUpdate{value: 0.1 ether}(digest, QUORUMS, refBlock, updates, transitionIndex, bytes4(0), nsss);

        // The whole transition rolled back, counter included.
        assertEq(sdk.stateTransitionCount(), 0);
    }

    // ---- reentrancy guard --------------------------------------------------------

    function test_verifyAndUpdate_ReentrantCallReverts() public {
        ReentrantAttacker attacker = new ReentrantAttacker(sdk);

        // Stage a fully valid *next* transition (index 1): mid-transition the counter
        // already reads 1, so this is exactly what an in-flight quorum signature for the
        // following transition would carry — the guard must be the only failure cause.
        bytes memory innerUpdates = _storeUpdate(bytes32(uint256(0xbeef)), bytes32(uint256(1)));
        attacker.stage(
            _digest(1, bytes4(0), innerUpdates), QUORUMS, uint32(block.number - 1), innerUpdates, 1, bytes4(0)
        );

        _submit(_callUpdate(address(attacker), 0, abi.encodeCall(ReentrantAttacker.attack, ())), 0);

        assertTrue(attacker.sawInTransition());
        assertFalse(attacker.reentrySucceeded());
        assertEq(attacker.caughtSelector(), TransitionGuard.ReentrantTransition.selector);

        // Only the outer transition applied; the staged inner update never landed.
        assertEq(sdk.stateTransitionCount(), 1);
        assertEq(vm.load(address(sdk), bytes32(uint256(0xbeef))), bytes32(0));
    }

    // ---- latch visibility --------------------------------------------------------

    function test_verifyAndUpdate_LatchVisibleMidTransition() public {
        LatchReader reader = new LatchReader(sdk);
        assertFalse(sdk.inTransition());

        _submit(_callUpdate(address(reader), 0, abi.encodeCall(LatchReader.observe, ())), 0);

        assertTrue(reader.sawInTransition());
        // Mid-transition the counter already reads N+1 while only part of transition N has
        // executed — the reason readers must treat in-transition state as unsettled.
        assertEq(reader.sawTransitionCount(), 1);
        assertFalse(sdk.inTransition());
    }

    function test_verifyAndUpdate_LatchReleasedBetweenTransitions() public {
        _submit(_storeUpdate(bytes32(uint256(0xa)), bytes32(uint256(1))), 0);
        // Same tx context, so this passes only if guardTransition explicitly cleared the
        // latch (transient storage has not reset between these calls).
        _submit(_storeUpdate(bytes32(uint256(0xb)), bytes32(uint256(2))), 0);

        assertEq(sdk.stateTransitionCount(), 2);
    }
}
