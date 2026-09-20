// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";

import {StateUpdateType} from "../../src/StateChangeHandlerLib.sol";
import {GKVM_ADDRESS, GKVM_OK_TAG} from "../../src/gkvm/GkVm.sol";
import {GkVmUnavailable, GkGuestTrap} from "../../src/gkvm/GkVmErrors.sol";
import {GkVmFfiShim} from "../../src/gkvm/testing/GkVmFfiShim.sol";
import {GasKillerChatNative} from "../../src/examples/onchain-llm-native/GasKillerChatNative.sol";
import {GkAnswer} from "../../src/examples/onchain-llm-native/gen/GkAnswer.sol";

import {MockBLSSignatureChecker} from "./OnchainLLM.t.sol";

/// @dev guest/answer.py, recomputed in Solidity: the oracle the real guest is held to, and the
///      body of the stand-in precompile the always-on tests run against
library AnswerReference {
    uint256 internal constant MASK31 = 0x7FFFFFFF;
    uint256 internal constant MAX_NEW = 64;

    function vocab() internal pure returns (string[32] memory) {
        return [
            "<eos>",
            "the",
            "gas",
            "killer",
            "operator",
            "signs",
            "one",
            "slot",
            "guest",
            "runs",
            "native",
            "and",
            "every",
            "honest",
            "node",
            "agrees",
            "on",
            "a",
            "single",
            "answer",
            "because",
            "cycles",
            "are",
            "counted",
            "not",
            "timed",
            "so",
            "state",
            "diffs",
            "stay",
            "small",
            "forever"
        ];
    }

    function respond(uint256[] memory promptIds, uint256 maxNew)
        internal
        pure
        returns (string memory answer, uint256[] memory ids)
    {
        require(maxNew <= MAX_NEW, "answer: max_new > 64");
        uint256 state = promptIds.length;
        for (uint256 i = 0; i < promptIds.length; ++i) {
            state = (state * 31 + (promptIds[i] & MASK31)) & MASK31;
        }
        string[32] memory words = vocab();
        ids = new uint256[](maxNew);
        uint256 n;
        bytes memory text;
        for (; n < maxNew; ++n) {
            state = (state * 1103515245 + 12345) & MASK31;
            uint256 tok = (state >> 16) % 32;
            if (tok == 0) break;
            ids[n] = tok;
            text = n == 0 ? bytes(words[tok]) : bytes.concat(text, " ", bytes(words[tok]));
        }
        assembly ("memory-safe") {
            mstore(ids, n)
        }
        answer = string(text);
    }
}

/// @dev Speaks the precompile's wire format for exactly one program: GkAnswer's
contract AnswerStandInGkVm {
    fallback(bytes calldata input) external returns (bytes memory) {
        require(input.length >= 64, "stand-in: short header");
        require(bytes32(input[:32]) == GkAnswer.PROGRAM_HASH, "stand-in: unknown program");
        require(bytes32(input[32:64]) == bytes32(0), "stand-in: unexpected artifact");
        (uint256[] memory promptIds, uint256 maxNew) = abi.decode(input[64:], (uint256[], uint256));
        (string memory answer, uint256[] memory ids) = AnswerReference.respond(promptIds, maxNew);
        return abi.encodePacked(GKVM_OK_TAG, abi.encode(answer, ids));
    }
}

/// @notice The consumer's shape, against a stand-in precompile (no ffi, runs everywhere)
contract GasKillerChatNativeTest is Test {
    /// @dev keccak256("gasKiller.stateTracker") - 1 (StateTracker slot, gate-exempt)
    bytes32 internal constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;

    address internal avsAddress = address(0x1234);

    GasKillerChatNative internal chat;
    MockBLSSignatureChecker internal blsChecker;
    uint256[] internal promptIds;

    event ChatAnswered(
        uint256 indexed transitionIndex,
        bytes32 indexed newRoot,
        uint256[] promptIds,
        string answer,
        uint256[] answerIds
    );

    function setUp() public {
        blsChecker = new MockBLSSignatureChecker();
        chat = new GasKillerChatNative(avsAddress, address(blsChecker), address(new AnswerStandInGkVm()), bytes32(0));
        promptIds = [uint256(9707), 11, 151644];
    }

    function test_DryRunDecodesTheGuestsTuple() public view {
        (string memory answer, uint256[] memory ids) = chat.dryRun(promptIds, 6);
        (string memory expected, uint256[] memory expectedIds) = AnswerReference.respond(promptIds, 6);
        assertEq(answer, expected);
        assertEq(ids, expectedIds);
        assertGt(ids.length, 0, "vector generates nothing");
    }

    function test_AskWritesSingleAppSlot() public {
        (string memory answer, uint256[] memory answerIds) = chat.dryRun(promptIds, 6);
        bytes32 expectedRoot = chat.computeChatRoot(chat.chatRoot(), promptIds, answer);

        vm.record();
        vm.expectEmit(true, true, true, true, address(chat));
        emit ChatAnswered(1, expectedRoot, promptIds, answer, answerIds);
        assertEq(chat.ask(promptIds, 6), answer);

        (, bytes32[] memory writes) = vm.accesses(address(chat));
        assertGt(writes.length, 0, "no writes recorded");
        for (uint256 i = 0; i < writes.length; ++i) {
            assertTrue(writes[i] == chat.CHAT_ROOT_SLOT() || writes[i] == TRACKER_SLOT, "unexpected storage write");
        }
        assertEq(chat.chatRoot(), expectedRoot, "chat root not updated");
        assertEq(chat.stateTransitionCount(), 1, "transition not tracked");
    }

    function test_VerifyAndUpdateAppliesChatDiff() public {
        vm.roll(100);

        (string memory answer, uint256[] memory answerIds) = chat.dryRun(promptIds, 6);
        uint256 transitionIndex = chat.stateTransitionCount();
        bytes32 newRoot = chat.computeChatRoot(chat.chatRoot(), promptIds, answer);

        StateUpdateType[] memory types = new StateUpdateType[](2);
        bytes[] memory args = new bytes[](2);
        types[0] = StateUpdateType.STORE;
        args[0] = abi.encode(chat.CHAT_ROOT_SLOT(), newRoot);
        types[1] = StateUpdateType.LOG3;
        args[1] = abi.encode(
            abi.encode(promptIds, answer, answerIds),
            keccak256("ChatAnswered(uint256,bytes32,uint256[],string,uint256[])"),
            bytes32(transitionIndex + 1),
            newRoot
        );
        bytes memory storageUpdates = abi.encode(types, args);
        bytes32 msgHash =
            sha256(abi.encode(transitionIndex, address(chat), GasKillerChatNative.ask.selector, storageUpdates));

        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory sig;
        vm.expectEmit(true, true, true, true, address(chat));
        emit ChatAnswered(transitionIndex + 1, newRoot, promptIds, answer, answerIds);
        chat.verifyAndUpdate(
            msgHash,
            hex"00",
            uint32(block.number - 1),
            storageUpdates,
            transitionIndex,
            GasKillerChatNative.ask.selector,
            sig
        );

        assertEq(chat.chatRoot(), newRoot, "diff not applied");
    }

    /// @dev Same domain, same fold: for ids that fit both, the native root is GasKillerChat's
    function test_RootFoldMatchesGasKillerChat() public view {
        uint32[] memory narrow = new uint32[](promptIds.length);
        for (uint256 i = 0; i < narrow.length; ++i) {
            narrow[i] = uint32(promptIds[i]);
        }
        bytes32 v2Root = keccak256(
            abi.encode(
                keccak256("gaskiller.llm.chat.v1"),
                bytes32(uint256(7)),
                keccak256(abi.encodePacked(narrow)),
                keccak256(bytes("hi"))
            )
        );
        assertEq(chat.computeChatRoot(bytes32(uint256(7)), promptIds, "hi"), v2Root);
    }

    /// @dev Production wiring: no precompile on a real chain, so the tracked function reverts
    ///      instead of settling anything — the answer only ever comes from the operators' diff
    function test_UnavailableWithoutThePrecompile() public {
        GasKillerChatNative prod = new GasKillerChatNative(avsAddress, address(blsChecker), address(0), bytes32(0));
        assertEq(prod.gkvm(), GKVM_ADDRESS);
        assertEq(prod.PROGRAM_HASH(), GkAnswer.PROGRAM_HASH);

        vm.expectRevert(GkVmUnavailable.selector);
        prod.dryRun(promptIds, 6);
        vm.expectRevert(GkVmUnavailable.selector);
        prod.ask(promptIds, 6);
    }

    function test_AGuestFailureBubblesOutOfAsk() public {
        vm.expectRevert(bytes("answer: max_new > 64"));
        chat.ask(promptIds, 65);
        assertEq(chat.chatRoot(), bytes32(0));
    }
}

/// @notice The same consumer over the REAL guest: answer.py's image under `gk-run`, behind
///         GkVmFfiShim. Skips unless GK_RUN names the binary; needs the ELF `gk build` leaves in
///         cache/ (it is not committed):  make -C tools/gk native-example-check
contract GasKillerChatNativeFfiTest is Test {
    string internal constant ANSWER_ELF = "cache/gkvm/build/native-answer/guest.elf";
    bytes32 internal constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;

    GasKillerChatNative internal chat;
    GkVmFfiShim internal shim;
    bool internal gkRunMissing;

    event ChatAnswered(
        uint256 indexed transitionIndex,
        bytes32 indexed newRoot,
        uint256[] promptIds,
        string answer,
        uint256[] answerIds
    );

    modifier needsGkRun() {
        vm.skip(gkRunMissing);
        _;
    }

    function setUp() public {
        string memory gkRun = vm.envOr("GK_RUN", string(""));
        gkRunMissing = bytes(gkRun).length == 0;
        if (gkRunMissing) return;
        shim = new GkVmFfiShim(gkRun);
        // the committed binding and the image built from the committed answer.py are one program
        assertEq(shim.installProgram(ANSWER_ELF), GkAnswer.PROGRAM_HASH, "rebuilt guest != committed binding");
        chat =
            new GasKillerChatNative(address(0x1234), address(new MockBLSSignatureChecker()), address(shim), bytes32(0));
    }

    function test_GuestMatchesTheSolidityReference() public needsGkRun {
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (9707, 11, 151644);
        _assertMatches(ids, 6);
        _assertMatches(ids, 64);
        _assertMatches(ids, 0);
        _assertMatches(new uint256[](0), 16);
        // ids past 2^31 (and past a machine word): mpz in the guest, masked the same way
        (ids[0], ids[1], ids[2]) = (type(uint256).max, 1 << 200, 0x80000000);
        _assertMatches(ids, 24);
    }

    function test_AskSettlesTheRealGuestsAnswerInOneSlot() public needsGkRun {
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (42, 7);
        (string memory answer, uint256[] memory answerIds) = AnswerReference.respond(ids, 12);
        bytes32 expectedRoot = chat.computeChatRoot(bytes32(0), ids, answer);

        vm.record();
        vm.expectEmit(true, true, true, true, address(chat));
        emit ChatAnswered(1, expectedRoot, ids, answer, answerIds);
        chat.ask(ids, 12);

        (, bytes32[] memory writes) = vm.accesses(address(chat));
        for (uint256 i = 0; i < writes.length; ++i) {
            assertTrue(writes[i] == chat.CHAT_ROOT_SLOT() || writes[i] == TRACKER_SLOT, "unexpected storage write");
        }
        assertEq(chat.chatRoot(), expectedRoot);
    }

    function test_AnUncaughtGuestExceptionRevertsAsk() public needsGkRun {
        vm.expectPartialRevert(GkGuestTrap.selector);
        chat.ask(new uint256[](0), 65);
    }

    function _assertMatches(uint256[] memory ids, uint256 maxNew) internal view {
        (string memory answer, uint256[] memory answerIds) = chat.dryRun(ids, maxNew);
        (string memory expected, uint256[] memory expectedIds) = AnswerReference.respond(ids, maxNew);
        assertEq(answer, expected, "answer text");
        assertEq(answerIds, expectedIds, "answer ids");
    }
}
