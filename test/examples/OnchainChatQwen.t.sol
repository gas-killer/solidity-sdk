// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {GKVM_OK_TAG} from "../../src/gkvm/GkVm.sol";
import {GkVmUnavailable} from "../../src/gkvm/GkVmErrors.sol";
import {GasKillerChatQwen} from "../../src/examples/onchain-llm-native/GasKillerChatQwen.sol";
import {GkQwen} from "../../src/examples/onchain-llm-native/gen/GkQwen.sol";
import {MockBLSSignatureChecker} from "./OnchainLLM.t.sol";

/// @dev Speaks the precompile's wire format for the qwen guest: checks the header and the
///      guest's wire ABI (packedConfig, uint32 ids, maxNew) and answers a canned tuple. The
///      real guest over the real weights runs in the service's e2e (GK_E2E_GUEST=qwen) and in
///      gas-analyzer's flagship workflow; this pins the consumer's marshalling.
contract QwenStandInGkVm {
    bytes32 internal immutable root;
    bytes32[3] internal config;

    constructor(bytes32 _root, bytes32[3] memory _config) {
        root = _root;
        config = _config;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        require(input.length >= 64, "stand-in: short header");
        require(bytes32(input[:32]) == GkQwen.PROGRAM_HASH, "stand-in: unknown program");
        require(bytes32(input[32:64]) == root, "stand-in: unexpected artifact");
        (bytes32[3] memory packed, uint32[] memory ids, uint256 maxNew) =
            abi.decode(input[64:], (bytes32[3], uint32[], uint256));
        require(packed[0] == config[0] && packed[1] == config[1] && packed[2] == config[2], "stand-in: config");
        // the consumer must send Qwen3Engine.chat's canonical encoding, nothing else
        require(keccak256(input[64:]) == keccak256(abi.encode(packed, ids, maxNew)), "stand-in: encoding");
        require(maxNew == 2, "stand-in: maxNew");
        // echo the (narrowed) prompt ids back as the answer ids: pins both conversions
        return abi.encodePacked(GKVM_OK_TAG, abi.encode(string("Ethereum is"), ids));
    }
}

contract GasKillerChatQwenTest is Test {
    bytes32 internal constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    bytes32 internal constant ROOT = 0xad3abf5617f9c7e1862d7a3e0a2cf368939e09ae69f094bb2e3bf42279e99115;

    GasKillerChatQwen internal chat;
    QwenStandInGkVm internal standIn;
    MockBLSSignatureChecker internal blsChecker;
    uint256[] internal promptIds;

    event ChatAnswered(
        uint256 indexed transitionIndex,
        bytes32 indexed newRoot,
        uint256[] promptIds,
        string answer,
        uint256[] answerIds
    );

    function config() internal pure returns (bytes32[3] memory) {
        return [
            bytes32(0x04000c001c100800800002518004000101000000000000000000000000000000),
            bytes32(0x0000000010c6f7a10000000016a09e6600000000239791f10000000000000000),
            bytes32(0x00182bc20002505d0002505b0000000000000000000000000000000000000000)
        ];
    }

    function setUp() public {
        blsChecker = new MockBLSSignatureChecker();
        standIn = new QwenStandInGkVm(ROOT, config());
        chat = new GasKillerChatQwen(address(0x1234), address(blsChecker), address(standIn), ROOT, config());
        promptIds = [
            uint256(151644), 872, 198, 3838, 374, 33946, 30, 151645, 198, 151644, 77091, 198, 151667, 271, 151668, 271
        ];
    }

    function test_AskMarshalsTheGuestsWireAbiAndWritesOneSlot() public {
        bytes32 expectedRoot = chat.computeChatRoot(bytes32(0), promptIds, "Ethereum is");

        vm.record();
        vm.expectEmit(true, true, true, true, address(chat));
        emit ChatAnswered(1, expectedRoot, promptIds, "Ethereum is", promptIds);
        assertEq(chat.ask(promptIds, 2), "Ethereum is");

        (, bytes32[] memory writes) = vm.accesses(address(chat));
        for (uint256 i = 0; i < writes.length; ++i) {
            assertTrue(writes[i] == chat.CHAT_ROOT_SLOT() || writes[i] == TRACKER_SLOT, "unexpected storage write");
        }
        assertEq(chat.chatRoot(), expectedRoot);
        assertEq(chat.stateTransitionCount(), 1);
    }

    function test_AWideIdIsNotAToken() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = uint256(type(uint32).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(GasKillerChatQwen.TokenIdOutOfRange.selector, ids[0]));
        chat.ask(ids, 1);
    }

    function test_UnavailableWithoutThePrecompile() public {
        GasKillerChatQwen prod = new GasKillerChatQwen(address(0x1234), address(blsChecker), address(0), ROOT, config());
        assertEq(prod.PROGRAM_HASH(), GkQwen.PROGRAM_HASH);
        vm.expectRevert(GkVmUnavailable.selector);
        prod.dryRun(promptIds, 8);
        vm.expectRevert(GkVmUnavailable.selector);
        prod.ask(promptIds, 8);
    }
}
