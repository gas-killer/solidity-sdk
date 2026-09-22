// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.12;

import {Test, Vm} from "forge-std/Test.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {GKVM_ADDRESS} from "../src/gkvm/GkVm.sol";
import {GkVmParityConsumer} from "./exposed/GkVmParityConsumer.sol";
import {GkVmFfiShim} from "../src/gkvm/testing/GkVmFfiShim.sol";

/// @dev The ffi leg of the M3 ffi ≡ precompile differential. Every golden vector becomes a TASK — a
///      call to GkVmParityConsumer wired to GkVmFfiShim — and what the task did to the consumer
///      (net storage writes, then logs) is encoded exactly as gas-analyzer encodes an extracted
///      payload: `abi.encode(StateUpdateType[], bytes[])`, stores slot-sorted ahead of logs. The
///      result is `test/fixtures/gkvm/parity_tasks.json`; gas-analyzer's evmsketch suite runs the
///      recorded production bytecode (GKVM = GKVM_ADDRESS) through its local executor against the
///      real precompile and requires the same bytes.
///      `make -C tools/gk parity` regenerates the fixture, `parity-check` diffs it. Skips unless
///      GK_RUN names the binary (gkvm-ffi profile).
contract GkVmParityTest is Test {
    string internal constant FIXTURES = "test/fixtures/gkvm/";
    string internal constant OUT_DIR = "cache/gkvm/parity";

    /// @dev `probe`'s guestGas for the pinned-budget vectors: the forwarded gas under which the
    ///      precompile's own budget — (gas at the precompile − intrinsic charge) × 4 — is exactly the
    ///      vectors' pinned PINNED_CYCLE_LIMIT for an 8-byte payload, so `GkGuestOutOfCycles(used,
    ///      limit)` is byte-identical on both legs. A function of the consumer bytecode; re-tune
    ///      with gas-analyzer's `tune_pinned_guest_gas` test if the fixture's consumerCode moves.
    uint256 internal constant PINNED_GUEST_GAS = 69_068;

    GkVmFfiShim internal shim;
    bool internal gkRunMissing;
    string internal tasks;
    uint256 internal taskCount;

    function setUp() public {
        string memory gkRun = vm.envOr("GK_RUN", string(""));
        gkRunMissing = bytes(gkRun).length == 0;
        shim = new GkVmFfiShim(gkRun);
    }

    function testWriteParityTasks() public {
        vm.skip(gkRunMissing);
        _tasks("hello-c_vectors.json", "hello-c.elf");
        _tasks("bench-c_vectors.json", "bench-c.elf");
        _tasks("bench-c-limit1000_vectors.json", "bench-c.elf");
        assertEq(taskCount, 17, "3 + 4 unpinned vectors x {ask, probe}, 3 pinned x {probe}");

        string memory json = string.concat(
            "{\n \"gkvmAddress\": \"",
            vm.toString(GKVM_ADDRESS),
            "\",\n \"consumerCode\": \"",
            vm.toString(address(new GkVmParityConsumer(address(0))).code),
            "\",\n \"tasks\": [\n",
            tasks,
            "\n ]\n}\n"
        );
        vm.createDir(OUT_DIR, true);
        vm.writeFile(string.concat(OUT_DIR, "/parity_tasks.json"), json);
    }

    function _tasks(string memory vectorsFile, string memory elf) private {
        string memory json = vm.readFile(string.concat(FIXTURES, vectorsFile));
        bytes32 programHash = shim.installProgram(string.concat(FIXTURES, elf));
        bytes32 artifactRoot = vm.parseJsonBytes32(json, ".artifactRoot");

        for (uint256 i = 0; vm.keyExistsJson(json, _key(i, "")); i++) {
            bytes memory input = vm.parseJsonBytes(json, _key(i, ".input"));
            string memory id = string.concat(vectorsFile, "#", vm.toString(i));
            if (vm.keyExistsJson(json, _key(i, ".cycleLimit"))) {
                shim.setCycleLimit(uint64(vm.parseJsonUint(json, _key(i, ".cycleLimit"))));
                _task(id, "probe", _probe(programHash, artifactRoot, input, PINNED_GUEST_GAS));
            } else {
                shim.setCycleLimit(0);
                _task(id, "ask", abi.encodeCall(GkVmParityConsumer.ask, (programHash, artifactRoot, input)));
                _task(id, "probe", _probe(programHash, artifactRoot, input, 0));
            }
        }
    }

    function _probe(bytes32 programHash, bytes32 artifactRoot, bytes memory input, uint256 guestGas)
        private
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(GkVmParityConsumer.probe, (programHash, artifactRoot, input, guestGas));
    }

    /// @dev One task against a FRESH consumer (pre-state all zero, so a written slot changed iff it
    ///      is non-zero now)
    function _task(string memory id, string memory fn, bytes memory callData) private {
        GkVmParityConsumer consumer = new GkVmParityConsumer(address(shim));
        vm.record();
        vm.recordLogs();
        (bool ok, bytes memory ret) = address(consumer).call(callData);
        (, bytes32[] memory writes) = vm.accesses(address(consumer));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (ok) {
            // an empty `err` would be the shim starving under `guestGas`, not a guest verdict
            bytes memory result = abi.decode(logs[logs.length - 1].data, (bytes));
            assertGt(result.length, 0, string.concat(id, ": empty guest result"));
        }

        // a reverted tracked call leaves nothing to apply: the revert transition's empty payload
        bytes memory storageUpdates =
            ok ? _encodeUpdates(address(consumer), writes, logs) : abi.encode(new StateUpdateType[](0), new bytes[](0));

        tasks = string.concat(
            tasks,
            taskCount == 0 ? "" : ",\n",
            string.concat("  {\n   \"vector\": \"", id, "\",\n   \"fn\": \"", fn, "\",\n   \"calldata\": \""),
            vm.toString(callData),
            string.concat("\",\n   \"success\": ", ok ? "true" : "false", ",\n   \"revertData\": \""),
            vm.toString(ok ? bytes("") : ret),
            "\",\n   \"storageUpdates\": \"",
            vm.toString(storageUpdates),
            "\"\n  }"
        );
        taskCount++;
    }

    function _encodeUpdates(address consumer, bytes32[] memory writes, Vm.Log[] memory logs)
        private
        view
        returns (bytes memory)
    {
        bytes32[] memory slots = _sortedUnique(writes);
        uint256 stores;
        for (uint256 i = 0; i < slots.length; i++) {
            if (vm.load(consumer, slots[i]) != bytes32(0)) stores++;
        }
        uint256 emitted;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == consumer) emitted++;
        }

        StateUpdateType[] memory types = new StateUpdateType[](stores + emitted);
        bytes[] memory datas = new bytes[](stores + emitted);
        uint256 n;
        for (uint256 i = 0; i < slots.length; i++) {
            bytes32 value = vm.load(consumer, slots[i]);
            if (value == bytes32(0)) continue;
            types[n] = StateUpdateType.STORE;
            datas[n++] = abi.encode(slots[i], value);
        }
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != consumer) continue;
            (types[n], datas[n]) = _encodeLog(logs[i]);
            n++;
        }
        return abi.encode(types, datas);
    }

    function _encodeLog(Vm.Log memory log) private pure returns (StateUpdateType, bytes memory) {
        bytes32[] memory t = log.topics;
        if (t.length == 0) return (StateUpdateType.LOG0, abi.encode(log.data));
        if (t.length == 1) return (StateUpdateType.LOG1, abi.encode(log.data, t[0]));
        if (t.length == 2) return (StateUpdateType.LOG2, abi.encode(log.data, t[0], t[1]));
        if (t.length == 3) return (StateUpdateType.LOG3, abi.encode(log.data, t[0], t[1], t[2]));
        return (StateUpdateType.LOG4, abi.encode(log.data, t[0], t[1], t[2], t[3]));
    }

    function _sortedUnique(bytes32[] memory input) private pure returns (bytes32[] memory out) {
        for (uint256 i = 1; i < input.length; i++) {
            bytes32 x = input[i];
            uint256 j = i;
            for (; j > 0 && input[j - 1] > x; j--) {
                input[j] = input[j - 1];
            }
            input[j] = x;
        }
        uint256 unique;
        for (uint256 i = 0; i < input.length; i++) {
            if (i == 0 || input[i] != input[i - 1]) input[unique++] = input[i];
        }
        out = new bytes32[](unique);
        for (uint256 i = 0; i < unique; i++) {
            out[i] = input[i];
        }
    }

    function _key(uint256 index, string memory field) private pure returns (string memory) {
        return string.concat(".vectors[", vm.toString(index), "]", field);
    }
}
