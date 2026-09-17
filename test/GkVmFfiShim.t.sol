// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.12;

import {Test} from "forge-std/Test.sol";
import {
    GkGuestTrap,
    GkGuestOutOfCycles,
    GkVmInputOverflow,
    GkVmOutputOverflow,
    GkVmStaticOnly
} from "../src/gkvm/GkVmErrors.sol";
import {GkVmExposed} from "./exposed/GkVmExposed.sol";
import {
    GkVmFfiShim,
    GkVmFfiShimMalformedInput,
    GkVmFfiShimProgramNotInstalled,
    GkVmFfiShimArtifactNotInstalled
} from "./GkVmFfiShim.sol";

/// @dev Runs real guests through `gk-run`; every test skips unless GK_RUN names the binary:
///        GK_RUN=/path/to/gk-run FOUNDRY_PROFILE=gkvm-ffi forge test --match-contract GkVmFfiShimTest
///      Fixtures are byte-identical copies of gas-analyzer crates/gkvm/tests/fixtures.
contract GkVmFfiShimTest is Test {
    string internal constant HELLO_ELF = "test/fixtures/gkvm/hello-c.elf";
    string internal constant BENCH_ELF = "test/fixtures/gkvm/bench-c.elf";
    bytes internal constant HELLO_TAG = "GKVM-HELLO-V1\n";
    /// @dev bench-c retires exactly 8 instructions per iteration + 157 (M1 measurement)
    uint64 internal constant BENCH_1E6_CYCLES = 8_000_157;

    GkVmExposed internal gk;
    GkVmFfiShim internal shim;
    bytes32 internal hello;
    bytes32 internal bench;
    bool internal gkRunMissing;

    modifier needsGkRun() {
        vm.skip(gkRunMissing);
        _;
    }

    function setUp() public {
        string memory gkRun = vm.envOr("GK_RUN", string(""));
        gkRunMissing = bytes(gkRun).length == 0;
        gk = new GkVmExposed();
        shim = new GkVmFfiShim(gkRun);
        hello = shim.installProgram(HELLO_ELF);
        bench = shim.installProgram(BENCH_ELF);
    }

    function testInstallProgramHashesTheElf() public view {
        assertEq(hello, keccak256(vm.readFileBinary(HELLO_ELF)));
        assertEq(shim.programPath(hello), HELLO_ELF);
    }

    /// @dev Doc risk 9: the whole path below `execExternal` (view) is a STATICCALL context
    function testHelloUnderStaticcall() public needsGkRun {
        bytes memory out = gk.execExternal(address(shim), hello, bytes32(0), hex"11223344");
        assertEq(out, abi.encodePacked(HELLO_TAG, hex"44332211"));
    }

    function testEmptyPayload() public needsGkRun {
        assertEq(gk.execExternal(address(shim), hello, bytes32(0), ""), HELLO_TAG);
    }

    function testAbiPayloadRoundTrip() public needsGkRun {
        bytes memory payload = abi.encode(uint256(7), "prompt");
        bytes memory out = gk.execExternal(address(shim), hello, bytes32(0), payload);
        assertEq(out, abi.encodePacked(HELLO_TAG, _reversed(payload)));
    }

    /// @dev Above ARGV_PAYLOAD_MAX the payload reaches gk-run as `--input @file`
    function testLargePayloadSpillsToFile() public needsGkRun {
        bytes memory payload = _pattern(100_000);
        bytes memory out = gk.execExternal(address(shim), hello, bytes32(0), payload);
        assertEq(keccak256(out), keccak256(abi.encodePacked(HELLO_TAG, _reversed(payload))));
    }

    function testGuestTrap() public needsGkRun {
        vm.expectRevert(abi.encodeWithSelector(GkGuestTrap.selector, 1, "bench wants a u64 BE iteration count"));
        gk.execExternal(address(shim), bench, bytes32(0), hex"01");
    }

    function testOutOfCyclesPinnedLimit() public needsGkRun {
        shim.setCycleLimit(1000);
        vm.expectRevert(abi.encodeWithSelector(GkGuestOutOfCycles.selector, BENCH_1E6_CYCLES, 1000));
        gk.execExternal(address(shim), bench, bytes32(0), abi.encodePacked(uint64(1_000_000)));
    }

    /// @dev 1M gas buys < 4M cycles; the exact limit depends on the shim's own overhead
    function testOutOfCyclesFromCallGas() public needsGkRun {
        try gk.execExternal{gas: 1_000_000}(address(shim), bench, bytes32(0), abi.encodePacked(uint64(1_000_000))) {
            fail();
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), GkGuestOutOfCycles.selector);
            (uint64 used, uint64 limit) = abi.decode(_tail(reason, 4), (uint64, uint64));
            assertEq(used, BENCH_1E6_CYCLES);
            assertLt(limit, 4_000_000);
            assertGt(limit, 3_000_000);
        }
    }

    function testBudgetFromCallGasSuffices() public needsGkRun {
        bytes memory out =
            gk.execExternal{gas: 3_000_000}(address(shim), bench, bytes32(0), abi.encodePacked(uint64(1_000_000)));
        assertEq(out.length, 8);
    }

    function testInputOverflow() public needsGkRun {
        bytes memory payload = _pattern(131_073);
        vm.expectRevert(GkVmInputOverflow.selector);
        gk.execExternal(address(shim), hello, bytes32(0), payload);
    }

    /// @dev hello answers tag (14) + payload: a cap-sized payload overflows the output cap
    function testOutputOverflow() public needsGkRun {
        bytes memory payload = _pattern(131_072);
        vm.expectRevert(GkVmOutputOverflow.selector);
        gk.execExternal(address(shim), hello, bytes32(0), payload);
    }

    function testNonStaticCallReverts() public {
        (bool ok, bytes memory ret) = address(shim).call(abi.encodePacked(hello, bytes32(0)));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(GkVmStaticOnly.selector));
    }

    function testMalformedInput() public {
        (bool ok, bytes memory ret) = address(shim).staticcall(hex"0102");
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(GkVmFfiShimMalformedInput.selector));
    }

    function testUnknownProgram() public {
        bytes32 unknown = keccak256("not installed");
        vm.expectRevert(abi.encodeWithSelector(GkVmFfiShimProgramNotInstalled.selector, unknown));
        gk.execExternal(address(shim), unknown, bytes32(0), "");
    }

    function testUnknownArtifact() public {
        bytes32 root = keccak256("not mounted");
        vm.expectRevert(abi.encodeWithSelector(GkVmFfiShimArtifactNotInstalled.selector, root));
        gk.execExternal(address(shim), hello, root, "");
    }

    function _pattern(uint256 length) private pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[i] = bytes1(uint8(i * 31 + 7));
        }
    }

    function _reversed(bytes memory input) private pure returns (bytes memory out) {
        out = new bytes(input.length);
        for (uint256 i = 0; i < input.length; i++) {
            out[i] = input[input.length - 1 - i];
        }
    }

    function _tail(bytes memory input, uint256 from) private pure returns (bytes memory out) {
        out = new bytes(input.length - from);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = input[i + from];
        }
    }
}
