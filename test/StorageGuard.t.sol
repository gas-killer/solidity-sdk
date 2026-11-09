// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {StorageGuard} from "../src/libraries/StorageGuard.sol";
import {StateChangeHandlerLib, StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {StateTracker} from "../src/StateTracker.sol";

/// @notice Exposes the library externally. Masked ranges read this contract's storage, which
///         tests set through `poke`.
contract StorageGuardHarness is StateTracker {
    function stateTrackerSlot() external pure returns (bytes32) {
        return STATE_TRACKER_STORAGE_LOCATION;
    }

    function poke(bytes32 slot, bytes32 value) external {
        assembly {
            sstore(slot, value)
        }
    }

    function validate(StorageGuard.ProtectedRange[] memory ranges) external pure {
        StorageGuard.validateRanges(ranges);
    }

    function each(StorageGuard.ProtectedRange[] memory ranges, bytes32[] memory slots, bytes32[] memory values)
        external
        view
    {
        for (uint256 i = 0; i < slots.length; ++i) {
            StorageGuard.checkEach(ranges, i, slots[i], values[i]);
        }
    }

    function linear(StorageGuard.ProtectedRange[] memory ranges, bytes32[] memory slots, bytes32[] memory values)
        external
        view
    {
        for (uint256 i = 0; i < slots.length; ++i) {
            StorageGuard.checkEachLinear(ranges, i, slots[i], values[i]);
        }
    }

    function merge(StorageGuard.ProtectedRange[] memory ranges, bytes32[] memory slots, bytes32[] memory values)
        external
        view
    {
        StorageGuard.Cursor memory c;
        for (uint256 i = 0; i < slots.length; ++i) {
            StorageGuard.advance(c, ranges, i, slots[i], values[i]);
        }
    }

    function program(bytes memory storageUpdates, StorageGuard.ProtectedRange[] memory ranges) external view {
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        StorageGuard.checkProgram(types, args, ranges);
    }

    /// @dev The shape a pre-pass integration would take: check the whole program, then run it.
    function guardedRun(bytes memory storageUpdates, StorageGuard.ProtectedRange[] memory ranges, bool each) external {
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        if (each) StorageGuard.checkProgramEach(types, args, ranges);
        else StorageGuard.checkProgram(types, args, ranges);
        StateChangeHandlerLib._runStateUpdates(types, args);
    }

    function programEach(bytes memory storageUpdates, StorageGuard.ProtectedRange[] memory ranges) external view {
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        StorageGuard.checkProgramEach(types, args, ranges);
    }
}

contract StorageGuardTest is Test {
    StorageGuardHarness h;

    bytes32 constant FULL = StorageGuard.FULL;

    function setUp() public {
        h = new StorageGuardHarness();
    }

    // ---------------------------------------------------------------- helpers

    function _r(uint256 start, uint256 end) internal pure returns (StorageGuard.ProtectedRange memory) {
        return StorageGuard.ProtectedRange(start, end, FULL);
    }

    function _one(uint256 start, uint256 end) internal pure returns (StorageGuard.ProtectedRange[] memory rs) {
        rs = new StorageGuard.ProtectedRange[](1);
        rs[0] = _r(start, end);
    }

    function _w(uint256 slot) internal pure returns (bytes32[] memory s, bytes32[] memory v) {
        s = new bytes32[](1);
        v = new bytes32[](1);
        s[0] = bytes32(slot);
    }

    /// @dev Runs all three checkers; asserts they agree and returns (rejected, index).
    function _all(StorageGuard.ProtectedRange[] memory rs, bytes32[] memory s, bytes32[] memory v)
        internal
        view
        returns (bool rejected, uint256 index)
    {
        (bool r1, uint256 i1) = _outcome(abi.encodeCall(h.each, (rs, s, v)));
        (bool r2, uint256 i2) = _outcome(abi.encodeCall(h.linear, (rs, s, v)));
        (bool r3, uint256 i3) = _outcome(abi.encodeCall(h.merge, (rs, s, v)));
        assertEq(r1, r2, "each vs linear");
        assertEq(r1, r3, "each vs merge");
        assertEq(i1, i2, "each vs linear index");
        assertEq(i1, i3, "each vs merge index");
        return (r1, i1);
    }

    function _outcome(bytes memory call) internal view returns (bool rejected, uint256 index) {
        (bool ok, bytes memory ret) = address(h).staticcall(call);
        if (ok) return (false, 0);
        require(bytes4(ret) == StorageGuard.ProtectedSlotWrite.selector, "unexpected revert");
        (index,) = abi.decode(_tail(ret), (uint256, bytes32));
        return (true, index);
    }

    function _tail(bytes memory ret) internal pure returns (bytes memory out) {
        out = new bytes(ret.length - 4);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = ret[i + 4];
        }
    }

    // ---------------------------------------------------------------- validateRanges

    function test_validate_acceptsWellFormed() public view {
        StorageGuard.ProtectedRange[] memory rs = new StorageGuard.ProtectedRange[](3);
        rs[0] = _r(0, 0);
        rs[1] = StorageGuard.ProtectedRange(5, 5, bytes32(uint256(type(uint160).max)));
        rs[2] = _r(6, type(uint256).max);
        h.validate(rs);
        h.validate(new StorageGuard.ProtectedRange[](0));
    }

    function test_validate_rejectsMalformed() public {
        StorageGuard.ProtectedRange[] memory rs = new StorageGuard.ProtectedRange[](2);

        rs[0] = _r(5, 4); // start > end
        rs[1] = _r(10, 10);
        vm.expectRevert(StorageGuard.InvalidRanges.selector);
        h.validate(rs);

        rs[0] = _r(1, 5);
        rs[1] = _r(5, 9); // overlaps at 5
        vm.expectRevert(StorageGuard.InvalidRanges.selector);
        h.validate(rs);

        rs[0] = _r(10, 10);
        rs[1] = _r(1, 1); // descending
        vm.expectRevert(StorageGuard.InvalidRanges.selector);
        h.validate(rs);

        rs[0] = StorageGuard.ProtectedRange(1, 2, bytes32(uint256(0xff))); // partial mask over two slots
        rs[1] = _r(10, 10);
        vm.expectRevert(StorageGuard.InvalidRanges.selector);
        h.validate(rs);

        rs[0] = StorageGuard.ProtectedRange(1, 1, bytes32(0)); // protects nothing
        vm.expectRevert(StorageGuard.InvalidRanges.selector);
        h.validate(rs);
    }

    // ---------------------------------------------------------------- boundaries

    function test_boundsAreInclusive() public view {
        StorageGuard.ProtectedRange[] memory rs = _one(10, 20);
        uint256[6] memory probe = [uint256(9), 10, 11, 19, 20, 21];
        bool[6] memory hit = [false, true, true, true, true, false];
        for (uint256 i = 0; i < 6; ++i) {
            (bytes32[] memory s, bytes32[] memory v) = _w(probe[i]);
            (bool rejected,) = _all(rs, s, v);
            assertEq(rejected, hit[i]);
        }
    }

    function test_extremeSlots() public view {
        (bytes32[] memory s, bytes32[] memory v) = _w(type(uint256).max);
        (bool rejected,) = _all(_one(type(uint256).max, type(uint256).max), s, v);
        assertTrue(rejected);
        (rejected,) = _all(_one(0, type(uint256).max - 1), s, v);
        assertFalse(rejected);

        (s, v) = _w(0);
        (rejected,) = _all(_one(0, 0), s, v);
        assertTrue(rejected);
        (rejected,) = _all(_one(1, type(uint256).max), s, v);
        assertFalse(rejected);
    }

    function test_noRangesAllowsEverything() public view {
        (bytes32[] memory s, bytes32[] memory v) = _w(0);
        (bool rejected,) = _all(new StorageGuard.ProtectedRange[](0), s, v);
        assertFalse(rejected);
    }

    function test_reportsFirstOffendingIndex() public view {
        StorageGuard.ProtectedRange[] memory rs = new StorageGuard.ProtectedRange[](2);
        rs[0] = _r(100, 100);
        rs[1] = _r(200, 200);
        bytes32[] memory s = new bytes32[](4);
        s[0] = bytes32(uint256(300)); // past every range
        s[1] = bytes32(uint256(5)); // descent: cursor re-seats
        s[2] = bytes32(uint256(200)); // hit
        s[3] = bytes32(uint256(100)); // also a hit, but later
        (bool rejected, uint256 index) = _all(rs, s, new bytes32[](4));
        assertTrue(rejected);
        assertEq(index, 2);
    }

    // ---------------------------------------------------------------- masked (packed) slots

    function test_maskedSlot_allowsUnprotectedBitsOnly() public {
        // Slot 7 packs `address owner` (low 160 bits, protected) with a `uint96` counter.
        bytes32 ownerMask = bytes32(uint256(type(uint160).max));
        StorageGuard.ProtectedRange[] memory rs = new StorageGuard.ProtectedRange[](1);
        rs[0] = StorageGuard.ProtectedRange(7, 7, ownerMask);

        address owner = address(0xA11CE);
        bytes32 stored = bytes32((uint256(41) << 160) | uint160(owner));
        h.poke(bytes32(uint256(7)), stored);

        (bytes32[] memory s, bytes32[] memory v) = _w(7);

        v[0] = bytes32((uint256(42) << 160) | uint160(owner)); // counter bump, owner kept
        (bool rejected,) = _all(rs, s, v);
        assertFalse(rejected);

        v[0] = bytes32((uint256(41) << 160) | uint160(address(0xBAD))); // owner swapped
        (rejected,) = _all(rs, s, v);
        assertTrue(rejected);

        v[0] = bytes32(0); // clearing the slot clears the owner
        (rejected,) = _all(rs, s, v);
        assertTrue(rejected);
    }

    // ---------------------------------------------------------------- well-known slots

    function _erc7201(string memory id) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1))) & ~uint256(0xff);
    }

    function _eip1967(string memory id) internal pure returns (uint256) {
        return uint256(keccak256(bytes(id))) - 1;
    }

    /// @dev The slots a typical Gas Killer consumer would protect, sorted. Each is recomputed
    ///      from its derivation, so a wrong constant fails here rather than leaving a hole.
    function _realistic() internal view returns (StorageGuard.ProtectedRange[] memory rs) {
        uint256[7] memory slots = [
            0, // OpenZeppelin `Ownable._owner` as the consumer's first state variable
            _erc7201("openzeppelin.storage.Ownable"),
            _erc7201("openzeppelin.storage.Initializable"),
            _eip1967("eip1967.proxy.implementation"),
            _eip1967("eip1967.proxy.admin"),
            _eip1967("eip1967.proxy.beacon"),
            uint256(h.stateTrackerSlot())
        ];
        // GasKillerSDKStorage occupies two slots (avsAddress; registry + blockStaleMeasure).
        uint256 sdk = _erc7201("gaskiller.SchnorrGasKillerSDK.storage");

        uint256[] memory sorted = new uint256[](slots.length);
        for (uint256 i = 0; i < slots.length; ++i) {
            sorted[i] = slots[i];
        }
        _sort(sorted);

        rs = new StorageGuard.ProtectedRange[](sorted.length + 1);
        uint256 j;
        bool sdkPlaced;
        for (uint256 i = 0; i < sorted.length; ++i) {
            if (!sdkPlaced && sdk < sorted[i]) {
                rs[j++] = _r(sdk, sdk + 1);
                sdkPlaced = true;
            }
            rs[j++] = _r(sorted[i], sorted[i]);
        }
        if (!sdkPlaced) rs[j] = _r(sdk, sdk + 1);
        h.validate(rs);
    }

    function test_wellKnownSlotsMatchTheirConstants() public view {
        assertEq(
            _erc7201("openzeppelin.storage.Ownable"), 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300
        );
        assertEq(
            _erc7201("openzeppelin.storage.Initializable"),
            0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00
        );
        assertEq(
            _eip1967("eip1967.proxy.implementation"), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
        );
        assertEq(_eip1967("eip1967.proxy.admin"), 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103);
        // Must match GasKillerSDK.STORAGE_LOCATION (private there, so restated).
        assertEq(
            _erc7201("gaskiller.SchnorrGasKillerSDK.storage"),
            0x1d6f9f139320a34a32f3b29eb8638270178e831962a74100c9e8b433f21e1200
        );
        assertEq(uint256(h.stateTrackerSlot()), 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf);
    }

    function test_realistic_rejectsEveryProtectedSlot() public view {
        StorageGuard.ProtectedRange[] memory rs = _realistic();
        for (uint256 i = 0; i < rs.length; ++i) {
            for (uint256 slot = rs[i].start; slot <= rs[i].end; ++slot) {
                (bytes32[] memory s, bytes32[] memory v) = _w(slot);
                (bool rejected,) = _all(rs, s, v);
                assertTrue(rejected);
            }
        }
    }

    function test_realistic_allowsOrdinaryConsumerWrites() public view {
        StorageGuard.ProtectedRange[] memory rs = _realistic();
        // ArraySummation-shaped layout behind an Ownable at slot 0: plain slots, a dynamic
        // array's elements, mapping entries.
        bytes32[] memory s = new bytes32[](12);
        for (uint256 i = 0; i < 4; ++i) {
            s[i] = bytes32(i + 1);
            s[4 + i] = bytes32(uint256(keccak256(abi.encode(uint256(3)))) + i);
            s[8 + i] = keccak256(abi.encode(address(uint160(0x1000 + i)), uint256(4)));
        }
        (bool rejected,) = _all(rs, s, new bytes32[](12));
        assertFalse(rejected);
    }

    // ---------------------------------------------------------------- checkProgram

    function _store(uint256 slot) internal pure returns (bytes memory) {
        return abi.encode(bytes32(slot), bytes32(uint256(1)));
    }

    function test_program_ignoresNonStoreOps() public view {
        StorageGuard.ProtectedRange[] memory rs = _one(0, 0);
        StateUpdateType[] memory t = new StateUpdateType[](4);
        bytes[] memory a = new bytes[](4);
        t[0] = StateUpdateType.STORE;
        a[0] = _store(5);
        t[1] = StateUpdateType.CALL;
        a[1] = abi.encode(address(0), uint256(0), bytes("")); // first word 0 would read as slot 0 if decoded
        t[2] = StateUpdateType.LOG1;
        a[2] = abi.encode(bytes(""), bytes32(0));
        t[3] = StateUpdateType.STORE;
        a[3] = _store(1);
        h.program(abi.encode(t, a), rs);
        h.programEach(abi.encode(t, a), rs);
    }

    function test_program_rejectsProtectedStoreAcrossSlices() public {
        StorageGuard.ProtectedRange[] memory rs = _one(0, 0);
        StateUpdateType[] memory t = new StateUpdateType[](4);
        bytes[] memory a = new bytes[](4);
        // Two ascending slices separated by a CALL; the second slice starts below the first.
        t[0] = StateUpdateType.STORE;
        a[0] = _store(4);
        t[1] = StateUpdateType.STORE;
        a[1] = _store(9);
        t[2] = StateUpdateType.CALL;
        a[2] = abi.encode(address(1), uint256(0), bytes(""));
        t[3] = StateUpdateType.STORE;
        a[3] = _store(0);
        bytes memory p = abi.encode(t, a);
        vm.expectRevert(abi.encodeWithSelector(StorageGuard.ProtectedSlotWrite.selector, 3, bytes32(0)));
        h.program(p, rs);
        vm.expectRevert(abi.encodeWithSelector(StorageGuard.ProtectedSlotWrite.selector, 3, bytes32(0)));
        h.programEach(p, rs);
    }

    function test_program_rejectsMalformedInput() public {
        StorageGuard.ProtectedRange[] memory rs = _one(0, 0);
        StateUpdateType[] memory t = new StateUpdateType[](2);
        bytes[] memory a = new bytes[](1);
        vm.expectRevert(StateChangeHandlerLib.InvalidArguments.selector);
        h.program(abi.encode(t, a), rs);

        t = new StateUpdateType[](1);
        a[0] = abi.encode(bytes32(uint256(5))); // STORE payload missing its value word
        vm.expectRevert();
        h.program(abi.encode(t, a), rs);
    }

    /// @dev Slot 7 packs `owner` (low 160 bits, protected) with a `uint96` counter above it.
    function _ownerSlot(address owner, uint256 counter) internal pure returns (bytes32) {
        return bytes32((counter << 160) | uint160(owner));
    }

    /// @dev [CALL that re-enters and legitimately moves the owner to B, STORE counter|A].
    ///      Against pre-program storage the STORE leaves the owner unchanged; at run time it
    ///      moves the owner from B back to A.
    function _ownerRestoringProgram() internal view returns (bytes memory) {
        StateUpdateType[] memory t = new StateUpdateType[](2);
        bytes[] memory a = new bytes[](2);
        t[0] = StateUpdateType.CALL;
        a[0] = abi.encode(
            address(h), uint256(0), abi.encodeCall(h.poke, (bytes32(uint256(7)), _ownerSlot(address(0xB0B), 41)))
        );
        t[1] = StateUpdateType.STORE;
        a[1] = abi.encode(bytes32(uint256(7)), _ownerSlot(address(0xA11CE), 42));
        return abi.encode(t, a);
    }

    function _maskedOwnerRange() internal pure returns (StorageGuard.ProtectedRange[] memory rs) {
        rs = new StorageGuard.ProtectedRange[](1);
        rs[0] = StorageGuard.ProtectedRange(7, 7, bytes32(uint256(type(uint160).max)));
    }

    function test_program_maskedStoreAfterCallCannotRestoreOldBits() public {
        bytes memory p = _ownerRestoringProgram();
        for (uint256 each = 0; each < 2; ++each) {
            h.poke(bytes32(uint256(7)), _ownerSlot(address(0xA11CE), 41));
            vm.expectRevert(
                abi.encodeWithSelector(StorageGuard.MaskedWriteAfterExternalCode.selector, 1, bytes32(uint256(7)))
            );
            h.guardedRun(p, _maskedOwnerRange(), each == 1);
        }
    }

    /// @dev [op, STORE slot 7 keeping the owner, STORE slot 9]; slot 7 holds owner A.
    function _afterOp(StateUpdateType op) internal returns (bytes memory) {
        h.poke(bytes32(uint256(7)), _ownerSlot(address(0xA11CE), 41));
        StateUpdateType[] memory t = new StateUpdateType[](3);
        bytes[] memory a = new bytes[](3);
        t[0] = op;
        a[0] = ""; // never decoded by the pre-pass
        t[1] = StateUpdateType.STORE;
        a[1] = abi.encode(bytes32(uint256(7)), _ownerSlot(address(0xA11CE), 42));
        t[2] = StateUpdateType.STORE;
        a[2] = abi.encode(bytes32(uint256(9)), bytes32(uint256(1)));
        return abi.encode(t, a);
    }

    function test_program_everyCodeRunningOpBlindsMaskedRanges() public {
        StateUpdateType[4] memory ops =
            [StateUpdateType.CALL, StateUpdateType.CREATE, StateUpdateType.CREATE2, StateUpdateType.NESTED];
        for (uint256 i = 0; i < ops.length; ++i) {
            bytes memory p = _afterOp(ops[i]);
            bytes memory err =
                abi.encodeWithSelector(StorageGuard.MaskedWriteAfterExternalCode.selector, 1, bytes32(uint256(7)));
            vm.expectRevert(err);
            h.program(p, _maskedOwnerRange());
            vm.expectRevert(err);
            h.programEach(p, _maskedOwnerRange());
        }
    }

    function test_program_logsDoNotBlindMaskedRanges() public {
        // A LOG runs no code, so the counter bump after it is still judged on its bits and passes.
        bytes memory p = _afterOp(StateUpdateType.LOG0);
        h.program(p, _maskedOwnerRange());
        h.programEach(p, _maskedOwnerRange());
    }

    function test_program_maskedStoreBeforeAnyCallIsJudgedOnItsBits() public {
        h.poke(bytes32(uint256(7)), _ownerSlot(address(0xA11CE), 41));
        StateUpdateType[] memory t = new StateUpdateType[](3);
        bytes[] memory a = new bytes[](3);
        t[0] = StateUpdateType.STORE;
        a[0] = abi.encode(bytes32(uint256(7)), _ownerSlot(address(0xA11CE), 42)); // counter bump: fine
        t[1] = StateUpdateType.CALL;
        a[1] = abi.encode(address(1), uint256(0), bytes(""));
        t[2] = StateUpdateType.STORE;
        a[2] = abi.encode(bytes32(uint256(9)), bytes32(uint256(1))); // unprotected: fine after a CALL
        h.program(abi.encode(t, a), _maskedOwnerRange());
        h.programEach(abi.encode(t, a), _maskedOwnerRange());

        a[0] = abi.encode(bytes32(uint256(7)), _ownerSlot(address(0xBAD), 41)); // owner swap: rejected
        vm.expectRevert(abi.encodeWithSelector(StorageGuard.ProtectedSlotWrite.selector, 0, bytes32(uint256(7))));
        h.program(abi.encode(t, a), _maskedOwnerRange());
    }

    // ---------------------------------------------------------------- equivalence fuzz

    /// @dev Up to 16 ascending, gapped ranges; some single-slot ones masked, with stored values.
    function _fuzzRanges(uint256 seed) internal returns (StorageGuard.ProtectedRange[] memory rs) {
        uint256 k = seed % 17;
        rs = new StorageGuard.ProtectedRange[](k);
        uint256 cursor = uint256(keccak256(abi.encode(seed, "base"))) % 64;
        for (uint256 i = 0; i < k; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 start = cursor + (r % 8);
            bool masked = (r >> 8) % 4 == 0;
            uint256 end = masked ? start : start + ((r >> 16) % 4);
            bytes32 mask = masked ? bytes32(uint256(type(uint160).max)) : FULL;
            rs[i] = StorageGuard.ProtectedRange(start, end, mask);
            if (masked) h.poke(bytes32(start), bytes32(r >> 32));
            cursor = end + 1;
        }
    }

    /// @dev Slots clustered around the ranges (so hits and near-misses are common) plus far ones.
    function _fuzzWrites(uint256 seed, uint256 n, uint256 order)
        internal
        view
        returns (bytes32[] memory s, bytes32[] memory v)
    {
        s = new bytes32[](n);
        v = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, "w", i)));
            s[i] = bytes32(r % 8 == 0 ? r : r % 256);
            // Half the time keep the stored value, so masked slots see both verdicts.
            bytes32 stored = vm.load(address(h), s[i]);
            v[i] = (r >> 128) % 2 == 0 ? stored : bytes32(r >> 64);
        }
        if (order == 1) _sortPairs(s, v, 0, n);
        if (order == 2) {
            for (uint256 from = 0; from < n; from += 5) {
                _sortPairs(s, v, from, from + 5 > n ? n : from + 5);
            }
        }
    }

    /// @dev Naive model: the first write landing in a fully protected range, or in a masked range
    ///      whose protected bits it changes. A full mask denies even a write of the stored value.
    function _oracle(StorageGuard.ProtectedRange[] memory rs, bytes32[] memory s, bytes32[] memory v)
        internal
        view
        returns (bool, uint256)
    {
        for (uint256 i = 0; i < s.length; ++i) {
            uint256 slot = uint256(s[i]);
            for (uint256 j = 0; j < rs.length; ++j) {
                if (slot < rs[j].start || slot > rs[j].end) continue;
                if (rs[j].mask == FULL) return (true, i);
                if ((vm.load(address(h), s[i]) ^ v[i]) & rs[j].mask != 0) return (true, i);
            }
        }
        return (false, 0);
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_checkersMatchModel(uint256 seed, uint8 n, uint8 order) public {
        StorageGuard.ProtectedRange[] memory rs = _fuzzRanges(seed);
        (bytes32[] memory s, bytes32[] memory v) = _fuzzWrites(seed, uint256(n) % 40, order % 3);
        (bool wantRejected, uint256 wantIndex) = _oracle(rs, s, v);
        (bool rejected, uint256 index) = _all(rs, s, v);
        assertEq(rejected, wantRejected, "verdict");
        if (wantRejected) assertEq(index, wantIndex, "index");
    }

    // ---------------------------------------------------------------- sorting (test-side only)

    function _sort(uint256[] memory a) internal pure {
        for (uint256 i = 1; i < a.length; ++i) {
            uint256 x = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > x) {
                a[j] = a[j - 1];
                --j;
            }
            a[j] = x;
        }
    }

    function _sortPairs(bytes32[] memory s, bytes32[] memory v, uint256 from, uint256 to) internal pure {
        for (uint256 i = from + 1; i < to; ++i) {
            (bytes32 xs, bytes32 xv) = (s[i], v[i]);
            uint256 j = i;
            while (j > from && s[j - 1] > xs) {
                (s[j], v[j]) = (s[j - 1], v[j - 1]);
                --j;
            }
            (s[j], v[j]) = (xs, xv);
        }
    }
}
