// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {StateChangeHandlerLib, StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {TaskSubmission} from "../src/interface/IGasKillerSDKBatch.sol";
import {AcceptingRegistry} from "./GasKillerSDKProtectedStorage.t.sol";

/// External state a program observes: a swap whose output can move, and a read that can revert.
contract Pool {
    uint256 public out = 100;
    bool public broken;

    function setOut(uint256 o) external {
        out = o;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function swap() external returns (uint256) {
        require(!broken, "paused");
        return out;
    }

    function quote() external view returns (uint256) {
        require(!broken, "paused");
        return out;
    }
}

contract Deployed {}

contract Consumer is GasKillerSDK {
    constructor(address registry) {
        _setSchnorrRegistry(registry);
    }

    receive() external payable {}

    /// Moves the contract's nonce outside any program, as a native function can.
    function deployNatively() external {
        new Deployed();
    }
}

/// A consumer whose policy rejects every op that runs code: the read checks don't go through it.
contract LockedConsumer is Consumer {
    constructor(address registry) Consumer(registry) {}

    function _authorizeCall(uint256, StateUpdateType, address, uint256, bytes memory) internal pure override {
        revert("no calls");
    }
}

/// @notice Observation pinning (#101): a program's view of external state is checked at settlement.
contract ObservationPinningTest is Test {
    receive() external payable {}

    bytes32 constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    bytes4 constant FN = bytes4(keccak256("work()"));

    AcceptingRegistry registry;
    Consumer c;
    Pool pool;

    function setUp() public {
        vm.roll(1000);
        registry = new AcceptingRegistry();
        c = new Consumer(address(registry));
        pool = new Pool();
    }

    // ---------------------------------------------------------------- helpers

    struct Program {
        StateUpdateType[] types;
        bytes[] args;
        uint256 n;
    }

    function _tracked(uint256 capacity) internal view returns (Program memory p) {
        p.types = new StateUpdateType[](capacity + 1);
        p.args = new bytes[](capacity + 1);
        p.args[0] = abi.encode(TRACKER_SLOT, bytes32(c.stateTransitionCount() + 1));
        p.n = 1;
    }

    function _op(Program memory p, StateUpdateType kind, bytes memory arg) internal pure {
        p.types[p.n] = kind;
        p.args[p.n++] = arg;
    }

    function _hash(bool success, bytes memory returndata) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(success, returndata));
    }

    function _swap(Program memory p, bytes32 expected) internal view {
        _op(p, StateUpdateType.CALL, abi.encode(address(pool), uint256(0), abi.encodeCall(Pool.swap, ()), expected));
    }

    function _store(Program memory p, uint256 slot, uint256 value) internal pure {
        _op(p, StateUpdateType.STORE, abi.encode(bytes32(slot), bytes32(value)));
    }

    function _settle(Program memory p, bytes memory revertData) internal {
        StateUpdateType[] memory t = new StateUpdateType[](p.n);
        bytes[] memory a = new bytes[](p.n);
        for (uint256 i = 0; i < p.n; ++i) {
            (t[i], a[i]) = (p.types[i], p.args[i]);
        }
        bytes memory updates = abi.encode(t, a);
        uint256 ti = c.stateTransitionCount();
        bytes32 h = c.getMessageHash(ti, FN, updates);
        if (revertData.length != 0) vm.expectRevert(revertData);
        c.verifyAndUpdate(h, uint32(block.number - 1), updates, ti, FN, 1, address(1), new address[](0));
    }

    function _mismatch(uint256 index, bytes32 expected, bytes32 actual) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(StateChangeHandlerLib.ObservationMismatch.selector, index, expected, actual);
    }

    function _stored(uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(address(c), bytes32(slot)));
    }

    // ---------------------------------------------------------------- CALL

    /// The trace saw the swap return 100 and credited 100: settles while the pool still pays 100.
    function test_pinnedCallSettlesWhenUnchanged() public {
        Program memory p = _tracked(2);
        _swap(p, _hash(true, abi.encode(uint256(100))));
        _store(p, 5, 100);
        _settle(p, "");
        assertEq(_stored(5), 100);
    }

    /// The pool moved before settlement: the credit of 100 no longer matches, so it reverts.
    function test_pinnedCallRevertsWhenTheResultMoved() public {
        pool.setOut(95);
        Program memory p = _tracked(2);
        _swap(p, _hash(true, abi.encode(uint256(100))));
        _store(p, 5, 100);
        _settle(p, _mismatch(1, _hash(true, abi.encode(uint256(100))), _hash(true, abi.encode(uint256(95)))));
    }

    /// A zero hash leaves the result unchecked.
    function test_unpinnedCallIsNotChecked() public {
        pool.setOut(95);
        Program memory p = _tracked(1);
        _swap(p, bytes32(0));
        _settle(p, "");
    }

    /// A pinned success that now reverts is reported with its revert data.
    function test_pinnedSuccessThatNowRevertsReportsTheRevert() public {
        pool.setBroken(true);
        Program memory p = _tracked(1);
        _swap(p, _hash(true, abi.encode(uint256(100))));
        _settle(
            p,
            abi.encodeWithSelector(
                StateChangeHandlerLib.RevertingContext.selector,
                1,
                address(pool),
                abi.encodeWithSignature("Error(string)", "paused"),
                abi.encodeCall(Pool.swap, ())
            )
        );
    }

    /// A revert the trace caught is pinned as a failure, and the program goes on.
    function test_pinnedCaughtRevertLetsTheProgramContinue() public {
        pool.setBroken(true);
        Program memory p = _tracked(2);
        _swap(p, _hash(false, abi.encodeWithSignature("Error(string)", "paused")));
        _store(p, 5, 1);
        _settle(p, "");
        assertEq(_stored(5), 1);
    }

    /// A call the trace saw revert that now succeeds doesn't match.
    function test_pinnedCaughtRevertThatNowSucceedsReverts() public {
        bytes32 failed = _hash(false, abi.encodeWithSignature("Error(string)", "paused"));
        Program memory p = _tracked(1);
        _swap(p, failed);
        _settle(p, _mismatch(1, failed, _hash(true, abi.encode(uint256(100)))));
    }

    /// A call that sends value must succeed even when pinned as a failure: an empty-data failure
    /// could be a value shortfall the trace never saw.
    function test_pinnedFailureMustSucceedWhenItSendsValue() public {
        bytes32 failed = _hash(false, "");
        Program memory p = _tracked(1);
        _op(p, StateUpdateType.CALL, abi.encode(address(pool), uint256(1 ether), "", failed));
        _settle(p, abi.encodeWithSelector(StateChangeHandlerLib.RevertingContext.selector, 1, address(pool), "", ""));
    }

    /// The layouts from before pinning are rejected, not misread.
    function test_oldLayoutsAreRejected() public {
        Program memory p = _tracked(1);
        _op(p, StateUpdateType.CALL, abi.encode(address(pool), uint256(0), abi.encodeCall(Pool.swap, ())));
        _settle(p, abi.encodeWithSelector(StateChangeHandlerLib.MalformedOp.selector, 1));

        p = _tracked(1);
        _op(p, StateUpdateType.CREATE, abi.encode(uint256(0), type(Deployed).creationCode));
        _settle(p, abi.encodeWithSelector(StateChangeHandlerLib.MalformedOp.selector, 1));
    }

    // ---------------------------------------------------------------- reads

    function _quote(Program memory p, bytes32 expected) internal view {
        _op(p, StateUpdateType.STATICCALL_CHECK, abi.encode(address(pool), abi.encodeCall(Pool.quote, ()), expected));
    }

    function test_staticcallCheck() public {
        Program memory p = _tracked(1);
        _quote(p, _hash(true, abi.encode(uint256(100))));
        _settle(p, "");

        pool.setOut(95);
        p = _tracked(1);
        _quote(p, _hash(true, abi.encode(uint256(100))));
        _settle(p, _mismatch(1, _hash(true, abi.encode(uint256(100))), _hash(true, abi.encode(uint256(95)))));
    }

    /// A read the trace saw revert is pinned as a failure too.
    function test_staticcallCheckPinsARevert() public {
        pool.setBroken(true);
        Program memory p = _tracked(1);
        _quote(p, _hash(false, abi.encodeWithSignature("Error(string)", "paused")));
        _settle(p, "");
    }

    /// The read checks change nothing, so a policy that rejects every call doesn't see them.
    function test_readChecksBypassTheCallPolicy() public {
        c = new LockedConsumer(address(registry));
        Program memory p = _tracked(3);
        _quote(p, _hash(true, abi.encode(uint256(100))));
        _op(p, StateUpdateType.BALANCE_CHECK, abi.encode(address(c), uint256(0)));
        _op(p, StateUpdateType.CODEHASH_CHECK, abi.encode(address(pool), address(pool).codehash));
        _settle(p, "");
    }

    /// Covers `SELFBALANCE` and any other account's balance.
    function test_balanceCheck() public {
        vm.deal(address(c), 1 ether);
        Program memory p = _tracked(2);
        _op(p, StateUpdateType.BALANCE_CHECK, abi.encode(address(c), 1 ether));
        _op(p, StateUpdateType.BALANCE_CHECK, abi.encode(address(pool), uint256(0)));
        _settle(p, "");

        vm.deal(address(pool), 1);
        p = _tracked(1);
        _op(p, StateUpdateType.BALANCE_CHECK, abi.encode(address(pool), uint256(0)));
        _settle(p, _mismatch(1, bytes32(0), bytes32(uint256(1))));
    }

    /// In a batch, each item's own balance check sees only the value its trace saw: the value
    /// later items and the surplus bring isn't counted.
    function test_selfBalanceCheckInABatch() public {
        TaskSubmission[] memory subs = new TaskSubmission[](2);
        for (uint256 i = 0; i < 2; ++i) {
            StateUpdateType[] memory t = new StateUpdateType[](2);
            bytes[] memory a = new bytes[](2);
            a[0] = abi.encode(TRACKER_SLOT, bytes32(i + 1));
            t[1] = StateUpdateType.BALANCE_CHECK;
            a[1] = abi.encode(address(c), (i + 1) * 1 ether);
            bytes memory updates = abi.encode(t, a);
            subs[i] = TaskSubmission(
                c.getMessageHashWithValue(i, FN, updates, 1 ether),
                uint32(block.number - 1),
                updates,
                i,
                FN,
                1,
                address(1),
                new address[](0),
                1 ether
            );
        }
        c.verifyAndUpdateBatch{value: 3 ether}(subs); // 1 ether of surplus, refunded
        assertEq(address(c).balance, 2 ether);
    }

    /// Covers `EXTCODEHASH` and `EXTCODESIZE`: code appearing at an empty address is caught.
    function test_codehashCheck() public {
        address empty = address(0xE0);
        Program memory p = _tracked(1);
        _op(p, StateUpdateType.CODEHASH_CHECK, abi.encode(empty, bytes32(0)));
        _settle(p, "");

        vm.etch(empty, hex"00");
        p = _tracked(1);
        _op(p, StateUpdateType.CODEHASH_CHECK, abi.encode(empty, bytes32(0)));
        _settle(p, _mismatch(1, bytes32(0), keccak256(hex"00")));
    }

    // ---------------------------------------------------------------- CREATE

    function _create(Program memory p, address expected) internal pure {
        _op(p, StateUpdateType.CREATE, abi.encode(uint256(0), type(Deployed).creationCode, expected));
    }

    function test_createPinsTheDeployedAddress() public {
        address next = vm.computeCreateAddress(address(c), vm.getNonce(address(c)));
        Program memory p = _tracked(1);
        _create(p, next);
        _settle(p, "");
        assertGt(next.code.length, 0);
    }

    /// The contract's own function moved its nonce, so the deployment lands elsewhere.
    function test_createRevertsWhenTheNonceMoved() public {
        address next = vm.computeCreateAddress(address(c), vm.getNonce(address(c)));
        c.deployNatively();
        address actual = vm.computeCreateAddress(address(c), vm.getNonce(address(c)));
        Program memory p = _tracked(1);
        _create(p, next);
        _settle(p, _mismatch(1, bytes32(uint256(uint160(next))), bytes32(uint256(uint160(actual)))));
    }

    function test_unpinnedCreateIsNotChecked() public {
        c.deployNatively();
        Program memory p = _tracked(1);
        _create(p, address(0));
        _settle(p, "");
    }
}
