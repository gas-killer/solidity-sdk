// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SchnorrStakeRegistry} from "../../src/schnorr/SchnorrStakeRegistry.sol";

/// @notice `updateOperatorWeight` — the additive owner surface the Commitments adapter
///         uses to retune weights without deregister/register churn. Fixtures are the
///         Rust-generated set from `test/SchnorrStakeRegistry.t.sol`; a weight change
///         never touches `X_all`, so the fixture signatures stay verifiable with a fresh
///         reference block.
contract SchnorrStakeRegistryWeightTest is Test {
    SchnorrStakeRegistry registry;

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

    bytes32 constant MESSAGE = 0xeca826d3bb47f0cbaed65764fb099b01af1c3ad160b35cb226d7249670866fd6;
    uint256 constant FULL_S = 0xf527f98d99ce218539679f270074804e72da151aa0495eff3f74769cfce15174;
    address constant FULL_R = 0xDb0aC2AC07Dc8c44b370C5eA1cf158077c386141;
    uint256 constant SUB_S = 0x0d4db16e196f8134612d1bd370b2193a3b8703245f7a0d64e82b2a1e15b4bb68;
    address constant SUB_R = 0x443F530ae1700809Aaa89acA96C43202ec650BBD;

    uint256 constant WEIGHT = 100;

    event OperatorWeightUpdated(address indexed operator, uint256 oldWeight, uint256 newWeight);
    event ForcedMutation(address indexed operator);

    function setUp() public {
        vm.roll(1000);
        registry = new SchnorrStakeRegistry(2, 3, address(this), 0);
        for (uint256 i = 0; i < 3; i++) {
            registry.registerOperator(opX[i], opY[i], WEIGHT, popS[i], popR[i]);
        }
        vm.roll(block.number + 10);
    }

    function _op(uint256 i) internal view returns (address) {
        return registry.pointAddress(opX[i], opY[i]);
    }

    function test_updatesWeightAndTotal() public {
        vm.expectEmit(true, false, false, true);
        emit ForcedMutation(_op(1));
        vm.expectEmit(true, false, false, true);
        emit OperatorWeightUpdated(_op(1), WEIGHT, 250);

        registry.updateOperatorWeight(_op(1), 250);

        (,, uint96 weight, bool isRegistered,) = registry.operators(_op(1));
        assertTrue(isRegistered, "still registered");
        assertEq(weight, 250, "weight");
        assertEq(registry.totalWeight(), 2 * WEIGHT + 250, "totalWeight");
        assertEq(registry.effectiveBlock(), block.number, "watermark advanced");
    }

    // The watermark advance fail-closes settlements pinned to pre-update reference
    // blocks, while a fresh reference block still verifies the SAME fixture signature —
    // a weight change alters what counts as quorum, never `X_all`.
    function test_watermarkFailClosesOldRefBlocks_butAggregateSurvives() public {
        uint256 staleRef = block.number - 1;
        registry.updateOperatorWeight(_op(0), 101);

        address[] memory none = new address[](0);
        vm.expectRevert(SchnorrStakeRegistry.StaleSnapshot.selector);
        registry.isValidSignature(MESSAGE, FULL_S, FULL_R, none, staleRef);

        vm.roll(block.number + 1);
        assertTrue(
            registry.isValidSignature(MESSAGE, FULL_S, FULL_R, none, block.number - 1),
            "full-participation fixture verifies against unchanged X_all"
        );
    }

    // Inflating operator 1's weight pushes signers {0,2} below the 2/3 threshold: the
    // subset signature is still cryptographically valid but no longer a quorum.
    function test_thresholdUsesUpdatedWeights() public {
        address[] memory ns = new address[](1);
        ns[0] = _op(1);

        vm.roll(block.number + 1);
        assertTrue(
            registry.isValidSignature(MESSAGE, SUB_S, SUB_R, ns, block.number - 1),
            "subset is a quorum at uniform weights"
        );

        registry.updateOperatorWeight(_op(1), 10 * WEIGHT);
        vm.roll(block.number + 1);
        assertFalse(
            registry.isValidSignature(MESSAGE, SUB_S, SUB_R, ns, block.number - 1),
            "subset falls below 2/3 once the non-signer carries most weight"
        );
    }

    function test_revertsOnZeroWeight() public {
        address op = _op(0);
        vm.expectRevert(SchnorrStakeRegistry.ZeroWeight.selector);
        registry.updateOperatorWeight(op, 0);
    }

    function test_revertsOnWeightOverflow() public {
        address op = _op(0);
        vm.expectRevert(SchnorrStakeRegistry.WeightOverflow.selector);
        registry.updateOperatorWeight(op, uint256(type(uint96).max) + 1);
    }

    function test_revertsOnUnregisteredOperator() public {
        address ghost = address(0xdead);
        vm.expectRevert(abi.encodeWithSelector(SchnorrStakeRegistry.NotRegistered.selector, ghost));
        registry.updateOperatorWeight(ghost, 1);
    }

    function test_revertsForNonOwner() public {
        address op = _op(0);
        vm.prank(address(0xbeef));
        vm.expectRevert(SchnorrStakeRegistry.NotOwner.selector);
        registry.updateOperatorWeight(op, 1);
    }
}
