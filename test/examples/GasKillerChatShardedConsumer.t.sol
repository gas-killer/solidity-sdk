// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";

import {StateUpdateType} from "../../src/StateChangeHandlerLib.sol";
import {GasKillerChatSharded} from "../../src/examples/onchain-llm/GasKillerChatSharded.sol";

import {MockBLSSignatureChecker} from "./OnchainLLM.t.sol";

/// @notice Tests the sharded-inference settlement consumer: a pure commit whose
///         correctness is attested by the operator quorum after segment-chain
///         verification, never by on-chain execution.
contract GasKillerChatShardedConsumerTest is Test {
    /// @dev keccak256("gasKiller.stateTracker") - 1 (StateTracker slot, gate-exempt)
    bytes32 internal constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;

    address internal avsAddress = address(0x1234);

    GasKillerChatSharded internal chat;
    MockBLSSignatureChecker internal blsChecker;

    uint32[] internal promptIds;
    uint32[] internal answerIds;
    bytes32 internal pipelineRoot = keccak256("pipeline root fixture");

    event ChatAnswered(
        uint256 indexed transitionIndex,
        bytes32 indexed newRoot,
        bytes32 indexed pipelineRoot,
        uint32[] promptIds,
        uint32[] answerIds
    );

    function setUp() public {
        blsChecker = new MockBLSSignatureChecker();
        chat = new GasKillerChatSharded(avsAddress, address(blsChecker));

        promptIds.push(1);
        promptIds.push(2);
        promptIds.push(3);
        answerIds.push(196);
        answerIds.push(73);
        answerIds.push(233);
    }

    function test_FulfilWritesSingleAppSlot() public {
        bytes32 expectedRoot = chat.computeChatRoot(chat.chatRoot(), promptIds, 3, answerIds, pipelineRoot);

        vm.record();
        vm.expectEmit(true, true, true, true, address(chat));
        emit ChatAnswered(1, expectedRoot, pipelineRoot, promptIds, answerIds);
        chat.fulfil(promptIds, 3, answerIds, pipelineRoot);

        // settledRoots is the first declared state var (slot 0); fulfil now also records
        // settledRoots[pipelineRoot] = true so the root can serve as a resume prefix.
        bytes32 settledSlot = keccak256(abi.encode(pipelineRoot, uint256(0)));

        (, bytes32[] memory writes) = vm.accesses(address(chat));
        assertGt(writes.length, 0, "no writes recorded");
        for (uint256 i = 0; i < writes.length; ++i) {
            assertTrue(
                writes[i] == chat.CHAT_ROOT_SLOT() || writes[i] == TRACKER_SLOT || writes[i] == settledSlot,
                "unexpected storage write"
            );
        }
        assertTrue(chat.settledRoots(pipelineRoot), "pipeline root not marked settled");
        assertEq(chat.chatRoot(), expectedRoot, "chat root not updated");
        assertEq(chat.stateTransitionCount(), 1, "transition not tracked");
    }

    function test_FulfilChainsAcrossExchanges() public {
        chat.fulfil(promptIds, 3, answerIds, pipelineRoot);
        bytes32 rootAfterFirst = chat.chatRoot();

        bytes32 secondPipeline = keccak256("second pipeline");
        bytes32 expectedRoot = chat.computeChatRoot(rootAfterFirst, promptIds, 5, answerIds, secondPipeline);
        chat.fulfil(promptIds, 5, answerIds, secondPipeline);

        assertEq(chat.chatRoot(), expectedRoot, "second exchange not chained onto the first");
        assertEq(chat.stateTransitionCount(), 2, "transition count wrong");
    }

    function test_FulfilRejectsZeroPipelineRoot() public {
        vm.expectRevert(GasKillerChatSharded.MissingPipelineRoot.selector);
        chat.fulfil(promptIds, 3, answerIds, bytes32(0));
    }

    function test_VerifyAndUpdateAppliesShardedDiff() public {
        vm.roll(100);

        uint256 transitionIndex = chat.stateTransitionCount();
        bytes32 newRoot = chat.computeChatRoot(chat.chatRoot(), promptIds, 3, answerIds, pipelineRoot);

        StateUpdateType[] memory types = new StateUpdateType[](2);
        bytes[] memory args = new bytes[](2);
        types[0] = StateUpdateType.STORE;
        args[0] = abi.encode(chat.CHAT_ROOT_SLOT(), newRoot);
        types[1] = StateUpdateType.LOG4;
        args[1] = abi.encode(
            abi.encode(promptIds, answerIds),
            keccak256("ChatAnswered(uint256,bytes32,bytes32,uint32[],uint32[])"),
            bytes32(transitionIndex + 1),
            newRoot,
            pipelineRoot
        );
        bytes memory storageUpdates = abi.encode(types, args);
        bytes32 msgHash =
            sha256(abi.encode(transitionIndex, address(chat), GasKillerChatSharded.fulfil.selector, storageUpdates));

        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory sig;
        vm.expectEmit(true, true, true, true, address(chat));
        emit ChatAnswered(transitionIndex + 1, newRoot, pipelineRoot, promptIds, answerIds);
        chat.verifyAndUpdate(
            msgHash,
            hex"00",
            uint32(block.number - 1),
            storageUpdates,
            transitionIndex,
            GasKillerChatSharded.fulfil.selector,
            sig
        );

        assertEq(chat.chatRoot(), newRoot, "diff not applied");
    }
}
