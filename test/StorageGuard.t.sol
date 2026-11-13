// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {StorageGuard} from "../src/libraries/StorageGuard.sol";
import {StateChangeHandlerLib, StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {StateTracker} from "../src/StateTracker.sol";
import {ERC1967Upgrade} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Upgrade.sol";
import {StorageGuardVariants} from "./utils/StorageGuardVariants.sol";
import {Sort} from "./utils/Sort.sol";

/// @notice Reads the EIP-1967 slots straight from the vendored OpenZeppelin source, so the test
///         compares against the constants proxies actually use rather than a retyped copy.
contract ERC1967Slots is ERC1967Upgrade {
    function slots() external pure returns (bytes32 implementation, bytes32 admin, bytes32 beacon) {
        return (_IMPLEMENTATION_SLOT, _ADMIN_SLOT, _BEACON_SLOT);
    }
}

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
            StorageGuardVariants.checkEach(ranges, i, slots[i], values[i]);
        }
    }

    function linear(StorageGuard.ProtectedRange[] memory ranges, bytes32[] memory slots, bytes32[] memory values)
        external
        view
    {
        for (uint256 i = 0; i < slots.length; ++i) {
            StorageGuardVariants.checkEachLinear(ranges, i, slots[i], values[i]);
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

    /// @dev `merge` from an arbitrary starting position, as a cursor carried over from another
    ///      list or never reset would arrive.
    function mergeFrom(
        StorageGuard.ProtectedRange[] memory ranges,
        bytes32[] memory slots,
        bytes32[] memory values,
        uint256 startNext
    ) external view {
        StorageGuard.Cursor memory c;
        c.next = startNext;
        for (uint256 i = 0; i < slots.length; ++i) {
            StorageGuard.advance(c, ranges, i, slots[i], values[i]);
        }
    }

    /// @dev One cursor walked through `first`, then reused unchanged on `second`.
    function mergeReused(
        StorageGuard.ProtectedRange[] memory first,
        bytes32 firstSlot,
        StorageGuard.ProtectedRange[] memory second,
        bytes32 secondSlot
    ) external view {
        StorageGuard.Cursor memory c;
        StorageGuard.advance(c, first, 0, firstSlot, bytes32(uint256(1)));
        StorageGuard.advance(c, second, 1, secondSlot, bytes32(uint256(1)));
    }

    function program(bytes memory storageUpdates, StorageGuard.ProtectedRange[] memory ranges) external view {
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        StorageGuardVariants.checkProgram(types, args, ranges);
    }

    /// @dev A pre-pass followed by the real, inline-guarded run over the same list.
    function guardedRun(bytes memory storageUpdates, StorageGuard.ProtectedRange[] memory ranges, bool perWrite)
        external
    {
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        if (perWrite) StorageGuardVariants.checkProgramEach(types, args, ranges);
        else StorageGuardVariants.checkProgram(types, args, ranges);
        // The real settlement run, guarded inline by the same list.
        StateChangeHandlerLib._runStateUpdates(types, args, ranges, StateChangeHandlerLib._unrestrictedCalls());
    }

    function programEach(bytes memory storageUpdates, StorageGuard.ProtectedRange[] memory ranges) external view {
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        StorageGuardVariants.checkProgramEach(types, args, ranges);
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

    /// @dev One write of a nonzero value. Untouched slots hold zero, so the write changes the
    ///      slot, which is what a protected range rejects.
    function _w(uint256 slot) internal pure returns (bytes32[] memory s, bytes32[] memory v) {
        s = new bytes32[](1);
        v = new bytes32[](1);
        s[0] = bytes32(slot);
        v[0] = bytes32(uint256(1));
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

    /// @dev The original high-level `validateRanges`, kept as the reference for the assembly one.
    function _validReference(StorageGuard.ProtectedRange[] memory rs) internal pure returns (bool) {
        for (uint256 i = 0; i < rs.length; ++i) {
            StorageGuard.ProtectedRange memory r = rs[i];
            if (r.start > r.end || r.mask == bytes32(0)) return false;
            if (r.mask != FULL && r.start != r.end) return false;
            if (i != 0 && r.start <= rs[i - 1].end) return false;
        }
        return true;
    }

    /// forge-config: default.fuzz.runs = 2048
    function testFuzz_validateMatchesReference(uint256 seed, uint8 k) public view {
        StorageGuard.ProtectedRange[] memory rs = new StorageGuard.ProtectedRange[](uint256(k) % 5);
        for (uint256 i = 0; i < rs.length; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            // Small bounds so equal, adjacent, overlapping and inverted ranges are all common;
            // masks cycle through zero, FULL and a partial mask.
            uint256 start = r % 6;
            uint256 end = (r >> 8) % 6;
            if ((r >> 16) % 16 == 0) end = type(uint256).max;
            uint256 m = (r >> 24) % 3;
            bytes32 mask = m == 0 ? bytes32(0) : m == 1 ? FULL : bytes32(uint256(0xff));
            rs[i] = StorageGuard.ProtectedRange(start, end, mask);
        }
        (bool ok,) = address(h).staticcall(abi.encodeCall(h.validate, (rs)));
        assertEq(ok, _validReference(rs));
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
        bytes32[] memory v = new bytes32[](4);
        for (uint256 i = 0; i < 4; ++i) {
            v[i] = bytes32(uint256(1));
        }
        (bool rejected, uint256 index) = _all(rs, s, v);
        assertTrue(rejected);
        assertEq(index, 2);
    }

    // ---------------------------------------------------------------- cursor state

    /// @dev The reported case: a cursor walked to the end of a long list, then reused on a short
    ///      list whose first range covers the next write.
    function test_cursorReusedOnAnotherListStillRejects() public {
        StorageGuard.ProtectedRange[] memory longList = new StorageGuard.ProtectedRange[](4);
        for (uint256 i = 0; i < 4; ++i) {
            longList[i] = _r(10 * i, 10 * i);
        }
        vm.expectRevert(abi.encodeWithSelector(StorageGuard.ProtectedSlotWrite.selector, 1, bytes32(uint256(50))));
        h.mergeReused(longList, bytes32(uint256(35)), _one(50, 50), bytes32(uint256(50)));
    }

    function test_cursorWithGarbagePositionStillRejects() public {
        StorageGuard.ProtectedRange[] memory rs = new StorageGuard.ProtectedRange[](3);
        rs[0] = _r(5, 5);
        rs[1] = _r(20, 20);
        rs[2] = _r(40, 40);
        (bytes32[] memory s, bytes32[] memory v) = _w(20);
        uint256[4] memory starts = [uint256(2), 3, 1000, type(uint256).max];
        for (uint256 i = 0; i < starts.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(StorageGuard.ProtectedSlotWrite.selector, 0, bytes32(uint256(20))));
            h.mergeFrom(rs, s, v, starts[i]);
        }
    }

    /// @notice The cursor's contents affect gas only: from any starting position, the merge
    ///         reaches the same verdict as the naive model.
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_cursorStateNeverChangesTheVerdict(uint256 seed, uint8 n, uint256 startNext) public {
        StorageGuard.ProtectedRange[] memory rs = _fuzzRanges(seed);
        (bytes32[] memory s, bytes32[] memory v) = _fuzzWrites(seed, uint256(n) % 40, seed % 3);
        // Mostly small positions (in and just past the list), sometimes anything at all.
        if (startNext % 4 != 0) startNext %= 20;
        (bool wantRejected, uint256 wantIndex) = _oracle(rs, s, v);
        (bool rejected, uint256 index) = _outcome(abi.encodeCall(h.mergeFrom, (rs, s, v, startNext)));
        assertEq(rejected, wantRejected, "verdict");
        if (wantRejected) assertEq(index, wantIndex, "index");
    }

    // ---------------------------------------------------------------- masked (packed) slots

    /// @dev The rule for every range: a write may not change protected bits. Rewriting the
    ///      stored value, as gas-analyzer's copy of the transition counter does, passes.
    function test_fullRange_allowsUnchangedWriteOnly() public {
        h.poke(bytes32(uint256(7)), bytes32(uint256(41)));
        (bytes32[] memory s, bytes32[] memory v) = _w(7);
        StorageGuard.ProtectedRange[] memory rs = _one(7, 7);

        v[0] = bytes32(uint256(41)); // the stored value: no change
        (bool rejected,) = _all(rs, s, v);
        assertFalse(rejected);

        v[0] = bytes32(uint256(42)); // any change at all
        (rejected,) = _all(rs, s, v);
        assertTrue(rejected);
    }

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
        Sort.sort(sorted);

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

    function test_wellKnownSlotsMatchTheirConstants() public {
        assertEq(
            _erc7201("openzeppelin.storage.Ownable"), 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300
        );
        assertEq(
            _erc7201("openzeppelin.storage.Initializable"),
            0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00
        );
        // EIP-1967: derivation, published constant, and the constant OpenZeppelin's proxies use.
        (bytes32 impl, bytes32 admin, bytes32 beacon) = new ERC1967Slots().slots();
        assertEq(
            _eip1967("eip1967.proxy.implementation"), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
        );
        assertEq(_eip1967("eip1967.proxy.implementation"), uint256(impl));
        assertEq(_eip1967("eip1967.proxy.admin"), 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103);
        assertEq(_eip1967("eip1967.proxy.admin"), uint256(admin));
        assertEq(_eip1967("eip1967.proxy.beacon"), 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50);
        assertEq(_eip1967("eip1967.proxy.beacon"), uint256(beacon));
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
        // The write follows a CALL, so a pre-pass can't judge it against storage and rejects it.
        bytes memory err =
            abi.encodeWithSelector(StorageGuardVariants.ProtectedWriteAfterExternalCode.selector, 3, bytes32(0));
        vm.expectRevert(err);
        h.program(p, rs);
        vm.expectRevert(err);
        h.programEach(p, rs);
    }

    /// @dev The reported case: SDK storage then slot 0, in descending order. Every checker
    ///      would stop at the first range (its end is above 0), see its start above 0, and
    ///      accept a write to slot 0.
    function _descendingRanges() internal pure returns (StorageGuard.ProtectedRange[] memory rs) {
        uint256 sdk = 0x1d6f9f139320a34a32f3b29eb8638270178e831962a74100c9e8b433f21e1200;
        rs = new StorageGuard.ProtectedRange[](2);
        rs[0] = _r(sdk, sdk + 1);
        rs[1] = _r(0, 0);
    }

    function test_program_rejectsUnvalidatedRanges() public {
        StateUpdateType[] memory t = new StateUpdateType[](1);
        bytes[] memory a = new bytes[](1);
        a[0] = _store(0); // the owner slot the descending list fails to protect
        bytes memory p = abi.encode(t, a);
        vm.expectRevert(StorageGuard.InvalidRanges.selector);
        h.program(p, _descendingRanges());
        vm.expectRevert(StorageGuard.InvalidRanges.selector);
        h.programEach(p, _descendingRanges());

        // A misconfiguration surfaces even when the program has no STOREs to check.
        vm.expectRevert(StorageGuard.InvalidRanges.selector);
        h.program(abi.encode(new StateUpdateType[](0), new bytes[](0)), _descendingRanges());
    }

    /// @dev Pins the documented precondition: the per-write checkers trust their caller, so the
    ///      same list fails open there. If this ever starts reverting, update the docs.
    function test_perWriteCheckersTrustTheCallerToValidate() public view {
        (bytes32[] memory s, bytes32[] memory v) = _w(0);
        (bool rejected,) = _all(_descendingRanges(), s, v);
        assertFalse(rejected);
    }

    /// @dev The input checks must not depend on there being anything to protect: a consumer with
    ///      no ranges yet still gets the same rejection `_runStateUpdates` would give.
    function test_program_rejectsMalformedInputWithNoRanges() public {
        StorageGuard.ProtectedRange[] memory none = new StorageGuard.ProtectedRange[](0);
        StateUpdateType[] memory t = new StateUpdateType[](1);
        bytes[] memory a = new bytes[](1);
        a[0] = abi.encode(bytes32(uint256(5))); // STORE payload missing its value word
        bytes memory p = abi.encode(t, a);
        vm.expectRevert();
        h.program(p, none);
        vm.expectRevert();
        h.programEach(p, none);

        bytes memory mismatched = abi.encode(new StateUpdateType[](2), new bytes[](1));
        vm.expectRevert(StateChangeHandlerLib.InvalidArguments.selector);
        h.program(mismatched, none);
        vm.expectRevert(StateChangeHandlerLib.InvalidArguments.selector);
        h.programEach(mismatched, none);
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
                abi.encodeWithSelector(
                    StorageGuardVariants.ProtectedWriteAfterExternalCode.selector, 1, bytes32(uint256(7))
                )
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

    function test_program_everyCodeRunningOpBlindsProtectedRanges() public {
        StateUpdateType[4] memory ops =
            [StateUpdateType.CALL, StateUpdateType.CREATE, StateUpdateType.CREATE2, StateUpdateType.NESTED];
        for (uint256 i = 0; i < ops.length; ++i) {
            bytes memory p = _afterOp(ops[i]);
            bytes memory err = abi.encodeWithSelector(
                StorageGuardVariants.ProtectedWriteAfterExternalCode.selector, 1, bytes32(uint256(7))
            );
            vm.expectRevert(err);
            h.program(p, _maskedOwnerRange());
            vm.expectRevert(err);
            h.programEach(p, _maskedOwnerRange());
        }
    }

    function test_program_logsDoNotBlindProtectedRanges() public {
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
        if (order == 1) Sort.sortPairs(s, v, 0, n);
        if (order == 2) {
            for (uint256 from = 0; from < n; from += 5) {
                Sort.sortPairs(s, v, from, from + 5 > n ? n : from + 5);
            }
        }
    }

    /// @dev Naive model: the first write landing in a protected range whose protected bits it
    ///      changes. A write that leaves them as stored passes, full mask or not.
    function _oracle(StorageGuard.ProtectedRange[] memory rs, bytes32[] memory s, bytes32[] memory v)
        internal
        view
        returns (bool, uint256)
    {
        for (uint256 i = 0; i < s.length; ++i) {
            uint256 slot = uint256(s[i]);
            for (uint256 j = 0; j < rs.length; ++j) {
                if (slot < rs[j].start || slot > rs[j].end) continue;
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

    // ---------------------------------------------------------------- pre-pass fuzz

    // Slots the generated programs touch: 3 is fully protected, 7 packs a protected owner with a
    // counter, 1 and 8 are unprotected.
    uint256[4] PP_SLOTS = [uint256(1), 3, 7, 8];
    bytes32 constant OWNER_MASK = bytes32(uint256(type(uint160).max));

    function _ppRanges() internal pure returns (StorageGuard.ProtectedRange[] memory rs) {
        rs = new StorageGuard.ProtectedRange[](2);
        rs[0] = _r(3, 3);
        rs[1] = StorageGuard.ProtectedRange(7, 7, OWNER_MASK);
    }

    /// @dev Values drawn from small pools, so programs often restore an earlier owner (the
    ///      attack a pre-pass must not miss) or keep the current one while bumping the counter.
    function _ppValue(uint256 r) internal pure returns (bytes32) {
        address[3] memory owners = [address(0xA11CE), address(0xB0B), address(0xCAFE)];
        return _ownerSlot(owners[r % 3], (r >> 8) % 3);
    }

    struct PP {
        StateUpdateType[] types;
        bytes[] args;
        bool ranCode;
    }

    /// @dev Up to 8 ops: STOREs (mostly to slot 7), CALLs that re-enter `poke` to change storage,
    ///      and LOGs. Seeds the harness's storage first.
    function _ppProgram(uint256 seed) internal returns (PP memory p) {
        for (uint256 j = 0; j < 4; ++j) {
            h.poke(bytes32(PP_SLOTS[j]), _ppValue(uint256(keccak256(abi.encode(seed, "init", j)))));
        }
        uint256 n = seed % 9;
        p.types = new StateUpdateType[](n);
        p.args = new bytes[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 slot = (r >> 8) % 2 == 0 ? 7 : PP_SLOTS[(r >> 16) % 4];
            bytes32 value = _ppValue(r >> 24);
            uint256 kind = r % 8;
            if (kind < 5) {
                p.types[i] = StateUpdateType.STORE;
                p.args[i] = abi.encode(bytes32(slot), value);
            } else if (kind < 7) {
                p.types[i] = StateUpdateType.CALL;
                p.args[i] = abi.encode(address(h), uint256(0), abi.encodeCall(h.poke, (bytes32(slot), value)));
                p.ranCode = true;
            } else {
                p.types[i] = StateUpdateType.LOG0;
                p.args[i] = abi.encode(bytes("log"));
            }
        }
    }

    /// @dev Simulates the program op by op. Returns whether some STORE writes slot 3 or changes
    ///      slot 7's owner bits as storage stands at that moment, and the final storage.
    function _ppSimulate(PP memory p) internal view returns (bool violation, bytes32[4] memory store) {
        for (uint256 j = 0; j < 4; ++j) {
            store[j] = vm.load(address(h), bytes32(PP_SLOTS[j]));
        }
        for (uint256 i = 0; i < p.types.length; ++i) {
            bytes32 slot;
            bytes32 value;
            if (p.types[i] == StateUpdateType.STORE) {
                (slot, value) = abi.decode(p.args[i], (bytes32, bytes32));
                uint256 j = _ppIndex(uint256(slot));
                if (uint256(slot) == 3 && store[j] != value) violation = true;
                if (uint256(slot) == 7 && (store[j] ^ value) & OWNER_MASK != 0) violation = true;
                store[j] = value;
            } else if (p.types[i] == StateUpdateType.CALL) {
                (,, bytes memory callargs) = abi.decode(p.args[i], (address, uint256, bytes));
                (slot, value) = abi.decode(_tail(callargs), (bytes32, bytes32));
                store[_ppIndex(uint256(slot))] = value;
            }
        }
    }

    function _ppIndex(uint256 slot) internal view returns (uint256) {
        for (uint256 j = 0; j < 4; ++j) {
            if (PP_SLOTS[j] == slot) return j;
        }
        revert("slot outside the program's universe");
    }

    /// forge-config: default.fuzz.runs = 2048
    function testFuzz_prePassIsSoundWhenStorageChangesBetweenWrites(uint256 seed) public {
        PP memory p = _ppProgram(seed);
        bytes memory encoded = abi.encode(p.types, p.args);
        StorageGuard.ProtectedRange[] memory rs = _ppRanges();

        (bool okMerge, bytes memory errMerge) = address(h).staticcall(abi.encodeCall(h.program, (encoded, rs)));
        (bool okEach, bytes memory errEach) = address(h).staticcall(abi.encodeCall(h.programEach, (encoded, rs)));
        assertEq(okMerge, okEach, "checkProgram and checkProgramEach disagree");
        assertEq(errMerge, errEach, "checkProgram and checkProgramEach disagree on the error");

        (bool violation, bytes32[4] memory expected) = _ppSimulate(p);
        // Soundness: an accepted program never changes protected bits at run time.
        if (okMerge) assertFalse(violation, "pre-pass accepted a program that changes protected bits");
        // Exactness: with no code-running op, storage can't move between writes, so the
        // pre-pass rejects exactly the violating programs.
        if (!p.ranCode) assertEq(okMerge, !violation, "pre-pass verdict differs from the model");

        // Tie the model to the real execution: run accepted programs and compare storage.
        if (okMerge) {
            h.guardedRun(encoded, rs, false);
            for (uint256 j = 0; j < 4; ++j) {
                assertEq(vm.load(address(h), bytes32(PP_SLOTS[j])), expected[j], "model and execution differ");
            }
        }
    }
}
