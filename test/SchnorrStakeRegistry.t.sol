// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {SchnorrStakeRegistry} from "../src/schnorr/SchnorrStakeRegistry.sol";
import {SchnorrVerify} from "../src/schnorr/libraries/SchnorrVerify.sol";
import {Secp256k1} from "../src/schnorr/libraries/Secp256k1.sol";

/// @notice Rust⇄Solidity parity + gas benchmark for the aggregate-Schnorr quorum.
///
/// Every hex literal below is produced by the deterministic Rust generator
/// `common/examples/schnorr_parity_fixture.rs`
/// (`cargo run -p gas-killer-common --example schnorr_parity_fixture`). If the Rust signing
/// convention changes, regenerate and update these — the whole point is that the *same*
/// aggregate signature the Rust protocol assembles verifies through the real on-chain path.
contract SchnorrStakeRegistryTest is Test {
    SchnorrStakeRegistry registry;

    // ---- fixture: operators (x, y, PoP) ----
    uint256[3] opX = [
        0x786557ebb05caaa341dd70766e782f55d93a4f23d964cf9dd8a440096627cc0e,
        0x6df893da6269a5645ad4ef89d68c2f24ac820f92f09a0a50ccf8d2d17c31de85,
        0x786e4b620cd30eaecaef3c012dd01564798d3b9d4feb4df009adb1946dd00f2f
    ];
    uint256[3] opY = [
        0xbd9fa1a7dedbd2a3d4439931424bcc3428bd391709312531bdc1726c3c675c12,
        0x57548c554720a201d68aeb95e9889bf0fd1866d80eb6d75992c05ef11e47bbfd,
        0xe3bedbbe4586d930cac481587afe2778cbebb676ea818615c64f32bf6fd4d800
    ];
    uint256[3] popS = [
        0x2e1fd0879bc03b8052b6d8c43d8670ad43c71b8b58c1f1a85ae34d0f714c0790,
        0xb079da44926d3ed88388199dbc4f8c733a606aac2d56f89453e7309d8b24afea,
        0x7c27a76e80c7fcdb18ed2efe5a5b25b1c751ade939c667fbc4f1cccd0f2baf94
    ];
    address[3] popR = [
        0x8cBDD2922341Eec161aad35426249aEEBfa17762,
        0xAA89aA92dff7535bFb43D15dd80F4E62978cDf5C,
        0x2f23702C4527CE7b0A2519E98b12B98D0c58a4a9
    ];

    // ---- fixture: aggregate key, message, signatures ----
    uint256 constant XALL_X = 0xb8ab245d2905f57175a57e3e8ecc0ccd34bf1ea86d0ec31862003cfda254cd95;
    uint256 constant XALL_Y = 0xc3b57214a224f85e22172674f6a163b589691010456bcad35bb52cdd96bff8f6;
    bytes32 constant MESSAGE = 0xeca826d3bb47f0cbaed65764fb099b01af1c3ad160b35cb226d7249670866fd6;

    // full participation (signers 0,1,2)
    uint256 constant FULL_S = 0xf527f98d99ce218539679f270074804e72da151aa0495eff3f74769cfce15174;
    address constant FULL_R = 0xDb0aC2AC07Dc8c44b370C5eA1cf158077c386141;

    // subset: operator 1 offline (signers 0,2)
    uint256 constant SUB_S = 0x0d4db16e196f8134612d1bd370b2193a3b8703245f7a0d64e82b2a1e15b4bb68;
    address constant SUB_R = 0x443F530ae1700809Aaa89acA96C43202ec650BBD;

    uint256 constant WEIGHT = 100;

    function setUp() public {
        // Move off genesis so a valid reference block (< effectiveBlock) exists later.
        vm.roll(1000);
        registry = new SchnorrStakeRegistry(2, 3, address(this), 0); // 2/3 threshold
        for (uint256 i = 0; i < 3; i++) {
            registry.registerOperator(opX[i], opY[i], WEIGHT, popS[i], popR[i]);
        }
        vm.roll(block.number + 10); // refBlock = block.number-1 stays >= effectiveBlock
    }

    function _refBlock() internal view returns (uint256) {
        return block.number - 1;
    }

    function _nonSigner(uint256 i) internal view returns (address) {
        return registry.pointAddress(opX[i], opY[i]);
    }

    // The registry's running aggregate equals the Rust-computed X_all.
    function test_aggregateKeyMatchesRust() public view {
        assertEq(registry.aggX(), XALL_X, "aggX");
        assertEq(registry.aggY(), XALL_Y, "aggY");
        assertEq(registry.totalWeight(), 3 * WEIGHT, "totalWeight");
    }

    // The raw Scribe verifier accepts the full-participation signature against X_all.
    function test_schnorrVerify_fullAgainstXall() public pure {
        assertTrue(SchnorrVerify.verify(XALL_X, uint8(XALL_Y & 1), MESSAGE, FULL_S, FULL_R));
        // Wrong message rejected.
        assertFalse(SchnorrVerify.verify(XALL_X, uint8(XALL_Y & 1), keccak256("nope"), FULL_S, FULL_R));
    }

    // Full participation through the registry (no non-signers) verifies.
    function test_fullParticipation_verifies() public view {
        address[] memory none = new address[](0);
        assertTrue(registry.isValidSignature(MESSAGE, FULL_S, FULL_R, none, _refBlock()));
    }

    // Subset: operator 1 offline. The registry subtracts its key + weight and verifies the
    // subset signature against X_all − X_1. This is the whole point — one signature, verified
    // against the exact signer subset via on-chain subtraction.
    function test_subset_nonSignerSubtraction_verifies() public view {
        address[] memory ns = new address[](1);
        ns[0] = _nonSigner(1);
        assertTrue(registry.isValidSignature(MESSAGE, SUB_S, SUB_R, ns, _refBlock()));
    }

    // Using the FULL signature but declaring op1 as a non-signer must fail: the aggregate
    // key no longer matches what was signed (guards against forged non-signer sets).
    function test_wrongNonSignerSet_rejected() public view {
        address[] memory ns = new address[](1);
        ns[0] = _nonSigner(1);
        assertFalse(registry.isValidSignature(MESSAGE, FULL_S, FULL_R, ns, _refBlock()));
    }

    // Dropping two operators falls below the 2/3 stake threshold → rejected.
    function test_belowThreshold_rejected() public view {
        address[] memory ns = new address[](2);
        // sorted ascending
        address a = _nonSigner(0);
        address b = _nonSigner(2);
        (ns[0], ns[1]) = a < b ? (a, b) : (b, a);
        assertFalse(registry.isValidSignature(MESSAGE, SUB_S, SUB_R, ns, _refBlock()));
    }

    // Non-signers must be strictly ascending (dedupe / canonical).
    function test_nonSignersMustBeSorted() public {
        address[] memory ns = new address[](2);
        ns[0] = _nonSigner(1);
        ns[1] = _nonSigner(1); // duplicate
        vm.expectRevert(SchnorrStakeRegistry.NonSignersNotSorted.selector);
        registry.isValidSignature(MESSAGE, SUB_S, SUB_R, ns, _refBlock());
    }

    // Fail-closed staleness: a reference block before the last operator-set mutation reverts.
    function test_staleSnapshot_reverts() public {
        uint256 stale = registry.effectiveBlock() - 1;
        address[] memory none = new address[](0);
        vm.expectRevert(SchnorrStakeRegistry.StaleSnapshot.selector);
        registry.isValidSignature(MESSAGE, FULL_S, FULL_R, none, stale);
    }

    // A forged PoP (valid signature but for a different key) is rejected at registration.
    function test_registration_rejectsBadPoP() public {
        // Reuse operator 0's key but operator 1's PoP → mismatch.
        vm.roll(block.number + 1);
        SchnorrStakeRegistry fresh = new SchnorrStakeRegistry(2, 3, address(this), 0);
        vm.expectRevert(SchnorrStakeRegistry.InvalidProofOfPossession.selector);
        fresh.registerOperator(opX[0], opY[0], WEIGHT, popS[1], popR[1]);
    }

    // An off-curve key is rejected.
    function test_registration_rejectsOffCurve() public {
        SchnorrStakeRegistry fresh = new SchnorrStakeRegistry(2, 3, address(this), 0);
        vm.expectRevert(SchnorrStakeRegistry.NotOnCurve.selector);
        fresh.registerOperator(opX[0], opY[0] ^ 1, WEIGHT, popS[0], popR[0]);
    }

    // A weight that does not fit the packed uint96 field is rejected (rather than
    // silently truncated into the quorum arithmetic).
    function test_registration_rejectsWeightOverflow() public {
        SchnorrStakeRegistry fresh = new SchnorrStakeRegistry(2, 3, address(this), 0);
        vm.expectRevert(SchnorrStakeRegistry.WeightOverflow.selector);
        fresh.registerOperator(opX[0], opY[0], uint256(type(uint96).max) + 1, popS[0], popR[0]);
    }

    // The boundary itself is accepted and stored losslessly (guards against the check
    // regressing from > to >=, and against a truncating cast reappearing).
    function test_registration_acceptsMaxUint96Weight() public {
        SchnorrStakeRegistry fresh = new SchnorrStakeRegistry(2, 3, address(this), 0);
        fresh.registerOperator(opX[0], opY[0], uint256(type(uint96).max), popS[0], popR[0]);
        address id = fresh.pointAddress(opX[0], opY[0]);
        (,, uint96 w, bool registered,) = fresh.operators(id);
        assertEq(uint256(w), uint256(type(uint96).max), "stored weight lossless at the bound");
        assertTrue(registered, "registered");
        assertEq(fresh.totalWeight(), uint256(type(uint96).max), "totalWeight credits the full value");
    }

    // ---- deregistration ----

    // Deregistering an operator subtracts its key and weight from the running aggregate. The
    // resulting aggregate must equal X_all − X_i computed directly. The record is left behind as
    // a tombstone: the key and weight stay readable and `exitBlock` records when it left, while
    // `registered` going false is what removes it from the active set.
    function test_deregister_updatesAggregateAndWeight() public {
        address id = _nonSigner(1);
        (uint256 ex, uint256 ey) = Secp256k1.sub(XALL_X, XALL_Y, opX[1], opY[1]);

        registry.deregisterOperator(id);

        assertEq(registry.aggX(), ex, "aggX after deregister");
        assertEq(registry.aggY(), ey, "aggY after deregister");
        assertEq(registry.totalWeight(), 2 * WEIGHT, "totalWeight debited");

        (uint256 x, uint256 y, uint96 w, bool registered, uint48 exitBlock) = registry.operators(id);
        assertFalse(registered, "no longer in the active set");
        assertEq(x, opX[1], "tombstone retains x");
        assertEq(y, opY[1], "tombstone retains y");
        assertEq(uint256(w), WEIGHT, "tombstone retains weight");
        assertEq(uint256(exitBlock), block.number, "tombstone records the exit block");
    }

    // After deregistering operator 1, the on-chain aggregate equals X_all − X_1 — exactly what
    // the subset signature (signers 0,2) was signed against. So that signature now verifies
    // with NO non-signers declared: deregistration and non-signer subtraction are equivalent.
    function test_deregister_thenSubsetVerifiesWithNoNonSigners() public {
        registry.deregisterOperator(_nonSigner(1));
        vm.roll(block.number + 10); // refBlock stays >= the new effectiveBlock

        address[] memory none = new address[](0);
        assertTrue(registry.isValidSignature(MESSAGE, SUB_S, SUB_R, none, _refBlock()));
    }

    // Advancing effectiveBlock is fail-closed: a signature valid before the deregistration
    // (referencing a block prior to it) is rejected as stale afterwards.
    function test_deregister_advancesWatermark() public {
        uint256 preBlock = block.number - 1; // valid refBlock before the mutation
        address[] memory none = new address[](0);
        assertTrue(registry.isValidSignature(MESSAGE, FULL_S, FULL_R, none, preBlock), "valid before");

        registry.deregisterOperator(_nonSigner(1));

        vm.expectRevert(SchnorrStakeRegistry.StaleSnapshot.selector);
        registry.isValidSignature(MESSAGE, FULL_S, FULL_R, none, preBlock);
    }

    // Pinning the freshest possible reference block does not rescue a signature assembled before
    // a mutation: the watermark check passes, but the cached aggregate is X_all − X_1 while the
    // signature was made for X_all, so verification simply fails. This is the other half of the
    // in-flight invalidation surface — the caller sees `false`, not `StaleSnapshot`. Mirror of
    // test_deregister_thenSubsetVerifiesWithNoNonSigners, which passes in this same state
    // because the subset signature *does* match the post-removal aggregate.
    function test_deregister_freshRefBlockRejectsPreMutationSignature() public {
        registry.deregisterOperator(_nonSigner(1));
        vm.roll(block.number + 10); // refBlock is now at or above the new effectiveBlock

        address[] memory none = new address[](0);
        assertFalse(registry.isValidSignature(MESSAGE, FULL_S, FULL_R, none, _refBlock()));
    }

    // Registration invalidates in-flight signatures exactly as deregistration does. Re-adding a
    // previously removed operator restores X_all, so the subset signature that was valid against
    // X_all − X_1 no longer matches — and referencing a block from before the re-registration is
    // stale. Both directions of a set mutation break an assembled round.
    function test_register_advancesWatermark() public {
        address id = _nonSigner(1);
        registry.deregisterOperator(id);
        vm.roll(block.number + 10);

        address[] memory none = new address[](0);
        assertTrue(registry.isValidSignature(MESSAGE, SUB_S, SUB_R, none, _refBlock()), "valid before");

        uint256 preBlock = block.number - 1; // valid refBlock before the registration
        registry.registerOperator(opX[1], opY[1], WEIGHT, popS[1], popR[1]);

        vm.expectRevert(SchnorrStakeRegistry.StaleSnapshot.selector);
        registry.isValidSignature(MESSAGE, SUB_S, SUB_R, none, preBlock);

        // ...and a fresh reference block does not help either: X_all is back to its full value.
        vm.roll(block.number + 10);
        assertFalse(registry.isValidSignature(MESSAGE, SUB_S, SUB_R, none, _refBlock()));
    }

    // The threshold is measured against the *current* totalWeight, so removing an operator
    // redefines what counts as a quorum. With a heavy non-signer in the set, signers {0,2} hold
    // 20/120 and are rejected; once that operator is deregistered the same signature holds 20/20
    // and is accepted. This is not something the watermark prevents — a freshest-block reference
    // clears it, as asserted below — and it is the correct outcome, because the remaining signers
    // really do carry the whole remaining weight. What still binds the signature to one signer set
    // is the aggregate match: the caller must present a non-signer set whose subtraction yields
    // exactly the key that signed. Uses non-uniform weights, which the shared fixture does not.
    function test_thresholdMeasuredAgainstCurrentTotalWeight() public {
        SchnorrStakeRegistry r = new SchnorrStakeRegistry(2, 3, address(this), 0);
        uint256[3] memory w = [uint256(10), 100, 10];
        for (uint256 i = 0; i < 3; i++) {
            r.registerOperator(opX[i], opY[i], w[i], popS[i], popR[i]);
        }
        vm.roll(block.number + 10);

        address heavy = r.pointAddress(opX[1], opY[1]);
        address[] memory ns = new address[](1);
        ns[0] = heavy;
        assertFalse(r.isValidSignature(MESSAGE, SUB_S, SUB_R, ns, _refBlock()), "20/120 is below 2/3");

        r.deregisterOperator(heavy);
        vm.roll(block.number + 10);

        address[] memory none = new address[](0);
        assertTrue(r.isValidSignature(MESSAGE, SUB_S, SUB_R, none, _refBlock()), "20/20 is a quorum");
    }

    // A deregistered identity is no longer a valid non-signer: the verification loop reverts
    // rather than subtracting a zeroed record (which would corrupt the aggregate).
    function test_deregister_nonSignerLookupReverts() public {
        address id = _nonSigner(1);
        registry.deregisterOperator(id);
        vm.roll(block.number + 10);

        address[] memory ns = new address[](1);
        ns[0] = id;
        vm.expectRevert(abi.encodeWithSelector(SchnorrStakeRegistry.NotRegistered.selector, id));
        registry.isValidSignature(MESSAGE, SUB_S, SUB_R, ns, _refBlock());
    }

    // Re-registering a deregistered operator restores the exact original aggregate and weight,
    // confirming the record was cleared cleanly (no residual key left in X_all).
    function test_deregister_thenReregisterRestoresAggregate() public {
        registry.deregisterOperator(_nonSigner(1));
        registry.registerOperator(opX[1], opY[1], WEIGHT, popS[1], popR[1]);

        assertEq(registry.aggX(), XALL_X, "aggX restored");
        assertEq(registry.aggY(), XALL_Y, "aggY restored");
        assertEq(registry.totalWeight(), 3 * WEIGHT, "totalWeight restored");
    }

    // Deregistering the last remaining operator collapses the aggregate back to the identity.
    function test_deregister_allClearsAggregate() public {
        for (uint256 i = 0; i < 3; i++) {
            registry.deregisterOperator(_nonSigner(i));
        }
        assertEq(registry.aggX(), 0, "aggX identity");
        assertEq(registry.aggY(), 0, "aggY identity");
        assertEq(registry.totalWeight(), 0, "totalWeight zero");
    }

    // Only the owner may mutate the operator set.
    function test_deregister_onlyOwner() public {
        // Resolve the id before pranking: `_nonSigner` makes an external call that would
        // otherwise consume the prank meant for `deregisterOperator`.
        address id = _nonSigner(1);
        vm.prank(address(0xBEEF));
        vm.expectRevert(SchnorrStakeRegistry.NotOwner.selector);
        registry.deregisterOperator(id);
    }

    // Deregistering an unknown identity reverts rather than silently underflowing weight.
    function test_deregister_unknownReverts() public {
        address ghost = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(SchnorrStakeRegistry.NotRegistered.selector, ghost));
        registry.deregisterOperator(ghost);
    }

    // Re-registering a tombstoned identity clears `exitBlock`, so a record cannot look
    // simultaneously active and exited.
    function test_reregister_clearsTombstone() public {
        address id = _nonSigner(1);
        registry.deregisterOperator(id);
        (,,,, uint48 exitedAt) = registry.operators(id);
        assertGt(uint256(exitedAt), 0, "tombstoned");

        registry.registerOperator(opX[1], opY[1], WEIGHT, popS[1], popR[1]);

        (,, uint96 w, bool registered, uint48 exitBlock) = registry.operators(id);
        assertTrue(registered, "active again");
        assertEq(uint256(w), WEIGHT, "weight restored");
        assertEq(uint256(exitBlock), 0, "exitBlock cleared");
    }

    // ---- scheduled changes (notice window) ----

    uint256 constant NOTICE = 50;

    // A registry with a real notice window and the three fixture operators already in the active
    // set, positioned so `_refBlock()` is a valid reference block.
    function _noticeRegistry() internal returns (SchnorrStakeRegistry r) {
        r = new SchnorrStakeRegistry(2, 3, address(this), NOTICE);
        for (uint256 i = 0; i < 3; i++) {
            r.registerOperator(opX[i], opY[i], WEIGHT, popS[i], popR[i]);
        }
        vm.roll(block.number + 10);
    }

    // With nothing announced there is no scheduled mutation, so the horizon is unbounded.
    function test_horizon_unboundedWhenNothingPending() public {
        SchnorrStakeRegistry r = _noticeRegistry();
        assertEq(r.nextPossibleMutationBlock(), type(uint256).max);
        assertEq(r.pendingChangeCount(), 0);
    }

    // Announcing publishes a horizon and changes nothing else: the aggregate, the total weight
    // and the watermark are untouched, so a signature assembled now still verifies. This is the
    // property the whole mechanism exists for.
    function test_announce_publishesHorizonWithoutMutating() public {
        SchnorrStakeRegistry r = _noticeRegistry();
        uint256 aggXBefore = r.aggX();
        uint256 watermarkBefore = r.effectiveBlock();

        r.announceDeregister(r.pointAddress(opX[1], opY[1]));

        assertEq(r.nextPossibleMutationBlock(), block.number + NOTICE, "horizon published");
        assertEq(r.pendingChangeCount(), 1);
        assertEq(r.aggX(), aggXBefore, "aggregate untouched");
        assertEq(r.totalWeight(), 3 * WEIGHT, "weight untouched");
        assertEq(r.effectiveBlock(), watermarkBefore, "watermark untouched");

        address[] memory none = new address[](0);
        assertTrue(r.isValidSignature(MESSAGE, FULL_S, FULL_R, none, _refBlock()), "still verifies");
    }

    // The set cannot change before the horizon: any block up to `eligibleBlock - 1` still
    // verifies a signature assembled against the pre-announcement set, and the commit that would
    // change it is rejected until then.
    function test_horizon_setUnchangedUntilEligibleBlock() public {
        SchnorrStakeRegistry r = _noticeRegistry();
        r.announceDeregister(r.pointAddress(opX[1], opY[1]));
        uint256 eligible = r.nextPossibleMutationBlock();

        vm.roll(eligible - 1);
        vm.expectRevert(abi.encodeWithSelector(SchnorrStakeRegistry.NoticeWindowNotElapsed.selector, eligible));
        r.commitNextChange();

        address[] memory none = new address[](0);
        assertTrue(r.isValidSignature(MESSAGE, FULL_S, FULL_R, none, _refBlock()), "set unchanged");
    }

    // Committing after the window applies exactly what the immediate path would have.
    function test_commit_appliesDeregistration() public {
        SchnorrStakeRegistry r = _noticeRegistry();
        address id = r.pointAddress(opX[1], opY[1]);
        (uint256 ex, uint256 ey) = Secp256k1.sub(XALL_X, XALL_Y, opX[1], opY[1]);

        r.announceDeregister(id);
        vm.roll(r.nextPossibleMutationBlock());
        r.commitNextChange();

        assertEq(r.aggX(), ex, "aggX");
        assertEq(r.aggY(), ey, "aggY");
        assertEq(r.totalWeight(), 2 * WEIGHT, "weight debited");
        assertEq(r.effectiveBlock(), block.number, "watermark advanced on commit");
        assertEq(r.pendingChangeCount(), 0, "dequeued");
        assertEq(r.nextPossibleMutationBlock(), type(uint256).max, "horizon released");
    }

    // An announced registration is not in the aggregate until commit — an operator must not sign
    // before then, because its key is not yet part of X_all.
    function test_commit_appliesRegistration() public {
        SchnorrStakeRegistry r = _noticeRegistry();
        address id = r.pointAddress(opX[1], opY[1]);
        r.deregisterOperator(id);
        vm.roll(block.number + 10);

        r.announceRegister(opX[1], opY[1], WEIGHT, popS[1], popR[1]);
        assertEq(r.totalWeight(), 2 * WEIGHT, "not credited while pending");

        vm.roll(r.nextPossibleMutationBlock());
        r.commitNextChange();

        assertEq(r.aggX(), XALL_X, "aggregate restored on commit");
        assertEq(r.totalWeight(), 3 * WEIGHT, "weight credited on commit");
    }

    // An announced-but-uncommitted exit still counts toward the threshold denominator, so the
    // operator is expected to keep signing through its notice window.
    function test_announcedExitStillCountsTowardThreshold() public {
        SchnorrStakeRegistry r = _noticeRegistry();
        address id = r.pointAddress(opX[1], opY[1]);
        r.announceDeregister(id);

        // The subset signature (op 1 absent) needs op 1 declared as a non-signer and still
        // clears 2/3 — its weight is in the denominator either way.
        address[] memory ns = new address[](1);
        ns[0] = id;
        assertTrue(r.isValidSignature(MESSAGE, SUB_S, SUB_R, ns, _refBlock()), "absorbed as non-signer");
        assertEq(r.totalWeight(), 3 * WEIGHT, "weight still counted");
    }

    // Proof of possession is checked when the change is announced, so an unusable announcement
    // cannot sit in the queue holding the horizon.
    function test_announceRegister_validatesUpFront() public {
        SchnorrStakeRegistry r = new SchnorrStakeRegistry(2, 3, address(this), NOTICE);
        vm.expectRevert(SchnorrStakeRegistry.InvalidProofOfPossession.selector);
        r.announceRegister(opX[0], opY[0], WEIGHT, popS[1], popR[1]);
        assertEq(r.pendingChangeCount(), 0, "nothing queued");
    }

    // One pending change per identity, so the queue cannot hold contradictory entries.
    function test_announce_rejectsSecondChangeForSameOperator() public {
        SchnorrStakeRegistry r = _noticeRegistry();
        address id = r.pointAddress(opX[1], opY[1]);
        r.announceDeregister(id);
        vm.expectRevert(abi.encodeWithSelector(SchnorrStakeRegistry.ChangeAlreadyPending.selector, id));
        r.announceDeregister(id);
    }

    // Changes commit in announcement order, which is what makes the queue head the earliest
    // possible mutation and the horizon a single storage read.
    function test_commit_isFifo() public {
        SchnorrStakeRegistry r = _noticeRegistry();
        address first = r.pointAddress(opX[0], opY[0]);
        address second = r.pointAddress(opX[1], opY[1]);

        r.announceDeregister(first);
        vm.roll(block.number + 5);
        r.announceDeregister(second);

        vm.roll(r.nextPossibleMutationBlock());
        r.commitNextChange();

        (,,, bool firstActive,) = r.operators(first);
        (,,, bool secondActive,) = r.operators(second);
        assertFalse(firstActive, "head applied first");
        assertTrue(secondActive, "tail still pending");
    }

    // Cancelling drops the head. The horizon can only move later as a result, never earlier, so
    // a round assembled against the published horizon stays valid.
    function test_cancel_movesHorizonLater() public {
        SchnorrStakeRegistry r = _noticeRegistry();
        r.announceDeregister(r.pointAddress(opX[0], opY[0]));
        uint256 firstHorizon = r.nextPossibleMutationBlock();

        vm.roll(block.number + 5);
        r.announceDeregister(r.pointAddress(opX[1], opY[1]));

        r.cancelNextChange();

        assertGt(r.nextPossibleMutationBlock(), firstHorizon, "horizon pushed later");
        assertEq(r.pendingChangeCount(), 1, "only the head dropped");
    }

    // A cancelled identity is free to be announced again.
    function test_cancel_releasesTheIdentity() public {
        SchnorrStakeRegistry r = _noticeRegistry();
        address id = r.pointAddress(opX[1], opY[1]);
        r.announceDeregister(id);
        r.cancelNextChange();
        r.announceDeregister(id); // must not revert
        assertEq(r.pendingChangeCount(), 1);
    }

    // Committing or cancelling an empty queue reverts rather than silently doing nothing.
    function test_emptyQueueReverts() public {
        SchnorrStakeRegistry r = _noticeRegistry();
        vm.expectRevert(SchnorrStakeRegistry.NoPendingChange.selector);
        r.commitNextChange();
        vm.expectRevert(SchnorrStakeRegistry.NoPendingChange.selector);
        r.cancelNextChange();
    }

    // The whole scheduled path is owner-gated, like the immediate one.
    function test_scheduledPath_onlyOwner() public {
        SchnorrStakeRegistry r = _noticeRegistry();
        address id = r.pointAddress(opX[1], opY[1]);
        // Resolved before the prank: an external view call inside the expectRevert window would
        // consume it and the assertion would test the wrong call.
        address other = r.pointAddress(opX[0], opY[0]);
        r.announceDeregister(id);

        vm.startPrank(address(0xBEEF));
        vm.expectRevert(SchnorrStakeRegistry.NotOwner.selector);
        r.announceDeregister(other);
        vm.expectRevert(SchnorrStakeRegistry.NotOwner.selector);
        r.commitNextChange();
        vm.expectRevert(SchnorrStakeRegistry.NotOwner.selector);
        r.cancelNextChange();
        vm.stopPrank();
    }

    // ---- cross-path collisions between the scheduled and forced paths ----

    // Forcing a registration that is already announced would apply the same key twice — once
    // immediately (an announcement leaves `registered` false, so validation does not object) and
    // again when the still-queued entry commits — doubling it in X_all and in totalWeight. The
    // forced path must refuse while a change is queued.
    function test_forcedRegister_rejectedWhileChangePending() public {
        SchnorrStakeRegistry r = new SchnorrStakeRegistry(2, 3, address(this), NOTICE);
        address id = r.pointAddress(opX[0], opY[0]);

        r.announceRegister(opX[0], opY[0], WEIGHT, popS[0], popR[0]);

        vm.expectRevert(abi.encodeWithSelector(SchnorrStakeRegistry.ChangeAlreadyPending.selector, id));
        r.registerOperator(opX[0], opY[0], WEIGHT, popS[0], popR[0]);

        // The queued change still applies exactly once.
        vm.roll(r.nextPossibleMutationBlock());
        r.commitNextChange();
        assertEq(r.totalWeight(), WEIGHT, "credited once");
        (,, uint96 w, bool registered,) = r.operators(id);
        assertTrue(registered);
        assertEq(uint256(w), WEIGHT);
    }

    // The mirror case would wedge the queue instead of corrupting the aggregate: the head would
    // revert NotRegistered on every commit and, because changes commit in order, block everything
    // behind it. Same rule closes it.
    function test_forcedDeregister_rejectedWhileChangePending() public {
        SchnorrStakeRegistry r = _noticeRegistry();
        address id = r.pointAddress(opX[1], opY[1]);

        r.announceDeregister(id);

        vm.expectRevert(abi.encodeWithSelector(SchnorrStakeRegistry.ChangeAlreadyPending.selector, id));
        r.deregisterOperator(id);

        // The queue is still committable rather than wedged.
        vm.roll(r.nextPossibleMutationBlock());
        r.commitNextChange();
        assertEq(r.totalWeight(), 2 * WEIGHT, "debited once");
    }

    // Cancelling releases the identity back to the forced path, so the guard blocks a collision
    // rather than locking an operator out permanently.
    function test_cancelReleasesIdentityToForcedPath() public {
        SchnorrStakeRegistry r = _noticeRegistry();
        address id = r.pointAddress(opX[1], opY[1]);

        r.announceDeregister(id);
        r.cancelNextChange();
        r.deregisterOperator(id); // must not revert

        assertEq(r.totalWeight(), 2 * WEIGHT);
    }

    // A notice window large enough to wrap `eligibleBlock` when narrowed to uint48 would land it
    // in the past and make changes committable immediately, defeating the window.
    function test_constructor_rejectsUnboundedNoticeWindow() public {
        vm.expectRevert(SchnorrStakeRegistry.NoticeWindowTooLarge.selector);
        new SchnorrStakeRegistry(2, 3, address(this), uint256(type(uint48).max));
    }

    // The immediate paths mark themselves, so a consumer relying on the horizon can detect that
    // it was bypassed.
    function test_immediatePath_emitsForcedMutation() public {
        SchnorrStakeRegistry r = _noticeRegistry();
        address id = r.pointAddress(opX[1], opY[1]);

        vm.expectEmit(true, false, false, false, address(r));
        emit SchnorrStakeRegistry.ForcedMutation(id);
        r.deregisterOperator(id);
    }

    // Deregistering the same operator twice reverts: the record is gone after the first call.
    function test_deregister_twiceReverts() public {
        address id = _nonSigner(1);
        registry.deregisterOperator(id);
        vm.expectRevert(abi.encodeWithSelector(SchnorrStakeRegistry.NotRegistered.selector, id));
        registry.deregisterOperator(id);
    }

    // Deregistration announces the removed identity and its weight.
    function test_deregister_emitsEvent() public {
        address id = _nonSigner(1);
        vm.expectEmit(true, false, false, true, address(registry));
        emit SchnorrStakeRegistry.OperatorDeregistered(id, WEIGHT);
        registry.deregisterOperator(id);
    }

    // ---- gas benchmark (constant in signer count at full participation) ----
    // NOTE: this measures the WARM access context (the warm-up calls below put the
    // registry in the EIP-2929 access set). A standalone on-chain transaction pays the
    // COLD context instead — roughly +2.5k for the account plus +2k per first-touch slot.
    // Under `forge test --gas-report` calls run ISOLATED (fresh access lists), so this
    // same test prints the cold-context numbers there. Both contexts, plus non-signer
    // scaling, are measured explicitly in SchnorrStakeRegistryGas.t.sol.
    function test_gas_benchmark() public view {
        address[] memory none = new address[](0);
        address[] memory ns = new address[](1);
        ns[0] = _nonSigner(1);

        // Warm the registry's base storage (aggX/aggY/totalWeight/effectiveBlock) and the
        // op-1 slot so both measurements below see the same warm baseline; what remains is
        // the actual compute (keccak + ecrecover, plus one affine point subtraction for the
        // non-signer case).
        registry.isValidSignature(MESSAGE, FULL_S, FULL_R, none, _refBlock());
        registry.isValidSignature(MESSAGE, SUB_S, SUB_R, ns, _refBlock());

        uint256 g0 = gasleft();
        registry.isValidSignature(MESSAGE, FULL_S, FULL_R, none, _refBlock());
        uint256 gasFull = g0 - gasleft();

        uint256 g1 = gasleft();
        registry.isValidSignature(MESSAGE, SUB_S, SUB_R, ns, _refBlock());
        uint256 gasOneNonSigner = g1 - gasleft();

        console2.log("Schnorr isValidSignature, 3/3 signed (0 non-signers):", gasFull);
        console2.log("Schnorr isValidSignature, 2/3 signed (1 non-signer): ", gasOneNonSigner);
        console2.log("  -> marginal per non-signer (affine point sub):     ", gasOneNonSigner - gasFull);
        // A full-participation verify is one keccak256 + one ecrecover plus a handful of warm
        // storage reads: constant in the number of *signers*. Cost grows only with the number
        // of *non-signers* (one affine point subtraction each), which is ~0 at healthy
        // participation. This budget guards that constant-gas property against a regression
        // that reintroduces per-signer work.
        uint256 constantVerifyGasBudget = 12_000;
        assertLt(gasFull, constantVerifyGasBudget, "full-participation verify must stay constant-gas cheap");
    }
}
