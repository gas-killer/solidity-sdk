// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {Qwen35} from "../src/examples/onchain-llm/Qwen35.sol";

/// @notice Engine-v3 numerics unit tests: every expected integer below is derived
///         from the .context/qwen35/SPEC.md formulas evaluated with exact EVM
///         semantics (sar = SAR, sdiv = SDIV, floor isqrt, the pinned expQ32),
///         cross-checked against float references. These pin the v3 primitives
///         BEFORE the synthetic-model fixtures exercise the full forward pass.
contract OnchainLLMV3PrimitivesTest is Test {
    uint256 internal constant EPS_Q48 = 281475; // round(1e-6 * 2^48)

    // ------------------------------------------------------------ log2Q64

    /// @notice log2 of 1.0 is exactly 0
    function test_Log2Q64_One() public pure {
        assertEq(Qwen35.log2Q64(uint256(1) << 32), 0);
    }

    /// @notice log2(1.5), log2(2 - 2^-32) and a mid-range value, floor-rounded Q64
    function test_Log2Q64_Values() public pure {
        // log2(1.5) = 0.58496...: floor(log2(1.5) * 2^64)
        assertEq(Qwen35.log2Q64(uint256(3) << 31), 10790653543394171999);
        // just below 2.0: approaches 2^64 from below
        assertEq(Qwen35.log2Q64((uint256(1) << 33) - 1), 18446744070611352842);
        // 1.5 + 12345/2^32
        assertEq(Qwen35.log2Q64(0x180000000 + 12345), 10790704536757496841);
    }

    /// @notice Result is monotone and below 2^64 across the domain edge cases
    function test_Log2Q64_Bounds() public pure {
        uint256 lo = Qwen35.log2Q64((uint256(1) << 32) + 1);
        uint256 hi = Qwen35.log2Q64((uint256(1) << 33) - 1);
        assertLt(lo, hi);
        assertLt(hi, uint256(1) << 64);
    }

    // ------------------------------------------------------------- sigQ32

    /// @notice sigmoid(0) is exactly 0.5 in Q32
    function test_SigQ32_Zero() public pure {
        assertEq(Qwen35.sigQ32(0), uint256(1) << 31);
    }

    /// @notice Q24 unit steps, both signs, and an odd value (float-checked)
    function test_SigQ32_Values() public pure {
        assertEq(Qwen35.sigQ32(int256(1) << 24), 3139872687); // sigmoid(1)
        assertEq(Qwen35.sigQ32(-(int256(1) << 24)), 1155094608); // sigmoid(-1)
        assertEq(Qwen35.sigQ32(int256(5) << 24), 4266221720); // sigmoid(5)
        assertEq(Qwen35.sigQ32(-(int256(5) << 24)), 28745575); // sigmoid(-5)
        assertEq(Qwen35.sigQ32(123456789), 4292232753); // sigmoid(7.3583...)
        assertEq(Qwen35.sigQ32(-987654321), 0); // deep negative underflows
    }

    /// @notice Saturation at both tails (result is Q32 in [0, 2^32])
    function test_SigQ32_Saturation() public pure {
        assertEq(Qwen35.sigQ32(int256(1) << 30), uint256(1) << 32); // sigmoid(64)
        assertEq(Qwen35.sigQ32(int256(1) << 40), uint256(1) << 32);
        assertEq(Qwen35.sigQ32(-(int256(1) << 40)), 0);
    }

    /// @notice Delta-gate constants used by the recurrence tests below
    function test_SigQ32_DeltaGateConstants() public pure {
        assertEq(Qwen35.sigQ32(int256(3) << 22), 2917050301);
        assertEq(Qwen35.sigQ32(-(int256(1) << 23)), 1621524825);
        assertEq(Qwen35.sigQ32(int256(1) << 20), 2214570675);
        assertEq(Qwen35.sigQ32(int256(1) << 21), 2281526886);
    }

    // -------------------------------------------------------- softplusQ24

    /// @notice softplus(0) = ln 2, floor-rounded Q24
    function test_SoftplusQ24_Zero() public pure {
        assertEq(Qwen35.softplusQ24(0), 11629079); // ln2 * 2^24 = 11629079.96
    }

    /// @notice Positive/negative pairs satisfy softplus(x) = x + softplus(-x) exactly
    function test_SoftplusQ24_Values() public pure {
        assertEq(Qwen35.softplusQ24(int256(1) << 24), 22032874); // softplus(1)
        assertEq(Qwen35.softplusQ24(-(int256(1) << 24)), 5255658); // softplus(-1)
        assertEq(Qwen35.softplusQ24(int256(3) << 24), 51146808); // softplus(3)
        assertEq(Qwen35.softplusQ24(-(int256(3) << 24)), 815160); // softplus(-3)
        assertEq(Qwen35.softplusQ24(123456789), 123467474);
        assertEq(Qwen35.softplusQ24(-123456789), 10685);
        assertEq(Qwen35.softplusQ24(int256(7) << 20), 15697342); // softplus(0.4375)
    }

    /// @notice Tails: identity for large x, underflow to 0 for very negative x
    function test_SoftplusQ24_Tails() public pure {
        assertEq(Qwen35.softplusQ24(int256(1) << 40), int256(1) << 40); // softplus(x) -> x
        assertEq(Qwen35.softplusQ24(-(int256(1) << 40)), 0);
        assertEq(Qwen35.softplusQ24(-(int256(1) << 30)), 0); // softplus(-64)
    }

    // ------------------------------------------------------------- l2norm

    /// @notice 3-4-5 triangle: s = isqrt(25<<48 + eps) = 5<<24 exactly
    function test_L2Norm_Pythagorean() public pure {
        int256[] memory v = new int256[](2);
        v[0] = int256(3) << 24;
        v[1] = int256(4) << 24;
        Qwen35.l2normSlice(v, 0, 2, EPS_Q48);
        assertEq(v[0], 10066329); // sdiv(3<<48, 5<<24) = (3/5)<<24 floor
        assertEq(v[1], 13421772); // (4/5)<<24 floor
    }

    /// @notice sdiv truncates toward zero for negative entries
    function test_L2Norm_NegativeTruncation() public pure {
        int256[] memory v = new int256[](2);
        v[0] = -(int256(3) << 24);
        v[1] = int256(4) << 24;
        Qwen35.l2normSlice(v, 0, 2, EPS_Q48);
        assertEq(v[0], -10066329); // toward zero, NOT floor
        assertEq(v[1], 13421772);
    }

    /// @notice 8-entry alternating-sign vector (float-checked), applied at an offset
    function test_L2Norm_EightWide() public pure {
        int256[] memory v = new int256[](10);
        v[0] = type(int256).max; // sentinel: untouched outside the slice
        for (uint256 i = 0; i < 8; ++i) {
            int256 val = int256(i + 1) << 24;
            v[1 + i] = i % 2 == 0 ? val : -val;
        }
        v[9] = type(int256).min;
        Qwen35.l2normSlice(v, 1, 8, EPS_Q48);
        int256[8] memory expected = [int256(1174640), -2349280, 3523920, -4698560, 5873200, -7047840, 8222480, -9397120];
        for (uint256 i = 0; i < 8; ++i) {
            assertEq(v[1 + i], expected[i]);
        }
        assertEq(v[0], type(int256).max);
        assertEq(v[9], type(int256).min);
    }

    /// @notice Zero vector maps to zero (eps keeps the divisor positive)
    function test_L2Norm_Zeros() public pure {
        int256[] memory v = new int256[](4);
        Qwen35.l2normSlice(v, 0, 4, EPS_Q48);
        for (uint256 i = 0; i < 4; ++i) {
            assertEq(v[i], 0);
        }
    }

    // ------------------------------------------------------------ conv4

    uint256 internal constant CONV_DIM = 8;
    uint256 internal constant CONV_K = 4;

    function _convBlob() internal pure returns (bytes memory blob) {
        // 8 channels of [u8 shift || 4 int8 taps], tap 0 oldest, tap 3 current
        blob = bytes.concat(
            _convRow(0, 1, 2, 3, 4),
            _convRow(1, -1, -2, -3, -4),
            _convRow(2, 127, -127, 64, -64),
            _convRow(3, 0, 0, 0, 5),
            _convRow(4, 5, 0, 0, 0),
            _convRow(5, -7, 11, -13, 17),
            _convRow(0, 1, 1, 1, 1),
            _convRow(7, -127, 127, -127, 127)
        );
    }

    function _convRow(uint8 shift, int8 w0, int8 w1, int8 w2, int8 w3) internal pure returns (bytes memory) {
        return abi.encodePacked(shift, w0, w1, w2, w3);
    }

    /// @notice Two consecutive tokens through the causal conv + SiLU: outputs and
    ///         the rolled packed state match the spec-mirror exactly
    function test_ConvStep_TwoTokens() public pure {
        uint256[] memory state = new uint256[]((CONV_K - 1) * CONV_DIM / 8); // zero left-context
        bytes memory conv = _convBlob();

        int256[] memory qkv = new int256[](CONV_DIM);
        qkv[0] = int256(1) << 24;
        qkv[1] = -(int256(1) << 24);
        qkv[2] = int256(2) << 24;
        qkv[3] = int256(3) << 24;
        qkv[4] = -(int256(3) << 24);
        qkv[5] = int256(5) << 20;
        qkv[6] = -(int256(5) << 20);
        qkv[7] = int256(1) << 22;
        Qwen35.convStep(state, 0, conv, qkv, CONV_DIM, CONV_K, 1);
        int256[8] memory exp0 = [int256(65901829), 29554645, 0, 27274586, 0, 1507975, -2215142, 2337516];
        for (uint256 ch = 0; ch < 8; ++ch) {
            assertEq(qkv[ch], exp0[ch], "t0 output");
        }

        qkv[0] = -(int256(1) << 23);
        qkv[1] = int256(1) << 25;
        qkv[2] = -(int256(1) << 21);
        qkv[3] = int256(7) << 20;
        qkv[4] = int256(11) << 18;
        qkv[5] = -(int256(13) << 16);
        qkv[6] = int256(1) << 24;
        qkv[7] = -(int256(1) << 24);
        Qwen35.convStep(state, 0, conv, qkv, CONV_DIM, CONV_K, 1);
        int256[8] memory exp1 = [int256(12265127), -3181723, 570425344, 2605420, 0, -1192078, 7675068, -4669144];
        for (uint256 ch = 0; ch < 8; ++ch) {
            assertEq(qkv[ch], exp1[ch], "t1 output");
        }

        // rolled state: C[c] = (0, s3_t0, s3_t1) as int32 Q16, layout [t][c]
        assertEq(state[0], 0, "state word t=0");
        int256[8] memory s3t0 = [int256(65536), -65536, 131072, 196608, -196608, 20480, -20480, 16384];
        int256[8] memory s3t1 = [int256(-32768), 131072, -8192, 28672, 11264, -3328, 65536, -65536];
        assertEq(state[1], _packI32x8(s3t0), "state word t=1");
        assertEq(state[2], _packI32x8(s3t1), "state word t=2");
    }

    // --------------------------------------------------------- delta rule

    uint256 internal constant DK = 8;
    uint256 internal constant DV = 8;

    function _deltaInputs() internal pure returns (int256[] memory q, int256[] memory k, int256[] memory v) {
        q = new int256[](DK);
        k = new int256[](DK);
        v = new int256[](DV);
        for (uint256 i = 0; i < DK; ++i) {
            int256 qv = int256((i + 1) << 20);
            q[i] = i % 2 == 0 ? qv : -qv;
            int256 kv = int256((3 * i + 2) << 19);
            k[i] = i % 3 == 0 ? -kv : kv;
        }
        for (uint256 i = 0; i < DV; ++i) {
            int256 vv = int256((7 * i + 1) << 20);
            v[i] = i % 2 == 0 ? vv : -vv;
        }
    }

    function _initS() internal pure returns (uint256[] memory S) {
        S = new uint256[]((DK * DV) / 8);
        for (uint256 kk = 0; kk < DK; ++kk) {
            for (uint256 vv = 0; vv < DV; ++vv) {
                int256 val =
                    int256(kk) * 131 - int256(vv) * 57 + int256((kk * vv) << 7) - 4000 + int256((kk + vv) << 10);
                _setI32(S, kk * DV + vv, val);
            }
        }
    }

    /// @notice One §5.4 step on a dense synthetic state: output and updated packed
    ///         state match the spec-mirror; then a second step proves persistence
    function test_DeltaStep_TwoSteps() public pure {
        uint256[] memory S = _initS();
        (int256[] memory q, int256[] memory k, int256[] memory v) = _deltaInputs();
        int256[] memory scratch = new int256[](DV);
        int256[] memory out = new int256[](DV);

        Qwen35.DeltaParams memory p;
        p.dK = DK;
        p.dV = DV;
        p.decay = 2917050301; // sigQ32(3<<22)
        p.beta = 1621524825; // sigQ32(-(1<<23))
        Qwen35.deltaStep(S, q, k, v, scratch, out, p);

        int256[8] memory expO = [int256(-387136), 1679520, -3676288, 4885376, -6965440, 8091104, -10254800, 11296800];
        for (uint256 i = 0; i < DV; ++i) {
            assertEq(out[i], expO[i], "o step 1");
        }
        int256[64] memory expS1 = [
            int256(-2784),
            -1230,
            -2769,
            1491,
            -2754,
            4213,
            -2739,
            6934,
            -1767,
            -3266,
            2966,
            -5299,
            7699,
            -7331,
            12432,
            -9363,
            -883,
            -3642,
            5972,
            -7611,
            12826,
            -11581,
            19682,
            -15552,
            -730,
            5123,
            -6036,
            14701,
            -11342,
            24279,
            -16647,
            33857,
            885,
            -4391,
            11983,
            -12237,
            23081,
            -20083,
            34178,
            -27928,
            1769,
            -4766,
            14988,
            -14550,
            28208,
            -24333,
            41427,
            -34117,
            1324,
            11475,
            -9302,
            27911,
            -19929,
            44345,
            -30556,
            60780,
            3537,
            -5515,
            21000,
            -19174,
            38461,
            -32835,
            55924,
            -46494
        ];
        for (uint256 e = 0; e < 64; ++e) {
            assertEq(_getI32(S, e), expS1[e], "S step 1");
        }

        // second step: perturbed inputs, new gates, SAME state
        for (uint256 i = 0; i < DK; ++i) {
            q[i] += int256(1) << 18;
            k[i] -= int256(1) << 17;
        }
        for (uint256 i = 0; i < DV; ++i) {
            v[i] = -v[i];
        }
        p.decay = 2214570675; // sigQ32(1<<20)
        p.beta = 2281526886; // sigQ32(1<<21)
        Qwen35.deltaStep(S, q, k, v, scratch, out, p);

        int256[8] memory expO2 = [int256(237616), -2422596, 4448104, -6551568, 8658700, -10680464, 12868968, -14809420];
        for (uint256 i = 0; i < DV; ++i) {
            assertEq(out[i], expO2[i], "o step 2");
        }
        int256[64] memory expS2 = [
            int256(-1227),
            -2219,
            1598,
            -3601,
            4422,
            -4983,
            7247,
            -6365,
            -1356,
            1656,
            -4862,
            6489,
            -8369,
            11322,
            -11874,
            16155,
            -1180,
            3574,
            -7348,
            11122,
            -13516,
            18670,
            -19684,
            26217,
            672,
            -5275,
            12021,
            -14263,
            23370,
            -23253,
            34719,
            -32242,
            -828,
            7408,
            -12320,
            20386,
            -23812,
            33363,
            -35305,
            46341,
            -652,
            9326,
            -14806,
            25018,
            -28961,
            40711,
            -43115,
            56403,
            2571,
            -8332,
            22445,
            -24927,
            42318,
            -41523,
            62190,
            -58119,
            -300,
            13161,
            -19778,
            34284,
            -39257,
            55405,
            -58736,
            76527
        ];
        for (uint256 e = 0; e < 64; ++e) {
            assertEq(_getI32(S, e), expS2[e], "S step 2");
        }
    }

    /// @notice vOff/outOff address the head slice inside larger arrays
    function test_DeltaStep_Offsets() public pure {
        uint256[] memory S = _initS();
        uint256[] memory Sref = _initS();
        (int256[] memory q, int256[] memory k, int256[] memory v) = _deltaInputs();

        // reference run at offset 0
        int256[] memory scratch = new int256[](DV);
        int256[] memory outRef = new int256[](DV);
        Qwen35.DeltaParams memory p;
        p.dK = DK;
        p.dV = DV;
        p.decay = 2917050301;
        p.beta = 1621524825;
        Qwen35.deltaStep(Sref, q, k, v, scratch, outRef, p);

        // offset run: v embedded at 5, out written at 3
        int256[] memory vBig = new int256[](5 + DV);
        for (uint256 i = 0; i < DV; ++i) {
            vBig[5 + i] = v[i];
        }
        int256[] memory outBig = new int256[](3 + DV);
        p.vOff = 5;
        p.outOff = 3;
        Qwen35.deltaStep(S, q, k, vBig, scratch, outBig, p);

        for (uint256 i = 0; i < DV; ++i) {
            assertEq(outBig[3 + i], outRef[i], "offset output");
        }
        for (uint256 e = 0; e < 64; ++e) {
            assertEq(_getI32(S, e), _getI32(Sref, e), "offset state");
        }
    }

    // -------------------------------------------------------- top-k router

    /// @notice Ties resolve to the LOWEST index; selection order is by magnitude
    function test_SelectTopK_TieBreak() public pure {
        int256[] memory e = new int256[](6);
        e[0] = 5 << 24;
        e[1] = 9 << 24;
        e[2] = 9 << 24;
        e[3] = 1 << 24;
        e[4] = 9 << 24;
        e[5] = 0;
        uint256[] memory idx = new uint256[](3);
        uint256[] memory w = new uint256[](3);
        uint256 tot = Qwen35.selectTopK(e, 3, idx, w);

        assertEq(tot, uint256(27) << 24);
        assertEq(idx[0], 1); // first 9 wins
        assertEq(idx[1], 2); // then the next tie, excluded entries skipped
        assertEq(idx[2], 4);
        // w_i = (e_i << 32) / tot, identical for the three-way tie
        uint256 expW = (uint256(9) << 56) / (uint256(27) << 24);
        assertEq(w[0], expW);
        assertEq(w[1], expW);
        assertEq(w[2], expW);
        // selected entries are consumed
        assertEq(e[1], -1);
        assertEq(e[2], -1);
        assertEq(e[4], -1);
        assertEq(e[0], 5 << 24); // others untouched
    }

    /// @notice Normalization: weights are Q32 fractions of the selected sum
    function test_SelectTopK_Weights() public pure {
        int256[] memory e = new int256[](3);
        e[0] = 3;
        e[1] = 7;
        e[2] = 2;
        uint256[] memory idx = new uint256[](2);
        uint256[] memory w = new uint256[](2);
        uint256 tot = Qwen35.selectTopK(e, 2, idx, w);

        assertEq(tot, 10);
        assertEq(idx[0], 1);
        assertEq(idx[1], 0);
        assertEq(w[0], (uint256(7) << 32) / 10); // 3006477107 (floor)
        assertEq(w[1], (uint256(3) << 32) / 10); // 1288490188 (floor)
    }

    /// @notice Zero numerators are selectable (strict > keeps first index)
    function test_SelectTopK_AllZero() public pure {
        int256[] memory e = new int256[](4);
        e[0] = 0;
        e[1] = 1;
        e[2] = 0;
        e[3] = 0;
        uint256[] memory idx = new uint256[](3);
        uint256[] memory w = new uint256[](3);
        uint256 tot = Qwen35.selectTopK(e, 3, idx, w);

        assertEq(tot, 1);
        assertEq(idx[0], 1);
        assertEq(idx[1], 0); // zeros tie: lowest index first
        assertEq(idx[2], 2);
        assertEq(w[0], uint256(1) << 32);
        assertEq(w[1], 0);
        assertEq(w[2], 0);
    }

    // ------------------------------------------------------------- helpers

    function _packI32x8(int256[8] memory vals) internal pure returns (uint256 word) {
        for (uint256 i = 0; i < 8; ++i) {
            word |= (uint256(vals[i]) & 0xffffffff) << (224 - 32 * i);
        }
    }

    function _setI32(uint256[] memory arr, uint256 e, int256 v) internal pure {
        uint256 sh = 224 - 32 * (e % 8);
        arr[e / 8] = (arr[e / 8] & ~(uint256(0xffffffff) << sh)) | ((uint256(v) & 0xffffffff) << sh);
    }

    function _getI32(uint256[] memory arr, uint256 e) internal pure returns (int256 v) {
        uint256 word = arr[e / 8];
        assembly ("memory-safe") {
            v := signextend(3, shr(sub(224, mul(32, mod(e, 8))), word))
        }
    }
}
