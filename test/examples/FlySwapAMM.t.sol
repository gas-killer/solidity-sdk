// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";

import {StateUpdateType} from "../../src/StateChangeHandlerLib.sol";
import {DataContractLib} from "../../src/examples/onchain-llm/DataContractLib.sol";
import {FlyEngine} from "../../src/examples/onchain-fly/FlyEngine.sol";
import {FlySwapPool, IFlySwapPolicyFills} from "../../src/examples/onchain-fly/FlySwapPool.sol";
import {FlySwapPolicy} from "../../src/examples/onchain-fly/FlySwapPolicy.sol";
import {FlySwapRasterizer} from "../../src/examples/onchain-fly/FlySwapRasterizer.sol";
import {FlyTypes} from "../../src/examples/onchain-fly/FlyTypes.sol";

import {TestToken} from "./FlyAMM.t.sol";
import {MockBLSSignatureChecker} from "./OnchainLLM.t.sol";

/// @notice v2 per-swap fly pricing on the synthetic graph (HANDOFF_PER_SWAP §8): escrow + queue, settle
///         writes only policy slots, the diff applies through verifyAndUpdate, applyNext fills at the fly fee,
///         order/idempotence/refunds, clamps, LP ops between reference and apply, rate chaining, vectors.
contract FlySwapAMMTest is Test {
    using stdJson for string;

    bytes32 internal constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    uint256 internal constant CHUNK = 24_575;

    address internal avsAddress = address(0x1234);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    TestToken internal baseTok;
    TestToken internal quoteTok;
    FlySwapPool internal pool;
    FlyEngine internal engine;
    FlySwapRasterizer internal rasterizer;
    FlySwapPolicy internal policy;
    MockBLSSignatureChecker internal blsChecker;
    string internal vectors;
    bytes32[3] internal cfg;
    address internal graphRoot;
    address internal warmRoot;

    function setUp() public {
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
        pool = new FlySwapPool(baseTok, quoteTok);
        blsChecker = new MockBLSSignatureChecker();
        engine = new FlyEngine();
        rasterizer = new FlySwapRasterizer();
        policy = new FlySwapPolicy(avsAddress, address(blsChecker), engine, rasterizer, graphRoot, warmRoot, cfg, pool);
        pool.setPolicy(IFlySwapPolicyFills(address(policy)));

        baseTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(pool), type(uint256).max);
        pool.addLiquidity(1_000e18, 2_000e18, address(this));
        for (uint256 i = 0; i < 2; ++i) {
            address t = i == 0 ? alice : bob;
            baseTok.transfer(t, 1e24);
            quoteTok.transfer(t, 1e24);
            vm.startPrank(t);
            baseTok.approve(address(pool), type(uint256).max);
            quoteTok.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
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

    function _status(uint64 id) internal view returns (uint8 st) {
        (,, st,,,) = pool.intents(id);
    }

    /// @dev x·y=k quote for a buy of `amountIn` quote at the fly fee `effFee` on the CURRENT reserves
    function _quoteBuy(uint256 amountIn, uint256 effFee) internal view returns (uint256) {
        uint256 rB = pool.reserveBase();
        uint256 rQ = pool.reserveQuote();
        uint256 inAfter = amountIn * (10_000 - effFee) / 10_000;
        return rB * inAfter / (rQ + inAfter);
    }

    function _effFee(uint64 id) internal view returns (uint256) {
        (uint16 fee, int16 skew,,,) = policy.fillOf(id);
        return uint256(int256(uint256(fee)) + skew);
    }

    function _genesis() internal view returns (FlyTypes.FlyStateV2 memory) {
        return policy.genesisState();
    }

    function _submit(address who, bool buy, uint256 amountIn, uint256 minOut, uint32 expiry)
        internal
        returns (uint64 id)
    {
        vm.prank(who);
        id = pool.submit(buy, amountIn, minOut, expiry);
    }

    /// @dev Render the settle diff exactly as the operators would ([STORE fills..., STORE decided, STORE fly, LOG4 per intent, LOG3 settled])
    function _settleViaVerifyAndUpdate(FlyTypes.FlyStateV2 memory prev)
        internal
        returns (FlyTypes.FlyStateV2 memory next)
    {
        (FlySwapPolicy.Round memory rd, bytes32 word) = policy.dryRun(prev);
        uint256 n = rd.fillWords.length;
        uint256 transitionIndex = policy.stateTransitionCount();
        StateUpdateType[] memory types = new StateUpdateType[](2 * n + 3);
        bytes[] memory args = new bytes[](2 * n + 3);
        for (uint256 k = 0; k < n; ++k) {
            types[k] = StateUpdateType.STORE;
            args[k] = abi.encode(policy.fillSlot(rd.from + uint64(k)), rd.fillWords[k]);
        }
        types[n] = StateUpdateType.STORE;
        args[n] = abi.encode(policy.DECIDED_SLOT(), bytes32(uint256(rd.next.decidedThrough)));
        types[n + 1] = StateUpdateType.STORE;
        args[n + 1] = abi.encode(policy.FLY_SLOT(), word);
        for (uint256 k = 0; k < n; ++k) {
            types[n + 2 + k] = StateUpdateType.LOG4;
            args[n + 2 + k] = abi.encode(
                abi.encode(rd.obs[k], rd.readouts[k]),
                keccak256(
                    "FlyIntentDecided(uint64,bytes32,bytes32,(uint64,bool,uint64,uint64,uint64,uint32,uint64[16],uint64[16],uint64,uint128,uint128,uint64,uint64),(uint32[4],uint32[4],uint32[14],uint64))"
                ),
                bytes32(uint256(rd.from + uint64(k))),
                rd.fillWords[k],
                rd.spikeRoots[k]
            );
        }
        types[2 * n + 2] = StateUpdateType.LOG3;
        args[2 * n + 2] = abi.encode(
            abi.encode(rd.next),
            keccak256("FlySettled(uint256,bytes32,(bytes32,uint32,uint64,uint8,uint32[4],bytes32))"),
            bytes32(transitionIndex + 1),
            word
        );
        bytes memory storageUpdates = abi.encode(types, args);
        bytes32 msgHash =
            sha256(abi.encode(transitionIndex, address(policy), FlySwapPolicy.settle.selector, storageUpdates));
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory sig;
        vm.roll(block.number + 1);
        policy.verifyAndUpdate(
            msgHash,
            hex"00",
            uint32(block.number - 1),
            storageUpdates,
            transitionIndex,
            FlySwapPolicy.settle.selector,
            sig
        );
        assertEq(policy.flyWord(), word, "diff not applied");
        next = rd.next;
    }

    // ------------------------------------------------------------------ 1. queue + apply guard

    function test_SubmitEscrowsAndQueues() public {
        uint256 before = quoteTok.balanceOf(alice);
        uint64 id = _submit(alice, true, 10e18, 0, 0);
        assertEq(id, 1);
        assertEq(quoteTok.balanceOf(alice), before - 10e18, "escrow");
        assertEq(quoteTok.balanceOf(address(pool)), 2_000e18 + 10e18, "pool holds escrow");
        (uint64 applied, uint64 tail) = pool.pendingRange();
        assertEq(applied, 0);
        assertEq(tail, 1);
        (address owner, bool buy, uint8 status, uint32 expiry, uint128 amountIn, uint128 minOut) = pool.intents(1);
        assertEq(owner, alice);
        assertTrue(buy);
        assertEq(status, pool.PENDING());
        assertEq(expiry, 0);
        assertEq(uint256(amountIn), 10e18);
        assertEq(uint256(minOut), 0);
        assertEq(pool.reserveQuote(), 2_000e18, "reserves untouched until apply");
    }

    function test_ApplyRequiresDecision() public {
        _submit(alice, true, 10e18, 0, 0);
        vm.expectRevert(FlySwapPool.NotDecided.selector);
        pool.applyNext();
        // applyUpTo stops silently at an undecided intent
        vm.prank(bob);
        assertEq(pool.applyUpTo(5), 0);
    }

    // ------------------------------------------------------------------ 2. settle writes only policy slots

    function test_SettleWritesOnlyPolicySlots() public {
        _submit(alice, true, 10e18, 0, 0);
        _submit(bob, false, 2e18, 0, 0);
        FlyTypes.FlyStateV2 memory prev = _genesis();
        (FlySwapPolicy.Round memory rd,) = policy.dryRun(prev);
        assertEq(rd.fillWords.length, 1, "MAX_BATCH = 1 from cfg");
        vm.record();
        policy.settle(prev);
        (, bytes32[] memory writes) = vm.accesses(address(policy));
        assertGt(writes.length, 0);
        for (uint256 i = 0; i < writes.length; ++i) {
            bool ok = writes[i] == policy.FLY_SLOT() || writes[i] == policy.DECIDED_SLOT() || writes[i] == TRACKER_SLOT
                || writes[i] == policy.fillSlot(1);
            assertTrue(ok, "unexpected policy slot written");
        }
        (, bytes32[] memory poolWrites) = vm.accesses(address(pool));
        assertEq(poolWrites.length, 0, "settle wrote pool storage");
        assertEq(policy.decidedThrough(), 1);
        (uint16 fee, int16 skew,, uint32 epoch, bool decided) = policy.fillOf(1);
        assertTrue(decided);
        assertEq(epoch, 1);
        assertTrue(fee >= 5 && fee <= 100 && skew >= -30 && skew <= 30, "band");
        (,,,, bool decided2) = policy.fillOf(2);
        assertFalse(decided2, "second intent not yet decided");
    }

    // ------------------------------------------------------------------ 3. diff applies via verifyAndUpdate, then applyNext fills

    function test_SettleDiffAppliesViaVerifyAndUpdate() public {
        uint64 id = _submit(alice, true, 10e18, 0, 0);
        FlyTypes.FlyStateV2 memory next = _settleViaVerifyAndUpdate(_genesis());
        assertEq(next.decidedThrough, 1);
        (,,,, bool decided) = policy.fillOf(id);
        assertTrue(decided);
        uint256 effFee = _effFee(id);
        uint256 expected = _quoteBuy(10e18, effFee);
        uint256 before = baseTok.balanceOf(alice);
        vm.prank(bob); // permissionless
        assertEq(pool.applyNext(), id);
        assertEq(baseTok.balanceOf(alice) - before, expected, "paid out at the fly fee");
        (uint128 amountOut, uint16 feeBps, uint32 epoch) = pool.fills(id);
        assertEq(uint256(amountOut), expected);
        assertEq(feeBps, effFee);
        assertEq(epoch, 1);
        assertEq(_status(id), pool.FILLED());
        assertEq(pool.reserveQuote(), 2_000e18 + 10e18);
        assertEq(pool.histEpoch(), 1);
    }

    // ------------------------------------------------------------------ 4. order, idempotence, refunds

    function test_ApplyInOrderOnly() public {
        _submit(alice, true, 10e18, 0, 0);
        _submit(bob, false, 2e18, 0, 0);
        FlyTypes.FlyStateV2 memory s1 = _settleViaVerifyAndUpdate(_genesis()); // decides #1 only (batch 1)
        assertEq(pool.applyNext(), 1);
        vm.expectRevert(FlySwapPool.NotDecided.selector);
        pool.applyNext(); // #2 not decided
        FlyTypes.FlyStateV2 memory s2 = _settleViaVerifyAndUpdate(s1);
        assertEq(s2.decidedThrough, 2);
        assertEq(s2.epoch, 2);
        assertEq(pool.applyNext(), 2);
        assertEq(_status(2), pool.FILLED());
    }

    function test_ApplyIdempotent() public {
        _submit(alice, true, 10e18, 0, 0);
        _settleViaVerifyAndUpdate(_genesis());
        pool.applyNext();
        vm.expectRevert(FlySwapPool.NothingToApply.selector);
        pool.applyNext();
        assertEq(pool.applied(), 1);
    }

    function test_RefundOnMinOut() public {
        uint64 id = _submit(alice, true, 10e18, 100e18, 0); // impossible minOut
        _settleViaVerifyAndUpdate(_genesis());
        uint256 before = quoteTok.balanceOf(alice);
        pool.applyNext();
        assertEq(quoteTok.balanceOf(alice), before + 10e18, "refunded");
        assertEq(_status(id), pool.REFUNDED());
        assertEq(pool.reserveQuote(), 2_000e18, "reserves untouched");
    }

    function test_RefundOnExpiry() public {
        uint64 id = _submit(alice, false, 2e18, 0, 1); // expires after epoch 1
        _submit(bob, true, 1e18, 0, 0);
        FlyTypes.FlyStateV2 memory s1 = _settleViaVerifyAndUpdate(_genesis()); // epoch 1 decides #1
        FlyTypes.FlyStateV2 memory s2 = _settleViaVerifyAndUpdate(s1); // epoch 2 decides #2
        assertEq(s2.epoch, 2);
        // #1 is applied while histEpoch rolls forward; its epoch (1) <= expiry (1) → fills
        pool.applyNext();
        assertEq(_status(id), pool.FILLED());
        // a fresh intent decided at epoch 3 with expiry 2 → refunded on apply
        uint64 id3 = _submit(alice, false, 2e18, 0, 2);
        pool.applyNext(); // #2
        FlyTypes.FlyStateV2 memory s3 = _settleViaVerifyAndUpdate(s2); // epoch 3 decides #3
        assertEq(s3.epoch, 3);
        uint256 before = baseTok.balanceOf(alice);
        pool.applyNext();
        assertEq(baseTok.balanceOf(alice), before + 2e18, "expired intent refunded");
        assertEq(_status(id3), pool.REFUNDED());
    }

    // ------------------------------------------------------------------ 5. clamps

    function test_PoolClampsOutOfRangeFill() public {
        uint64 id = _submit(alice, true, 10e18, 0, 0);
        // pretend a colluding quorum wrote an out-of-band fill word + decidedThrough directly
        vm.store(address(policy), policy.DECIDED_SLOT(), bytes32(uint256(1)));
        vm.store(address(policy), policy.fillSlot(id), policy.packFill(10_000, 200, 0, 1, bytes32(0)));
        uint256 expected = _quoteBuy(10e18, 100); // fee clamped to MAX (100), +30 skew → still 100
        pool.applyNext();
        (uint128 amountOut, uint16 feeBps,) = pool.fills(id);
        assertEq(feeBps, 100, "fee clamped to MAX_FEE");
        assertEq(uint256(amountOut), expected);
        // fee 0 with skew +200 on a sell (sells pay fee − skew) → MIN_FEE; skew −200 on a sell → 5 + 30 = 35
        uint64 id2 = _submit(bob, false, 1e18, 0, 0);
        vm.store(address(policy), policy.DECIDED_SLOT(), bytes32(uint256(2)));
        vm.store(address(policy), policy.fillSlot(id2), policy.packFill(0, 200, 0, 1, bytes32(0)));
        pool.applyNext();
        (, uint16 fee2,) = pool.fills(id2);
        assertEq(fee2, 5, "fee clamped to MIN_FEE");
        uint64 id3 = _submit(bob, false, 1e18, 0, 0);
        vm.store(address(policy), policy.DECIDED_SLOT(), bytes32(uint256(3)));
        vm.store(address(policy), policy.fillSlot(id3), policy.packFill(0, -200, 0, 1, bytes32(0)));
        pool.applyNext();
        (, uint16 fee3,) = pool.fills(id3);
        assertEq(fee3, 35, "skew capped at 30 on the sell side");
    }

    // ------------------------------------------------------------------ 6. LP ops between reference and apply

    function test_LiquidityOpsBetweenReferenceAndApplyDoNotBreakSettlement() public {
        uint64 id = _submit(alice, true, 10e18, 0, 0);
        (FlySwapPolicy.Round memory rd, bytes32 word) = policy.dryRun(_genesis()); // "reference state"
        pool.addLiquidity(500e18, 1_000e18, address(this)); // lands before the apply
        FlyTypes.FlyStateV2 memory next = _settleViaVerifyAndUpdate(_genesis()); // the reference-state diff still applies
        assertEq(policy.flyWord(), word);
        assertEq(policy.fillWordOf(id), rd.fillWords[0]);
        assertEq(next.decidedThrough, 1);
        uint256 expected = _quoteBuy(10e18, _effFee(id)); // against the NEW reserves
        pool.applyNext();
        (uint128 amountOut,,) = pool.fills(id);
        assertEq(uint256(amountOut), expected, "filled against the reserves at apply time");
    }

    // ------------------------------------------------------------------ 7. batch chaining

    function test_BatchChainsRates() public {
        // cfg with maxBatch = 2
        bytes32[3] memory cfg2 = cfg;
        cfg2[2] = bytes32((uint256(cfg2[2]) & ~(uint256(0xff) << 96)) | (uint256(2) << 96));
        FlySwapPool pool2 = new FlySwapPool(baseTok, quoteTok);
        FlySwapPolicy policy2 =
            new FlySwapPolicy(avsAddress, address(blsChecker), engine, rasterizer, graphRoot, warmRoot, cfg2, pool2);
        pool2.setPolicy(IFlySwapPolicyFills(address(policy2)));
        baseTok.approve(address(pool2), type(uint256).max);
        quoteTok.approve(address(pool2), type(uint256).max);
        pool2.addLiquidity(1_000e18, 2_000e18, address(this));
        pool2.submit(true, 10e18, 0, 0);
        pool2.submit(false, 2e18, 0, 0);
        pool2.submit(true, 1e18, 0, 0);
        (FlySwapPolicy.Round memory rd,) = policy2.dryRun(policy2.genesisState());
        assertEq(rd.fillWords.length, 2, "batch of 2");
        assertEq(rd.next.decidedThrough, 2);
        // second episode is seeded with the first's terminal rates: recompute it standalone and compare
        FlyTypes.Observation memory unused; // silence
        unused;
        FlyTypes.Stimulus memory noStim;
        bytes memory frame2 = rasterizer.rasterizeSwap(graphRoot, cfg2, _rotate(rd.obs[1]));
        (FlyTypes.Readout memory r2, bytes32 root2) =
            engine.decide(graphRoot, warmRoot, cfg2, frame2, noStim, rd.readouts[0].rateMilliHz);
        assertEq(root2, rd.spikeRoots[1], "second episode not seeded with the first's rates");
        for (uint256 j = 0; j < 4; ++j) {
            assertEq(rd.next.rateMilliHz[j], r2.rateMilliHz[j], "FlyState carries the last episode's rates");
        }
    }

    /// @dev obs already rotated by the policy; identity here (kept for readability of the chaining test)
    function _rotate(FlyTypes.SwapObservation memory o) internal pure returns (FlyTypes.SwapObservation memory) {
        return o;
    }

    // ------------------------------------------------------------------ 8. vectors + packing

    function test_RasterizeSwapMatchesReference() public view {
        string memory k = ".decideSwap.observation";
        FlyTypes.SwapObservation memory o;
        o.id = uint64(vectors.readUint(string.concat(k, ".id")));
        o.buyBase = vectors.readBool(string.concat(k, ".buyBase"));
        o.sizeBps = uint64(vectors.readUint(string.concat(k, ".sizeBps")));
        o.maxSlipBps = uint64(vectors.readUint(string.concat(k, ".maxSlipBps")));
        o.queueDepth = uint64(vectors.readUint(string.concat(k, ".queueDepth")));
        o.epoch = uint32(vectors.readUint(string.concat(k, ".epoch")));
        uint256[] memory buy = vectors.readUintArray(string.concat(k, ".buyQuote"));
        uint256[] memory sell = vectors.readUintArray(string.concat(k, ".sellQuote"));
        for (uint256 i = 0; i < 16; ++i) {
            o.buyQuote[i] = uint64(buy[i]);
            o.sellQuote[i] = uint64(sell[i]);
        }
        o.volRef = uint64(vectors.readUint(string.concat(k, ".volRef")));
        o.spotQ64 = uint128(vm.parseUint(vectors.readString(string.concat(k, ".spotQ64"))));
        o.emaSpotQ64 = uint128(vm.parseUint(vectors.readString(string.concat(k, ".emaSpotQ64"))));
        o.feeIncomeQuote = uint64(vectors.readUint(string.concat(k, ".feeIncomeQuote")));
        o.lpLossQuote = uint64(vectors.readUint(string.concat(k, ".lpLossQuote")));
        bytes memory frame = rasterizer.rasterizeSwap(graphRoot, cfg, o);
        assertEq(
            keccak256(frame), keccak256(vm.parseBytes(vectors.readString(".decideSwap.frame"))), "swap frame mismatch"
        );
        // and the episode on it
        FlyTypes.Stimulus memory stim = FlyTypes.Stimulus({
            punishSteps: uint16(vectors.readUint(".decideSwap.stimulus.punishSteps")),
            rewardSteps: uint16(vectors.readUint(".decideSwap.stimulus.rewardSteps"))
        });
        uint256[] memory r0 = vectors.readUintArray(".decideSwap.rates0");
        (FlyTypes.Readout memory r, bytes32 root) = engine.decide(
            graphRoot, warmRoot, cfg, frame, stim, [uint32(r0[0]), uint32(r0[1]), uint32(r0[2]), uint32(r0[3])]
        );
        assertEq(root, vectors.readBytes32(".decideSwap.spikeRoot"), "swap spikeRoot mismatch");
        uint256[] memory rates = vectors.readUintArray(".decideSwap.readout.rateMilliHz");
        for (uint256 j = 0; j < 4; ++j) {
            assertEq(uint256(r.rateMilliHz[j]), rates[j]);
        }
    }

    function test_PackFillRoundTrip() public view {
        bytes32 root = keccak256("root");
        uint256 w = uint256(policy.packFill(42, -7, 1, 1234, root));
        assertEq(w >> 240, 42);
        assertEq(int16(uint16(w >> 224)), -7);
        assertEq((w >> 216) & 0xff, 1);
        assertEq((w >> 192) & 0xffffff, 1234);
        assertEq(w & ((1 << 160) - 1), uint256(uint160(uint256(root))));
    }

    function test_FlyStateV2PackRoundTrip() public view {
        FlyTypes.FlyStateV2 memory s = policy.genesisState();
        s.epoch = 9;
        s.decidedThrough = 123456789;
        s.flags = 6;
        s.rateMilliHz = [uint32(1), 2, 3, 4];
        uint256 w = uint256(policy.pack(s));
        assertEq(w >> 232, 9);
        assertEq((w >> 168) & ((1 << 64) - 1), 123456789);
        assertEq((w >> 160) & 0xff, 6);
        assertEq(w & ((1 << 160) - 1), uint256(uint160(uint256(keccak256(abi.encode(s))))));
    }

    function test_HistogramRotation() public {
        // fills at epochs 1 and 2 land in ring slots 1 and 2; the epoch-3 observation must show them in bins 14 and 15
        _submit(alice, true, 10e18, 0, 0);
        _submit(bob, true, 10e18, 0, 0);
        _submit(alice, true, 1e18, 0, 0);
        FlyTypes.FlyStateV2 memory s1 = _settleViaVerifyAndUpdate(_genesis());
        pool.applyNext();
        FlyTypes.FlyStateV2 memory s2 = _settleViaVerifyAndUpdate(s1);
        pool.applyNext();
        (FlySwapPolicy.Round memory rd,) = policy.dryRun(s2); // epoch 3 observing intent #3
        assertEq(rd.obs[0].epoch, 3);
        assertEq(uint256(rd.obs[0].buyQuote[14]), 10e18 / pool.OBS_UNIT(), "epoch 1 volume in bin 14");
        assertEq(uint256(rd.obs[0].buyQuote[15]), 10e18 / pool.OBS_UNIT(), "epoch 2 volume in bin 15");
        assertEq(uint256(rd.obs[0].buyQuote[13]), 0);
        assertGt(rd.obs[0].feeIncomeQuote, 0, "epoch 2's fee income feeds the reward pulse");
        assertEq(rd.obs[0].queueDepth, 1);
    }
}
