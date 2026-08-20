// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {GasKillerSP1Arbiter} from "../../src/commitments/GasKillerSP1Arbiter.sol";
import {SchnorrCommitmentsAdapter} from "../../src/commitments/SchnorrCommitmentsAdapter.sol";
import {SchnorrStakeRegistry} from "../../src/schnorr/SchnorrStakeRegistry.sol";
import {IArbiter} from "../../src/commitments/interfaces/ICommitmentsMinimal.sol";
import {MockCommitmentManager, MockOperatorRegistry, MockSP1Verifier} from "./mocks/CommitmentsMocks.sol";

/// @notice Slashing-path coverage for `GasKillerSP1Arbiter`: mocked SP1 verifier and
///         CommitmentManager, but a REAL `SchnorrCommitmentsAdapter` + `SchnorrStakeRegistry`
///         so the ejection leg is observed end to end — a slash must remove the operator's
///         Schnorr key from the live signer set in the same transaction.
///
/// Operator 0's key material is the Rust-generated parity fixture from
/// `test/SchnorrStakeRegistry.t.sol` (`common/examples/schnorr_parity_fixture.rs`); a valid
/// proof of possession is required to get the operator into the registry at all.
contract GasKillerSP1ArbiterTest is Test {
    MockOperatorRegistry mockReg;
    MockCommitmentManager manager;
    MockSP1Verifier verifier;
    GasKillerSP1Arbiter arbiter;
    SchnorrCommitmentsAdapter adapter;
    SchnorrStakeRegistry registry;

    // ---- fixture: operator 0 (x, y, PoP) — from test/SchnorrStakeRegistry.t.sol ----
    uint256 constant OP0_X = 0x786557ebb05caaa341dd70766e782f55d93a4f23d964cf9dd8a440096627cc0e;
    uint256 constant OP0_Y = 0xbd9fa1a7dedbd2a3d4439931424bcc3428bd391709312531bdc1726c3c675c12;
    uint256 constant OP0_POP_S = 0x2e1fd0879bc03b8052b6d8c43d8670ad43c71b8b58c1f1a85ae34d0f714c0790;
    address constant OP0_POP_R = 0x8cBDD2922341Eec161aad35426249aEEBfa17762;

    bytes32 constant VKEY = bytes32(uint256(0x5117));
    bytes32 constant NEW_VKEY = bytes32(uint256(0x5118));
    uint256 constant VKEY_DELAY = 8 days;
    uint16 constant PENALTY_BPS = 5000;
    address constant GUARDIAN = address(0xCAFE);
    address constant RANDO = address(0xBEEF);
    bytes32 constant FAULT = keccak256("equivocation-1");

    uint256 constant SCALE = 1 ether;
    uint256 constant STAKE = 100 ether;

    address op0;
    bytes publicValues;
    bytes32 offenseKey;

    function setUp() public {
        vm.roll(1000);
        mockReg = new MockOperatorRegistry();
        manager = new MockCommitmentManager();
        verifier = new MockSP1Verifier();
        // Deploy order per the arbiter's NatSpec: arbiter first (unwired), then the service.
        arbiter = new GasKillerSP1Arbiter(address(manager), address(verifier), VKEY, GUARDIAN, VKEY_DELAY, PENALTY_BPS);
        adapter = new SchnorrCommitmentsAdapter(address(mockReg), SCALE, address(this));
        registry = new SchnorrStakeRegistry(2, 3, address(adapter), 0);
        adapter.setRegistry(address(registry));
        adapter.setArbiter(address(arbiter));
        vm.prank(GUARDIAN);
        arbiter.wireService(address(mockReg), address(adapter));

        // Join operator 0 into the live signer set so the ejection leg is observable.
        op0 = registry.pointAddress(OP0_X, OP0_Y);
        mockReg.setOperator(op0, true, STAKE);
        uint256[2] memory g1 = [uint256(1), 2];
        uint256[4] memory g2 = [uint256(3), 4, 5, 6];
        vm.prank(op0);
        adapter.join(OP0_X, OP0_Y, OP0_POP_S, OP0_POP_R, g1, g2, "node-0:3001");

        // Two stake commitments (self-stake + one delegation) bound to the operator.
        mockReg.setOperatorForCommitment(1, op0);
        mockReg.setOperatorForCommitment(2, op0);

        publicValues = abi.encode(op0, FAULT);
        offenseKey = keccak256(abi.encodePacked(op0, FAULT));

        // The mock cannot record what it receives (the arbiter STATICCALLs it), so it is armed
        // with the exact vkey + public values every slash below must forward — any drift reverts.
        verifier.setExpectedVkey(VKEY);
        verifier.setExpectedPublicValues(publicValues);
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    // ---- wiring ----

    // wireService is guardian-gated and one-shot: the Commitments registry bakes the arbiter
    // address in immutably, so the reverse pointer must not be re-aimable.
    function test_wireService_guardianGatedOneShot() public {
        GasKillerSP1Arbiter fresh =
            new GasKillerSP1Arbiter(address(manager), address(verifier), VKEY, GUARDIAN, VKEY_DELAY, PENALTY_BPS);

        vm.prank(RANDO);
        vm.expectRevert(GasKillerSP1Arbiter.NotGuardian.selector);
        fresh.wireService(address(mockReg), address(adapter));

        vm.prank(GUARDIAN);
        fresh.wireService(address(mockReg), address(adapter));
        assertEq(address(fresh.operatorRegistry()), address(mockReg));
        assertEq(address(fresh.adapter()), address(adapter));

        vm.prank(GUARDIAN);
        vm.expectRevert(GasKillerSP1Arbiter.AlreadyWired.selector);
        fresh.wireService(address(mockReg), address(adapter));
    }

    // slash fails closed before wiring.
    function test_slash_requiresWiring() public {
        GasKillerSP1Arbiter fresh =
            new GasKillerSP1Arbiter(address(manager), address(verifier), VKEY, GUARDIAN, VKEY_DELAY, PENALTY_BPS);
        vm.expectRevert(GasKillerSP1Arbiter.NotWired.selector);
        fresh.slash(publicValues, "", _ids(1, 2));
    }

    // ---- slash ----

    // Happy path: valid proof, two commitments bound to the operator. Both forfeits open with
    // the configured penalty, the offense is recorded, and the operator's Schnorr key leaves
    // the REAL registry in the same transaction.
    function test_slash_happyPath() public {
        (,,, bool registeredBefore,) = registry.operators(op0);
        assertTrue(registeredBefore, "operator in the signer set before the slash");

        vm.expectEmit(true, true, false, true, address(arbiter));
        emit GasKillerSP1Arbiter.OffenseRecorded(offenseKey, op0, FAULT);
        vm.expectEmit(true, true, false, true, address(arbiter));
        emit GasKillerSP1Arbiter.ForfeitOpened(offenseKey, 1, PENALTY_BPS);
        vm.expectEmit(true, true, false, true, address(arbiter));
        emit GasKillerSP1Arbiter.ForfeitOpened(offenseKey, 2, PENALTY_BPS);
        arbiter.slash(publicValues, "", _ids(1, 2));

        // Both initiateForfeit calls reached the manager with the penalty.
        assertEq(manager.initiateCallCount(), 2, "two forfeits opened");
        (uint256 id0, uint16 bps0) = manager.initiateCalls(0);
        (uint256 id1, uint16 bps1) = manager.initiateCalls(1);
        assertEq(id0, 1);
        assertEq(uint256(bps0), PENALTY_BPS);
        assertEq(id1, 2);
        assertEq(uint256(bps1), PENALTY_BPS);

        // Offense ledger entry (replay protection state).
        (address recordedOp, uint64 recordedAt, bool recorded) = arbiter.offenses(offenseKey);
        assertTrue(recorded, "offense recorded");
        assertEq(recordedOp, op0, "attributed to the operator");
        assertEq(uint256(recordedAt), block.timestamp, "timestamped");

        // Ejection leg: the key is out of the live Schnorr signer set immediately.
        (,,, bool registeredAfter,) = registry.operators(op0);
        assertFalse(registeredAfter, "deregistered from the Schnorr registry");
        assertEq(registry.totalWeight(), 0, "signing weight gone");
        assertEq(adapter.getOperatorCount(), 0, "swept from the adapter set");
    }

    // The same (operator, faultDigest) proof cannot be consumed twice.
    function test_slash_replayReverts() public {
        arbiter.slash(publicValues, "", _ids(1, 2));
        vm.expectRevert(abi.encodeWithSelector(GasKillerSP1Arbiter.OffenseAlreadyRecorded.selector, offenseKey));
        arbiter.slash(publicValues, "", _ids(1, 2));
    }

    // Every supplied commitment must be bound to the accused operator — a caller cannot smuggle
    // someone else's commitment into the forfeit list.
    function test_slash_foreignCommitmentReverts() public {
        mockReg.setOperatorForCommitment(3, address(0xD00D));
        vm.expectRevert(abi.encodeWithSelector(GasKillerSP1Arbiter.CommitmentNotOperators.selector, 3, op0));
        arbiter.slash(publicValues, "", _ids(1, 3));
    }

    // A manager-side failure on one id (e.g. forfeit already pending) is caught and surfaced as
    // an event; the other forfeit still opens and the slash completes.
    function test_slash_partialManagerFailureStillOpensOthers() public {
        manager.setRevertOnInitiate(1, true);
        bytes memory reason = abi.encodeWithSelector(MockCommitmentManager.ForfeitPending.selector, uint256(1));

        vm.expectEmit(true, true, false, true, address(arbiter));
        emit GasKillerSP1Arbiter.ForfeitAttemptFailed(offenseKey, 1, reason);
        vm.expectEmit(true, true, false, true, address(arbiter));
        emit GasKillerSP1Arbiter.ForfeitOpened(offenseKey, 2, PENALTY_BPS);
        arbiter.slash(publicValues, "", _ids(1, 2));

        assertEq(manager.initiateCallCount(), 1, "only the surviving forfeit recorded");
        (uint256 id0,) = manager.initiateCalls(0);
        assertEq(id0, 2, "id 2 opened");
        (,, bool recorded) = arbiter.offenses(offenseKey);
        assertTrue(recorded, "offense still recorded");
        (,,, bool registered,) = registry.operators(op0);
        assertFalse(registered, "operator still ejected");
    }

    // If every forfeit fails the slash reverts: a proof that opens nothing must not be consumed.
    function test_slash_allManagerFailuresRevert() public {
        manager.setRevertOnInitiate(1, true);
        manager.setRevertOnInitiate(2, true);
        vm.expectRevert(GasKillerSP1Arbiter.NoForfeitsInitiated.selector);
        arbiter.slash(publicValues, "", _ids(1, 2));
    }

    // An empty id list is the eject-only path (capital already gone, key still signing): the
    // offense records and the ejection happens with no forfeits required.
    function test_slash_emptyIdsIsEjectOnly() public {
        uint256[] memory none = new uint256[](0);
        arbiter.slash(publicValues, "", none);

        assertEq(manager.initiateCallCount(), 0, "no forfeits attempted");
        (,, bool recorded) = arbiter.offenses(offenseKey);
        assertTrue(recorded, "offense recorded");
        (,,, bool registered,) = registry.operators(op0);
        assertFalse(registered, "operator ejected");
    }

    // An invalid proof reverts the whole slash (the mock verifier mirrors the gateway, which
    // reverts rather than returning false).
    function test_slash_invalidProofReverts() public {
        verifier.setOk(false);
        vm.expectRevert(MockSP1Verifier.InvalidProof.selector);
        arbiter.slash(publicValues, "", _ids(1, 2));
    }

    // ---- slashMore ----

    // A recorded offense authorizes follow-up forfeits (late-indexed delegations) without
    // re-verifying the proof.
    function test_slashMore_opensAdditionalForfeits() public {
        arbiter.slash(publicValues, "", _ids(1, 2));
        mockReg.setOperatorForCommitment(5, op0);

        vm.expectEmit(true, true, false, true, address(arbiter));
        emit GasKillerSP1Arbiter.ForfeitOpened(offenseKey, 5, PENALTY_BPS);
        arbiter.slashMore(offenseKey, _ids(5));

        assertEq(manager.initiateCallCount(), 3, "third forfeit opened");
        (uint256 id,) = manager.initiateCalls(2);
        assertEq(id, 5);
    }

    // No recorded offense, no forfeits.
    function test_slashMore_unknownOffenseReverts() public {
        bytes32 unknown = keccak256("never-happened");
        vm.expectRevert(abi.encodeWithSelector(GasKillerSP1Arbiter.OffenseNotRecorded.selector, unknown));
        arbiter.slashMore(unknown, _ids(1));
    }

    // slashMore must open at least one forfeit — it has no eject leg to justify a no-op.
    function test_slashMore_nothingOpenedReverts() public {
        arbiter.slash(publicValues, "", _ids(1, 2));
        mockReg.setOperatorForCommitment(5, op0);
        manager.setRevertOnInitiate(5, true);
        vm.expectRevert(GasKillerSP1Arbiter.NoForfeitsInitiated.selector);
        arbiter.slashMore(offenseKey, _ids(5));
    }

    // ---- crankExecute ----

    // The execute crank is best-effort: successes and failures are surfaced per id and a
    // failure does not block the rest of the batch.
    function test_crankExecute_recordsAndSurvivesFailures() public {
        manager.setRevertOnExecute(2, true);
        bytes memory reason = abi.encodeWithSelector(MockCommitmentManager.ExecuteFailed.selector, uint256(2));

        vm.expectEmit(true, false, false, true, address(arbiter));
        emit GasKillerSP1Arbiter.ForfeitExecuted(1);
        vm.expectEmit(true, false, false, true, address(arbiter));
        emit GasKillerSP1Arbiter.ForfeitExecutionFailed(2, reason);
        arbiter.crankExecute(_ids(1, 2));

        assertEq(manager.executeCallCount(), 1, "only the surviving execute recorded");
    }

    // ---- cancelForfeit ----

    function test_cancelForfeit_guardianOnly() public {
        vm.prank(RANDO);
        vm.expectRevert(GasKillerSP1Arbiter.NotGuardian.selector);
        arbiter.cancelForfeit(7);

        vm.prank(GUARDIAN);
        vm.expectEmit(true, false, false, true, address(arbiter));
        emit GasKillerSP1Arbiter.ForfeitCancelled(7);
        arbiter.cancelForfeit(7);

        assertEq(manager.cancelCallCount(), 1, "cancel reached the manager");
        assertEq(manager.cancelCalls(0), 7);
    }

    // ---- vkey rotation ----

    function test_proposeVkey_guardianOnly() public {
        vm.prank(RANDO);
        vm.expectRevert(GasKillerSP1Arbiter.NotGuardian.selector);
        arbiter.proposeVkey(NEW_VKEY);
    }

    // The timelock is the operators' exit guarantee: activation before the delay reverts, at
    // the deadline it goes through, and subsequent slashes verify against the ROTATED vkey.
    function test_vkeyRotation_timelocked() public {
        vm.prank(GUARDIAN);
        arbiter.proposeVkey(NEW_VKEY);
        uint256 activeAt = block.timestamp + VKEY_DELAY;
        assertEq(arbiter.pendingVkey(), NEW_VKEY);
        assertEq(arbiter.pendingVkeyActiveAt(), activeAt);

        vm.expectRevert(abi.encodeWithSelector(GasKillerSP1Arbiter.VkeyTimelockActive.selector, activeAt));
        arbiter.activateVkey();
        assertEq(arbiter.vkey(), VKEY, "old vkey still active");

        vm.warp(activeAt);
        arbiter.activateVkey(); // permissionless once elapsed
        assertEq(arbiter.vkey(), NEW_VKEY, "vkey rotated");
        assertEq(arbiter.pendingVkey(), bytes32(0), "proposal cleared");
        assertEq(arbiter.pendingVkeyActiveAt(), 0, "deadline cleared");

        // The verifier mock now demands the NEW vkey — the slash passing proves the arbiter
        // forwards the rotated key.
        verifier.setExpectedVkey(NEW_VKEY);
        arbiter.slash(publicValues, "", _ids(1, 2));
        (,, bool recorded) = arbiter.offenses(offenseKey);
        assertTrue(recorded, "slash verified under the rotated vkey");
    }

    // A cancelled proposal leaves nothing to activate.
    function test_cancelVkeyProposal() public {
        vm.prank(GUARDIAN);
        arbiter.proposeVkey(NEW_VKEY);

        vm.prank(RANDO);
        vm.expectRevert(GasKillerSP1Arbiter.NotGuardian.selector);
        arbiter.cancelVkeyProposal();

        vm.prank(GUARDIAN);
        vm.expectEmit(true, false, false, false, address(arbiter));
        emit GasKillerSP1Arbiter.VkeyProposalCancelled(NEW_VKEY);
        arbiter.cancelVkeyProposal();

        assertEq(arbiter.pendingVkey(), bytes32(0));
        assertEq(arbiter.pendingVkeyActiveAt(), 0);
        vm.warp(block.timestamp + VKEY_DELAY);
        vm.expectRevert(GasKillerSP1Arbiter.NoPendingVkey.selector);
        arbiter.activateVkey();
    }

    function test_activateVkey_noPendingReverts() public {
        vm.expectRevert(GasKillerSP1Arbiter.NoPendingVkey.selector);
        arbiter.activateVkey();
    }

    // ---- IArbiter surface ----

    // ERC-165: the IArbiter id (xor of its three selectors, per upstream convention) and the
    // ERC-165 id itself are supported; everything else is not.
    function test_supportsInterface() public view {
        bytes4 arbiterId = IArbiter.commitmentManager.selector ^ IArbiter.arbiterCapabilities.selector
            ^ IArbiter.arbiterMetadataURI.selector;
        assertTrue(arbiter.supportsInterface(arbiterId), "IArbiter id");
        assertTrue(arbiter.supportsInterface(0x01ffc9a7), "ERC-165 id");
        assertFalse(arbiter.supportsInterface(0xffffffff), "sentinel rejected");
    }

    // Capabilities advertise exactly INITIATE_FORFEIT | CANCEL_FORFEIT.
    function test_arbiterCapabilitiesAndViews() public {
        assertEq(arbiter.arbiterCapabilities(), 3, "INITIATE_FORFEIT | CANCEL_FORFEIT");
        assertEq(arbiter.commitmentManager(), address(manager));

        vm.prank(RANDO);
        vm.expectRevert(GasKillerSP1Arbiter.NotGuardian.selector);
        arbiter.setMetadataURI("ipfs://nope");

        vm.prank(GUARDIAN);
        arbiter.setMetadataURI("ipfs://arbiter-metadata");
        assertEq(arbiter.arbiterMetadataURI(), "ipfs://arbiter-metadata");
    }
}
