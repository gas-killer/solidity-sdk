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
        registry = new SchnorrStakeRegistry(2, 3, address(this)); // 2/3 threshold
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
        SchnorrStakeRegistry fresh = new SchnorrStakeRegistry(2, 3, address(this));
        vm.expectRevert(SchnorrStakeRegistry.InvalidProofOfPossession.selector);
        fresh.registerOperator(opX[0], opY[0], WEIGHT, popS[1], popR[1]);
    }

    // An off-curve key is rejected.
    function test_registration_rejectsOffCurve() public {
        SchnorrStakeRegistry fresh = new SchnorrStakeRegistry(2, 3, address(this));
        vm.expectRevert(SchnorrStakeRegistry.NotOnCurve.selector);
        fresh.registerOperator(opX[0], opY[0] ^ 1, WEIGHT, popS[0], popR[0]);
    }

    // ---- gas benchmark (constant in signer count at full participation) ----
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
