// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {GkGuestTrap} from "gk-sdk/gkvm/GkVmErrors.sol";
import {GkVmFfiShim} from "gk-sdk/gkvm/testing/GkVmFfiShim.sol";
import {GkAnswer} from "../src/gen/GkAnswer.sol";
import {GkAlltypes} from "../src/gen/GkAlltypes.sol";

/// @dev The generated bindings behind external functions, so a guest trap is a revert the test can
///      expect rather than the test's own
contract PyGuestsHarness {
    address internal immutable gkvm;

    constructor(address _gkvm) {
        gkvm = _gkvm;
    }

    function answer(uint256[] memory promptIds, uint256 maxNew) external view returns (bytes memory) {
        return GkAnswer.call(gkvm, bytes32(0), promptIds, maxNew);
    }

    function alltypes(
        uint256[] memory nums,
        uint256 big,
        bool flag,
        bytes memory blob,
        string memory name,
        uint256[][] memory rows
    ) external view returns (string memory, uint256[] memory, bool, bytes[] memory, uint256) {
        return GkAlltypes.call(gkvm, bytes32(0), nums, big, flag, blob, name, rows);
    }
}

/// @dev tools/gk's Python-guest end-to-end (test_gk.py copies this next to the two bindings `gk
///      build` generated from testdata/answer.py and testdata/alltypes.py): solc's abi.encode →
///      gk_runtime's decoder → main() → gk_runtime's encoder → solc's abi.decode, with the real
///      MicroPython image under gk-run. Not a test of the sdk checkout itself — it needs GK_RUN and
///      the gkvm-ffi profile, and fails (not skips) without them.
contract PyGuestsTest is Test {
    GkVmFfiShim internal shim;
    PyGuestsHarness internal guests;

    function setUp() public {
        shim = new GkVmFfiShim(vm.envString("GK_RUN"));
        assertEq(shim.installProgram("cache/gkvm/build/answer/guest.elf"), GkAnswer.PROGRAM_HASH);
        assertEq(shim.installProgram("cache/gkvm/build/alltypes/guest.elf"), GkAlltypes.PROGRAM_HASH);
        guests = new PyGuestsHarness(address(shim));
    }

    function testAnswerReturnsMainsBytesUndecoded() public view {
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (7, 65000, 12345678901234567890);
        uint256 acc;
        for (uint256 i; i < ids.length; ++i) {
            acc = (acc * 31 + ids[i]) % 65521;
        }
        bytes memory expected;
        for (uint256 i; i < 5; ++i) {
            acc = (acc * 31 + i) % 65521;
            expected = abi.encodePacked(expected, uint32(acc));
        }
        assertEq(guests.answer(ids, 5), expected);
        assertEq(guests.answer(new uint256[](0), 0), "");
    }

    function testAlltypesRoundTripsEveryMappedType() public view {
        uint256[] memory nums = new uint256[](3);
        (nums[0], nums[1], nums[2]) = (1, 2, 3);
        uint256[][] memory rows = new uint256[][](3);
        rows[0] = new uint256[](2);
        (rows[0][0], rows[0][1]) = (10, 20);
        rows[2] = new uint256[](1);
        rows[2][0] = 7;

        (string memory s, uint256[] memory doubled, bool flipped, bytes[] memory blobs, uint256 wrapped) =
            guests.alltypes(nums, type(uint256).max - 5, true, hex"11223344", unicode"héllo", rows);

        assertEq(s, unicode"héllo!!!");
        uint256[] memory expected = new uint256[](6);
        (expected[0], expected[1], expected[2], expected[3], expected[5]) = (2, 4, 6, 2, 1);
        assertEq(doubled, expected);
        assertFalse(flipped);
        assertEq(blobs.length, 3);
        assertEq(blobs[0], hex"44332211");
        assertEq(blobs[1], bytes(unicode"héllo"));
        assertEq(blobs[2], "");
        // (2^256 - 6) + 43 wraps to 37: mpz arithmetic, reduced by the guest, fits the word again
        assertEq(wrapped, 37);
    }

    function testAnUncaughtExceptionIsATypedTrap() public {
        vm.expectPartialRevert(GkGuestTrap.selector);
        guests.answer(new uint256[](0), 65);
    }

    function testAMalformedPayloadIsATypedTrap() public {
        (bool ok, bytes memory data) =
            address(shim).staticcall(abi.encodePacked(GkAnswer.PROGRAM_HASH, bytes32(0), hex"01"));
        assertFalse(ok);
        assertEq(bytes4(data), GkGuestTrap.selector);
    }
}
