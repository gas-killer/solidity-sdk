// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SchnorrCommitmentsAdapter} from "../../src/commitments/SchnorrCommitmentsAdapter.sol";
import {SchnorrStakeRegistry} from "../../src/schnorr/SchnorrStakeRegistry.sol";
import {MockOperatorRegistry} from "./mocks/CommitmentsMocks.sol";

/// @notice Lifecycle coverage for `SchnorrCommitmentsAdapter` driving a REAL
///         `SchnorrStakeRegistry` off a mocked Commitments `OperatorRegistry`.
///
/// The Schnorr key material below is the Rust-generated parity fixture shared with
/// `test/SchnorrStakeRegistry.t.sol` (`common/examples/schnorr_parity_fixture.rs`) — new
/// Schnorr signatures cannot be produced in Solidity, so the fixture keys, PoPs and
/// aggregate signatures are reused verbatim. Operator identity is
/// `registry.pointAddress(opX[i], opY[i])`, so joins are pranked from those addresses.
contract SchnorrCommitmentsAdapterTest is Test {
    MockOperatorRegistry mockReg;
    SchnorrCommitmentsAdapter adapter;
    SchnorrStakeRegistry registry;

    // ---- fixture: operators (x, y, PoP) — from test/SchnorrStakeRegistry.t.sol ----
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

    // ---- stake/weight quantization ----
    uint256 constant SCALE = 1 ether;
    uint256 constant STAKE = 100 ether; // quantizes to weight 100, matching the fixture's uniform weights
    uint256 constant WEIGHT = 100;

    address constant ARBITER = address(0xA5B1);
    address constant RANDO = address(0xBEEF);

    function setUp() public {
        // Move off genesis so a valid reference block (< effectiveBlock) exists later.
        vm.roll(1000);
        mockReg = new MockOperatorRegistry();
        // Deploy order matters: the registry's owner is immutable, so the adapter exists first.
        adapter = new SchnorrCommitmentsAdapter(address(mockReg), SCALE, address(this));
        registry = new SchnorrStakeRegistry(2, 3, address(adapter), 0); // 2/3 threshold, no notice
        adapter.setRegistry(address(registry));
        adapter.setArbiter(ARBITER);
    }

    function _refBlock() internal view returns (uint256) {
        return block.number - 1;
    }

    /// Operator identity: the Ethereum address of the pubkey point (what the node pranks from).
    function _opAddr(uint256 i) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(opX[i], opY[i])))));
    }

    function _blsG1(uint256 i) internal pure returns (uint256[2] memory) {
        return [i * 10 + 1, i * 10 + 2];
    }

    function _blsG2(uint256 i) internal pure returns (uint256[4] memory) {
        return [i * 10 + 3, i * 10 + 4, i * 10 + 5, i * 10 + 6];
    }

    function _socket(uint256 i) internal pure returns (string memory) {
        return string.concat("node-", vm.toString(i), ":3001");
    }

    /// Fund operator `i` in the mocked Commitments registry and join it through `a`.
    function _joinOn(SchnorrCommitmentsAdapter a, uint256 i) internal {
        address op = _opAddr(i);
        mockReg.setOperator(op, true, STAKE);
        uint256[2] memory g1 = _blsG1(i);
        uint256[4] memory g2 = _blsG2(i);
        string memory socket = _socket(i);
        vm.prank(op);
        a.join(opX[i], opY[i], popS[i], popR[i], g1, g2, socket);
    }

    function _join(uint256 i) internal {
        _joinOn(adapter, i);
    }

    // ---- wiring one-shots ----

    // The registry pointer can be set exactly once: the adapter is the registry's immutable
    // owner, so re-pointing it would orphan the mirror.
    function test_setRegistry_isOneShot() public {
        vm.expectRevert(SchnorrCommitmentsAdapter.AlreadyWired.selector);
        adapter.setRegistry(address(registry));
    }

    function test_setRegistry_onlyAdmin() public {
        SchnorrCommitmentsAdapter fresh = new SchnorrCommitmentsAdapter(address(mockReg), SCALE, address(this));
        vm.prank(RANDO);
        vm.expectRevert(SchnorrCommitmentsAdapter.NotAdmin.selector);
        fresh.setRegistry(address(registry));
        // Zero address is rejected rather than burning the one shot on a useless value.
        vm.expectRevert(SchnorrCommitmentsAdapter.ZeroAddress.selector);
        fresh.setRegistry(address(0));
    }

    function test_setArbiter_isOneShot() public {
        vm.expectRevert(SchnorrCommitmentsAdapter.AlreadyWired.selector);
        adapter.setArbiter(ARBITER);
    }

    function test_setArbiter_onlyAdmin() public {
        SchnorrCommitmentsAdapter fresh = new SchnorrCommitmentsAdapter(address(mockReg), SCALE, address(this));
        vm.prank(RANDO);
        vm.expectRevert(SchnorrCommitmentsAdapter.NotAdmin.selector);
        fresh.setArbiter(ARBITER);
        vm.expectRevert(SchnorrCommitmentsAdapter.ZeroAddress.selector);
        fresh.setArbiter(address(0));
    }

    // Lifecycle entry points fail closed until the registry is wired.
    function test_join_requiresWiring() public {
        SchnorrCommitmentsAdapter fresh = new SchnorrCommitmentsAdapter(address(mockReg), SCALE, address(this));
        address op = _opAddr(0);
        mockReg.setOperator(op, true, STAKE);
        uint256[2] memory g1 = _blsG1(0);
        uint256[4] memory g2 = _blsG2(0);
        vm.prank(op);
        vm.expectRevert(SchnorrCommitmentsAdapter.NotWired.selector);
        fresh.join(opX[0], opY[0], popS[0], popR[0], g1, g2, "node-0:3001");
    }

    // ---- join ----

    // Happy path with no notice window: the operator lands directly in the real registry with
    // weight = stake / weightScale, and the p2p sidecar is readable from getOperatorSet.
    function test_join_registersWithQuantizedWeight() public {
        address op = _opAddr(0);
        mockReg.setOperator(op, true, STAKE);
        uint256[2] memory g1 = _blsG1(0);
        uint256[4] memory g2 = _blsG2(0);

        vm.prank(op);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit SchnorrCommitmentsAdapter.OperatorJoined(op, WEIGHT, false);
        adapter.join(opX[0], opY[0], popS[0], popR[0], g1, g2, "node-0:3001");

        (uint256 x, uint256 y, uint96 w, bool registered,) = registry.operators(op);
        assertTrue(registered, "registered in the Schnorr registry");
        assertEq(x, opX[0], "key mirrored");
        assertEq(y, opY[0], "key mirrored");
        assertEq(uint256(w), WEIGHT, "weight = stake / weightScale");
        assertEq(registry.totalWeight(), WEIGHT, "totalWeight credited");

        SchnorrCommitmentsAdapter.OperatorView[] memory set = adapter.getOperatorSet();
        assertEq(set.length, 1, "one operator in the set");
        assertEq(set[0].operator, op, "identity");
        assertEq(set[0].weight, WEIGHT, "live registry weight");
        assertEq(set[0].info.secpX, opX[0], "sidecar secp x");
        assertEq(set[0].info.secpY, opY[0], "sidecar secp y");
        assertEq(set[0].info.blsG1[0], g1[0], "sidecar bls g1");
        assertEq(set[0].info.blsG2[0], g2[0], "sidecar bls g2");
        assertEq(set[0].info.blsG2[3], g2[3], "sidecar bls g2");
        assertEq(set[0].info.socket, "node-0:3001", "sidecar socket");
    }

    // Only a registered Commitments operator may join — stake is the source of truth.
    function test_join_rejectsNonCommitmentsOperator() public {
        address op = _opAddr(0);
        uint256[2] memory g1 = _blsG1(0);
        uint256[4] memory g2 = _blsG2(0);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(SchnorrCommitmentsAdapter.NotCommitmentsOperator.selector, op));
        adapter.join(opX[0], opY[0], popS[0], popR[0], g1, g2, "node-0:3001");
    }

    // The submitted key's address must BE the caller: operator 0 cannot join with operator 1's
    // key even though the PoP for that key is valid.
    function test_join_rejectsKeyThatIsNotSender() public {
        address op0 = _opAddr(0);
        address op1 = _opAddr(1);
        mockReg.setOperator(op0, true, STAKE);
        uint256[2] memory g1 = _blsG1(0);
        uint256[4] memory g2 = _blsG2(0);
        vm.prank(op0);
        vm.expectRevert(abi.encodeWithSelector(SchnorrCommitmentsAdapter.KeyIsNotSender.selector, op1, op0));
        adapter.join(opX[1], opY[1], popS[1], popR[1], g1, g2, "node-0:3001");
    }

    // Sub-scale stake quantizes to weight 0 and is rejected rather than registered weightless.
    function test_join_rejectsStakeBelowScale() public {
        address op = _opAddr(0);
        mockReg.setOperator(op, true, SCALE - 1);
        uint256[2] memory g1 = _blsG1(0);
        uint256[4] memory g2 = _blsG2(0);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(SchnorrCommitmentsAdapter.StakeBelowScale.selector, SCALE - 1, SCALE));
        adapter.join(opX[0], opY[0], popS[0], popR[0], g1, g2, "node-0:3001");
    }

    // The end-to-end point: after all three fixture operators join THROUGH THE ADAPTER, the
    // registry's aggregate equals the Rust X_all and the Rust-assembled full-participation
    // signature verifies through the real on-chain path.
    function test_join_allThree_fullFixtureSignatureVerifies() public {
        for (uint256 i = 0; i < 3; i++) {
            _join(i);
        }
        assertEq(registry.aggX(), XALL_X, "aggregate matches Rust X_all");
        assertEq(registry.aggY(), XALL_Y, "aggregate matches Rust X_all");
        assertEq(registry.totalWeight(), 3 * WEIGHT, "totalWeight");
        assertEq(adapter.getOperatorCount(), 3, "all three in the sidecar set");

        vm.roll(block.number + 10); // refBlock = block.number-1 stays >= effectiveBlock
        address[] memory none = new address[](0);
        assertTrue(registry.isValidSignature(MESSAGE, FULL_S, FULL_R, none, _refBlock()));
    }

    // ---- syncWeight ----

    // A stake change is mirrored into the registry: weight + totalWeight move and the registry
    // announces it (OperatorWeightUpdated), followed by the adapter's own WeightSynced.
    function test_syncWeight_updatesWeightAndTotal() public {
        for (uint256 i = 0; i < 3; i++) {
            _join(i);
        }
        address op = _opAddr(0);
        mockReg.setStake(op, 250 ether);

        vm.expectEmit(true, false, false, true, address(registry));
        emit SchnorrStakeRegistry.OperatorWeightUpdated(op, WEIGHT, 250);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit SchnorrCommitmentsAdapter.WeightSynced(op, WEIGHT, 250);
        adapter.syncWeight(op);

        (,, uint96 w,,) = registry.operators(op);
        assertEq(uint256(w), 250, "weight re-quantized");
        assertEq(registry.totalWeight(), 250 + 2 * WEIGHT, "totalWeight adjusted in place");
    }

    // An unchanged stake is a no-op: the watermark must NOT advance, so cranking the sync
    // does not invalidate in-flight rounds for free.
    function test_syncWeight_unchangedStakeIsNoop() public {
        _join(0);
        uint256 watermark = registry.effectiveBlock();
        vm.roll(block.number + 5);
        adapter.syncWeight(_opAddr(0));
        assertEq(registry.effectiveBlock(), watermark, "watermark untouched");
        assertEq(registry.totalWeight(), WEIGHT, "weight untouched");
    }

    // An operator that stops being Commitments-registered is dropped from the registry AND the
    // sidecar set. No signature re-check against pre-drop fixtures — any mutation breaks them —
    // except the one that is cryptographically owed: the SUB fixture was signed by {0,2} against
    // X_all − X_1, which is exactly the post-drop aggregate, so it verifies with no non-signers.
    function test_syncWeight_dropsOperatorNoLongerRegistered() public {
        for (uint256 i = 0; i < 3; i++) {
            _join(i);
        }
        address op1 = _opAddr(1);
        mockReg.setIsOperator(op1, false);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit SchnorrCommitmentsAdapter.OperatorDropped(op1, 0);
        adapter.syncWeight(op1);

        (,,, bool registered,) = registry.operators(op1);
        assertFalse(registered, "removed from the Schnorr registry");
        assertEq(registry.totalWeight(), 2 * WEIGHT, "weight debited");
        assertEq(adapter.getOperatorCount(), 2, "removed from the sidecar set");
        SchnorrCommitmentsAdapter.OperatorView[] memory set = adapter.getOperatorSet();
        for (uint256 i = 0; i < set.length; i++) {
            assertTrue(set[i].operator != op1, "dropped operator not enumerated");
        }

        vm.roll(block.number + 10);
        address[] memory none = new address[](0);
        assertTrue(
            registry.isValidSignature(MESSAGE, SUB_S, SUB_R, none, _refBlock()),
            "subset signature matches the post-drop aggregate"
        );
    }

    // Stake decaying below the scale floor also drops the operator (weight 0 is not registrable).
    function test_syncWeight_dropsSubScaleStake() public {
        _join(0);
        address op = _opAddr(0);
        mockReg.setStake(op, SCALE - 1);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit SchnorrCommitmentsAdapter.OperatorDropped(op, SCALE - 1);
        adapter.syncWeight(op);

        (,,, bool registered,) = registry.operators(op);
        assertFalse(registered, "dropped from the registry");
        assertEq(adapter.getOperatorCount(), 0, "dropped from the sidecar set");
    }

    // ---- eject ----

    // The arbiter path: immediate removal, and idempotent so a slash transaction can never
    // fail on the ejection leg.
    function test_eject_byArbiter_immediateAndIdempotent() public {
        _join(0);
        address op = _opAddr(0);

        vm.prank(ARBITER);
        adapter.eject(op);

        (,,, bool registered,) = registry.operators(op);
        assertFalse(registered, "removed immediately");
        assertEq(registry.totalWeight(), 0, "weight debited");
        assertEq(adapter.getOperatorCount(), 0, "sidecar swept");

        vm.prank(ARBITER);
        adapter.eject(op); // second call must not revert
        assertEq(adapter.getOperatorCount(), 0);
    }

    // The admin shares the forced-removal authority (emergency path).
    function test_eject_byAdminAllowed() public {
        _join(0);
        adapter.eject(_opAddr(0)); // test contract is the admin
        assertEq(adapter.getOperatorCount(), 0);
    }

    function test_eject_byRandoReverts() public {
        _join(0);
        address op = _opAddr(0);
        vm.prank(RANDO);
        vm.expectRevert(SchnorrCommitmentsAdapter.NotArbiter.selector);
        adapter.eject(op);
    }

    // ---- leave ----

    // With no notice window the voluntary exit applies immediately.
    function test_leave_immediateWithoutNoticeWindow() public {
        _join(0);
        address op = _opAddr(0);

        vm.prank(op);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit SchnorrCommitmentsAdapter.OperatorLeft(op, false);
        adapter.leave();

        (,,, bool registered,) = registry.operators(op);
        assertFalse(registered, "removed immediately");
        assertEq(adapter.getOperatorCount(), 0, "sidecar swept");
    }

    function test_leave_notJoinedReverts() public {
        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(SchnorrCommitmentsAdapter.NotJoined.selector, RANDO));
        adapter.leave();
    }

    // ---- notice-window stack ----

    uint256 constant NOTICE = 5;

    /// A second stack whose registry enforces a real notice window.
    function _noticeStack() internal returns (SchnorrCommitmentsAdapter a, SchnorrStakeRegistry r) {
        a = new SchnorrCommitmentsAdapter(address(mockReg), SCALE, address(this));
        r = new SchnorrStakeRegistry(2, 3, address(a), NOTICE);
        a.setRegistry(address(r));
        a.setArbiter(ARBITER);
    }

    // Under a notice window a join is announced, not applied: it queues in the registry and the
    // sidecar reports the operator with weight 0 until the change commits.
    function test_noticeWindow_joinEnqueues() public {
        (SchnorrCommitmentsAdapter a, SchnorrStakeRegistry r) = _noticeStack();
        address op = _opAddr(0);
        mockReg.setOperator(op, true, STAKE);
        uint256[2] memory g1 = _blsG1(0);
        uint256[4] memory g2 = _blsG2(0);

        vm.prank(op);
        vm.expectEmit(true, false, false, true, address(a));
        emit SchnorrCommitmentsAdapter.OperatorJoined(op, WEIGHT, true);
        a.join(opX[0], opY[0], popS[0], popR[0], g1, g2, "node-0:3001");

        assertEq(r.pendingChangeCount(), 1, "queued");
        (,,, bool registered,) = r.operators(op);
        assertFalse(registered, "NOT registered until commit");
        assertEq(r.totalWeight(), 0, "no weight credited while pending");

        SchnorrCommitmentsAdapter.OperatorView[] memory set = a.getOperatorSet();
        assertEq(set.length, 1, "sidecar published at join time");
        assertEq(set[0].weight, 0, "pending operators report weight 0");
    }

    // commitNext is gated by the registry's window, then applies the queued registration.
    function test_noticeWindow_commitNextGatedThenApplies() public {
        (SchnorrCommitmentsAdapter a, SchnorrStakeRegistry r) = _noticeStack();
        _joinOn(a, 0);
        uint256 eligible = r.nextPossibleMutationBlock();
        assertEq(eligible, block.number + NOTICE, "horizon published");

        vm.expectRevert(abi.encodeWithSelector(SchnorrStakeRegistry.NoticeWindowNotElapsed.selector, eligible));
        a.commitNext();

        vm.roll(eligible);
        a.commitNext();

        (,, uint96 w, bool registered,) = r.operators(_opAddr(0));
        assertTrue(registered, "applied after the window");
        assertEq(uint256(w), WEIGHT, "queued weight credited");
        assertEq(r.pendingChangeCount(), 0, "dequeued");
        assertEq(a.getOperatorCount(), 1, "sidecar kept for the committed operator");
    }

    // Ejecting mid-window performs the targeted cancel: the queued change is dropped, nothing
    // reverts, and nothing ever lands in the registry.
    function test_noticeWindow_ejectMidWindowCancelsPending() public {
        (SchnorrCommitmentsAdapter a, SchnorrStakeRegistry r) = _noticeStack();
        _joinOn(a, 0);
        address op = _opAddr(0);
        assertEq(r.pendingChangeCount(), 1, "queued");

        vm.prank(ARBITER);
        a.eject(op); // must not revert mid-window

        assertEq(r.pendingChangeCount(), 0, "pending change cancelled");
        assertEq(r.nextPossibleMutationBlock(), type(uint256).max, "horizon released");
        (,,, bool registered,) = r.operators(op);
        assertFalse(registered, "never registered");
        assertEq(a.getOperatorCount(), 0, "sidecar swept");

        // Nothing left to apply once the window elapses.
        vm.roll(block.number + NOTICE);
        vm.expectRevert(SchnorrStakeRegistry.NoPendingChange.selector);
        a.commitNext();
    }
}
