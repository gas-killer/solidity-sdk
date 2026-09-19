// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.12;

import {Vm} from "forge-std/Vm.sol";
import {GKVM_OK_TAG} from "../GkVm.sol";
import {
    GkGuestTrap,
    GkGuestOutOfCycles,
    GkVmInputOverflow,
    GkVmOutputOverflow,
    GkVmStaticOnly
} from "../GkVmErrors.sol";

/// @notice The wire input is shorter than programHash (32) || artifactRoot (32)
error GkVmFfiShimMalformedInput();

/// @notice `programHash` was never `installProgram`ed on this shim
/// @dev Operator-side this is an environment failure (abstain), not an EVM outcome; in a forge
///      test the closest honest analogue is a loud revert that matches no `GkVmErrors` selector.
error GkVmFfiShimProgramNotInstalled(bytes32 programHash);

/// @notice `artifactRoot` was never `installArtifact`ed on this shim (environment class, see above)
error GkVmFfiShimArtifactNotInstalled(bytes32 artifactRoot);

/// @notice `gk-run` exited in its environment/usage class, or broke the one-hex-line discipline
error GkVmFfiShimEnvFailure(int32 exitCode, bytes stderr);

/// @title GkVmFfiShim
/// @notice Forge-test stand-in for the gkvm precompile: decodes the wire format and runs the
///         same `gk-run` sidecar binary the operator path wraps, through `vm.tryFfi`
/// @dev TEST ONLY — lives under `src/gkvm/testing/` (not `test/`) so a project that
///      `forge install`s the sdk can import it; never deploy it on a chain.
///      Needs `ffi = true` (the `gkvm-ffi` profile in foundry.toml). Deploy at any
///      address and inject it into the consumer's constructor in place of `GKVM_ADDRESS`; production
///      bytecode carries zero ffi paths. See src/examples/onchain-llm/UNBOUNDED_V3_NATIVE.md
///      (§ Foundry integration, Phase A).
///      Fidelity limits, by construction: gas is not metered like the precompile (the guest runs
///      out-of-process; `GkGuestOutOfCycles` does not consume the call's full gas), and the
///      gas-derived cycle budget is approximate because the shim's own EVM overhead is spent
///      before `gasleft()` is read — pin it with `setCycleLimit` when a test needs exact bytes.
contract GkVmFfiShim {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Mirrors of the pinned protocol constants (doc § Gas model); never tuned here
    uint256 internal constant CYCLES_PER_GAS = 4;
    uint256 internal constant GAS_BASE = 65_536;
    uint256 internal constant GAS_PER_INPUT_BYTE = 16;

    /// @dev gk-run exit codes (crates/gkvm/src/bin/gk-run.rs)
    int32 internal constant EXIT_OK = 0;
    int32 internal constant EXIT_TRAP = 10;
    int32 internal constant EXIT_OUT_OF_CYCLES = 11;
    int32 internal constant EXIT_INPUT_OVERFLOW = 12;
    int32 internal constant EXIT_OUTPUT_OVERFLOW = 13;

    /// @dev Payloads above this go to gk-run as `--input @file`: one argv string caps at 131071
    ///      chars on Linux, under the 262144 hex chars of a cap-sized (131072-byte) payload
    uint256 internal constant ARGV_PAYLOAD_MAX = 32_768;
    string internal constant SPILL_DIR = "cache/gkvm";

    struct Artifact {
        string blobs; // comma-separated paths, gk-run `--artifact` syntax
        string schedule; // kind:page,… — gk-run `--schedule` syntax, may be empty
    }

    string public gkRun;
    /// @notice Fixed cycle budget; zero derives it from the call's gas like the precompile does
    uint64 public cycleLimit;
    mapping(bytes32 => string) public programPath;
    mapping(bytes32 => Artifact) internal artifacts;

    event StaticProbe();

    /// @param _gkRun Path (or PATH-resolvable name) of the `gk-run` binary
    constructor(string memory _gkRun) {
        gkRun = _gkRun;
    }

    /// @notice Registers a guest ELF; its programHash is the keccak256 of the file bytes
    /// @param path ELF path, readable under foundry.toml `fs_permissions`
    function installProgram(string calldata path) external returns (bytes32 programHash) {
        programHash = keccak256(vm.readFileBinary(path));
        programPath[programHash] = path;
    }

    /// @notice Registers an artifact bundle under its manifest-v3 root
    /// @dev The root is NOT recomputed here: gk-run verifies the blobs against it at load and
    ///      fails in the environment class on mismatch.
    /// @param blobs Comma-separated blob paths, in manifest file order
    /// @param schedule Page-serving order the guest will request (`kind:page,…`), may be empty
    function installArtifact(bytes32 artifactRoot, string calldata blobs, string calldata schedule) external {
        artifacts[artifactRoot] = Artifact({blobs: blobs, schedule: schedule});
    }

    /// @notice Pins the cycle budget passed to gk-run; zero restores gas-derived budgets
    function setCycleLimit(uint64 _cycleLimit) external {
        cycleLimit = _cycleLimit;
    }

    /// @dev Target of the static-context probe: a LOG is forbidden under STATICCALL
    function staticProbe() external {
        emit StaticProbe();
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        if (!_isStatic()) revert GkVmStaticOnly();
        if (data.length < 64) revert GkVmFfiShimMalformedInput();
        bytes32 programHash = bytes32(data[:32]);
        bytes32 artifactRoot = bytes32(data[32:64]);
        bytes calldata payload = data[64:];

        uint64 limit = cycleLimit != 0 ? cycleLimit : _budgetFromGas(payload.length);
        Vm.FfiResult memory result = vm.tryFfi(_gkRunArgs(programHash, artifactRoot, payload, limit));

        if (result.exitCode == EXIT_OK) return abi.encodePacked(GKVM_OK_TAG, result.stdout);
        if (result.exitCode == EXIT_TRAP && result.stdout.length >= 4) {
            (uint32 code, bytes memory trapData) = _splitTrap(result.stdout);
            revert GkGuestTrap(code, trapData);
        }
        if (result.exitCode == EXIT_OUT_OF_CYCLES && result.stdout.length == 16) {
            uint128 usedAndLimit = uint128(bytes16(result.stdout));
            revert GkGuestOutOfCycles(uint64(usedAndLimit >> 64), uint64(usedAndLimit));
        }
        if (result.exitCode == EXIT_INPUT_OVERFLOW) revert GkVmInputOverflow();
        if (result.exitCode == EXIT_OUTPUT_OVERFLOW) revert GkVmOutputOverflow();
        revert GkVmFfiShimEnvFailure(result.exitCode, result.stderr);
    }

    /// @dev A self-call that logs fails iff this frame is static. The probe's gas is capped
    ///      because the static-violation halt burns everything forwarded to it.
    function _isStatic() private returns (bool) {
        try this.staticProbe{gas: 5_000}() {
            return false;
        } catch {
            return true;
        }
    }

    /// @dev Doc § Gas model: charge base + input cost, then `cycle_limit = gas_remaining × 4`,
    ///      saturated to u64 (forge's default gas limit is u64::MAX). Too little gas to cover
    ///      the charge is a plain out-of-gas on the precompile: empty revert here.
    function _budgetFromGas(uint256 payloadLength) private view returns (uint64) {
        uint256 charge = GAS_BASE + GAS_PER_INPUT_BYTE * payloadLength;
        uint256 gasRemaining = gasleft();
        if (gasRemaining < charge) revert();
        uint256 cycles = (gasRemaining - charge) * CYCLES_PER_GAS;
        return cycles > type(uint64).max ? type(uint64).max : uint64(cycles);
    }

    function _gkRunArgs(bytes32 programHash, bytes32 artifactRoot, bytes calldata payload, uint64 limit)
        private
        returns (string[] memory args)
    {
        string memory program = programPath[programHash];
        if (bytes(program).length == 0) revert GkVmFfiShimProgramNotInstalled(programHash);

        Artifact storage artifact = artifacts[artifactRoot];
        bool mounted = artifactRoot != bytes32(0);
        if (mounted && bytes(artifact.blobs).length == 0) revert GkVmFfiShimArtifactNotInstalled(artifactRoot);
        bool scheduled = mounted && bytes(artifact.schedule).length != 0;

        args = new string[](9 + (mounted ? 4 : 0) + (scheduled ? 2 : 0));
        args[0] = gkRun;
        args[1] = "--program";
        args[2] = program;
        args[3] = "--program-hash";
        args[4] = vm.toString(programHash);
        args[5] = "--input";
        args[6] = _inputArg(payload);
        args[7] = "--cycle-limit";
        args[8] = vm.toString(uint256(limit));
        if (mounted) {
            args[9] = "--artifact";
            args[10] = artifact.blobs;
            args[11] = "--artifact-root";
            args[12] = vm.toString(artifactRoot);
        }
        if (scheduled) {
            args[13] = "--schedule";
            args[14] = artifact.schedule;
        }
    }

    /// @dev Inline hex, or a content-addressed spill file (idempotent under parallel tests)
    function _inputArg(bytes calldata payload) private returns (string memory) {
        if (payload.length <= ARGV_PAYLOAD_MAX) return vm.toString(payload);
        string memory path = string.concat(SPILL_DIR, "/input-", vm.toString(keccak256(payload)), ".bin");
        vm.createDir(SPILL_DIR, true);
        vm.writeFileBinary(path, payload);
        return string.concat("@", path);
    }

    /// @dev gk-run prints a trap as `code (u32 BE) || data`
    function _splitTrap(bytes memory stdout) private pure returns (uint32 code, bytes memory trapData) {
        code = uint32(bytes4(stdout));
        trapData = new bytes(stdout.length - 4);
        for (uint256 i = 0; i < trapData.length; i++) {
            trapData[i] = stdout[i + 4];
        }
    }
}
