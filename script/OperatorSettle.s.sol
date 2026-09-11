// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";

import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {GasKillerChat} from "../src/examples/onchain-llm/GasKillerChat.sol";

/// @notice Settlement half of the operator lifecycle: build the single-STORE + LOG3
///         payload for an ALREADY-SIMULATED `ask()` and apply it via `verifyAndUpdate`.
/// @dev `OperatorReplay.s.sol` re-runs `dryRun` inside the script, which is fine on a
///      local node holding all 24,385 data contracts but impossible over a public RPC
///      (hundreds of Ggas, 597 MB of code fetches). Operators simulate against their
///      own node and only ship the diff; this script is that step. Feed it the answer
///      and token ids produced by the simulation (see e2e_directory_dryrun.sh).
///
///      env: CHAT_ADDRESS, PROMPT_IDS (csv), ANSWER (string), ANSWER_IDS (csv)
contract OperatorSettleScript is Script {
    function run() public {
        GasKillerChat chat = GasKillerChat(vm.envAddress("CHAT_ADDRESS"));
        uint32[] memory promptIds = _u32(vm.envUint("PROMPT_IDS", ","));
        uint32[] memory answerIds = _u32(vm.envUint("ANSWER_IDS", ","));
        string memory answer = vm.envString("ANSWER");

        uint256 transitionIndex = chat.stateTransitionCount();
        bytes32 newRoot = chat.computeChatRoot(chat.chatRoot(), promptIds, answer);

        StateUpdateType[] memory types = new StateUpdateType[](2);
        bytes[] memory args = new bytes[](2);
        types[0] = StateUpdateType.STORE;
        args[0] = abi.encode(chat.CHAT_ROOT_SLOT(), newRoot);
        types[1] = StateUpdateType.LOG3;
        args[1] = abi.encode(
            abi.encode(promptIds, answer, answerIds),
            keccak256("ChatAnswered(uint256,bytes32,uint32[],string,uint32[])"),
            bytes32(transitionIndex + 1),
            newRoot
        );
        bytes memory storageUpdates = abi.encode(types, args);
        bytes32 msgHash = sha256(abi.encode(transitionIndex, address(chat), GasKillerChat.ask.selector, storageUpdates));
        console.log("consumer: %s  transitionIndex: %d", address(chat), transitionIndex);
        console.log("payload: %d bytes; msgHash:", storageUpdates.length);
        console.logBytes32(msgHash);
        console.log("newRoot:");
        console.logBytes32(newRoot);

        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory sig;
        vm.startBroadcast();
        chat.verifyAndUpdate(
            msgHash, hex"00", uint32(block.number - 1), storageUpdates, transitionIndex, GasKillerChat.ask.selector, sig
        );
        vm.stopBroadcast();

        require(chat.chatRoot() == newRoot, "chat root not applied");
        console.log("verifyAndUpdate applied. transition=%d", chat.stateTransitionCount());
    }

    function _u32(uint256[] memory raw) internal pure returns (uint32[] memory out) {
        out = new uint32[](raw.length);
        for (uint256 i = 0; i < raw.length; ++i) {
            out[i] = uint32(raw[i]);
        }
    }
}
