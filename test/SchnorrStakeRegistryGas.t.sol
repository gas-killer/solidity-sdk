// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {SchnorrStakeRegistry} from "../src/schnorr/SchnorrStakeRegistry.sol";

/// @notice Gas benchmarks for `SchnorrStakeRegistry.isValidSignature`, measured in BOTH
///         access contexts, because the two differ ~3x and quoting one as the other has
///         already caused confusion:
///
///         * **warm** — the registry account + its slots are already in the EIP-2929
///           access set (a multicall sub-transition after the first, or any composed call
///           that touched the registry earlier in the tx).
///         * **cold** — first touch in the transaction (a standalone `verifyAndUpdate`
///           tx, i.e. what a receipt on-chain actually reflects). Forced here with
///           `vm.cool`.
///
///         ⚠️  `forge test --gas-report` runs calls in ISOLATION (fresh access lists per
///         call), so numbers printed by these tests under `--gas-report` shift toward the
///         cold context (the warm asserts detect that and stand down). Run plain
///         `forge test -vv` for the warm numbers.
///
///         Reference measurements (3 ops, 2/3 threshold, solc 0.8.29, prague): warm full
///         participation ~6.5k — packing does not touch the full-participation path,
///         which reads no operator records. The marginal per non-signer is dominated by
///         one modexp-based point-sub inverse plus, when cold, the non-signer's record
///         SLOADs. That modexp call's own price is forge-version-dependent: EIP-7883
///         (ModExp Gas Cost Increase, Fusaka) removes the historical GQUADDIVISOR=3 for
///         the common <=32-byte-operand case, tripling the 32-byte-modulus call from
///         1,360 to 4,080 gas. Toolchains without it give a ~4.2k marginal; toolchains
///         with it (CI always installs `forge-toolchain stable`, so it tracks this as soon
///         as revm ships it) give ~6.9k. The ceilings below are set for the repriced
///         (current CI) toolchain with headroom; a ~4.2k marginal on an older cached local
///         `forge` is not a regression — run `foundryup` to match CI.
///
///         The real-signature fixture (3 operators) covers k ∈ {0,1}; linearity in the
///         non-signer count is proven separately on a synthetic 16-operator registry
///         (`vm.store`-injected records — arbitrary field elements exercise the identical
///         opcode path: distinct-x affine subtraction incl. the modexp inverse, then a
///         full ecrecover that simply fails to match).
contract SchnorrStakeRegistryGasTest is Test {
    // ---- real Rust-generated fixture (same vectors as SchnorrStakeRegistry.t.sol) ----
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

    // ---- synthetic 16-operator registry for scaling ----
    SchnorrStakeRegistry synth;
    uint256 constant SYNTH_OPS = 16;
    address[] synthIds;

    function setUp() public {
        vm.roll(1000);

        registry = new SchnorrStakeRegistry(2, 3, address(this));
        for (uint256 i = 0; i < 3; i++) {
            registry.registerOperator(opX[i], opY[i], 100, popS[i], popR[i]);
        }
        // Precomputed here so cold-context tests never touch the registry pre-bracket.
        nsOp1 = registry.pointAddress(opX[1], opY[1]);

        // Synthetic registry: inject packed Operator records directly (bypasses PoP —
        // fine, we measure the gas path, not signature validity). Storage layout:
        // operators mapping @ slot 0 {x, y, weight|registered<<96}, aggX @ 1, aggY @ 2,
        // totalWeight @ 3, effectiveBlock @ 4.
        synth = new SchnorrStakeRegistry(2, 3, address(this));
        for (uint256 i = 0; i < SYNTH_OPS; i++) {
            uint256 x = uint256(keccak256(abi.encode("x", i))) >> 4;
            uint256 y = uint256(keccak256(abi.encode("y", i))) >> 4;
            address id = address(uint160(0x10000 + i * 0x100)); // strictly ascending
            synthIds.push(id);
            bytes32 base = keccak256(abi.encode(id, uint256(0)));
            vm.store(address(synth), base, bytes32(x));
            vm.store(address(synth), bytes32(uint256(base) + 1), bytes32(y));
            // packed slot: weight (uint96, low bits) | registered (bool, bit 96)
            vm.store(address(synth), bytes32(uint256(base) + 2), bytes32((uint256(1) << 96) | uint256(1)));
        }
        vm.store(address(synth), bytes32(uint256(1)), bytes32(uint256(keccak256("aggX")) >> 4));
        vm.store(address(synth), bytes32(uint256(2)), bytes32(uint256(keccak256("aggY")) >> 4));
        vm.store(address(synth), bytes32(uint256(3)), bytes32(uint256(10_000)));

        vm.roll(block.number + 10);
    }

    function _refBlock() internal view returns (uint256) {
        return block.number - 1;
    }

    function _nonSigner(uint256 i) internal view returns (address) {
        return registry.pointAddress(opX[i], opY[i]);
    }

    function _synthNs(uint256 k) internal view returns (address[] memory a) {
        a = new address[](k);
        for (uint256 i = 0; i < k; i++) {
            a[i] = synthIds[i];
        }
    }

    /// Warm context: registry + all touched slots pre-warmed in this tx. Measurement
    /// hygiene: (a) forge-std asserts and console logs are cheatcode calls and stay
    /// OUTSIDE the gas brackets (the first cheatcode call in a bracket pays a cold
    /// account access to the VM address); (b) the registry reference is hoisted to a
    /// local so the harness's own storage read is not measured.
    ///
    /// Under `--gas-report`/`--isolate` every call runs with fresh access lists, so the
    /// pre-warming cannot stick; the warm-context asserts detect that and stand down
    /// (the cold tests below cover that context).
    function test_gas_realFixture_warm() public view {
        SchnorrStakeRegistry r = registry;
        address[] memory none = new address[](0);
        address[] memory ns = new address[](1);
        ns[0] = nsOp1;
        uint256 refBlock = _refBlock();

        r.isValidSignature(MESSAGE, FULL_S, FULL_R, none, refBlock);
        r.isValidSignature(MESSAGE, SUB_S, SUB_R, ns, refBlock);

        uint256 g0 = gasleft();
        bool okFull = r.isValidSignature(MESSAGE, FULL_S, FULL_R, none, refBlock);
        uint256 warmFull = g0 - gasleft();

        g0 = gasleft();
        bool okOneNs = r.isValidSignature(MESSAGE, SUB_S, SUB_R, ns, refBlock);
        uint256 warmOneNs = g0 - gasleft();

        assertTrue(okFull, "full-participation signature verifies");
        assertTrue(okOneNs, "subset signature verifies");
        console2.log("warm  full participation:  ", warmFull);
        console2.log("warm  1 non-signer:        ", warmOneNs);
        console2.log("warm  marginal/non-signer: ", warmOneNs - warmFull);

        if (warmFull > 15_000) {
            console2.log("isolated context detected (pre-warm did not stick); warm asserts skipped");
            return;
        }
        // One ecrecover + a handful of warm SLOADs; loose bounds to survive solc drift.
        // 8_000 headroom above the ~6.9k EIP-7883-repriced modexp marginal (see contract
        // docstring above) — was 6_500 pre-repricing.
        assertLt(warmFull, 12_000, "warm full-participation verify");
        assertLt(warmOneNs - warmFull, 8_000, "warm per-non-signer marginal");
    }

    /// Cold context, full participation: what a standalone verifyAndUpdate transaction
    /// pays for the verify. Forge resets EIP-2929 access lists between setUp and each
    /// test, so the FIRST registry call inside a test body is genuinely cold — no
    /// cheatcodes needed (and none run before the bracket, which would warm things).
    function test_gas_realFixture_coldFullParticipation() public view {
        SchnorrStakeRegistry r = registry; // hoisted: don't measure the harness's own SLOAD
        address[] memory none = new address[](0);
        uint256 refBlock = _refBlock(); // pure block math, does not touch the registry

        uint256 g0 = gasleft();
        bool ok = r.isValidSignature(MESSAGE, FULL_S, FULL_R, none, refBlock);
        uint256 coldFull = g0 - gasleft();

        assertTrue(ok, "full-participation signature verifies");
        console2.log("cold  full participation:  ", coldFull);

        // The comparison the scheme exists for: cheaper than the CACHED ECDSA registry at
        // 3 ops (30,825, service #311) even in the cold context, and far below its
        // 65,027 base. Cold-vs-warm delta is the account + base-slot access surcharge.
        assertLt(coldFull, 30_825, "cold full-participation beats cached 3-op ECDSA");
    }

    /// Cold context, one non-signer. Uses a non-signer address precomputed in setUp so
    /// nothing touches the registry before the measured (first, cold) call. Compare the
    /// log against coldFullParticipation's to get the cold per-non-signer marginal
    /// (~ warm marginal + the non-signer's cold record SLOADs).
    address nsOp1;

    function test_gas_realFixture_coldOneNonSigner() public view {
        SchnorrStakeRegistry r = registry; // hoisted: don't measure the harness's own SLOAD
        address[] memory ns = new address[](1);
        ns[0] = nsOp1; // test-contract storage, not a registry access
        uint256 refBlock = _refBlock();

        uint256 g0 = gasleft();
        bool ok = r.isValidSignature(MESSAGE, SUB_S, SUB_R, ns, refBlock);
        uint256 coldOneNs = g0 - gasleft();

        assertTrue(ok, "subset signature verifies");
        console2.log("cold  1 non-signer:        ", coldOneNs);
        assertLt(coldOneNs, 37_525, "cold 1-non-signer stays below cached 3-op ECDSA + one op");
    }

    /// Marginal cost is LINEAR in the non-signer count (warm context; k = 1..8): each
    /// step is one packed-record load + one affine point subtraction (modexp inverse).
    /// The shipped fixture can only exercise k <= 1 meaningfully, hence the synthetic set.
    function test_gas_marginalPerNonSigner_isLinear() public view {
        SchnorrStakeRegistry r = synth;
        bytes32 msgh = keccak256("m");
        uint256 s = uint256(keccak256("s")) >> 4;
        address raddr = address(0xBEEF);
        uint256 refBlock = _refBlock();

        // Warm everything the loop will touch (no-op under --gas-report isolation; the
        // marginal is then cold — one packed record's cold SLOADs on top of the compute —
        // but stays just as linear, so the bounds below adapt instead of skipping).
        r.isValidSignature(msgh, s, raddr, _synthNs(8), refBlock);

        uint256 k0;
        uint256 prev;
        uint256 minMarginal = type(uint256).max;
        uint256 maxMarginal;
        for (uint256 k = 0; k <= 8; k++) {
            address[] memory nsK = _synthNs(k);
            uint256 g0 = gasleft();
            r.isValidSignature(msgh, s, raddr, nsK, refBlock);
            uint256 used = g0 - gasleft();
            if (k > 0) {
                uint256 marginal = used - prev;
                if (marginal < minMarginal) minMarginal = marginal;
                if (marginal > maxMarginal) maxMarginal = marginal;
                console2.log("k, gas, marginal:", k, used, marginal);
            } else {
                k0 = used;
                console2.log("k=0 (full participation):", used);
            }
            prev = used;
        }

        bool isolated = k0 > 15_000; // pre-warm didn't stick => cold per-call context
        // Every step lands in a tight band around one point-sub + one packed record.
        // Non-isolated ceiling carries the same EIP-7883 headroom as the warm test above
        // (was 6_500 pre-repricing).
        assertGt(minMarginal, 2_500, "marginal floor (point sub is real work)");
        assertLt(maxMarginal, isolated ? 13_500 : 8_000, "marginal ceiling (no superlinear blowup)");
        assertLt(maxMarginal - minMarginal, 1_500, "linearity: steps within a tight band");
    }
}
