// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {GasKillerNestedSDK} from "../src/GasKillerNestedSDK.sol";
import {SchnorrStakeRegistry} from "../src/SchnorrStakeRegistry.sol";
import {StateChangeHandlerLib, StateUpdateType, CallPolicy} from "../src/StateChangeHandlerLib.sol";
import {StorageGuard} from "../src/libraries/StorageGuard.sol";
import {TreeSubmission} from "../src/interface/IGasKillerNested.sol";
import {QuorumSignature} from "../src/interface/ISchnorrApprovalRegistry.sol";
import {SchnorrSigner} from "./utils/SchnorrSigner.sol";
import {NestedTreeBuilder} from "./utils/NestedTreeBuilder.sol";

/// A nested consumer with a self-gated setter. It allows `setBeneficiary` for one
/// `targetFunction`, set at deployment, and records the `targetFunction` each self-call was
/// checked under.
contract NestedSelfCaller is GasKillerNestedSDK {
    address public beneficiary; // slot 0
    bytes4 public immutable allowedFor;

    constructor(address registry, bytes4 allowedFor_) {
        _setSchnorrRegistry(registry);
        _setAvsAddress(address(0xA75));
        allowedFor = allowedFor_;
    }

    function setBeneficiary(address b) external {
        require(msg.sender == address(this), "only self");
        beneficiary = b;
    }

    function _allowSelfCall(bytes4 targetFunction, bytes4 selector) internal view override returns (bool) {
        return targetFunction == allowedFor && selector == this.setBeneficiary.selector;
    }
}

/// Runs programs through the library directly, with a policy built by hand.
contract LibraryRunner {
    address public beneficiary; // slot 0

    function setBeneficiary(address b) external {
        require(msg.sender == address(this), "only self");
        beneficiary = b;
    }

    function run(StateUpdateType[] memory types, bytes[] memory args, bool rejectSelfCalls) external {
        StorageGuard.ProtectedRange[] memory ranges = new StorageGuard.ProtectedRange[](1);
        ranges[0] = StorageGuard.ProtectedRange(100, 100, StorageGuard.FULL);
        CallPolicy memory policy = StateChangeHandlerLib._unrestrictedCalls();
        if (rejectSelfCalls) policy.allowSelfCall = StateChangeHandlerLib._rejectSelfCalls;
        StateChangeHandlerLib._runStateUpdates(types, args, ranges, policy);
    }
}

/// @notice Self-calls inside nested settlement. A callee's frame checks its self-calls with
///         `targetFunction` zero, and a root frame can open such a frame on its own contract
///         with a `NESTED` op to itself, which is why scoping `_allowSelfCall` by
///         `targetFunction` is not a security boundary.
contract GasKillerSDKSelfCallNestedTest is Test {
    using NestedTreeBuilder for NestedTreeBuilder.Frame[];

    uint256 constant OPERATOR_KEY = 0xA11CE5;
    bytes4 constant ROOT_FN = bytes4(keccak256("work()"));
    address constant NEW_BENEFICIARY = address(0xBEEF);

    SchnorrStakeRegistry registry;
    uint256 expiryBlock;

    function setUp() public {
        vm.roll(1000);
        registry = new SchnorrStakeRegistry(2, 3, address(this), 0);
        (uint256 px, uint256 py) = SchnorrSigner.publicKey(OPERATOR_KEY);
        (uint256 popS, address popR) =
            SchnorrSigner.sign(OPERATOR_KEY, 991, registry.popMessage(registry.pointAddress(px, py)));
        registry.registerOperator(px, py, 1, popS, popR);
        vm.roll(block.number + 10);
        expiryBlock = block.number + 50;
    }

    /// The root frame checks its self-call under the signed selector.
    function test_rootFrameSelfCallUsesSignedSelector() public {
        NestedSelfCaller t = new NestedSelfCaller(address(registry), ROOT_FN);
        NestedTreeBuilder.Frame[] memory frames = new NestedTreeBuilder.Frame[](1);
        frames[0] = _frame(address(t), address(0), 0, ROOT_FN, 1);
        _op(frames[0], 0, StateUpdateType.CALL, _setBeneficiaryCall(t));

        t.verifyAndUpdateTree(_submission(frames));
        assertEq(t.beneficiary(), NEW_BENEFICIARY);
    }

    /// A NESTED op to the contract itself opens a callee frame there, whose self-calls are
    /// checked with `targetFunction` zero. Allowed only for `ROOT_FN`, the self-call is rejected.
    function test_nestedSelfFrameSelfCallIsCheckedUnderZero() public {
        NestedSelfCaller t = new NestedSelfCaller(address(registry), ROOT_FN);
        TreeSubmission memory sub = _submission(_nestedSelfFrames(t));

        bytes memory reason = abi.encodeWithSelector(
            StateChangeHandlerLib.SelfCall.selector, 0, NestedSelfCaller.setBeneficiary.selector
        );
        try t.verifyAndUpdateTree(sub) {
            fail("tree settled");
        } catch (bytes memory err) {
            assertTrue(_contains(err, reason), "callee frame's self-call rejected under zero");
        }
        assertEq(t.beneficiary(), address(0));
    }

    /// A selector allowed only for `bytes4(0)`, meant for nested callee frames, is reachable by
    /// any root program for this contract through a NESTED op to itself.
    function test_selectorAllowedForZeroIsReachableFromARootFrame() public {
        NestedSelfCaller t = new NestedSelfCaller(address(registry), bytes4(0));
        t.verifyAndUpdateTree(_submission(_nestedSelfFrames(t)));
        assertEq(t.beneficiary(), NEW_BENEFICIARY);
        assertEq(t.stateTransitionCount(), 2, "root frame and the self-opened frame");
    }

    /// `_rejectSelfCalls` rejects a self-call in a policy built by hand; `_unrestrictedCalls`
    /// alone allows it.
    function test_libraryRejectSelfCallsHelper() public {
        LibraryRunner r = new LibraryRunner();
        StateUpdateType[] memory types = new StateUpdateType[](1);
        bytes[] memory args = new bytes[](1);
        types[0] = StateUpdateType.CALL;
        args[0] = abi.encode(address(r), uint256(0), abi.encodeCall(LibraryRunner.setBeneficiary, (NEW_BENEFICIARY)));

        vm.expectRevert(
            abi.encodeWithSelector(StateChangeHandlerLib.SelfCall.selector, 0, LibraryRunner.setBeneficiary.selector)
        );
        r.run(types, args, true);

        r.run(types, args, false);
        assertEq(r.beneficiary(), NEW_BENEFICIARY);
    }

    /// Frame 0: a `ROOT_FN` program whose only op is a NESTED op to its own contract. Frame 1:
    /// that contract's callee frame, calling `setBeneficiary` on itself.
    function _nestedSelfFrames(NestedSelfCaller t) private pure returns (NestedTreeBuilder.Frame[] memory frames) {
        frames = new NestedTreeBuilder.Frame[](2);
        frames[0] = _frame(address(t), address(0), 0, ROOT_FN, 1);
        _op(frames[0], 0, StateUpdateType.NESTED, abi.encode(address(t), uint256(0), uint256(1)));
        frames[1] = _frame(address(t), address(t), 1, bytes4(0), 1);
        _op(frames[1], 0, StateUpdateType.CALL, _setBeneficiaryCall(t));
    }

    function _setBeneficiaryCall(NestedSelfCaller t) private pure returns (bytes memory) {
        return abi.encode(address(t), uint256(0), abi.encodeCall(NestedSelfCaller.setBeneficiary, (NEW_BENEFICIARY)));
    }

    function _submission(NestedTreeBuilder.Frame[] memory frames) private returns (TreeSubmission memory) {
        NestedTreeBuilder.Tree memory tree = frames.build(expiryBlock);
        (uint256 s, address r) = SchnorrSigner.sign(OPERATOR_KEY, uint256(keccak256(abi.encode(tree.root))), tree.root);
        return TreeSubmission(
            tree.root,
            expiryBlock,
            tree.expiryProof,
            QuorumSignature(s, r, new address[](0), block.number - 1),
            0,
            ROOT_FN,
            tree.programs[0],
            tree.rootProof,
            tree.rootChildren
        );
    }

    function _frame(address target, address caller, uint256 index, bytes4 selector, uint256 ops)
        private
        pure
        returns (NestedTreeBuilder.Frame memory f)
    {
        f.target = target;
        f.caller = caller;
        f.index = index;
        f.targetFunction = selector;
        f.calldataHash = keccak256("self");
        f.types = new StateUpdateType[](ops);
        f.args = new bytes[](ops);
    }

    function _op(NestedTreeBuilder.Frame memory f, uint256 i, StateUpdateType kind, bytes memory arg) private pure {
        f.types[i] = kind;
        f.args[i] = arg;
    }

    function _contains(bytes memory haystack, bytes memory needle) private pure returns (bool) {
        if (needle.length > haystack.length) return false;
        for (uint256 i = 0; i <= haystack.length - needle.length; ++i) {
            bool match_ = true;
            for (uint256 j = 0; j < needle.length && match_; ++j) {
                match_ = haystack[i + j] == needle[j];
            }
            if (match_) return true;
        }
        return false;
    }
}
