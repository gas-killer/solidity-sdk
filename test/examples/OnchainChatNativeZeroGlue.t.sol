// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, Vm} from "forge-std/Test.sol";

import {StateUpdateType} from "../../src/StateChangeHandlerLib.sol";
import {GKVM_ADDRESS} from "../../src/gkvm/GkVm.sol";
import {GkVmFfiShim} from "../../src/gkvm/testing/GkVmFfiShim.sol";
import {GasKillerChatNative} from "../../src/examples/onchain-llm-native/GasKillerChatNative.sol";
import {GkAnswer} from "../../src/examples/onchain-llm-native/gen/GkAnswer.sol";

import {MockBLSSignatureChecker} from "./OnchainLLM.t.sol";
import {AnswerReference} from "./OnchainChatNative.t.sol";

/// @dev The forge leg of the zero-glue check (`answer.py → gk build → forge test → local executor`).
///      Every task is one `ask` against a FRESH GasKillerChatNative wired to GkVmFfiShim, i.e. the
///      real answer.py image under `gk-run`; what the task did to the consumer (net storage
///      writes, then logs) is encoded exactly as gas-analyzer encodes an extracted payload:
///      `abi.encode(StateUpdateType[], bytes[])`, stores slot-sorted ahead of logs. The result is
///      `test/fixtures/gkvm/native_tasks.json`, together with the consumer's PRODUCTION runtime
///      code (gkvm = GKVM_ADDRESS); gas-analyzer's evmsketch suite (`src/tests/gkvm_native.rs`)
///      runs that bytecode and that calldata through its local executor against the real
///      precompile with the same image installed, and requires the same bytes.
///      Nothing between answer.py's type hints and these bytes is written by hand: the consumer
///      calls the generated binding, the binding calls GkVm.exec, the guest's codec is frozen in
///      by `gk build`.
///      `make -C tools/gk zero-glue` regenerates the fixture, `zero-glue-check` runs the whole
///      chain. Skips unless GK_RUN names the binary (gkvm-ffi profile).
contract GasKillerChatNativeZeroGlueTest is Test {
    string internal constant ANSWER_ELF = "cache/gkvm/build/native-answer/guest.elf";
    string internal constant OUT_DIR = "cache/gkvm/zero-glue";

    GkVmFfiShim internal shim;
    MockBLSSignatureChecker internal blsChecker;
    bool internal gkRunMissing;
    string internal tasks;
    uint256 internal taskCount;

    function setUp() public {
        string memory gkRun = vm.envOr("GK_RUN", string(""));
        gkRunMissing = bytes(gkRun).length == 0;
        if (gkRunMissing) return;
        shim = new GkVmFfiShim(gkRun);
        blsChecker = new MockBLSSignatureChecker();
        // the committed binding and the image built from the committed answer.py are one program
        assertEq(shim.installProgram(ANSWER_ELF), GkAnswer.PROGRAM_HASH, "rebuilt guest != committed binding");
    }

    function testWriteNativeTasks() public {
        vm.skip(gkRunMissing);

        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (9707, 11, 151644);
        _task("doc-vector", ids, 6);
        _task("max-new-64", ids, 64);
        _task("max-new-0", ids, 0);
        _task("empty-prompt", new uint256[](0), 16);
        // ids past 2^31 (and past a machine word): mpz in the guest
        (ids[0], ids[1], ids[2]) = (type(uint256).max, 1 << 200, 0x80000000);
        _task("wide-ids", ids, 24);
        // answer.py raises ValueError: the typed trap bubbles out of `ask`, nothing to apply
        _task("max-new-65-traps", ids, 65);
        assertEq(taskCount, 6);

        GasKillerChatNative production =
            new GasKillerChatNative(address(0x1234), address(blsChecker), address(0), bytes32(0));
        assertEq(production.gkvm(), GKVM_ADDRESS);
        string memory json = string.concat(
            "{\n \"gkvmAddress\": \"",
            vm.toString(GKVM_ADDRESS),
            "\",\n \"programHash\": \"",
            vm.toString(GkAnswer.PROGRAM_HASH),
            "\",\n \"consumerCode\": \"",
            vm.toString(address(production).code),
            "\",\n \"tasks\": [\n",
            tasks,
            "\n ]\n}\n"
        );
        vm.createDir(OUT_DIR, true);
        vm.writeFile(string.concat(OUT_DIR, "/native_tasks.json"), json);
    }

    /// @dev One task against a fresh consumer (pre-state of every slot `ask` writes is zero, so a
    ///      written slot changed iff it is non-zero now)
    function _task(string memory name, uint256[] memory ids, uint256 maxNew) private {
        GasKillerChatNative chat =
            new GasKillerChatNative(address(0x1234), address(blsChecker), address(shim), bytes32(0));
        bytes memory callData = abi.encodeCall(GasKillerChatNative.ask, (ids, maxNew));

        vm.record();
        vm.recordLogs();
        (bool ok, bytes memory ret) = address(chat).call(callData);
        (, bytes32[] memory writes) = vm.accesses(address(chat));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        if (ok) {
            // the recorded answer is the Solidity reference's, not merely whatever the guest said
            (string memory expected,) = AnswerReference.respond(ids, maxNew);
            assertEq(abi.decode(ret, (string)), expected, name);
            assertEq(chat.chatRoot(), chat.computeChatRoot(bytes32(0), ids, expected), name);
        }

        // A reverted task records its revert data and NO payload: forge sees only what survived
        // the revert, while gas-analyzer's extraction of a reverted call is revert-unaware by
        // design (its struct-log semantics keep the rolled-back `trackState` bump) — that
        // payload is the executor's to define, and its suite pins it. Parity for a failure is
        // the revert data.
        tasks = string.concat(
            tasks,
            taskCount == 0 ? "" : ",\n",
            string.concat("  {\n   \"name\": \"", name, "\",\n   \"calldata\": \""),
            vm.toString(callData),
            string.concat("\",\n   \"success\": ", ok ? "true" : "false", ",\n   \"revertData\": \""),
            vm.toString(ok ? bytes("") : ret),
            ok
                ? string.concat(
                    "\",\n   \"storageUpdates\": \"", vm.toString(_encodeUpdates(address(chat), writes, logs))
                )
                : "",
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
}
