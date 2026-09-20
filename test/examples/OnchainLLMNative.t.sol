// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {GKVM_ADDRESS, GKVM_OK_TAG} from "../../src/gkvm/GkVm.sol";
import {GkVmUnavailable, GkGuestTrap} from "../../src/gkvm/GkVmErrors.sol";
import {GkVmFfiShim} from "../../src/gkvm/testing/GkVmFfiShim.sol";
import {GasKillerLLMNative} from "../../src/examples/onchain-llm-native/GasKillerLLMNative.sol";
import {GkStories260k} from "../../src/examples/onchain-llm-native/gen/GkStories260k.sol";

import {MockBLSSignatureChecker} from "./OnchainLLM.t.sol";

/// @dev Manifest-v3 root of [weights.bin, tokenizer.bin] — the donor's committed hex fixtures
///      (test/fixtures/onchain-llm) as binary files; `make -C tools/gk native-stories-artifacts`
///      writes them and prints this root, and gk-run refuses the mount when they disagree.
bytes32 constant STORIES_ARTIFACT_ROOT = 0x384048263b9737fd43295ad0f557f3a9eca62997a3214e94ac658a2e7a385b14;

/// @dev Speaks the precompile's wire format for GkStories260k and answers every request with
///      one canned story — the consumer's shape is what the always-on tests are about
contract StoriesStandInGkVm {
    string internal story;
    uint256[] internal tokens;

    constructor(string memory _story, uint256[] memory _tokens) {
        story = _story;
        tokens = _tokens;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        require(input.length >= 64, "stand-in: short header");
        require(bytes32(input[:32]) == GkStories260k.PROGRAM_HASH, "stand-in: unknown program");
        require(bytes32(input[32:64]) == STORIES_ARTIFACT_ROOT, "stand-in: unexpected artifact");
        abi.decode(input[64:], (string, uint256));
        return abi.encodePacked(GKVM_OK_TAG, abi.encode(story, tokens));
    }
}

/// @notice The consumer's shape, against a stand-in precompile (no ffi, runs everywhere)
contract GasKillerLLMNativeTest is Test {
    using stdJson for string;

    /// @dev keccak256("gasKiller.stateTracker") - 1 (StateTracker slot, gate-exempt)
    bytes32 internal constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;

    GasKillerLLMNative internal llm;
    MockBLSSignatureChecker internal blsChecker;
    string internal prompt;
    string internal story;
    uint256[] internal tokens;

    event StoryTold(
        uint256 indexed transitionIndex, bytes32 indexed newRoot, string prompt, string story, uint256[] tokens
    );

    function setUp() public {
        string memory vectors = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/onchain-llm/vectors.json"));
        prompt = vectors.readString(".prompt");
        story = vectors.readString(".storyShort");
        tokens = vectors.readUintArray(".genShort");
        blsChecker = new MockBLSSignatureChecker();
        llm = new GasKillerLLMNative(
            address(0x1234), address(blsChecker), address(new StoriesStandInGkVm(story, tokens)), STORIES_ARTIFACT_ROOT
        );
    }

    function test_DryRunDecodesTheGuestsTuple() public view {
        (string memory got, uint256[] memory gotTokens) = llm.dryRun(prompt, 32);
        assertEq(got, story);
        assertEq(gotTokens, tokens);
    }

    function test_TellStoryWritesSingleAppSlot() public {
        bytes32 expectedRoot = llm.computeStoryRoot(llm.storyRoot(), prompt, story);

        vm.record();
        vm.expectEmit(true, true, true, true, address(llm));
        emit StoryTold(1, expectedRoot, prompt, story, tokens);
        assertEq(llm.tellStory(prompt, 32), story);

        (, bytes32[] memory writes) = vm.accesses(address(llm));
        assertGt(writes.length, 0, "no writes recorded");
        for (uint256 i = 0; i < writes.length; ++i) {
            assertTrue(writes[i] == llm.STORY_ROOT_SLOT() || writes[i] == TRACKER_SLOT, "unexpected storage write");
        }
        assertEq(llm.storyRoot(), expectedRoot, "story root not updated");
    }

    /// @dev Same domain, same fold as the donor's GasKillerLLM.computeStoryRoot
    function test_RootFoldIsTheDonors() public view {
        bytes32 donorRoot = keccak256(
            abi.encode(
                keccak256("gaskiller.llm.story.v1"), bytes32(uint256(7)), keccak256(bytes("a")), keccak256(bytes("b"))
            )
        );
        assertEq(llm.computeStoryRoot(bytes32(uint256(7)), "a", "b"), donorRoot);
    }

    /// @dev Production wiring: no precompile on a real chain, so nothing settles from a direct call
    function test_UnavailableWithoutThePrecompile() public {
        GasKillerLLMNative prod =
            new GasKillerLLMNative(address(0x1234), address(blsChecker), address(0), STORIES_ARTIFACT_ROOT);
        assertEq(prod.gkvm(), GKVM_ADDRESS);
        assertEq(prod.PROGRAM_HASH(), GkStories260k.PROGRAM_HASH);

        vm.expectRevert(GkVmUnavailable.selector);
        prod.dryRun(prompt, 32);
        vm.expectRevert(GkVmUnavailable.selector);
        prod.tellStory(prompt, 32);
    }
}

/// @notice The same consumer over the REAL guest: stories260k.py's image under `gk-run`, behind
///         GkVmFfiShim, with the donor's blobs mounted as artifacts — held to the donor's own
///         vectors (tools/reference.py ≡ Llama2.sol ≡ llama2.c run.c). Skips unless GK_RUN names
///         the binary; needs the ELF and the artifact files in cache/ (neither is committed):
///         make -C tools/gk native-stories-check
contract GasKillerLLMNativeFfiTest is Test {
    using stdJson for string;

    string internal constant STORIES_ELF = "cache/gkvm/build/native-stories/guest.elf";
    string internal constant STORIES_BLOBS =
        "cache/gkvm/artifacts/stories260k/weights.bin,cache/gkvm/artifacts/stories260k/tokenizer.bin";
    bytes32 internal constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;

    GasKillerLLMNative internal llm;
    GkVmFfiShim internal shim;
    string internal vectors;
    string internal prompt;
    bool internal gkRunMissing;

    event StoryTold(
        uint256 indexed transitionIndex, bytes32 indexed newRoot, string prompt, string story, uint256[] tokens
    );

    modifier needsGkRun() {
        vm.skip(gkRunMissing);
        _;
    }

    function setUp() public {
        string memory gkRun = vm.envOr("GK_RUN", string(""));
        gkRunMissing = bytes(gkRun).length == 0;
        if (gkRunMissing) return;
        vectors = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/onchain-llm/vectors.json"));
        prompt = vectors.readString(".prompt");
        shim = new GkVmFfiShim(gkRun);
        // the committed binding and the image built from the committed stories260k.py are one program
        assertEq(shim.installProgram(STORIES_ELF), GkStories260k.PROGRAM_HASH, "rebuilt guest != committed binding");
        // the guest reads the whole bundle once, front to back
        shim.installArtifact(STORIES_ARTIFACT_ROOT, STORIES_BLOBS, "sequential");
        llm = new GasKillerLLMNative(
            address(0x1234), address(new MockBLSSignatureChecker()), address(shim), STORIES_ARTIFACT_ROOT
        );
    }

    /// @dev The donor's 32-token vector: same ids, same text (≈ 9.5G guest cycles)
    function test_ShortStoryIsTheDonorsBitForBit() public needsGkRun {
        (string memory story, uint256[] memory tokens) = llm.dryRun(prompt, 32);
        assertEq(tokens, vectors.readUintArray(".genShort"), "token mismatch");
        assertEq(story, vectors.readString(".storyShort"), "story mismatch");
    }

    /// @dev The donor's 200-token vector — the 10,467,959,687-gas story. ≈ 100G guest cycles
    ///      (minutes on the interpreter tier), so opt-in: GK_STORIES_LONG=1
    function test_LongStoryIsTheDonorsBitForBit() public needsGkRun {
        vm.skip(!vm.envOr("GK_STORIES_LONG", false));
        (string memory story, uint256[] memory tokens) = llm.dryRun(prompt, 200);
        assertEq(tokens, vectors.readUintArray(".genLong"), "token mismatch");
        assertEq(story, vectors.readString(".storyLong"), "story mismatch");
    }

    function test_TellStorySettlesTheRealGuestsStoryInOneSlot() public needsGkRun {
        uint256[] memory short = vectors.readUintArray(".genShort");
        uint256[] memory tokens = new uint256[](4);
        for (uint256 i = 0; i < 4; ++i) {
            tokens[i] = short[i];
        }
        // greedy decode: a 4-token story is the 32-token story's first four tokens
        string memory story = ", there was a";
        bytes32 expectedRoot = llm.computeStoryRoot(bytes32(0), prompt, story);

        vm.record();
        vm.expectEmit(true, true, true, true, address(llm));
        emit StoryTold(1, expectedRoot, prompt, story, tokens);
        llm.tellStory(prompt, 4);

        (, bytes32[] memory writes) = vm.accesses(address(llm));
        for (uint256 i = 0; i < writes.length; ++i) {
            assertTrue(writes[i] == llm.STORY_ROOT_SLOT() || writes[i] == TRACKER_SLOT, "unexpected storage write");
        }
        assertEq(llm.storyRoot(), expectedRoot);
    }

    /// @dev A Python `str` is UTF-8: a prompt the donor would tokenize byte by byte is an
    ///      uncaught UnicodeError here — the deterministic runtime trap, before any page is read
    function test_ANonUtf8PromptTrapsDeterministically() public needsGkRun {
        bytes memory notUtf8 = hex"ff";
        vm.expectPartialRevert(GkGuestTrap.selector);
        llm.tellStory(string(notUtf8), 4);
    }
}
