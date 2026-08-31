// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SchnorrNonceRegistry} from "../src/schnorr/SchnorrNonceRegistry.sol";
import {SchnorrStakeRegistry} from "../src/schnorr/SchnorrStakeRegistry.sol";
import {ISchnorrOperatorRegistry} from "../src/schnorr/interface/ISchnorrOperatorRegistry.sol";
import {ISchnorrNonceRegistry} from "../src/schnorr/interface/ISchnorrNonceRegistry.sol";
import {Secp256k1} from "../src/schnorr/libraries/Secp256k1.sol";
import {SchnorrVerify} from "../src/schnorr/libraries/SchnorrVerify.sol";

/// @notice Test-only affine scalar multiplication (double-and-add over `Secp256k1.add`).
///         Wildly gas-inefficient — which is fine: it exists so these tests can create
///         keys and Schnorr signatures entirely in Solidity, with no Rust fixture
///         circularity on the registry address / chain id the registration message binds.
library TestCurve {
    uint256 constant GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    uint256 constant GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
    uint256 constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function mulG(uint256 k) internal view returns (uint256 x, uint256 y) {
        uint256 rx;
        uint256 ry;
        for (uint256 i = 0; i < 256; i++) {
            (rx, ry) = Secp256k1.add(rx, ry, rx, ry);
            if ((k >> (255 - i)) & 1 == 1) {
                (rx, ry) = Secp256k1.add(rx, ry, GX, GY);
            }
        }
        return (rx, ry);
    }

    function pointAddr(uint256 x, uint256 y) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(x, y)))));
    }

    /// Single-key Schnorr signature in the repo convention:
    /// `e = keccak256(Xx ‖ Xparity ‖ m ‖ Raddr) mod n`, `s = k − e·x (mod n)`.
    function signSingle(uint256 privKey, bytes32 message, uint256 nonce)
        internal
        view
        returns (uint256 s, address rAddr)
    {
        (uint256 px, uint256 py) = mulG(privKey);
        (uint256 rx, uint256 ry) = mulG(nonce);
        rAddr = pointAddr(rx, ry);
        uint256 e = uint256(keccak256(abi.encodePacked(px, uint8(py & 1), message, rAddr))) % N;
        s = addmod(nonce, N - mulmod(e, privKey, N), N);
    }
}

contract SchnorrNonceRegistryTest is Test {
    // Fixed address so the Rust parity vector (which bakes the registry address into the
    // registration message) can pin the same constants.
    address constant REGISTRY_ADDR = 0x4242424242424242424242424242424242424242;

    // Test operator secret keys (arbitrary valid scalars).
    uint256 constant KEY_A = 0xA11CE00000000000000000000000000000000000000000000000000000000001;
    uint256 constant KEY_B = 0xB0B0000000000000000000000000000000000000000000000000000000000002;
    uint256 constant WEIGHT = 100;

    SchnorrStakeRegistry stakeRegistry;
    SchnorrNonceRegistry registry;

    uint256 aX;
    uint256 aY;
    address aId;

    function setUp() public {
        vm.roll(1000);
        // noticeWindow 0: this suite only exercises batch commitment, and
        // `registerOperator` bypasses the window regardless.
        stakeRegistry = new SchnorrStakeRegistry(2, 3, address(this), 0);
        deployCodeTo(
            "SchnorrNonceRegistry.sol:SchnorrNonceRegistry",
            abi.encode(ISchnorrOperatorRegistry(address(stakeRegistry))),
            REGISTRY_ADDR
        );
        registry = SchnorrNonceRegistry(REGISTRY_ADDR);

        (aX, aY) = TestCurve.mulG(KEY_A);
        aId = TestCurve.pointAddr(aX, aY);
        _registerOperator(KEY_A, 1);
    }

    function _registerOperator(uint256 key, uint256 nonceSeed) internal returns (address id) {
        (uint256 x, uint256 y) = TestCurve.mulG(key);
        id = TestCurve.pointAddr(x, y);
        (uint256 popS, address popR) = TestCurve.signSingle(key, stakeRegistry.popMessage(id), nonceSeed + 7777);
        stakeRegistry.registerOperator(x, y, WEIGHT, popS, popR);
    }

    function _signBatch(uint256 key, address id, uint64 batchIndex, uint64 startSlot, uint64 count, bytes32 root)
        internal
        view
        returns (uint256 s, address rAddr)
    {
        bytes32 message = registry.batchMessage(id, batchIndex, startSlot, count, root);
        return TestCurve.signSingle(key, message, uint256(keccak256(abi.encodePacked("nonce", batchIndex, root))));
    }

    function _register(uint256 key, uint256 x, uint256 y, uint64 count, bytes32 root) internal {
        address id = TestCurve.pointAddr(x, y);
        uint64 batchIndex = uint64(registry.batchCount(id));
        uint64 startSlot = registry.coverage(id);
        (uint256 s, address rAddr) = _signBatch(key, id, batchIndex, startSlot, count, root);
        registry.registerBatch(x, y, root, count, s, rAddr);
    }

    // ---- happy path: contiguous append-only coverage + views ----

    function test_registerBatches_contiguousCoverage() public {
        assertEq(registry.coverage(aId), 0);

        vm.expectEmit(true, true, true, true, REGISTRY_ADDR);
        emit ISchnorrNonceRegistry.NonceBatchRegistered(aId, 0, 0, 128, bytes32(uint256(1)));
        _register(KEY_A, aX, aY, 128, bytes32(uint256(1)));

        assertEq(registry.coverage(aId), 128);
        assertEq(registry.batchCount(aId), 1);

        _register(KEY_A, aX, aY, 64, bytes32(uint256(2)));
        assertEq(registry.coverage(aId), 192);
        assertEq(registry.batchCount(aId), 2);

        // batchAt resolves every region and edge correctly.
        (uint64 batchIndex, bytes32 root, uint64 offset) = registry.batchAt(aId, 0);
        assertEq(batchIndex, 0);
        assertEq(root, bytes32(uint256(1)));
        assertEq(offset, 0);

        (batchIndex, root, offset) = registry.batchAt(aId, 127);
        assertEq(batchIndex, 0);
        assertEq(offset, 127);

        (batchIndex, root, offset) = registry.batchAt(aId, 128);
        assertEq(batchIndex, 1);
        assertEq(root, bytes32(uint256(2)));
        assertEq(offset, 0);

        (batchIndex, root, offset) = registry.batchAt(aId, 191);
        assertEq(batchIndex, 1);
        assertEq(offset, 63);

        // Beyond coverage reverts.
        vm.expectRevert(abi.encodeWithSelector(SchnorrNonceRegistry.NotCovered.selector, aId, 192));
        registry.batchAt(aId, 192);
    }

    function test_batchAt_manyBatches_binarySearch() public {
        for (uint64 i = 0; i < 7; i++) {
            _register(KEY_A, aX, aY, 10 + i, bytes32(uint256(100 + i)));
        }
        // Walk every covered slot and cross-check against the linear answer.
        uint64 start = 0;
        for (uint64 i = 0; i < 7; i++) {
            uint64 count = 10 + i;
            (uint64 batchIndex, bytes32 root, uint64 offset) = registry.batchAt(aId, start);
            assertEq(batchIndex, i);
            assertEq(root, bytes32(uint256(100 + i)));
            assertEq(offset, 0);
            (batchIndex,, offset) = registry.batchAt(aId, start + count - 1);
            assertEq(batchIndex, i);
            assertEq(offset, count - 1);
            start += count;
        }
    }

    // ---- authentication ----

    function test_unregisteredOperator_rejected() public {
        (uint256 bX, uint256 bY) = TestCurve.mulG(KEY_B);
        address bId = TestCurve.pointAddr(bX, bY);
        (uint256 s, address rAddr) = _signBatch(KEY_B, bId, 0, 0, 8, bytes32(uint256(3)));
        vm.expectRevert(abi.encodeWithSelector(SchnorrNonceRegistry.NotRegisteredOperator.selector, bId));
        registry.registerBatch(bX, bY, bytes32(uint256(3)), 8, s, rAddr);

        // After stake registration, the same call succeeds.
        _registerOperator(KEY_B, 2);
        registry.registerBatch(bX, bY, bytes32(uint256(3)), 8, s, rAddr);
        assertEq(registry.coverage(bId), 8);
    }

    /// An exited operator's record survives as a tombstone with `registered == false`, so it
    /// can no longer extend its coverage even though `x`/`y` still read back.
    function test_exitedOperator_rejected() public {
        _register(KEY_A, aX, aY, 8, bytes32(uint256(20)));
        stakeRegistry.deregisterOperator(aId);
        (uint256 x,,, bool registered,) = stakeRegistry.operators(aId);
        assertEq(x, aX, "tombstone keeps the key readable");
        assertFalse(registered, "tombstone is out of the active set");

        (uint256 s, address rAddr) = _signBatch(KEY_A, aId, 1, 8, 8, bytes32(uint256(21)));
        vm.expectRevert(abi.encodeWithSelector(SchnorrNonceRegistry.NotRegisteredOperator.selector, aId));
        registry.registerBatch(aX, aY, bytes32(uint256(21)), 8, s, rAddr);
        // Coverage already committed before the exit is untouched.
        assertEq(registry.coverage(aId), 8);
    }

    function test_wrongKeySignature_rejected() public {
        // Operator B (registered) tries to commit a batch for operator A's key.
        _registerOperator(KEY_B, 2);
        (uint256 s, address rAddr) = _signBatch(KEY_B, aId, 0, 0, 8, bytes32(uint256(4)));
        vm.expectRevert(SchnorrNonceRegistry.InvalidRegistrationSignature.selector);
        registry.registerBatch(aX, aY, bytes32(uint256(4)), 8, s, rAddr);
    }

    function test_tamperedFields_rejected() public {
        (uint256 s, address rAddr) = _signBatch(KEY_A, aId, 0, 0, 8, bytes32(uint256(5)));
        // Signature was made for count=8; submitting count=9 must fail.
        vm.expectRevert(SchnorrNonceRegistry.InvalidRegistrationSignature.selector);
        registry.registerBatch(aX, aY, bytes32(uint256(5)), 9, s, rAddr);
        // Wrong root likewise.
        vm.expectRevert(SchnorrNonceRegistry.InvalidRegistrationSignature.selector);
        registry.registerBatch(aX, aY, bytes32(uint256(6)), 8, s, rAddr);
    }

    function test_replayedRegistration_rejected() public {
        (uint256 s, address rAddr) = _signBatch(KEY_A, aId, 0, 0, 8, bytes32(uint256(7)));
        registry.registerBatch(aX, aY, bytes32(uint256(7)), 8, s, rAddr);
        // Replaying the identical registration must fail: batchIndex and startSlot have
        // both advanced, so the signed message no longer matches.
        vm.expectRevert(SchnorrNonceRegistry.InvalidRegistrationSignature.selector);
        registry.registerBatch(aX, aY, bytes32(uint256(7)), 8, s, rAddr);
    }

    function test_chainIdBinding() public {
        (uint256 s, address rAddr) = _signBatch(KEY_A, aId, 0, 0, 8, bytes32(uint256(8)));
        vm.chainId(1);
        vm.expectRevert(SchnorrNonceRegistry.InvalidRegistrationSignature.selector);
        registry.registerBatch(aX, aY, bytes32(uint256(8)), 8, s, rAddr);
        vm.chainId(31337);
        registry.registerBatch(aX, aY, bytes32(uint256(8)), 8, s, rAddr);
    }

    function test_keyMismatchAgainstStakeRegistry_rejected() public {
        // A key pair whose pointAddress collides with a registered id cannot exist, but a
        // caller may pass coordinates that hash to an id whose registered record differs.
        // Simulate via a mock registry that returns a mismatched record.
        MockOperatorRegistry mock = new MockOperatorRegistry();
        SchnorrNonceRegistry fresh = new SchnorrNonceRegistry(ISchnorrOperatorRegistry(address(mock)));
        mock.set(fresh.pointAddress(aX, aY), aX + 1, aY, true);
        (uint256 s, address rAddr) = TestCurve.signSingle(KEY_A, bytes32(uint256(1)), 3);
        vm.expectRevert(SchnorrNonceRegistry.KeyMismatch.selector);
        fresh.registerBatch(aX, aY, bytes32(uint256(9)), 8, s, rAddr);
    }

    // ---- bounds ----

    function test_countBounds() public {
        (uint256 s, address rAddr) = _signBatch(KEY_A, aId, 0, 0, 0, bytes32(uint256(10)));
        vm.expectRevert(SchnorrNonceRegistry.ZeroCount.selector);
        registry.registerBatch(aX, aY, bytes32(uint256(10)), 0, s, rAddr);

        uint64 tooLarge = registry.MAX_BATCH_SLOTS() + 1;
        (s, rAddr) = _signBatch(KEY_A, aId, 0, 0, tooLarge, bytes32(uint256(10)));
        vm.expectRevert(SchnorrNonceRegistry.CountTooLarge.selector);
        registry.registerBatch(aX, aY, bytes32(uint256(10)), tooLarge, s, rAddr);
    }

    // ---- Rust parity anchor ----

    /// Mirrors `precommit::tests::batch_message_parity_vector` in the `gas-killer/service`
    /// repo — identical inputs, identical constant. If the preimage layout changes,
    /// regenerate BOTH.
    function test_batchMessage_parityWithRust() public view {
        assertEq(block.chainid, 31337, "parity vector assumes the default test chain id");
        bytes32 message = registry.batchMessage(
            0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa,
            1,
            1024,
            2048,
            bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111))
        );
        assertEq(message, bytes32(0x40d92eb65c7bf4b8a1af08673c34e217aaef9979016364b87cc9b078c26569e7));
    }

    /// The in-test signer itself must satisfy the production verifier — anchors the
    /// TestCurve helper to the same convention the Rust signer uses.
    function test_testSigner_matchesSchnorrVerify() public view {
        bytes32 message = keccak256("self check");
        (uint256 s, address rAddr) = TestCurve.signSingle(KEY_A, message, 987654321);
        // Direct library call — the same code path registerBatch uses.
        assertTrue(SchnorrVerify.verify(aX, uint8(aY & 1), message, s, rAddr));
        assertFalse(SchnorrVerify.verify(aX, uint8(aY & 1), keccak256("other"), s, rAddr));
    }
}

/// @dev Minimal operator-registry mock for the KeyMismatch branch.
contract MockOperatorRegistry is ISchnorrOperatorRegistry {
    struct Record {
        uint256 x;
        uint256 y;
        bool registered;
    }

    mapping(address => Record) internal records;

    function set(address id, uint256 x, uint256 y, bool registered) external {
        records[id] = Record(x, y, registered);
    }

    function operators(address id) external view returns (uint256, uint256, uint96, bool, uint48) {
        Record storage r = records[id];
        return (r.x, r.y, 0, r.registered, 0);
    }
}
