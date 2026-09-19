// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.12;

import {Test} from "forge-std/Test.sol";
import {GKVM_OK_TAG} from "../src/gkvm/GkVm.sol";
import {GkGuestTrap, GkGuestOutOfCycles, GkVmInputOverflow, GkVmOutputOverflow} from "../src/gkvm/GkVmErrors.sol";
import {GkVmFfiShim} from "../src/gkvm/testing/GkVmFfiShim.sol";

/// @dev Golden parity: the `*_vectors.json` fixtures are written by `gk vectors` from DIRECT
///      `gk-run` invocations (`make -C tools/gk golden`); here every vector is replayed through
///      GkVmFfiShim and the raw returndata must be bit-identical to what the recorded stdout
///      implies — `0x01 || stdout` on success, the typed error rebuilt from the failure frame
///      otherwise. CI regenerates the fixtures and diffs them first (`make -C tools/gk
///      golden-check`), so shim ≡ committed ≡ fresh direct gk-run.
///      The replay skips unless GK_RUN names the binary (gkvm-ffi profile); the fixture
///      self-consistency test always runs.
contract GkVmGoldenTest is Test {
    string internal constant FIXTURES = "test/fixtures/gkvm/";

    /// @dev gk-run exit codes as recorded in the vectors (crates/gkvm/src/bin/gk-run.rs)
    uint256 internal constant EXIT_OK = 0;
    uint256 internal constant EXIT_TRAP = 10;
    uint256 internal constant EXIT_OUT_OF_CYCLES = 11;
    uint256 internal constant EXIT_INPUT_OVERFLOW = 12;
    uint256 internal constant EXIT_OUTPUT_OVERFLOW = 13;

    GkVmFfiShim internal shim;
    bool internal gkRunMissing;

    modifier needsGkRun() {
        vm.skip(gkRunMissing);
        _;
    }

    function setUp() public {
        string memory gkRun = vm.envOr("GK_RUN", string(""));
        gkRunMissing = bytes(gkRun).length == 0;
        shim = new GkVmFfiShim(gkRun);
    }

    function testGoldenHello() public needsGkRun {
        assertEq(_replay("hello-c_vectors.json", "hello-c.elf"), 3);
    }

    function testGoldenBench() public needsGkRun {
        assertEq(_replay("bench-c_vectors.json", "bench-c.elf"), 4);
    }

    function testGoldenBenchPinnedLimit() public needsGkRun {
        assertEq(_replay("bench-c-limit1000_vectors.json", "bench-c.elf"), 3);
    }

    /// @dev Needs no gk-run: each fixture names the committed ELF it was recorded from, and
    ///      gasUsed = ceil(cycles / 4) on every vector
    function testFixturesAreSelfConsistent() public view {
        _checkFixture("hello-c_vectors.json", "hello-c.elf");
        _checkFixture("bench-c_vectors.json", "bench-c.elf");
        _checkFixture("bench-c-limit1000_vectors.json", "bench-c.elf");
    }

    function _replay(string memory vectorsFile, string memory elf) private returns (uint256 count) {
        string memory json = vm.readFile(string.concat(FIXTURES, vectorsFile));
        bytes32 programHash = shim.installProgram(string.concat(FIXTURES, elf));
        assertEq(programHash, vm.parseJsonBytes32(json, ".programHash"), "fixture recorded from another ELF");
        bytes32 artifactRoot = vm.parseJsonBytes32(json, ".artifactRoot");

        for (; vm.keyExistsJson(json, _key(count, "")); count++) {
            bytes memory input = vm.parseJsonBytes(json, _key(count, ".input"));
            bytes memory stdout = vm.parseJsonBytes(json, _key(count, ".stdout"));
            uint256 exit = vm.parseJsonUint(json, _key(count, ".exit"));
            bool pinned = vm.keyExistsJson(json, _key(count, ".cycleLimit"));
            shim.setCycleLimit(pinned ? uint64(vm.parseJsonUint(json, _key(count, ".cycleLimit"))) : 0);

            (bool ok, bytes memory ret) = address(shim).staticcall(abi.encodePacked(programHash, artifactRoot, input));
            assertEq(ok, exit == EXIT_OK, _key(count, ": success flag"));
            assertEq(ret, _expected(exit, stdout), _key(count, ": returndata"));
        }
    }

    /// @dev The precompile-side bytes a direct gk-run result maps to
    function _expected(uint256 exit, bytes memory stdout) private pure returns (bytes memory) {
        if (exit == EXIT_OK) return abi.encodePacked(GKVM_OK_TAG, stdout);
        if (exit == EXIT_TRAP) {
            return abi.encodeWithSelector(GkGuestTrap.selector, uint32(bytes4(stdout)), _tail(stdout, 4));
        }
        if (exit == EXIT_OUT_OF_CYCLES) {
            require(stdout.length == 16, "out-of-cycles frame is used (u64 BE) || limit (u64 BE)");
            uint128 usedAndLimit = uint128(bytes16(stdout));
            return abi.encodeWithSelector(GkGuestOutOfCycles.selector, uint64(usedAndLimit >> 64), uint64(usedAndLimit));
        }
        if (exit == EXIT_INPUT_OVERFLOW) return abi.encodeWithSelector(GkVmInputOverflow.selector);
        if (exit == EXIT_OUTPUT_OVERFLOW) return abi.encodeWithSelector(GkVmOutputOverflow.selector);
        revert("not a vector-class gk-run exit code");
    }

    function _checkFixture(string memory vectorsFile, string memory elf) private view {
        string memory json = vm.readFile(string.concat(FIXTURES, vectorsFile));
        assertEq(vm.parseJsonBytes32(json, ".programHash"), keccak256(vm.readFileBinary(string.concat(FIXTURES, elf))));
        uint256 count;
        for (; vm.keyExistsJson(json, _key(count, "")); count++) {
            uint256 cycles = vm.parseJsonUint(json, _key(count, ".cycles"));
            assertEq(vm.parseJsonUint(json, _key(count, ".gasUsed")), (cycles + 3) / 4, _key(count, ": gasUsed"));
        }
        assertGt(count, 0, "empty fixture");
    }

    function _key(uint256 index, string memory field) private pure returns (string memory) {
        return string.concat(".vectors[", vm.toString(index), "]", field);
    }

    function _tail(bytes memory input, uint256 from) private pure returns (bytes memory out) {
        out = new bytes(input.length - from);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = input[i + from];
        }
    }
}
