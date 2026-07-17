// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {GasKillerChatSharded} from "../../src/examples/onchain-llm/GasKillerChatSharded.sol";
import {GasKillerChat35Sharded} from "../../src/examples/onchain-llm/GasKillerChat35Sharded.sol";

import {MockBLSSignatureChecker} from "./OnchainLLM.t.sol";

/// @dev The additive prefix-resume latency surface both sharded consumers expose in
///      lockstep. Only CHAT_DOMAIN / CHAT_ROOT_SLOT / RESUME_DOMAIN differ between the
///      0.6B and 35B consumers — the ABI and behavior tested here are identical.
interface IShardedChat {
    function fulfil(uint32[] calldata promptIds, uint256 maxNewTokens, uint32[] calldata answerIds, bytes32 pipelineRoot)
        external;
    function fulfilResumed(
        uint32[] calldata promptIds,
        uint256 maxNewTokens,
        uint32[] calldata answerIds,
        bytes32 pipelineRoot,
        bytes32 prefixRoot
    ) external;
    function settlePrefix(uint32[] calldata prefixIds, bytes32 prefixRoot) external;

    function chatRoot() external view returns (bytes32);
    function stateTransitionCount() external view returns (uint256);
    function settledRoots(bytes32) external view returns (bool);

    function computeChatRoot(
        bytes32 previousRoot,
        uint32[] calldata promptIds,
        uint256 maxNewTokens,
        uint32[] calldata answerIds,
        bytes32 pipelineRoot
    ) external pure returns (bytes32);
    function computeResumedChatRoot(
        bytes32 previousRoot,
        uint32[] calldata promptIds,
        uint256 maxNewTokens,
        uint32[] calldata answerIds,
        bytes32 pipelineRoot,
        bytes32 prefixRoot
    ) external pure returns (bytes32);
}

/// @notice Shared test suite for the prefix-resume (warm-start) surface added to the sharded
///         settlement consumers. Run identically against both models via the concrete
///         subclasses at the bottom of this file.
abstract contract ShardedResumeBase is Test {
    address internal avsAddress = address(0x1234);

    IShardedChat internal chat;
    MockBLSSignatureChecker internal blsChecker;

    uint32[] internal promptIds;
    uint32[] internal answerIds;

    bytes32 internal pipelineRoot = keccak256("pipeline root fixture");
    bytes32 internal prefixRoot = keccak256("warm prefix root fixture");

    // Mirror the consumer events so vm.expectEmit can match by topic + data.
    event ChatAnswered(
        uint256 indexed transitionIndex,
        bytes32 indexed newRoot,
        bytes32 indexed pipelineRoot,
        uint32[] promptIds,
        uint32[] answerIds
    );
    event ChatResumed(
        uint256 indexed transitionIndex,
        bytes32 indexed newRoot,
        bytes32 indexed pipelineRoot,
        bytes32 prefixRoot,
        uint32[] promptIds,
        uint32[] answerIds
    );
    event PrefixSettled(uint256 indexed transitionIndex, bytes32 indexed prefixRoot, uint32[] prefixIds);

    /// @dev Deploy the concrete consumer under test.
    function _deploy(address _avs, address _bls) internal virtual returns (IShardedChat);

    function setUp() public {
        blsChecker = new MockBLSSignatureChecker();
        chat = _deploy(avsAddress, address(blsChecker));

        promptIds.push(1);
        promptIds.push(2);
        promptIds.push(3);
        answerIds.push(196);
        answerIds.push(73);
        answerIds.push(233);
    }

    // ------------------------------------------------------- existing fulfil unchanged

    /// @notice The original fulfil still folds via computeChatRoot + emits ChatAnswered.
    ///         A whole answer of `maxNewTokens` settles in this ONE call. It deliberately
    ///         does NOT record the pipeline root in settledRoots — the unbounded gas
    ///         profile allows one consumer storage write per settlement (the chat root);
    ///         resume anchors are admitted only via settlePrefix.
    function test_ExistingFulfilUnchanged() public {
        bytes32 expected = chat.computeChatRoot(chat.chatRoot(), promptIds, 3, answerIds, pipelineRoot);

        vm.expectEmit(true, true, true, true, address(chat));
        emit ChatAnswered(1, expected, pipelineRoot, promptIds, answerIds);
        chat.fulfil(promptIds, 3, answerIds, pipelineRoot);

        assertEq(chat.chatRoot(), expected, "chat root fold changed");
        assertEq(chat.stateTransitionCount(), 1, "transition not tracked");
        assertFalse(chat.settledRoots(pipelineRoot), "fulfil must not write settledRoots (single-slot rule)");
    }

    /// @notice The unbounded gas profile's shape rule: every settlement function writes
    ///         exactly TWO storage slots — the SDK's state-tracker counter plus ONE
    ///         consumer slot (chat root, or the settlePrefix anchor). A third write is
    ///         what made the round die live with "found 2 Store ops".
    function test_SettlementFunctionsWriteSingleConsumerSlot() public {
        vm.record();
        chat.fulfil(promptIds, 3, answerIds, pipelineRoot);
        (, bytes32[] memory w1) = vm.accesses(address(chat));
        assertEq(_uniqueCount(w1), 2, "fulfil must write tracker + chat root only");

        vm.record();
        chat.settlePrefix(promptIds, prefixRoot);
        (, bytes32[] memory w2) = vm.accesses(address(chat));
        assertEq(_uniqueCount(w2), 2, "settlePrefix must write tracker + anchor only");

        vm.record();
        chat.fulfilResumed(promptIds, 8, answerIds, keccak256("resumed pipeline"), prefixRoot);
        (, bytes32[] memory w3) = vm.accesses(address(chat));
        assertEq(_uniqueCount(w3), 2, "fulfilResumed must write tracker + chat root only");
    }

    function _uniqueCount(bytes32[] memory slots) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < slots.length; i++) {
            bool seen = false;
            for (uint256 j = 0; j < i; j++) {
                if (slots[j] == slots[i]) {
                    seen = true;
                    break;
                }
            }
            if (!seen) n++;
        }
    }

    // ------------------------------------------------------------- fulfilResumed guards

    /// @notice Resuming from a root that was never settled reverts.
    function test_FulfilResumedRevertsOnUnsettledPrefix() public {
        assertFalse(chat.settledRoots(prefixRoot), "prefix must start unsettled");
        vm.expectRevert(GasKillerChatSharded.PrefixNotSettled.selector);
        chat.fulfilResumed(promptIds, 3, answerIds, pipelineRoot, prefixRoot);
    }

    /// @notice A zero pipeline root is rejected before the prefix check.
    function test_FulfilResumedRejectsZeroPipeline() public {
        // admit the prefix so the only failing condition is the zero pipeline root
        chat.settlePrefix(promptIds, prefixRoot);
        vm.expectRevert(GasKillerChatSharded.MissingPipelineRoot.selector);
        chat.fulfilResumed(promptIds, 3, answerIds, bytes32(0), prefixRoot);
    }

    // --------------------------------------------------------- settlePrefix (warm admit)

    /// @notice settlePrefix rejects a zero prefix root.
    function test_SettlePrefixRejectsZeroRoot() public {
        vm.expectRevert(GasKillerChatSharded.MissingPipelineRoot.selector);
        chat.settlePrefix(promptIds, bytes32(0));
    }

    /// @notice settlePrefix admits a warm prefix root into settledRoots and emits PrefixSettled,
    ///         without folding the chat root (it is a pure anchor commit).
    function test_SettlePrefixAdmitsRoot() public {
        bytes32 warmPrefix = keccak256("prefill-only warm prefix");
        assertFalse(chat.settledRoots(warmPrefix), "warm prefix must start unsettled");
        bytes32 prevRoot = chat.chatRoot();

        vm.expectEmit(true, true, true, true, address(chat));
        emit PrefixSettled(1, warmPrefix, promptIds);
        chat.settlePrefix(promptIds, warmPrefix);

        assertTrue(chat.settledRoots(warmPrefix), "warm prefix not admitted");
        assertEq(chat.stateTransitionCount(), 1, "transition not tracked");
        assertEq(chat.chatRoot(), prevRoot, "settlePrefix must not fold the chat root");
    }

    /// @notice A warm prefix that no fulfil ever produced can be admitted via settlePrefix and
    ///         then resumed from — the coupling fix. Without settlePrefix this reverts.
    function test_SettlePrefixEnablesResume() public {
        bytes32 warmPrefix = keccak256("prefill-only warm prefix for resume");

        // Before admission, resuming from the warm prefix reverts.
        vm.expectRevert(GasKillerChatSharded.PrefixNotSettled.selector);
        chat.fulfilResumed(promptIds, 8, answerIds, pipelineRoot, warmPrefix);

        // Admit the committee-verified warm prefix, then resume succeeds.
        chat.settlePrefix(promptIds, warmPrefix);
        bytes32 prev = chat.chatRoot();
        bytes32 expected = chat.computeResumedChatRoot(prev, promptIds, 8, answerIds, pipelineRoot, warmPrefix);

        vm.expectEmit(true, true, true, true, address(chat));
        emit ChatResumed(2, expected, pipelineRoot, warmPrefix, promptIds, answerIds);
        chat.fulfilResumed(promptIds, 8, answerIds, pipelineRoot, warmPrefix);

        assertEq(chat.chatRoot(), expected, "resumed-from-warm-prefix fold mismatch");
        assertFalse(chat.settledRoots(pipelineRoot), "resume must not write settledRoots (single-slot rule)");
    }

    // ------------------------------------------------------------ fulfilResumed success

    /// @notice Once a prefix is admitted via settlePrefix, resuming from it succeeds,
    ///         folds under RESUME_DOMAIN, and emits ChatResumed.
    function test_FulfilResumedSucceedsAfterPrefixSettled() public {
        // Warm run: admit the fixed chat-template prefix via settlePrefix.
        chat.settlePrefix(promptIds, prefixRoot);
        assertTrue(chat.settledRoots(prefixRoot), "prefix not admitted by settlePrefix");

        bytes32 prev = chat.chatRoot();
        bytes32 expected = chat.computeResumedChatRoot(prev, promptIds, 8, answerIds, pipelineRoot, prefixRoot);

        vm.expectEmit(true, true, true, true, address(chat));
        emit ChatResumed(2, expected, pipelineRoot, prefixRoot, promptIds, answerIds);
        chat.fulfilResumed(promptIds, 8, answerIds, pipelineRoot, prefixRoot);

        assertEq(chat.chatRoot(), expected, "resumed fold mismatch");
        assertEq(chat.stateTransitionCount(), 2, "transition not tracked");
        assertFalse(chat.settledRoots(pipelineRoot), "resume must not write settledRoots (single-slot rule)");
    }

    /// @notice The resumed fold is unambiguous: same inputs through the resumed vs the
    ///         non-resumed path can never produce the same chat root.
    function test_ResumedRootDiffersFromNonResumed() public view {
        bytes32 prev = chat.chatRoot();
        bytes32 nonResumed = chat.computeChatRoot(prev, promptIds, 8, answerIds, pipelineRoot);
        bytes32 resumed = chat.computeResumedChatRoot(prev, promptIds, 8, answerIds, pipelineRoot, prefixRoot);
        assertTrue(resumed != nonResumed, "resumed root must differ from non-resumed root");

        // Even a resume whose prefixRoot equals the pipelineRoot stays distinct from a
        // fresh fold, because RESUME_DOMAIN != CHAT_DOMAIN.
        bytes32 resumedSelf = chat.computeResumedChatRoot(prev, promptIds, 8, answerIds, pipelineRoot, pipelineRoot);
        assertTrue(resumedSelf != nonResumed, "domain separation broken");
    }

    /// @notice Chained warm starts require an explicit settlePrefix of the completed
    ///         exchange's root — settlement functions no longer auto-admit anchors.
    function test_ChainedResumeNeedsExplicitSettlePrefix() public {
        chat.settlePrefix(promptIds, prefixRoot);
        chat.fulfilResumed(promptIds, 8, answerIds, pipelineRoot, prefixRoot);

        bytes32 nextPipeline = keccak256("second resumed pipeline");
        // The resumed pipelineRoot was NOT auto-admitted: chaining off it reverts...
        vm.expectRevert(GasKillerChatSharded.PrefixNotSettled.selector);
        chat.fulfilResumed(promptIds, 8, answerIds, nextPipeline, pipelineRoot);

        // ...until it is admitted explicitly (one extra pure-commit round).
        chat.settlePrefix(promptIds, pipelineRoot);
        chat.fulfilResumed(promptIds, 8, answerIds, nextPipeline, pipelineRoot);
        assertFalse(chat.settledRoots(nextPipeline), "chained resume must not write settledRoots");
    }
}

/// @notice Run the suite against the 0.6B sharded consumer.
contract GasKillerChatShardedResumeTest is ShardedResumeBase {
    function _deploy(address _avs, address _bls) internal override returns (IShardedChat) {
        return IShardedChat(address(new GasKillerChatSharded(_avs, _bls)));
    }
}

/// @notice Run the identical suite against the 35B sharded consumer (lockstep ABI/behavior).
contract GasKillerChat35ShardedResumeTest is ShardedResumeBase {
    function _deploy(address _avs, address _bls) internal override returns (IShardedChat) {
        return IShardedChat(address(new GasKillerChat35Sharded(_avs, _bls)));
    }
}
