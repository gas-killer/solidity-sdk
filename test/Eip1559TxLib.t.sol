// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Eip1559TxLib} from "../src/Eip1559TxLib.sol";

/// @dev Vectors are real EIP-1559 transactions signed offline with `cast mktx` against Sepolia
/// (chainId 11155111) using the standard Anvil dev keys. Each asserts that the library
/// reconstructs the exact signing hash the wallet produced by recovering the known signer — a
/// wrong RLP encoding recovers a different address and fails. Vectors deliberately span the RLP
/// edge cases: zero nonce/value (empty-string encoding), single-byte and multi-byte scalars, short
/// and long (>55 byte) calldata, and both y-parities.
contract Eip1559TxLibTest is Test {
    address constant ACCT0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant ACCT1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant TARGET = 0x00000000000000000000000000000000000000A1;
    uint256 constant CHAIN = 11155111;

    /// Vector A: nonce 7, value 0x3039, 4-byte calldata, yParity 1.
    function test_vectorA_recovers_signer() public pure {
        (address signer,) = Eip1559TxLib.recoverSigner(
            CHAIN,
            7,
            1_000_000_000,
            2_000_000_000,
            1_000_000,
            TARGET,
            12345,
            hex"abcdef01",
            1,
            0x06e8d35c9dee8cecc94c166b2083ba97c09553578fb89a3f5e159edc0ebf5c92,
            0x028f46d16b07b96dc44d699c35020498e2a9520b7d05ee35a7b55019743c0653
        );
        assertEq(signer, ACCT0, "vector A signer mismatch");
    }

    /// Vector A signing hash matches the independently computed value.
    function test_vectorA_sighash_matches() public pure {
        bytes32 h =
            Eip1559TxLib.sigHashOf(CHAIN, 7, 1_000_000_000, 2_000_000_000, 1_000_000, TARGET, 12345, hex"abcdef01");
        assertEq(h, 0x91e4331ffd5c0c11312d6e1fabee23b6ccec11273ae50d3b223c9a303e3288ab, "vector A sighash");
    }

    /// Vector B: nonce 0 and value 0 (empty-string RLP), 60-byte calldata (long-string RLP), yParity 1.
    function test_vectorB_zero_fields_and_long_calldata() public pure {
        bytes memory data = new bytes(60);
        for (uint256 i = 0; i < 60; i++) {
            data[i] = 0xab;
        }
        (address signer,) = Eip1559TxLib.recoverSigner(
            CHAIN,
            0,
            1_000_000_000,
            1_000_000_000,
            500_000,
            TARGET,
            0,
            data,
            1,
            0xcbd8822cf62897e3ec7fb3f9fba6cbc3eddfdf0ec8eaf1e997d9a6d617e6ec07,
            0x7733c0eb580fbe9258d173ca200dc5a6eaeb8df7652777b28633636d74498402
        );
        assertEq(signer, ACCT1, "vector B signer mismatch");
    }

    /// Vector C: nonce 300 and value 1 ether (multi-byte scalars), yParity 0 (v = 27).
    function test_vectorC_multibyte_and_yparity0() public pure {
        (address signer,) = Eip1559TxLib.recoverSigner(
            CHAIN,
            300,
            1_500_000_000,
            3_000_000_000,
            800_000,
            TARGET,
            1 ether,
            hex"1234abcd",
            0,
            0xc46288ba62243e6e15e00c877690354d09acc4c41a0ffb2244ca1dc856467e7a,
            0x28e2705dcf87e1ad2bb5e4867866c77c2861412a96a95e37918ae94bf8f78555
        );
        assertEq(signer, ACCT1, "vector C signer mismatch");
    }

    /// Calldata of exactly 55 bytes — the last length that RLP encodes with a single-byte string
    /// prefix (0xb7). One byte longer switches to the long form; both boundaries must be exact.
    function test_vector_calldata55_short_string_boundary() public pure {
        bytes memory data = new bytes(55);
        for (uint256 i = 0; i < 55; i++) {
            data[i] = 0xcd;
        }
        (address signer,) = Eip1559TxLib.recoverSigner(
            CHAIN,
            1,
            1_000_000_000,
            2_000_000_000,
            600_000,
            TARGET,
            1,
            data,
            1,
            0x766bf88fdf7edda24b0d6f28005af3809a59a87dee5bd8e7c59ea67c60ba3090,
            0x76c6030ceca9ea9fcd0d722ee776add81715516b1a74b235bc3e5d423deb1c3e
        );
        assertEq(signer, ACCT1, "55-byte calldata boundary signer mismatch");
    }

    /// Calldata of exactly 56 bytes — the first length that RLP encodes with the long-string form
    /// (0xb8 followed by the length byte).
    function test_vector_calldata56_long_string_boundary() public pure {
        bytes memory data = new bytes(56);
        for (uint256 i = 0; i < 56; i++) {
            data[i] = 0xcd;
        }
        (address signer,) = Eip1559TxLib.recoverSigner(
            CHAIN,
            1,
            1_000_000_000,
            2_000_000_000,
            600_000,
            TARGET,
            1,
            data,
            0,
            0xf4c81e8eba93fb80c531b2e4a13619e10d624ae23cc8349859f2979c5918a03c,
            0x417b29a428d0f8536a69921420790154577a7d4b926ab78dcf2eefa0fd1a4414
        );
        assertEq(signer, ACCT1, "56-byte calldata boundary signer mismatch");
    }

    /// A tampered field (wrong value) must recover a different address, never the true signer —
    /// this is what stops a relayer swapping the executed call for one the user did not sign.
    function test_tampered_value_recovers_wrong_signer() public pure {
        (address signer,) = Eip1559TxLib.recoverSigner(
            CHAIN,
            7,
            1_000_000_000,
            2_000_000_000,
            1_000_000,
            TARGET,
            99999, // tampered: real value was 12345
            hex"abcdef01",
            1,
            0x06e8d35c9dee8cecc94c166b2083ba97c09553578fb89a3f5e159edc0ebf5c92,
            0x028f46d16b07b96dc44d699c35020498e2a9520b7d05ee35a7b55019743c0653
        );
        assertTrue(signer != ACCT0, "tampered value must not recover the true signer");
    }

    /// A tampered calldata byte likewise breaks recovery.
    function test_tampered_calldata_recovers_wrong_signer() public pure {
        (address signer,) = Eip1559TxLib.recoverSigner(
            CHAIN,
            7,
            1_000_000_000,
            2_000_000_000,
            1_000_000,
            TARGET,
            12345,
            hex"abcdef02", // tampered last byte
            1,
            0x06e8d35c9dee8cecc94c166b2083ba97c09553578fb89a3f5e159edc0ebf5c92,
            0x028f46d16b07b96dc44d699c35020498e2a9520b7d05ee35a7b55019743c0653
        );
        assertTrue(signer != ACCT0, "tampered calldata must not recover the true signer");
    }
}
