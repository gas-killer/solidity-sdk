// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {StateUpdateType} from "../../src/StateChangeHandlerLib.sol";
import {DataContractLib} from "../../src/examples/onchain-llm/DataContractLib.sol";
import {FlyAMM, IFlyPolicyParams} from "../../src/examples/onchain-fly/FlyAMM.sol";
import {FlyEngine} from "../../src/examples/onchain-fly/FlyEngine.sol";
import {FlyPolicy} from "../../src/examples/onchain-fly/FlyPolicy.sol";
import {FlyTypes} from "../../src/examples/onchain-fly/FlyTypes.sol";

import {MockBLSSignatureChecker} from "./OnchainLLM.t.sol";

contract TestToken is ERC20 {
    constructor(string memory n) ERC20(n, n) {
        _mint(msg.sender, 1e30);
    }
}

/// @notice FlyPolicy + FlyAMM on the synthetic graph: the single-slot regression, verifyAndUpdate
///         applying the [STORE, LOG3] diff, the commitment chain, and the pool's clamps (HANDOFF §7.3 tests 3, 4, 6).
contract FlyAMMTest is Test {
    using stdJson for string;

    /// @dev keccak256("gasKiller.stateTracker") - 1 (StateTracker slot, gate-exempt)
    bytes32 internal constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    uint256 internal constant CHUNK = 24_575;

    address internal avsAddress = address(0x1234);
    address internal trader = address(0xBEEF);

    TestToken internal baseTok;
    TestToken internal quoteTok;
    FlyAMM internal pool;
    FlyEngine internal engine;
    FlyPolicy internal policy;
    MockBLSSignatureChecker internal blsChecker;
    string internal vectors;
    bytes32[3] internal cfg;
    address internal graphRoot;
    address internal warmRoot;

    event FlyDecided(
        uint256 indexed transitionIndex,
        bytes32 indexed flyWord,
        bytes32 indexed spikeRoot,
        FlyTypes.FlyState next,
        bytes frame,
        FlyTypes.Readout readout
    );

    function setUp() public {
        vm.roll(1000);
        string memory root = vm.projectRoot();
        vectors = vm.readFile(string.concat(root, "/test/fixtures/onchain-fly/vectors.json"));
        string[] memory words = vectors.readStringArray(".packedConfig");
        for (uint256 i = 0; i < 3; ++i) {
            cfg[i] = bytes32(vm.parseUint(words[i]));
        }
        bytes[] memory blobs = new bytes[](3);
        blobs[0] = vm.readFileBinary(string.concat(root, "/test/fixtures/onchain-fly/ptr.bin"));
        blobs[1] = vm.readFileBinary(string.concat(root, "/test/fixtures/onchain-fly/edges.bin"));
        blobs[2] = vm.readFileBinary(string.concat(root, "/test/fixtures/onchain-fly/meta.bin"));
        graphRoot = _directory(blobs);
        bytes[] memory warm = new bytes[](1);
        warm[0] = vm.parseBytes(vectors.readString(".warm.stateOut"));
        warmRoot = _directory(warm);

        baseTok = new TestToken("BASE");
        quoteTok = new TestToken("QUOTE");
        pool = new FlyAMM(baseTok, quoteTok);
        blsChecker = new MockBLSSignatureChecker();
        engine = new FlyEngine();
        policy = new FlyPolicy(avsAddress, address(blsChecker), engine, graphRoot, warmRoot, cfg, pool);
        pool.setPolicy(IFlyPolicyParams(address(policy)));

        baseTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(pool), type(uint256).max);
        pool.addLiquidity(1_000e18, 2_000e18, address(this));
        baseTok.transfer(trader, 1e24);
        quoteTok.transfer(trader, 1e24);
        vm.startPrank(trader);
        baseTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ fixtures

    function _directory(bytes[] memory blobs) internal returns (address) {
        bytes memory pageBytes;
        for (uint256 b = 0; b < blobs.length; ++b) {
            for (uint256 at = 0; at < blobs[b].length; at += CHUNK) {
                uint256 len = blobs[b].length - at;
                if (len > CHUNK) len = CHUNK;
                bytes memory s = new bytes(len);
                for (uint256 i = 0; i < len; ++i) {
                    s[i] = blobs[b][at + i];
                }
                pageBytes = abi.encodePacked(pageBytes, DataContractLib.write(s));
            }
        }
        address page = DataContractLib.write(pageBytes);
        return DataContractLib.write(abi.encodePacked(page));
    }

    function _genesisState() internal pure returns (FlyTypes.FlyState memory s) {
        s.memoryRoot = keccak256("");
    }

    /// @dev Trade through a few windows so the pool has a closed window with a histogram
    function _tradeWindows() internal {
        vm.startPrank(trader);
        for (uint256 w = 0; w < 3; ++w) {
            vm.roll(block.number + pool.WINDOW_BLOCKS());
            pool.swap(true, 10e18, 0, trader);
            vm.roll(block.number + 3);
            pool.swap(false, 2e18, 0, trader);
        }
        vm.roll(block.number + pool.WINDOW_BLOCKS());
        pool.swap(true, 1e18, 0, trader); // closes the previous window
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ pool

    function test_WindowsCloseAndObserveIsStorageOnly() public {
        _tradeWindows();
        FlyTypes.Observation memory o = pool.observe();
        assertGt(o.windowId, 0, "no closed window");
        assertGt(o.buyQuote[15], 0, "newest bin empty");
        assertGt(o.sellQuote[15], 0, "newest sell bin empty");
        assertGt(o.volRef, 0, "volRef");
        assertGt(o.twapQ64, 0, "twap");
        assertGt(o.feeIncomeQuote, 0, "fee income");
        // observe() is a function of closed-window storage only: rolling blocks changes nothing
        vm.roll(block.number + 7);
        FlyTypes.Observation memory o2 = pool.observe();
        assertEq(keccak256(abi.encode(o)), keccak256(abi.encode(o2)), "observe depends on block env");
    }

    function test_DefaultFeeWithoutDecision() public view {
        assertEq(pool.effectiveFee(true), pool.DEFAULT_FEE_BPS());
        assertEq(pool.effectiveFee(false), pool.DEFAULT_FEE_BPS());
    }

    function test_PoolClampsOutOfRangeWord() public {
        _tradeWindows();
        uint32 wid = pool.currentWindowId();
        // fee 5000 bps (out of band) → default
        vm.store(address(policy), policy.FLY_SLOT(), bytes32(_word(5000, 0, 0, wid, 1)));
        assertEq(pool.effectiveFee(true), pool.DEFAULT_FEE_BPS(), "out-of-band fee not defaulted");
        // fee 40, skew +200 (out of band) → skew clamped to ±30
        vm.store(address(policy), policy.FLY_SLOT(), bytes32(_word(40, 200, 0, wid, 1)));
        assertEq(pool.effectiveFee(true), 70, "buy skew clamp");
        assertEq(pool.effectiveFee(false), 10, "sell skew clamp");
        // fee 95, skew +30 → clamped to MAX on buys, 65 on sells
        vm.store(address(policy), policy.FLY_SLOT(), bytes32(_word(95, 30, 0, wid, 1)));
        assertEq(pool.effectiveFee(true), 100, "max fee clamp");
        assertEq(pool.effectiveFee(false), 65, "sell side");
        // stale decision (older than MAX_LAG_WINDOWS) → default
        vm.store(address(policy), policy.FLY_SLOT(), bytes32(_word(40, 10, 0, wid - 3, 1)));
        assertEq(pool.effectiveFee(true), pool.DEFAULT_FEE_BPS(), "stale not defaulted");
        // rebalance flag overrides skew toward the side that moves spot away from TWAP
        vm.store(address(policy), policy.FLY_SLOT(), bytes32(_word(40, -10, 1, wid, 1)));
        uint16 fb = pool.effectiveFee(true);
        uint16 fs = pool.effectiveFee(false);
        assertTrue((fb == 70 && fs == 10) || (fb == 10 && fs == 70), "rebalance surcharge");
    }

    function _word(uint16 fee, int16 skew, uint8 flags, uint32 wid, uint24 epoch) internal pure returns (uint256 w) {
        w = uint256(epoch) << 160 | uint256(wid) << 184 | uint256(flags) << 216 | uint256(uint16(skew)) << 224
            | uint256(fee) << 240;
    }

    function test_SwapChargesEffectiveFee() public {
        _tradeWindows();
        uint32 wid = pool.currentWindowId();
        vm.store(address(policy), policy.FLY_SLOT(), bytes32(_word(100, 0, 0, wid, 1)));
        uint256 rB = pool.reserveBase();
        uint256 rQ = pool.reserveQuote();
        uint256 amountIn = 100e18;
        uint256 inAfter = amountIn * (10_000 - 100) / 10_000;
        uint256 expected = rB * inAfter / (rQ + inAfter);
        vm.prank(trader);
        uint256 out = pool.swap(true, amountIn, 0, trader);
        assertEq(out, expected, "fee not applied");
    }

    // ------------------------------------------------------------------ policy

    function test_DecideRequiresClosedWindow() public {
        FlyTypes.FlyState memory prev = _genesisState();
        vm.expectRevert(FlyPolicy.WindowNotClosed.selector);
        policy.decide(prev);
    }

    function test_DecideRejectsWrongPrev() public {
        _tradeWindows();
        FlyTypes.FlyState memory prev = _genesisState();
        prev.epoch = 7; // does not match the zero word in FLY_SLOT
        vm.expectRevert(FlyPolicy.StateMismatch.selector);
        policy.decide(prev);
    }

    function test_DecideWritesSingleAppSlot() public {
        _tradeWindows();
        FlyTypes.FlyState memory prev = _genesisState();
        (
            FlyTypes.FlyState memory next,
            bytes32 word,
            bytes memory frame,
            FlyTypes.Readout memory r,
            bytes32 spikeRoot
        ) = policy.dryRun(prev);
        assertEq(next.epoch, 1, "epoch");
        assertEq(next.windowId, pool.observe().windowId, "window");
        assertTrue(next.feeBps >= 5 && next.feeBps <= 100, "fee band");
        assertTrue(next.skewBps >= -30 && next.skewBps <= 30, "skew band");

        vm.record();
        vm.expectEmit(true, true, true, true, address(policy));
        emit FlyDecided(1, word, spikeRoot, next, frame, r);
        policy.decide(prev);

        (, bytes32[] memory writes) = vm.accesses(address(policy));
        assertGt(writes.length, 0, "no writes recorded");
        for (uint256 i = 0; i < writes.length; ++i) {
            assertTrue(writes[i] == policy.FLY_SLOT() || writes[i] == TRACKER_SLOT, "unexpected storage write");
        }
        (, bytes32[] memory poolWrites) = vm.accesses(address(pool));
        assertEq(poolWrites.length, 0, "decide wrote to the pool");
        assertEq(policy.flyWord(), word, "word not stored");
        assertEq(policy.stateTransitionCount(), 1, "transition not tracked");

        // the pool now reads the fly's parameters
        (uint16 fee, int16 skew,, uint32 wid,) = policy.params();
        assertEq(fee, next.feeBps);
        assertEq(skew, next.skewBps);
        assertEq(wid, next.windowId);
        uint16 eff = pool.effectiveFee(true);
        assertTrue(eff >= 5 && eff <= 100, "effective fee band");

        // second decision on the same closed window is refused; a new window enables it
        vm.expectRevert(FlyPolicy.WindowNotClosed.selector);
        policy.decide(next);
        vm.roll(block.number + pool.WINDOW_BLOCKS());
        vm.prank(trader);
        pool.swap(false, 1e18, 0, trader);
        (FlyTypes.FlyState memory next2, bytes32 word2,,,) = policy.dryRun(next);
        assertEq(next2.prevWord, word, "commitment chain");
        assertEq(next2.epoch, 2, "epoch 2");
        policy.decide(next);
        assertEq(policy.flyWord(), word2, "second word");
    }

    function test_VerifyAndUpdateAppliesDecisionDiff() public {
        _tradeWindows();
        FlyTypes.FlyState memory prev = _genesisState();
        (
            FlyTypes.FlyState memory next,
            bytes32 word,
            bytes memory frame,
            FlyTypes.Readout memory r,
            bytes32 spikeRoot
        ) = policy.dryRun(prev);
        uint256 transitionIndex = policy.stateTransitionCount();

        StateUpdateType[] memory types = new StateUpdateType[](2);
        bytes[] memory args = new bytes[](2);
        types[0] = StateUpdateType.STORE;
        args[0] = abi.encode(policy.FLY_SLOT(), word);
        types[1] = StateUpdateType.LOG4; // three indexed params + the signature topic
        args[1] = abi.encode(
            abi.encode(next, frame, r),
            keccak256(
                "FlyDecided(uint256,bytes32,bytes32,(bytes32,uint32,uint32,uint16,int16,uint8,uint32[4],bytes32),bytes,(uint32[4],uint32[4],uint32[14],uint64))"
            ),
            bytes32(transitionIndex + 1),
            word,
            spikeRoot
        );
        bytes memory storageUpdates = abi.encode(types, args);
        bytes32 msgHash =
            sha256(abi.encode(transitionIndex, address(policy), FlyPolicy.decide.selector, storageUpdates));

        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory sig;
        vm.expectEmit(true, true, true, true, address(policy));
        emit FlyDecided(transitionIndex + 1, word, spikeRoot, next, frame, r);
        policy.verifyAndUpdate(
            msgHash, hex"00", uint32(block.number - 1), storageUpdates, transitionIndex, FlyPolicy.decide.selector, sig
        );
        assertEq(policy.flyWord(), word, "diff not applied");
        (uint16 fee,,, uint32 wid,) = policy.params();
        assertEq(fee, next.feeBps);
        assertEq(wid, next.windowId);
    }

    function test_PackRoundTrip() public view {
        FlyTypes.FlyState memory s = _genesisState();
        s.epoch = 3;
        s.windowId = 77;
        s.feeBps = 42;
        s.skewBps = -7;
        s.flags = 5;
        s.rateMilliHz = [uint32(1), 2, 3, 4];
        uint256 w = uint256(policy.pack(s));
        assertEq(w >> 240, 42);
        assertEq(int16(uint16(w >> 224)), -7);
        assertEq((w >> 216) & 0xff, 5);
        assertEq((w >> 184) & 0xffffffff, 77);
        assertEq((w >> 160) & 0xffffff, 3);
        assertEq(w & ((1 << 160) - 1), uint256(uint160(uint256(keccak256(abi.encode(s))))));
    }
}
