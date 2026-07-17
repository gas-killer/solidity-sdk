// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";

import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {GasKillerChat} from "../src/examples/onchain-llm/GasKillerChat.sol";

/// @title OperatorReplayScript
/// @notice The full Gas Killer lifecycle for the on-chain LLM against a live RPC, in
///         one command: simulate the tracked `ask` off-chain (exactly what operators
///         sign over), extract the single-STORE + LOG3 diff, and apply it on-chain via
///         `verifyAndUpdate` — inference never executes in the applying transaction.
/// @dev This is the operator-rehearsal path (mock quorum): the target GasKillerChat
///      must be wired to a signature checker that accepts (e.g.
///      `test/examples/OnchainLLM.t.sol:MockBLSSignatureChecker`). With a real AVS
///      the service performs these same steps (see service#313's harness).
///
///      Env:
///        CHAT_ADDRESS     the deployed GasKillerChat
///        PROMPT_IDS       comma-separated token ids (chat template applied off-chain)
///        MAX_NEW_TOKENS   generation budget (default 8)
///
///      Run (against anvil or a testnet):
///        CHAT_ADDRESS=0x.. PROMPT_IDS=151644,872,... forge script \
///          script/OperatorReplay.s.sol --rpc-url $RPC --private-key $PK --broadcast -vv
contract OperatorReplayScript is Script {
    function run() public {
        GasKillerChat chat = GasKillerChat(vm.envAddress("CHAT_ADDRESS"));
        uint256[] memory raw = vm.envUint("PROMPT_IDS", ",");
        uint256 maxNew = vm.envOr("MAX_NEW_TOKENS", uint256(8));
        uint32[] memory promptIds = new uint32[](raw.length);
        for (uint256 i = 0; i < raw.length; ++i) {
            promptIds[i] = uint32(raw[i]);
        }

        // ---- operator side: simulate the tracked function, derive the diff ----
        console.log("simulating ask() with %d prompt ids, maxNew=%d ...", raw.length, maxNew);
        (string memory answer, uint32[] memory answerIds) = chat.dryRun(promptIds, maxNew);
        console.log("model answer: %s", answer);

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
        console.log("payload: %d bytes; msgHash:", storageUpdates.length);
        console.logBytes32(msgHash);

        // ---- chain side: quorum-verified application, no inference on-chain ----
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory sig;
        vm.startBroadcast();
        chat.verifyAndUpdate(
            msgHash, hex"00", uint32(block.number - 1), storageUpdates, transitionIndex, GasKillerChat.ask.selector, sig
        );
        vm.stopBroadcast();

        require(chat.chatRoot() == newRoot, "chat root not applied");
        console.log("verifyAndUpdate applied. transition=%d newRoot:", chat.stateTransitionCount());
        console.logBytes32(newRoot);
    }
}
