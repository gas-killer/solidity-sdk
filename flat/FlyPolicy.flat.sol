// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.5.0 >=0.6.2 ^0.8.0 ^0.8.1 ^0.8.13 ^0.8.27;

// lib/openzeppelin-contracts/contracts/utils/Address.sol

// OpenZeppelin Contracts (last updated v4.9.0) (utils/Address.sol)

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     *
     * Furthermore, `isContract` will also return true if the target contract within
     * the same transaction is already scheduled for destruction by `SELFDESTRUCT`,
     * which only has an effect at the end of a transaction.
     * ====
     *
     * [IMPORTANT]
     * ====
     * You shouldn't rely on `isContract` to protect against flash loan attacks!
     *
     * Preventing calls from contracts is highly discouraged. It breaks composability, breaks support for smart wallets
     * like Gnosis Safe, and does not provide security since it can be circumvented by calling from a contract
     * constructor.
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize/address.code.length, which returns 0
        // for contracts in construction, since the code is only stored at the end
        // of the constructor execution.

        return account.code.length > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://consensys.net/diligence/blog/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.8.0/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionDelegateCall(target, data, "Address: low-level delegate call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    /**
     * @dev Tool to verify that a low level call to smart-contract was successful, and revert (either by bubbling
     * the revert reason or using the provided one) in case of unsuccessful call or if target was not a contract.
     *
     * _Available since v4.8._
     */
    function verifyCallResultFromTarget(
        address target,
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        if (success) {
            if (returndata.length == 0) {
                // only check isContract if the call was successful and the return data is empty
                // otherwise we already know that it was a contract
                require(isContract(target), "Address: call to non-contract");
            }
            return returndata;
        } else {
            _revert(returndata, errorMessage);
        }
    }

    /**
     * @dev Tool to verify that a low level call was successful, and revert if it wasn't, either by bubbling the
     * revert reason or using the provided one.
     *
     * _Available since v4.3._
     */
    function verifyCallResult(
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal pure returns (bytes memory) {
        if (success) {
            return returndata;
        } else {
            _revert(returndata, errorMessage);
        }
    }

    function _revert(bytes memory returndata, string memory errorMessage) private pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            /// @solidity memory-safe-assembly
            assembly {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert(errorMessage);
        }
    }
}

// lib/eigenlayer-middleware/src/libraries/BN254.sol

// several functions are taken or adapted from https://github.com/HarryR/solcrypto/blob/master/contracts/altbn128.sol (MIT license):
// Copyright 2017 Christian Reitwiessner
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.

// The remainder of the code in this library is written by LayrLabs Inc. and is also under an MIT license

/**
 * @title Library for operations on the BN254 elliptic curve.
 * @author Layr Labs, Inc.
 * @notice Terms of Service: https://docs.eigenlayer.xyz/overview/terms-of-service
 * @notice Contains BN254 parameters, common operations (addition, scalar mul, pairing), and BLS signature functionality.
 */
library BN254 {
    // modulus for the underlying field F_p of the elliptic curve
    uint256 internal constant FP_MODULUS =
        21888242871839275222246405745257275088696311157297823662689037894645226208583;
    // modulus for the underlying field F_r of the elliptic curve
    uint256 internal constant FR_MODULUS =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    struct G1Point {
        uint256 X;
        uint256 Y;
    }

    // Encoding of field elements is: X[1] * i + X[0]
    struct G2Point {
        uint256[2] X;
        uint256[2] Y;
    }

    /// @dev Thrown when the sum of two points of G1 fails
    error ECAddFailed();
    /// @dev Thrown when the scalar multiplication of a point of G1 fails
    error ECMulFailed();
    /// @dev Thrown when the scalar is too large.
    error ScalarTooLarge();
    /// @dev Thrown when the pairing check fails
    error ECPairingFailed();
    /// @dev Thrown when the exponentiation mod fails
    error ExpModFailed();

    function generatorG1() internal pure returns (G1Point memory) {
        return G1Point(1, 2);
    }

    // generator of group G2
    /// @dev Generator point in F_q2 is of the form: (x0 + ix1, y0 + iy1).
    uint256 internal constant G2x1 =
        11559732032986387107991004021392285783925812861821192530917403151452391805634;
    uint256 internal constant G2x0 =
        10857046999023057135944570762232829481370756359578518086990519993285655852781;
    uint256 internal constant G2y1 =
        4082367875863433681332203403145435568316851327593401208105741076214120093531;
    uint256 internal constant G2y0 =
        8495653923123431417604973247489272438418190587263600148770280649306958101930;

    /// @notice returns the G2 generator
    /// @dev mind the ordering of the 1s and 0s!
    ///      this is because of the (unknown to us) convention used in the bn254 pairing precompile contract
    ///      "Elements a * i + b of F_p^2 are encoded as two elements of F_p, (a, b)."
    ///      https://github.com/ethereum/EIPs/blob/master/EIPS/eip-197.md#encoding
    function generatorG2() internal pure returns (G2Point memory) {
        return G2Point([G2x1, G2x0], [G2y1, G2y0]);
    }

    // negation of the generator of group G2
    /// @dev Generator point in F_q2 is of the form: (x0 + ix1, y0 + iy1).
    uint256 internal constant nG2x1 =
        11559732032986387107991004021392285783925812861821192530917403151452391805634;
    uint256 internal constant nG2x0 =
        10857046999023057135944570762232829481370756359578518086990519993285655852781;
    uint256 internal constant nG2y1 =
        17805874995975841540914202342111839520379459829704422454583296818431106115052;
    uint256 internal constant nG2y0 =
        13392588948715843804641432497768002650278120570034223513918757245338268106653;

    function negGeneratorG2() internal pure returns (G2Point memory) {
        return G2Point([nG2x1, nG2x0], [nG2y1, nG2y0]);
    }

    bytes32 internal constant powersOfTauMerkleRoot =
        0x22c998e49752bbb1918ba87d6d59dd0e83620a311ba91dd4b2cc84990b31b56f;

    /**
     * @param p Some point in G1.
     * @return The negation of `p`, i.e. p.plus(p.negate()) should be zero.
     */
    function negate(
        G1Point memory p
    ) internal pure returns (G1Point memory) {
        // The prime q in the base field F_q for G1
        if (p.X == 0 && p.Y == 0) {
            return G1Point(0, 0);
        } else {
            return G1Point(p.X, FP_MODULUS - (p.Y % FP_MODULUS));
        }
    }

    /**
     * @return r the sum of two points of G1
     */
    function plus(G1Point memory p1, G1Point memory p2) internal view returns (G1Point memory r) {
        uint256[4] memory input;
        input[0] = p1.X;
        input[1] = p1.Y;
        input[2] = p2.X;
        input[3] = p2.Y;
        bool success;

        // solium-disable-next-line security/no-inline-assembly
        assembly {
            success := staticcall(sub(gas(), 2000), 6, input, 0x80, r, 0x40)
            // Use "invalid" to make gas estimation work
            switch success
            case 0 { invalid() }
        }

        require(success, ECAddFailed());
    }

    /**
     * @notice an optimized ecMul implementation that takes O(log_2(s)) ecAdds
     * @param p the point to multiply
     * @param s the scalar to multiply by
     * @dev this function is only safe to use if the scalar is 9 bits or less
     */
    function scalar_mul_tiny(
        BN254.G1Point memory p,
        uint16 s
    ) internal view returns (BN254.G1Point memory) {
        require(s < 2 ** 9, ScalarTooLarge());

        // if s is 1 return p
        if (s == 1) {
            return p;
        }

        // the accumulated product to return
        BN254.G1Point memory acc = BN254.G1Point(0, 0);
        // the 2^n*p to add to the accumulated product in each iteration
        BN254.G1Point memory p2n = p;
        // value of most significant bit
        uint16 m = 1;
        // index of most significant bit
        uint8 i = 0;

        //loop until we reach the most significant bit
        while (s >= m) {
            unchecked {
                // if the  current bit is 1, add the 2^n*p to the accumulated product
                if ((s >> i) & 1 == 1) {
                    acc = plus(acc, p2n);
                }
                // double the 2^n*p for the next iteration
                p2n = plus(p2n, p2n);

                // increment the index and double the value of the most significant bit
                m <<= 1;
                ++i;
            }
        }

        // return the accumulated product
        return acc;
    }

    /**
     * @return r the product of a point on G1 and a scalar, i.e.
     *         p == p.scalar_mul(1) and p.plus(p) == p.scalar_mul(2) for all
     *         points p.
     */
    function scalar_mul(G1Point memory p, uint256 s) internal view returns (G1Point memory r) {
        uint256[3] memory input;
        input[0] = p.X;
        input[1] = p.Y;
        input[2] = s;
        bool success;
        // solium-disable-next-line security/no-inline-assembly
        assembly {
            success := staticcall(sub(gas(), 2000), 7, input, 0x60, r, 0x40)
            // Use "invalid" to make gas estimation work
            switch success
            case 0 { invalid() }
        }
        require(success, ECMulFailed());
    }

    /**
     *  @return The result of computing the pairing check
     *         e(p1[0], p2[0]) *  .... * e(p1[n], p2[n]) == 1
     *         For example,
     *         pairing([P1(), P1().negate()], [P2(), P2()]) should return true.
     */
    function pairing(
        G1Point memory a1,
        G2Point memory a2,
        G1Point memory b1,
        G2Point memory b2
    ) internal view returns (bool) {
        G1Point[2] memory p1 = [a1, b1];
        G2Point[2] memory p2 = [a2, b2];

        uint256[12] memory input;

        for (uint256 i = 0; i < 2; i++) {
            uint256 j = i * 6;
            input[j + 0] = p1[i].X;
            input[j + 1] = p1[i].Y;
            input[j + 2] = p2[i].X[0];
            input[j + 3] = p2[i].X[1];
            input[j + 4] = p2[i].Y[0];
            input[j + 5] = p2[i].Y[1];
        }

        uint256[1] memory out;
        bool success;

        // solium-disable-next-line security/no-inline-assembly
        assembly {
            success := staticcall(sub(gas(), 2000), 8, input, mul(12, 0x20), out, 0x20)
            // Use "invalid" to make gas estimation work
            switch success
            case 0 { invalid() }
        }

        require(success, ECPairingFailed());

        return out[0] != 0;
    }

    /**
     * @notice This function is functionally the same as pairing(), however it specifies a gas limit
     *         the user can set, as a precompile may use the entire gas budget if it reverts.
     */
    function safePairing(
        G1Point memory a1,
        G2Point memory a2,
        G1Point memory b1,
        G2Point memory b2,
        uint256 pairingGas
    ) internal view returns (bool, bool) {
        G1Point[2] memory p1 = [a1, b1];
        G2Point[2] memory p2 = [a2, b2];

        uint256[12] memory input;

        for (uint256 i = 0; i < 2; i++) {
            uint256 j = i * 6;
            input[j + 0] = p1[i].X;
            input[j + 1] = p1[i].Y;
            input[j + 2] = p2[i].X[0];
            input[j + 3] = p2[i].X[1];
            input[j + 4] = p2[i].Y[0];
            input[j + 5] = p2[i].Y[1];
        }

        uint256[1] memory out;
        bool success;

        // solium-disable-next-line security/no-inline-assembly
        assembly {
            success := staticcall(pairingGas, 8, input, mul(12, 0x20), out, 0x20)
        }

        //Out is the output of the pairing precompile, either 0 or 1 based on whether the two pairings are equal.
        //Success is true if the precompile actually goes through (aka all inputs are valid)

        return (success, out[0] != 0);
    }

    /// @return hashedG1 the keccak256 hash of the G1 Point
    /// @dev used for BLS signatures
    function hashG1Point(
        BN254.G1Point memory pk
    ) internal pure returns (bytes32 hashedG1) {
        assembly {
            mstore(0, mload(pk))
            mstore(0x20, mload(add(0x20, pk)))
            hashedG1 := keccak256(0, 0x40)
        }
    }

    /// @return the keccak256 hash of the G2 Point
    /// @dev used for BLS signatures
    function hashG2Point(
        BN254.G2Point memory pk
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(pk.X[0], pk.X[1], pk.Y[0], pk.Y[1]));
    }

    /**
     * @notice adapted from https://github.com/HarryR/solcrypto/blob/master/contracts/altbn128.sol
     */
    function hashToG1(
        bytes32 _x
    ) internal view returns (G1Point memory) {
        uint256 beta = 0;
        uint256 y = 0;

        uint256 x = uint256(_x) % FP_MODULUS;

        while (true) {
            (beta, y) = findYFromX(x);

            // y^2 == beta
            if (beta == mulmod(y, y, FP_MODULUS)) {
                return G1Point(x, y);
            }

            x = addmod(x, 1, FP_MODULUS);
        }
        return G1Point(0, 0);
    }

    /**
     * Given X, find Y
     *
     *   where y = sqrt(x^3 + b)
     *
     * Returns: (x^3 + b), y
     */
    function findYFromX(
        uint256 x
    ) internal view returns (uint256, uint256) {
        // beta = (x^3 + b) % p
        uint256 beta = addmod(mulmod(mulmod(x, x, FP_MODULUS), x, FP_MODULUS), 3, FP_MODULUS);

        // y^2 = x^3 + b
        // this acts like: y = sqrt(beta) = beta^((p+1) / 4)
        uint256 y = expMod(
            beta, 0xc19139cb84c680a6e14116da060561765e05aa45a1c72a34f082305b61f3f52, FP_MODULUS
        );

        return (beta, y);
    }

    function expMod(
        uint256 _base,
        uint256 _exponent,
        uint256 _modulus
    ) internal view returns (uint256 retval) {
        bool success;
        uint256[1] memory output;
        uint256[6] memory input;
        input[0] = 0x20; // baseLen = new(big.Int).SetBytes(getData(input, 0, 32))
        input[1] = 0x20; // expLen  = new(big.Int).SetBytes(getData(input, 32, 32))
        input[2] = 0x20; // modLen  = new(big.Int).SetBytes(getData(input, 64, 32))
        input[3] = _base;
        input[4] = _exponent;
        input[5] = _modulus;
        assembly {
            success := staticcall(sub(gas(), 2000), 5, input, 0xc0, output, 0x20)
            // Use "invalid" to make gas estimation work
            switch success
            case 0 { invalid() }
        }
        require(success, ExpModFailed());
        return output[0];
    }
}

// src/examples/onchain-llm/DataContractLib.sol

/// @title DataContractLib
/// @notice Minimal from-scratch "data contract" helpers: store immutable byte blobs as
///         contract runtime code (up to 24,575 payload bytes each under EIP-170) and read
///         them back with EXTCODECOPY.
/// @dev The deployed runtime is `0x00 || payload`. The leading STOP byte guarantees the
///      blob can never be executed as meaningful code. Reads skip that first byte.
///      Under Gas Killer's unbounded simulation mode, EXTCODECOPY reads never enter the
///      extracted state-update payload, so weights stored this way are free to consume
///      off-chain while remaining part of verifiable chain state.
library DataContractLib {
    /// @notice Maximum payload per data contract: EIP-170 (24,576) minus the STOP prefix
    uint256 internal constant MAX_PAYLOAD = 24_575;

    /// @notice Thrown when a payload exceeds MAX_PAYLOAD
    error PayloadTooLarge();

    /// @notice Thrown when CREATE fails (e.g. out of gas or nonce issues)
    error DeployFailed();

    /// @notice Deploy `payload` as the runtime code of a fresh data contract
    /// @param payload The bytes to persist (at most MAX_PAYLOAD)
    /// @return pointer The address of the deployed data contract
    function write(bytes memory payload) internal returns (address pointer) {
        if (payload.length > MAX_PAYLOAD) revert PayloadTooLarge();
        // Init code: PUSH2 len | DUP1 | PUSH1 0x0C | PUSH1 0x00 | CODECOPY | PUSH1 0x00 | RETURN
        // (12 bytes) followed by the runtime `0x00 || payload` at offset 0x0C.
        bytes memory initCode =
            abi.encodePacked(hex"61", uint16(payload.length + 1), hex"80600C6000396000F3", hex"00", payload);
        assembly ("memory-safe") {
            pointer := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (pointer == address(0)) revert DeployFailed();
    }

    /// @notice Payload length of a data contract (code size minus the STOP prefix)
    /// @param pointer The data contract address
    /// @return length The payload byte length
    function payloadLength(address pointer) internal view returns (uint256 length) {
        assembly ("memory-safe") {
            length := extcodesize(pointer)
        }
        if (length == 0) revert DeployFailed();
        unchecked {
            length -= 1;
        }
    }

    /// @notice Read the full payload of a data contract
    /// @param pointer The data contract address
    /// @return data The payload bytes
    function read(address pointer) internal view returns (bytes memory data) {
        uint256 length = payloadLength(pointer);
        data = new bytes(length);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(data, 0x20), 1, length)
        }
    }

    /// @notice Copy a data contract's payload into `dest` starting at byte `destOffset`
    /// @dev Reverts if the payload would overflow `dest`
    /// @param pointer The data contract address
    /// @param dest The destination buffer
    /// @param destOffset The byte offset within `dest` to copy to
    /// @return copied The number of payload bytes copied
    function readInto(address pointer, bytes memory dest, uint256 destOffset) internal view returns (uint256 copied) {
        copied = payloadLength(pointer);
        if (destOffset + copied > dest.length) revert PayloadTooLarge();
        assembly ("memory-safe") {
            extcodecopy(pointer, add(add(dest, 0x20), destOffset), 1, copied)
        }
    }
}

// src/examples/onchain-fly/FlyTypes.sol

/// @title FlyTypes
/// @notice Shared value types of the fly-connectome AMM (HANDOFF §3.5, §4.2, §4.5, §4.7; HANDOFF_PER_SWAP §4–§5)
library FlyTypes {
    // ------------------------------------------------------------------ v1 (window policy loop)

    /// @notice What the v1 pool exposes to the fly: the last CLOSED window, storage reads only
    struct Observation {
        uint32 windowId;
        uint64[16] buyQuote;
        uint64[16] sellQuote;
        uint64 volRef;
        uint128 spotQ64;
        uint128 twapQ64;
        uint64 feeIncomeQuote;
        uint64 lpLossQuote;
    }

    /// @notice Reinforcement pulses applied from step 0 of an episode
    struct Stimulus {
        uint16 punishSteps;
        uint16 rewardSteps;
    }

    /// @notice Decoder outputs of one episode
    struct Readout {
        uint32[4] rateMilliHz;
        uint32[4] spikesLast30ms;
        uint32[14] windowCounts;
        uint64 totalSpikes;
    }

    /// @notice The v1 per-round consumer state (lives in the log; its packed word lives in FLY_SLOT)
    struct FlyState {
        bytes32 prevWord;
        uint32 epoch;
        uint32 windowId;
        uint16 feeBps;
        int16 skewBps;
        uint8 flags;
        uint32[4] rateMilliHz;
        bytes32 memoryRoot;
    }

    // ------------------------------------------------------------------ v2 (per-swap intents)

    /// @notice One queued intent as the fly sees it (HANDOFF_PER_SWAP §5.1). Storage reads only; the
    ///         histogram is already rotated so index 15 is epoch−1 and the strips use `epoch`.
    struct SwapObservation {
        uint64 id;
        bool buyBase;
        uint64 sizeBps; // amountIn relative to the input-side reserve, bps, saturating at 10_000
        uint64 maxSlipBps; // implied by minOut vs the curve quote at current reserves (0 if minOut == 0)
        uint64 queueDepth; // tail − applied at the reference block
        uint32 epoch; // policy epoch the observation is taken for (prev.epoch + 1)
        uint64[16] buyQuote; // per-epoch fee-paid quote volume, oldest..newest (OBS_UNIT)
        uint64[16] sellQuote;
        uint64 volRef;
        uint128 spotQ64;
        uint128 emaSpotQ64;
        uint64 feeIncomeQuote; // last applied epoch's fee income → REWARD pulse
        uint64 lpLossQuote; // last applied epoch's LP loss vs emaSpot → PUNISH pulse
    }

    /// @notice The v2 chained consumer state (fee/skew live per intent in `fills`, not here)
    struct FlyStateV2 {
        bytes32 prevWord;
        uint32 epoch;
        uint64 decidedThrough;
        uint8 flags;
        uint32[4] rateMilliHz;
        bytes32 memoryRoot;
    }
}

// lib/eigenlayer-middleware/lib/eigenlayer-contracts/src/contracts/interfaces/IAVSRegistrar.sol

interface IAVSRegistrar {
    /**
     * @notice Called by the AllocationManager when an operator wants to register
     * for one or more operator sets. This method should revert if registration
     * is unsuccessful.
     * @param operator the registering operator
     * @param avs the AVS the operator is registering for. This should be the same as IAVSRegistrar.avs()
     * @param operatorSetIds the list of operator set ids being registered for
     * @param data arbitrary data the operator can provide as part of registration
     */
    function registerOperator(
        address operator,
        address avs,
        uint32[] calldata operatorSetIds,
        bytes calldata data
    ) external;

    /**
     * @notice Called by the AllocationManager when an operator is deregistered from
     * one or more operator sets. If this method reverts, it is ignored.
     * @param operator the deregistering operator
     * @param avs the AVS the operator is deregistering from. This should be the same as IAVSRegistrar.avs()
     * @param operatorSetIds the list of operator set ids being deregistered from
     */
    function deregisterOperator(address operator, address avs, uint32[] calldata operatorSetIds) external;

    /**
     * @notice Returns true if the AVS is supported by the registrar
     * @param avs the AVS to check
     * @return true if the AVS is supported, false otherwise
     */
    function supportsAVS(
        address avs
    ) external view returns (bool);
}

// lib/forge-std/src/interfaces/IERC165.sol

interface IERC165 {
    /// @notice Query if a contract implements an interface
    /// @param interfaceID The interface identifier, as specified in ERC-165
    /// @dev Interface identification is specified in ERC-165. This function
    /// uses less than 30,000 gas.
    /// @return `true` if the contract implements `interfaceID` and
    /// `interfaceID` is not 0xffffffff, `false` otherwise
    function supportsInterface(bytes4 interfaceID) external view returns (bool);
}

// lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol

// OpenZeppelin Contracts (last updated v4.9.0) (token/ERC20/IERC20.sol)

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol

// OpenZeppelin Contracts (last updated v4.9.0) (token/ERC20/extensions/IERC20Permit.sol)

/**
 * @dev Interface of the ERC20 Permit extension allowing approvals to be made via signatures, as defined in
 * https://eips.ethereum.org/EIPS/eip-2612[EIP-2612].
 *
 * Adds the {permit} method, which can be used to change an account's ERC20 allowance (see {IERC20-allowance}) by
 * presenting a message signed by the account. By not relying on {IERC20-approve}, the token holder account doesn't
 * need to send a transaction, and thus is not required to hold Ether at all.
 */
interface IERC20Permit {
    /**
     * @dev Sets `value` as the allowance of `spender` over ``owner``'s tokens,
     * given ``owner``'s signed approval.
     *
     * IMPORTANT: The same issues {IERC20-approve} has related to transaction
     * ordering also apply here.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `deadline` must be a timestamp in the future.
     * - `v`, `r` and `s` must be a valid `secp256k1` signature from `owner`
     * over the EIP712-formatted function arguments.
     * - the signature must use ``owner``'s current nonce (see {nonces}).
     *
     * For more information on the signature format, see the
     * https://eips.ethereum.org/EIPS/eip-2612#specification[relevant EIP
     * section].
     */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /**
     * @dev Returns the current nonce for `owner`. This value must be
     * included whenever a signature is generated for {permit}.
     *
     * Every successful call to {permit} increases ``owner``'s nonce by one. This
     * prevents a signature from being used multiple times.
     */
    function nonces(address owner) external view returns (uint256);

    /**
     * @dev Returns the domain separator used in the encoding of the signature for {permit}, as defined by {EIP712}.
     */
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

// lib/eigenlayer-middleware/src/interfaces/IIndexRegistry.sol

interface IIndexRegistryErrors {
    /// @notice Thrown when a function is called by an address that is not the RegistryCoordinator.
    error OnlyRegistryCoordinator();
    /// @notice Thrown when attempting to query a quorum that has no history.
    error QuorumDoesNotExist();
    /// @notice Thrown when attempting to look up an operator that does not exist at the specified block number.
    error OperatorIdDoesNotExist();
}

interface IIndexRegistryTypes {
    /// @notice Represents an update to an operator's status at a specific index.
    /// @param fromBlockNumber The block number from which this update takes effect.
    /// @param operatorId The unique identifier of the operator.
    struct OperatorUpdate {
        uint32 fromBlockNumber;
        bytes32 operatorId;
    }

    /// @notice Represents an update to the total number of operators in a quorum.
    /// @param fromBlockNumber The block number from which this update takes effect.
    /// @param numOperators The total number of operators after the update.
    struct QuorumUpdate {
        uint32 fromBlockNumber;
        uint32 numOperators;
    }
}

interface IIndexRegistryEvents is IIndexRegistryTypes {
    /*
     * @notice Emitted when an operator's index in a quorum is updated.
     * @param operatorId The unique identifier of the operator.
     * @param quorumNumber The identifier of the quorum.
     * @param newOperatorIndex The new index assigned to the operator.
     */
    event QuorumIndexUpdate(
        bytes32 indexed operatorId, uint8 quorumNumber, uint32 newOperatorIndex
    );
}

interface IIndexRegistry is IIndexRegistryErrors, IIndexRegistryEvents {
    /*
     * @notice Returns the special identifier used to indicate a non-existent operator.
     * @return The bytes32 constant OPERATOR_DOES_NOT_EXIST_ID.
     */
    function OPERATOR_DOES_NOT_EXIST_ID() external pure returns (bytes32);

    /*
     * @notice Returns the address of the RegistryCoordinator contract.
     * @return The address of the RegistryCoordinator.
     */
    function registryCoordinator() external view returns (address);

    /*
     * @notice Returns the current index of an operator with ID `operatorId` in quorum `quorumNumber`.
     * @dev This mapping is NOT updated when an operator is deregistered,
     * so it's possible that an index retrieved from this mapping is inaccurate.
     * If you're querying for an operator that might be deregistered, ALWAYS
     * check this index against the latest `_operatorIndexHistory` entry.
     * @param quorumNumber The identifier of the quorum.
     * @param operatorId The unique identifier of the operator.
     * @return The current index of the operator.
     */
    function currentOperatorIndex(
        uint8 quorumNumber,
        bytes32 operatorId
    ) external view returns (uint32);

    // ACTIONS

    /*
     * @notice Registers the operator with the specified `operatorId` for the quorums specified by `quorumNumbers`.
     * @param operatorId The unique identifier of the operator.
     * @param quorumNumbers The quorum numbers to register for.
     * @return An array containing a list of the number of operators (including the registering operator)
     *         in each of the quorums the operator is registered for.
     * @dev Access restricted to the RegistryCoordinator.
     * @dev Preconditions:
     *         1) `quorumNumbers` has no duplicates
     *         2) `quorumNumbers.length` != 0
     *         3) `quorumNumbers` is ordered in ascending order
     *         4) the operator is not already registered
     */
    function registerOperator(
        bytes32 operatorId,
        bytes calldata quorumNumbers
    ) external returns (uint32[] memory);

    /*
     * @notice Deregisters the operator with the specified `operatorId` for the quorums specified by `quorumNumbers`.
     * @param operatorId The unique identifier of the operator.
     * @param quorumNumbers The quorum numbers to deregister from.
     * @dev Access restricted to the RegistryCoordinator.
     * @dev Preconditions:
     *         1) `quorumNumbers` has no duplicates
     *         2) `quorumNumbers.length` != 0
     *         3) `quorumNumbers` is ordered in ascending order
     *         4) the operator is not already deregistered
     *         5) `quorumNumbers` is a subset of the quorumNumbers that the operator is registered for
     */
    function deregisterOperator(bytes32 operatorId, bytes calldata quorumNumbers) external;

    /*
     * @notice Initializes a new quorum `quorumNumber`.
     * @param quorumNumber The identifier of the quorum to initialize.
     */
    function initializeQuorum(
        uint8 quorumNumber
    ) external;

    // VIEW

    /*
     * @notice Returns the operator update at index `arrayIndex` for operator at index `operatorIndex` in quorum `quorumNumber`.
     * @param quorumNumber The identifier of the quorum.
     * @param operatorIndex The index of the operator.
     * @param arrayIndex The index in the update history.
     * @return The operator update entry.
     */
    function getOperatorUpdateAtIndex(
        uint8 quorumNumber,
        uint32 operatorIndex,
        uint32 arrayIndex
    ) external view returns (OperatorUpdate memory);

    /*
     * @notice Returns the quorum update at index `quorumIndex` for quorum `quorumNumber`.
     * @param quorumNumber The identifier of the quorum.
     * @param quorumIndex The index in the quorum's update history.
     * @return The quorum update entry.
     */
    function getQuorumUpdateAtIndex(
        uint8 quorumNumber,
        uint32 quorumIndex
    ) external view returns (QuorumUpdate memory);

    /*
     * @notice Returns the latest quorum update for quorum `quorumNumber`.
     * @param quorumNumber The identifier of the quorum.
     * @return The most recent quorum update.
     */
    function getLatestQuorumUpdate(
        uint8 quorumNumber
    ) external view returns (QuorumUpdate memory);

    /*
     * @notice Returns the latest operator update for operator at index `operatorIndex` in quorum `quorumNumber`.
     * @param quorumNumber The identifier of the quorum.
     * @param operatorIndex The index of the operator.
     * @return The most recent operator update.
     */
    function getLatestOperatorUpdate(
        uint8 quorumNumber,
        uint32 operatorIndex
    ) external view returns (OperatorUpdate memory);

    /*
     * @notice Returns the list of operators in quorum `quorumNumber` at block `blockNumber`.
     * @param quorumNumber The identifier of the quorum.
     * @param blockNumber The block number to query.
     * @return An array of operator IDs.
     */
    function getOperatorListAtBlockNumber(
        uint8 quorumNumber,
        uint32 blockNumber
    ) external view returns (bytes32[] memory);

    /*
     * @notice Returns the total number of operators in quorum `quorumNumber`.
     * @param quorumNumber The identifier of the quorum.
     * @return The total number of operators.
     */
    function totalOperatorsForQuorum(
        uint8 quorumNumber
    ) external view returns (uint32);

    /*
     * @notice Returns the total number of operators in quorum `quorumNumber` at block `blockNumber`.
     * @param quorumNumber The identifier of the quorum.
     * @param blockNumber The block number to query.
     * @return The total number of operators at the specified block.
     */
    function totalOperatorsForQuorumAtBlockNumber(
        uint8 quorumNumber,
        uint32 blockNumber
    ) external view returns (uint32);
}

// lib/eigenlayer-middleware/lib/eigenlayer-contracts/src/contracts/interfaces/IPauserRegistry.sol

/**
 * @title Interface for the `PauserRegistry` contract.
 * @author Layr Labs, Inc.
 * @notice Terms of Service: https://docs.eigenlayer.xyz/overview/terms-of-service
 */
interface IPauserRegistry {
    error OnlyUnpauser();
    error InputAddressZero();

    event PauserStatusChanged(address pauser, bool canPause);

    event UnpauserChanged(address previousUnpauser, address newUnpauser);

    /// @notice Mapping of addresses to whether they hold the pauser role.
    function isPauser(
        address pauser
    ) external view returns (bool);

    /// @notice Unique address that holds the unpauser role. Capable of changing *both* the pauser and unpauser addresses.
    function unpauser() external view returns (address);
}

// lib/eigenlayer-middleware/lib/eigenlayer-contracts/src/contracts/interfaces/ISemVerMixin.sol

/// @title ISemVerMixin
/// @notice A mixin interface that provides semantic versioning functionality.
/// @dev Follows SemVer 2.0.0 specification (https://semver.org/)
interface ISemVerMixin {
    /// @notice Returns the semantic version string of the contract.
    /// @return The version string in SemVer format (e.g., "v1.1.1")
    function version() external view returns (string memory);
}

// lib/eigenlayer-middleware/src/interfaces/ISocketRegistry.sol

interface ISocketRegistryErrors {
    /// @notice Thrown when the caller is not the SlashingRegistryCoordinator
    error OnlySlashingRegistryCoordinator();
}

interface ISocketRegistry is ISocketRegistryErrors {
    /**
     * @notice Sets the socket for an operator.
     * @param _operatorId The id of the operator to set the socket for.
     * @param _socket The socket (any arbitrary string as deemed useful by an AVS) to set.
     * @dev Only callable by the SlashingRegistryCoordinator.
     */
    function setOperatorSocket(bytes32 _operatorId, string memory _socket) external;

    /**
     * @notice Gets the stored socket for an operator.
     * @param _operatorId The id of the operator to query.
     * @return The stored socket associated with the operator.
     */
    function getOperatorSocket(
        bytes32 _operatorId
    ) external view returns (string memory);
}

// lib/openzeppelin-contracts/contracts/utils/math/Math.sol

// OpenZeppelin Contracts (last updated v4.9.0) (utils/math/Math.sol)

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    enum Rounding {
        Down, // Toward negative infinity
        Up, // Toward infinity
        Zero // Toward zero
    }

    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow.
        return (a & b) + (a ^ b) / 2;
    }

    /**
     * @dev Returns the ceiling of the division of two numbers.
     *
     * This differs from standard division with `/` in that it rounds up instead
     * of rounding down.
     */
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b - 1) / b can overflow on addition, so we distribute.
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /**
     * @notice Calculates floor(x * y / denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
     * @dev Original credit to Remco Bloemen under MIT license (https://xn--2-umb.com/21/muldiv)
     * with further edits by Uniswap Labs also under MIT license.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = x * y. Compute the product mod 2^256 and mod 2^256 - 1, then use
            // use the Chinese Remainder Theorem to reconstruct the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2^256 + prod0.
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division.
            if (prod1 == 0) {
                // Solidity will revert if denominator == 0, unlike the div opcode on its own.
                // The surrounding unchecked block does not change this fact.
                // See https://docs.soliditylang.org/en/latest/control-structures.html#checked-or-unchecked-arithmetic.
                return prod0 / denominator;
            }

            // Make sure the result is less than 2^256. Also prevents denominator == 0.
            require(denominator > prod1, "Math: mulDiv overflow");

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0].
            uint256 remainder;
            assembly {
                // Compute remainder using mulmod.
                remainder := mulmod(x, y, denominator)

                // Subtract 256 bit number from 512 bit number.
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator. Always >= 1.
            // See https://cs.stackexchange.com/q/138556/92363.

            // Does not overflow because the denominator cannot be zero at this stage in the function.
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                // Divide denominator by twos.
                denominator := div(denominator, twos)

                // Divide [prod1 prod0] by twos.
                prod0 := div(prod0, twos)

                // Flip twos such that it is 2^256 / twos. If twos is zero, then it becomes one.
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Shift in bits from prod1 into prod0.
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256. Now that denominator is an odd number, it has an inverse modulo 2^256 such
            // that denominator * inv = 1 mod 2^256. Compute the inverse by starting with a seed that is correct for
            // four bits. That is, denominator * inv = 1 mod 2^4.
            uint256 inverse = (3 * denominator) ^ 2;

            // Use the Newton-Raphson iteration to improve the precision. Thanks to Hensel's lifting lemma, this also works
            // in modular arithmetic, doubling the correct bits in each step.
            inverse *= 2 - denominator * inverse; // inverse mod 2^8
            inverse *= 2 - denominator * inverse; // inverse mod 2^16
            inverse *= 2 - denominator * inverse; // inverse mod 2^32
            inverse *= 2 - denominator * inverse; // inverse mod 2^64
            inverse *= 2 - denominator * inverse; // inverse mod 2^128
            inverse *= 2 - denominator * inverse; // inverse mod 2^256

            // Because the division is now exact we can divide by multiplying with the modular inverse of denominator.
            // This will give us the correct result modulo 2^256. Since the preconditions guarantee that the outcome is
            // less than 2^256, this is the final result. We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inverse;
            return result;
        }
    }

    /**
     * @notice Calculates x * y / denominator with full precision, following the selected rounding direction.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding rounding) internal pure returns (uint256) {
        uint256 result = mulDiv(x, y, denominator);
        if (rounding == Rounding.Up && mulmod(x, y, denominator) > 0) {
            result += 1;
        }
        return result;
    }

    /**
     * @dev Returns the square root of a number. If the number is not a perfect square, the value is rounded down.
     *
     * Inspired by Henry S. Warren, Jr.'s "Hacker's Delight" (Chapter 11).
     */
    function sqrt(uint256 a) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        // For our first guess, we get the biggest power of 2 which is smaller than the square root of the target.
        //
        // We know that the "msb" (most significant bit) of our target number `a` is a power of 2 such that we have
        // `msb(a) <= a < 2*msb(a)`. This value can be written `msb(a)=2**k` with `k=log2(a)`.
        //
        // This can be rewritten `2**log2(a) <= a < 2**(log2(a) + 1)`
        // → `sqrt(2**k) <= sqrt(a) < sqrt(2**(k+1))`
        // → `2**(k/2) <= sqrt(a) < 2**((k+1)/2) <= 2**(k/2 + 1)`
        //
        // Consequently, `2**(log2(a) / 2)` is a good first approximation of `sqrt(a)` with at least 1 correct bit.
        uint256 result = 1 << (log2(a) >> 1);

        // At this point `result` is an estimation with one bit of precision. We know the true value is a uint128,
        // since it is the square root of a uint256. Newton's method converges quadratically (precision doubles at
        // every iteration). We thus need at most 7 iteration to turn our partial result with one bit of precision
        // into the expected uint128 result.
        unchecked {
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            return min(result, a / result);
        }
    }

    /**
     * @notice Calculates sqrt(a), following the selected rounding direction.
     */
    function sqrt(uint256 a, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = sqrt(a);
            return result + (rounding == Rounding.Up && result * result < a ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 2, rounded down, of a positive value.
     * Returns 0 if given 0.
     */
    function log2(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 128;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 64;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 32;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 16;
            }
            if (value >> 8 > 0) {
                value >>= 8;
                result += 8;
            }
            if (value >> 4 > 0) {
                value >>= 4;
                result += 4;
            }
            if (value >> 2 > 0) {
                value >>= 2;
                result += 2;
            }
            if (value >> 1 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 2, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log2(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log2(value);
            return result + (rounding == Rounding.Up && 1 << result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 10, rounded down, of a positive value.
     * Returns 0 if given 0.
     */
    function log10(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >= 10 ** 64) {
                value /= 10 ** 64;
                result += 64;
            }
            if (value >= 10 ** 32) {
                value /= 10 ** 32;
                result += 32;
            }
            if (value >= 10 ** 16) {
                value /= 10 ** 16;
                result += 16;
            }
            if (value >= 10 ** 8) {
                value /= 10 ** 8;
                result += 8;
            }
            if (value >= 10 ** 4) {
                value /= 10 ** 4;
                result += 4;
            }
            if (value >= 10 ** 2) {
                value /= 10 ** 2;
                result += 2;
            }
            if (value >= 10 ** 1) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 10, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log10(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log10(value);
            return result + (rounding == Rounding.Up && 10 ** result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 256, rounded down, of a positive value.
     * Returns 0 if given 0.
     *
     * Adding one to the result gives the number of pairs of hex symbols needed to represent `value` as a hex string.
     */
    function log256(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 16;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 8;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 4;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 2;
            }
            if (value >> 8 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 256, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log256(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log256(value);
            return result + (rounding == Rounding.Up && 1 << (result << 3) < value ? 1 : 0);
        }
    }
}

// lib/eigenlayer-middleware/lib/eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol

using OperatorSetLib for OperatorSet global;

/**
 * @notice An operator set identified by the AVS address and an identifier
 * @param avs The address of the AVS this operator set belongs to
 * @param id The unique identifier for the operator set
 */
struct OperatorSet {
    address avs;
    uint32 id;
}

library OperatorSetLib {
    function key(
        OperatorSet memory os
    ) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(os.avs, uint96(os.id)));
    }

    function decode(
        bytes32 _key
    ) internal pure returns (OperatorSet memory) {
        /// forgefmt: disable-next-item
        return OperatorSet({
            avs: address(uint160(uint256(_key) >> 96)),
            id: uint32(uint256(_key) & type(uint96).max)
        });
    }
}

// lib/eigenlayer-middleware/lib/openzeppelin-contracts-upgradeable/contracts/utils/math/SafeCastUpgradeable.sol

// OpenZeppelin Contracts (last updated v4.8.0) (utils/math/SafeCast.sol)
// This file was procedurally generated from scripts/generate/templates/SafeCast.js.

/**
 * @dev Wrappers over Solidity's uintXX/intXX casting operators with added overflow
 * checks.
 *
 * Downcasting from uint256/int256 in Solidity does not revert on overflow. This can
 * easily result in undesired exploitation or bugs, since developers usually
 * assume that overflows raise errors. `SafeCast` restores this intuition by
 * reverting the transaction when such an operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 *
 * Can be combined with {SafeMath} and {SignedSafeMath} to extend it to smaller types, by performing
 * all math on `uint256` and `int256` and then downcasting.
 */
library SafeCastUpgradeable {
    /**
     * @dev Returns the downcasted uint248 from uint256, reverting on
     * overflow (when the input is greater than largest uint248).
     *
     * Counterpart to Solidity's `uint248` operator.
     *
     * Requirements:
     *
     * - input must fit into 248 bits
     *
     * _Available since v4.7._
     */
    function toUint248(uint256 value) internal pure returns (uint248) {
        require(value <= type(uint248).max, "SafeCast: value doesn't fit in 248 bits");
        return uint248(value);
    }

    /**
     * @dev Returns the downcasted uint240 from uint256, reverting on
     * overflow (when the input is greater than largest uint240).
     *
     * Counterpart to Solidity's `uint240` operator.
     *
     * Requirements:
     *
     * - input must fit into 240 bits
     *
     * _Available since v4.7._
     */
    function toUint240(uint256 value) internal pure returns (uint240) {
        require(value <= type(uint240).max, "SafeCast: value doesn't fit in 240 bits");
        return uint240(value);
    }

    /**
     * @dev Returns the downcasted uint232 from uint256, reverting on
     * overflow (when the input is greater than largest uint232).
     *
     * Counterpart to Solidity's `uint232` operator.
     *
     * Requirements:
     *
     * - input must fit into 232 bits
     *
     * _Available since v4.7._
     */
    function toUint232(uint256 value) internal pure returns (uint232) {
        require(value <= type(uint232).max, "SafeCast: value doesn't fit in 232 bits");
        return uint232(value);
    }

    /**
     * @dev Returns the downcasted uint224 from uint256, reverting on
     * overflow (when the input is greater than largest uint224).
     *
     * Counterpart to Solidity's `uint224` operator.
     *
     * Requirements:
     *
     * - input must fit into 224 bits
     *
     * _Available since v4.2._
     */
    function toUint224(uint256 value) internal pure returns (uint224) {
        require(value <= type(uint224).max, "SafeCast: value doesn't fit in 224 bits");
        return uint224(value);
    }

    /**
     * @dev Returns the downcasted uint216 from uint256, reverting on
     * overflow (when the input is greater than largest uint216).
     *
     * Counterpart to Solidity's `uint216` operator.
     *
     * Requirements:
     *
     * - input must fit into 216 bits
     *
     * _Available since v4.7._
     */
    function toUint216(uint256 value) internal pure returns (uint216) {
        require(value <= type(uint216).max, "SafeCast: value doesn't fit in 216 bits");
        return uint216(value);
    }

    /**
     * @dev Returns the downcasted uint208 from uint256, reverting on
     * overflow (when the input is greater than largest uint208).
     *
     * Counterpart to Solidity's `uint208` operator.
     *
     * Requirements:
     *
     * - input must fit into 208 bits
     *
     * _Available since v4.7._
     */
    function toUint208(uint256 value) internal pure returns (uint208) {
        require(value <= type(uint208).max, "SafeCast: value doesn't fit in 208 bits");
        return uint208(value);
    }

    /**
     * @dev Returns the downcasted uint200 from uint256, reverting on
     * overflow (when the input is greater than largest uint200).
     *
     * Counterpart to Solidity's `uint200` operator.
     *
     * Requirements:
     *
     * - input must fit into 200 bits
     *
     * _Available since v4.7._
     */
    function toUint200(uint256 value) internal pure returns (uint200) {
        require(value <= type(uint200).max, "SafeCast: value doesn't fit in 200 bits");
        return uint200(value);
    }

    /**
     * @dev Returns the downcasted uint192 from uint256, reverting on
     * overflow (when the input is greater than largest uint192).
     *
     * Counterpart to Solidity's `uint192` operator.
     *
     * Requirements:
     *
     * - input must fit into 192 bits
     *
     * _Available since v4.7._
     */
    function toUint192(uint256 value) internal pure returns (uint192) {
        require(value <= type(uint192).max, "SafeCast: value doesn't fit in 192 bits");
        return uint192(value);
    }

    /**
     * @dev Returns the downcasted uint184 from uint256, reverting on
     * overflow (when the input is greater than largest uint184).
     *
     * Counterpart to Solidity's `uint184` operator.
     *
     * Requirements:
     *
     * - input must fit into 184 bits
     *
     * _Available since v4.7._
     */
    function toUint184(uint256 value) internal pure returns (uint184) {
        require(value <= type(uint184).max, "SafeCast: value doesn't fit in 184 bits");
        return uint184(value);
    }

    /**
     * @dev Returns the downcasted uint176 from uint256, reverting on
     * overflow (when the input is greater than largest uint176).
     *
     * Counterpart to Solidity's `uint176` operator.
     *
     * Requirements:
     *
     * - input must fit into 176 bits
     *
     * _Available since v4.7._
     */
    function toUint176(uint256 value) internal pure returns (uint176) {
        require(value <= type(uint176).max, "SafeCast: value doesn't fit in 176 bits");
        return uint176(value);
    }

    /**
     * @dev Returns the downcasted uint168 from uint256, reverting on
     * overflow (when the input is greater than largest uint168).
     *
     * Counterpart to Solidity's `uint168` operator.
     *
     * Requirements:
     *
     * - input must fit into 168 bits
     *
     * _Available since v4.7._
     */
    function toUint168(uint256 value) internal pure returns (uint168) {
        require(value <= type(uint168).max, "SafeCast: value doesn't fit in 168 bits");
        return uint168(value);
    }

    /**
     * @dev Returns the downcasted uint160 from uint256, reverting on
     * overflow (when the input is greater than largest uint160).
     *
     * Counterpart to Solidity's `uint160` operator.
     *
     * Requirements:
     *
     * - input must fit into 160 bits
     *
     * _Available since v4.7._
     */
    function toUint160(uint256 value) internal pure returns (uint160) {
        require(value <= type(uint160).max, "SafeCast: value doesn't fit in 160 bits");
        return uint160(value);
    }

    /**
     * @dev Returns the downcasted uint152 from uint256, reverting on
     * overflow (when the input is greater than largest uint152).
     *
     * Counterpart to Solidity's `uint152` operator.
     *
     * Requirements:
     *
     * - input must fit into 152 bits
     *
     * _Available since v4.7._
     */
    function toUint152(uint256 value) internal pure returns (uint152) {
        require(value <= type(uint152).max, "SafeCast: value doesn't fit in 152 bits");
        return uint152(value);
    }

    /**
     * @dev Returns the downcasted uint144 from uint256, reverting on
     * overflow (when the input is greater than largest uint144).
     *
     * Counterpart to Solidity's `uint144` operator.
     *
     * Requirements:
     *
     * - input must fit into 144 bits
     *
     * _Available since v4.7._
     */
    function toUint144(uint256 value) internal pure returns (uint144) {
        require(value <= type(uint144).max, "SafeCast: value doesn't fit in 144 bits");
        return uint144(value);
    }

    /**
     * @dev Returns the downcasted uint136 from uint256, reverting on
     * overflow (when the input is greater than largest uint136).
     *
     * Counterpart to Solidity's `uint136` operator.
     *
     * Requirements:
     *
     * - input must fit into 136 bits
     *
     * _Available since v4.7._
     */
    function toUint136(uint256 value) internal pure returns (uint136) {
        require(value <= type(uint136).max, "SafeCast: value doesn't fit in 136 bits");
        return uint136(value);
    }

    /**
     * @dev Returns the downcasted uint128 from uint256, reverting on
     * overflow (when the input is greater than largest uint128).
     *
     * Counterpart to Solidity's `uint128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     *
     * _Available since v2.5._
     */
    function toUint128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, "SafeCast: value doesn't fit in 128 bits");
        return uint128(value);
    }

    /**
     * @dev Returns the downcasted uint120 from uint256, reverting on
     * overflow (when the input is greater than largest uint120).
     *
     * Counterpart to Solidity's `uint120` operator.
     *
     * Requirements:
     *
     * - input must fit into 120 bits
     *
     * _Available since v4.7._
     */
    function toUint120(uint256 value) internal pure returns (uint120) {
        require(value <= type(uint120).max, "SafeCast: value doesn't fit in 120 bits");
        return uint120(value);
    }

    /**
     * @dev Returns the downcasted uint112 from uint256, reverting on
     * overflow (when the input is greater than largest uint112).
     *
     * Counterpart to Solidity's `uint112` operator.
     *
     * Requirements:
     *
     * - input must fit into 112 bits
     *
     * _Available since v4.7._
     */
    function toUint112(uint256 value) internal pure returns (uint112) {
        require(value <= type(uint112).max, "SafeCast: value doesn't fit in 112 bits");
        return uint112(value);
    }

    /**
     * @dev Returns the downcasted uint104 from uint256, reverting on
     * overflow (when the input is greater than largest uint104).
     *
     * Counterpart to Solidity's `uint104` operator.
     *
     * Requirements:
     *
     * - input must fit into 104 bits
     *
     * _Available since v4.7._
     */
    function toUint104(uint256 value) internal pure returns (uint104) {
        require(value <= type(uint104).max, "SafeCast: value doesn't fit in 104 bits");
        return uint104(value);
    }

    /**
     * @dev Returns the downcasted uint96 from uint256, reverting on
     * overflow (when the input is greater than largest uint96).
     *
     * Counterpart to Solidity's `uint96` operator.
     *
     * Requirements:
     *
     * - input must fit into 96 bits
     *
     * _Available since v4.2._
     */
    function toUint96(uint256 value) internal pure returns (uint96) {
        require(value <= type(uint96).max, "SafeCast: value doesn't fit in 96 bits");
        return uint96(value);
    }

    /**
     * @dev Returns the downcasted uint88 from uint256, reverting on
     * overflow (when the input is greater than largest uint88).
     *
     * Counterpart to Solidity's `uint88` operator.
     *
     * Requirements:
     *
     * - input must fit into 88 bits
     *
     * _Available since v4.7._
     */
    function toUint88(uint256 value) internal pure returns (uint88) {
        require(value <= type(uint88).max, "SafeCast: value doesn't fit in 88 bits");
        return uint88(value);
    }

    /**
     * @dev Returns the downcasted uint80 from uint256, reverting on
     * overflow (when the input is greater than largest uint80).
     *
     * Counterpart to Solidity's `uint80` operator.
     *
     * Requirements:
     *
     * - input must fit into 80 bits
     *
     * _Available since v4.7._
     */
    function toUint80(uint256 value) internal pure returns (uint80) {
        require(value <= type(uint80).max, "SafeCast: value doesn't fit in 80 bits");
        return uint80(value);
    }

    /**
     * @dev Returns the downcasted uint72 from uint256, reverting on
     * overflow (when the input is greater than largest uint72).
     *
     * Counterpart to Solidity's `uint72` operator.
     *
     * Requirements:
     *
     * - input must fit into 72 bits
     *
     * _Available since v4.7._
     */
    function toUint72(uint256 value) internal pure returns (uint72) {
        require(value <= type(uint72).max, "SafeCast: value doesn't fit in 72 bits");
        return uint72(value);
    }

    /**
     * @dev Returns the downcasted uint64 from uint256, reverting on
     * overflow (when the input is greater than largest uint64).
     *
     * Counterpart to Solidity's `uint64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     *
     * _Available since v2.5._
     */
    function toUint64(uint256 value) internal pure returns (uint64) {
        require(value <= type(uint64).max, "SafeCast: value doesn't fit in 64 bits");
        return uint64(value);
    }

    /**
     * @dev Returns the downcasted uint56 from uint256, reverting on
     * overflow (when the input is greater than largest uint56).
     *
     * Counterpart to Solidity's `uint56` operator.
     *
     * Requirements:
     *
     * - input must fit into 56 bits
     *
     * _Available since v4.7._
     */
    function toUint56(uint256 value) internal pure returns (uint56) {
        require(value <= type(uint56).max, "SafeCast: value doesn't fit in 56 bits");
        return uint56(value);
    }

    /**
     * @dev Returns the downcasted uint48 from uint256, reverting on
     * overflow (when the input is greater than largest uint48).
     *
     * Counterpart to Solidity's `uint48` operator.
     *
     * Requirements:
     *
     * - input must fit into 48 bits
     *
     * _Available since v4.7._
     */
    function toUint48(uint256 value) internal pure returns (uint48) {
        require(value <= type(uint48).max, "SafeCast: value doesn't fit in 48 bits");
        return uint48(value);
    }

    /**
     * @dev Returns the downcasted uint40 from uint256, reverting on
     * overflow (when the input is greater than largest uint40).
     *
     * Counterpart to Solidity's `uint40` operator.
     *
     * Requirements:
     *
     * - input must fit into 40 bits
     *
     * _Available since v4.7._
     */
    function toUint40(uint256 value) internal pure returns (uint40) {
        require(value <= type(uint40).max, "SafeCast: value doesn't fit in 40 bits");
        return uint40(value);
    }

    /**
     * @dev Returns the downcasted uint32 from uint256, reverting on
     * overflow (when the input is greater than largest uint32).
     *
     * Counterpart to Solidity's `uint32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     *
     * _Available since v2.5._
     */
    function toUint32(uint256 value) internal pure returns (uint32) {
        require(value <= type(uint32).max, "SafeCast: value doesn't fit in 32 bits");
        return uint32(value);
    }

    /**
     * @dev Returns the downcasted uint24 from uint256, reverting on
     * overflow (when the input is greater than largest uint24).
     *
     * Counterpart to Solidity's `uint24` operator.
     *
     * Requirements:
     *
     * - input must fit into 24 bits
     *
     * _Available since v4.7._
     */
    function toUint24(uint256 value) internal pure returns (uint24) {
        require(value <= type(uint24).max, "SafeCast: value doesn't fit in 24 bits");
        return uint24(value);
    }

    /**
     * @dev Returns the downcasted uint16 from uint256, reverting on
     * overflow (when the input is greater than largest uint16).
     *
     * Counterpart to Solidity's `uint16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     *
     * _Available since v2.5._
     */
    function toUint16(uint256 value) internal pure returns (uint16) {
        require(value <= type(uint16).max, "SafeCast: value doesn't fit in 16 bits");
        return uint16(value);
    }

    /**
     * @dev Returns the downcasted uint8 from uint256, reverting on
     * overflow (when the input is greater than largest uint8).
     *
     * Counterpart to Solidity's `uint8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits
     *
     * _Available since v2.5._
     */
    function toUint8(uint256 value) internal pure returns (uint8) {
        require(value <= type(uint8).max, "SafeCast: value doesn't fit in 8 bits");
        return uint8(value);
    }

    /**
     * @dev Converts a signed int256 into an unsigned uint256.
     *
     * Requirements:
     *
     * - input must be greater than or equal to 0.
     *
     * _Available since v3.0._
     */
    function toUint256(int256 value) internal pure returns (uint256) {
        require(value >= 0, "SafeCast: value must be positive");
        return uint256(value);
    }

    /**
     * @dev Returns the downcasted int248 from int256, reverting on
     * overflow (when the input is less than smallest int248 or
     * greater than largest int248).
     *
     * Counterpart to Solidity's `int248` operator.
     *
     * Requirements:
     *
     * - input must fit into 248 bits
     *
     * _Available since v4.7._
     */
    function toInt248(int256 value) internal pure returns (int248 downcasted) {
        downcasted = int248(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 248 bits");
    }

    /**
     * @dev Returns the downcasted int240 from int256, reverting on
     * overflow (when the input is less than smallest int240 or
     * greater than largest int240).
     *
     * Counterpart to Solidity's `int240` operator.
     *
     * Requirements:
     *
     * - input must fit into 240 bits
     *
     * _Available since v4.7._
     */
    function toInt240(int256 value) internal pure returns (int240 downcasted) {
        downcasted = int240(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 240 bits");
    }

    /**
     * @dev Returns the downcasted int232 from int256, reverting on
     * overflow (when the input is less than smallest int232 or
     * greater than largest int232).
     *
     * Counterpart to Solidity's `int232` operator.
     *
     * Requirements:
     *
     * - input must fit into 232 bits
     *
     * _Available since v4.7._
     */
    function toInt232(int256 value) internal pure returns (int232 downcasted) {
        downcasted = int232(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 232 bits");
    }

    /**
     * @dev Returns the downcasted int224 from int256, reverting on
     * overflow (when the input is less than smallest int224 or
     * greater than largest int224).
     *
     * Counterpart to Solidity's `int224` operator.
     *
     * Requirements:
     *
     * - input must fit into 224 bits
     *
     * _Available since v4.7._
     */
    function toInt224(int256 value) internal pure returns (int224 downcasted) {
        downcasted = int224(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 224 bits");
    }

    /**
     * @dev Returns the downcasted int216 from int256, reverting on
     * overflow (when the input is less than smallest int216 or
     * greater than largest int216).
     *
     * Counterpart to Solidity's `int216` operator.
     *
     * Requirements:
     *
     * - input must fit into 216 bits
     *
     * _Available since v4.7._
     */
    function toInt216(int256 value) internal pure returns (int216 downcasted) {
        downcasted = int216(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 216 bits");
    }

    /**
     * @dev Returns the downcasted int208 from int256, reverting on
     * overflow (when the input is less than smallest int208 or
     * greater than largest int208).
     *
     * Counterpart to Solidity's `int208` operator.
     *
     * Requirements:
     *
     * - input must fit into 208 bits
     *
     * _Available since v4.7._
     */
    function toInt208(int256 value) internal pure returns (int208 downcasted) {
        downcasted = int208(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 208 bits");
    }

    /**
     * @dev Returns the downcasted int200 from int256, reverting on
     * overflow (when the input is less than smallest int200 or
     * greater than largest int200).
     *
     * Counterpart to Solidity's `int200` operator.
     *
     * Requirements:
     *
     * - input must fit into 200 bits
     *
     * _Available since v4.7._
     */
    function toInt200(int256 value) internal pure returns (int200 downcasted) {
        downcasted = int200(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 200 bits");
    }

    /**
     * @dev Returns the downcasted int192 from int256, reverting on
     * overflow (when the input is less than smallest int192 or
     * greater than largest int192).
     *
     * Counterpart to Solidity's `int192` operator.
     *
     * Requirements:
     *
     * - input must fit into 192 bits
     *
     * _Available since v4.7._
     */
    function toInt192(int256 value) internal pure returns (int192 downcasted) {
        downcasted = int192(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 192 bits");
    }

    /**
     * @dev Returns the downcasted int184 from int256, reverting on
     * overflow (when the input is less than smallest int184 or
     * greater than largest int184).
     *
     * Counterpart to Solidity's `int184` operator.
     *
     * Requirements:
     *
     * - input must fit into 184 bits
     *
     * _Available since v4.7._
     */
    function toInt184(int256 value) internal pure returns (int184 downcasted) {
        downcasted = int184(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 184 bits");
    }

    /**
     * @dev Returns the downcasted int176 from int256, reverting on
     * overflow (when the input is less than smallest int176 or
     * greater than largest int176).
     *
     * Counterpart to Solidity's `int176` operator.
     *
     * Requirements:
     *
     * - input must fit into 176 bits
     *
     * _Available since v4.7._
     */
    function toInt176(int256 value) internal pure returns (int176 downcasted) {
        downcasted = int176(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 176 bits");
    }

    /**
     * @dev Returns the downcasted int168 from int256, reverting on
     * overflow (when the input is less than smallest int168 or
     * greater than largest int168).
     *
     * Counterpart to Solidity's `int168` operator.
     *
     * Requirements:
     *
     * - input must fit into 168 bits
     *
     * _Available since v4.7._
     */
    function toInt168(int256 value) internal pure returns (int168 downcasted) {
        downcasted = int168(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 168 bits");
    }

    /**
     * @dev Returns the downcasted int160 from int256, reverting on
     * overflow (when the input is less than smallest int160 or
     * greater than largest int160).
     *
     * Counterpart to Solidity's `int160` operator.
     *
     * Requirements:
     *
     * - input must fit into 160 bits
     *
     * _Available since v4.7._
     */
    function toInt160(int256 value) internal pure returns (int160 downcasted) {
        downcasted = int160(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 160 bits");
    }

    /**
     * @dev Returns the downcasted int152 from int256, reverting on
     * overflow (when the input is less than smallest int152 or
     * greater than largest int152).
     *
     * Counterpart to Solidity's `int152` operator.
     *
     * Requirements:
     *
     * - input must fit into 152 bits
     *
     * _Available since v4.7._
     */
    function toInt152(int256 value) internal pure returns (int152 downcasted) {
        downcasted = int152(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 152 bits");
    }

    /**
     * @dev Returns the downcasted int144 from int256, reverting on
     * overflow (when the input is less than smallest int144 or
     * greater than largest int144).
     *
     * Counterpart to Solidity's `int144` operator.
     *
     * Requirements:
     *
     * - input must fit into 144 bits
     *
     * _Available since v4.7._
     */
    function toInt144(int256 value) internal pure returns (int144 downcasted) {
        downcasted = int144(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 144 bits");
    }

    /**
     * @dev Returns the downcasted int136 from int256, reverting on
     * overflow (when the input is less than smallest int136 or
     * greater than largest int136).
     *
     * Counterpart to Solidity's `int136` operator.
     *
     * Requirements:
     *
     * - input must fit into 136 bits
     *
     * _Available since v4.7._
     */
    function toInt136(int256 value) internal pure returns (int136 downcasted) {
        downcasted = int136(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 136 bits");
    }

    /**
     * @dev Returns the downcasted int128 from int256, reverting on
     * overflow (when the input is less than smallest int128 or
     * greater than largest int128).
     *
     * Counterpart to Solidity's `int128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     *
     * _Available since v3.1._
     */
    function toInt128(int256 value) internal pure returns (int128 downcasted) {
        downcasted = int128(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 128 bits");
    }

    /**
     * @dev Returns the downcasted int120 from int256, reverting on
     * overflow (when the input is less than smallest int120 or
     * greater than largest int120).
     *
     * Counterpart to Solidity's `int120` operator.
     *
     * Requirements:
     *
     * - input must fit into 120 bits
     *
     * _Available since v4.7._
     */
    function toInt120(int256 value) internal pure returns (int120 downcasted) {
        downcasted = int120(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 120 bits");
    }

    /**
     * @dev Returns the downcasted int112 from int256, reverting on
     * overflow (when the input is less than smallest int112 or
     * greater than largest int112).
     *
     * Counterpart to Solidity's `int112` operator.
     *
     * Requirements:
     *
     * - input must fit into 112 bits
     *
     * _Available since v4.7._
     */
    function toInt112(int256 value) internal pure returns (int112 downcasted) {
        downcasted = int112(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 112 bits");
    }

    /**
     * @dev Returns the downcasted int104 from int256, reverting on
     * overflow (when the input is less than smallest int104 or
     * greater than largest int104).
     *
     * Counterpart to Solidity's `int104` operator.
     *
     * Requirements:
     *
     * - input must fit into 104 bits
     *
     * _Available since v4.7._
     */
    function toInt104(int256 value) internal pure returns (int104 downcasted) {
        downcasted = int104(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 104 bits");
    }

    /**
     * @dev Returns the downcasted int96 from int256, reverting on
     * overflow (when the input is less than smallest int96 or
     * greater than largest int96).
     *
     * Counterpart to Solidity's `int96` operator.
     *
     * Requirements:
     *
     * - input must fit into 96 bits
     *
     * _Available since v4.7._
     */
    function toInt96(int256 value) internal pure returns (int96 downcasted) {
        downcasted = int96(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 96 bits");
    }

    /**
     * @dev Returns the downcasted int88 from int256, reverting on
     * overflow (when the input is less than smallest int88 or
     * greater than largest int88).
     *
     * Counterpart to Solidity's `int88` operator.
     *
     * Requirements:
     *
     * - input must fit into 88 bits
     *
     * _Available since v4.7._
     */
    function toInt88(int256 value) internal pure returns (int88 downcasted) {
        downcasted = int88(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 88 bits");
    }

    /**
     * @dev Returns the downcasted int80 from int256, reverting on
     * overflow (when the input is less than smallest int80 or
     * greater than largest int80).
     *
     * Counterpart to Solidity's `int80` operator.
     *
     * Requirements:
     *
     * - input must fit into 80 bits
     *
     * _Available since v4.7._
     */
    function toInt80(int256 value) internal pure returns (int80 downcasted) {
        downcasted = int80(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 80 bits");
    }

    /**
     * @dev Returns the downcasted int72 from int256, reverting on
     * overflow (when the input is less than smallest int72 or
     * greater than largest int72).
     *
     * Counterpart to Solidity's `int72` operator.
     *
     * Requirements:
     *
     * - input must fit into 72 bits
     *
     * _Available since v4.7._
     */
    function toInt72(int256 value) internal pure returns (int72 downcasted) {
        downcasted = int72(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 72 bits");
    }

    /**
     * @dev Returns the downcasted int64 from int256, reverting on
     * overflow (when the input is less than smallest int64 or
     * greater than largest int64).
     *
     * Counterpart to Solidity's `int64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     *
     * _Available since v3.1._
     */
    function toInt64(int256 value) internal pure returns (int64 downcasted) {
        downcasted = int64(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 64 bits");
    }

    /**
     * @dev Returns the downcasted int56 from int256, reverting on
     * overflow (when the input is less than smallest int56 or
     * greater than largest int56).
     *
     * Counterpart to Solidity's `int56` operator.
     *
     * Requirements:
     *
     * - input must fit into 56 bits
     *
     * _Available since v4.7._
     */
    function toInt56(int256 value) internal pure returns (int56 downcasted) {
        downcasted = int56(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 56 bits");
    }

    /**
     * @dev Returns the downcasted int48 from int256, reverting on
     * overflow (when the input is less than smallest int48 or
     * greater than largest int48).
     *
     * Counterpart to Solidity's `int48` operator.
     *
     * Requirements:
     *
     * - input must fit into 48 bits
     *
     * _Available since v4.7._
     */
    function toInt48(int256 value) internal pure returns (int48 downcasted) {
        downcasted = int48(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 48 bits");
    }

    /**
     * @dev Returns the downcasted int40 from int256, reverting on
     * overflow (when the input is less than smallest int40 or
     * greater than largest int40).
     *
     * Counterpart to Solidity's `int40` operator.
     *
     * Requirements:
     *
     * - input must fit into 40 bits
     *
     * _Available since v4.7._
     */
    function toInt40(int256 value) internal pure returns (int40 downcasted) {
        downcasted = int40(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 40 bits");
    }

    /**
     * @dev Returns the downcasted int32 from int256, reverting on
     * overflow (when the input is less than smallest int32 or
     * greater than largest int32).
     *
     * Counterpart to Solidity's `int32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     *
     * _Available since v3.1._
     */
    function toInt32(int256 value) internal pure returns (int32 downcasted) {
        downcasted = int32(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 32 bits");
    }

    /**
     * @dev Returns the downcasted int24 from int256, reverting on
     * overflow (when the input is less than smallest int24 or
     * greater than largest int24).
     *
     * Counterpart to Solidity's `int24` operator.
     *
     * Requirements:
     *
     * - input must fit into 24 bits
     *
     * _Available since v4.7._
     */
    function toInt24(int256 value) internal pure returns (int24 downcasted) {
        downcasted = int24(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 24 bits");
    }

    /**
     * @dev Returns the downcasted int16 from int256, reverting on
     * overflow (when the input is less than smallest int16 or
     * greater than largest int16).
     *
     * Counterpart to Solidity's `int16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     *
     * _Available since v3.1._
     */
    function toInt16(int256 value) internal pure returns (int16 downcasted) {
        downcasted = int16(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 16 bits");
    }

    /**
     * @dev Returns the downcasted int8 from int256, reverting on
     * overflow (when the input is less than smallest int8 or
     * greater than largest int8).
     *
     * Counterpart to Solidity's `int8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits
     *
     * _Available since v3.1._
     */
    function toInt8(int256 value) internal pure returns (int8 downcasted) {
        downcasted = int8(value);
        require(downcasted == value, "SafeCast: value doesn't fit in 8 bits");
    }

    /**
     * @dev Converts an unsigned uint256 into a signed int256.
     *
     * Requirements:
     *
     * - input must be less than or equal to maxInt256.
     *
     * _Available since v3.0._
     */
    function toInt256(uint256 value) internal pure returns (int256) {
        // Note: Unsafe cast below is okay because `type(int256).max` is guaranteed to be positive
        require(value <= uint256(type(int256).max), "SafeCast: value doesn't fit in an int256");
        return int256(value);
    }
}

// src/StateChangeHandlerLib.sol

/// @notice Discriminator enum for the type of state update operation to execute
/// @dev Each variant maps to a different EVM operation: storage writes, external calls, log emissions, or contract deployment
enum StateUpdateType {
    /// @notice Write a 32-byte value directly to a storage slot
    STORE,
    /// @notice Execute an external call with optional ETH value transfer
    CALL,
    /// @notice Emit a log with no indexed topics
    LOG0,
    /// @notice Emit a log with one indexed topic
    LOG1,
    /// @notice Emit a log with two indexed topics
    LOG2,
    /// @notice Emit a log with three indexed topics
    LOG3,
    /// @notice Emit a log with four indexed topics
    LOG4,
    /// @notice Deploy a contract using CREATE (nonce-derived address)
    CREATE,
    /// @notice Deploy a contract using CREATE2 (salt-derived deterministic address)
    CREATE2
}

/// @title StateChangeHandlerLib
/// @notice Library for decoding and executing batched state update operations
/// @dev Processes ABI-encoded arrays of typed state updates; supports STORE, CALL, LOG0-LOG4, CREATE, and CREATE2
library StateChangeHandlerLib {
    /// @notice Decodes and executes a series of state updates
    /// @dev This function processes an array of state updates, executing them in sequence. Each update can be one of:
    ///      - STORE: Direct storage writes using assembly
    ///      - CALL: External contract calls with value transfer
    ///      - LOG0-LOG4: Event emission with 0-4 indexed topics
    ///      - CREATE: Contract deployment via CREATE opcode
    ///      - CREATE2: Deterministic contract deployment via CREATE2 opcode
    /// @param types Array of StateUpdateType enums indicating the type of each state update operation
    /// @param args Array of ABI-encoded arguments corresponding to each operation type
    /// @dev types and args arrays must be equal length, with args[i] containing the encoded parameters for types[i]
    function _runStateUpdates(StateUpdateType[] memory types, bytes[] memory args) internal {
        require(types.length == args.length, InvalidArguments());
        for (uint256 i = 0; i < types.length; i++) {
            StateUpdateType stateUpdateType = types[i];
            bytes memory arg = args[i];

            if (stateUpdateType == StateUpdateType.STORE) {
                (bytes32 slot, bytes32 value) = abi.decode(arg, (bytes32, bytes32));
                assembly {
                    sstore(slot, value)
                }
            } else if (stateUpdateType == StateUpdateType.CALL) {
                (address target, uint256 value, bytes memory callargs) = abi.decode(arg, (address, uint256, bytes));
                bool success;
                // TOOD: might need better gas handling
                uint256 callgas = gasleft();
                assembly {
                    success := call(callgas, target, value, add(callargs, 0x20), mload(callargs), 0, 0)
                }
                // TODO: this section needs heavy testing
                if (!success) {
                    uint256 _returndatasize;
                    assembly {
                        _returndatasize := returndatasize()
                    }
                    bytes memory revertData = new bytes(_returndatasize);
                    assembly {
                        returndatacopy(add(revertData, 0x20), 0, _returndatasize)
                    }
                    revert RevertingContext(i, target, revertData, callargs);
                }
            } else if (stateUpdateType == StateUpdateType.LOG0) {
                // NOTE: For consistency I decode an abi encoding of bytes from bytes, but technically it's redundant
                (bytes memory data) = abi.decode(arg, (bytes));
                assembly {
                    log0(add(data, 0x20), mload(data))
                }
            } else if (stateUpdateType == StateUpdateType.LOG1) {
                (bytes memory data, bytes32 topic1) = abi.decode(arg, (bytes, bytes32));
                assembly {
                    log1(add(data, 0x20), mload(data), topic1)
                }
            } else if (stateUpdateType == StateUpdateType.LOG2) {
                (bytes memory data, bytes32 topic1, bytes32 topic2) = abi.decode(arg, (bytes, bytes32, bytes32));
                assembly {
                    log2(add(data, 0x20), mload(data), topic1, topic2)
                }
            } else if (stateUpdateType == StateUpdateType.LOG3) {
                (bytes memory data, bytes32 topic1, bytes32 topic2, bytes32 topic3) =
                    abi.decode(arg, (bytes, bytes32, bytes32, bytes32));
                assembly {
                    log3(add(data, 0x20), mload(data), topic1, topic2, topic3)
                }
            } else if (stateUpdateType == StateUpdateType.LOG4) {
                (bytes memory data, bytes32 topic1, bytes32 topic2, bytes32 topic3, bytes32 topic4) =
                    abi.decode(arg, (bytes, bytes32, bytes32, bytes32, bytes32));
                assembly {
                    log4(add(data, 0x20), mload(data), topic1, topic2, topic3, topic4)
                }
            } else if (stateUpdateType == StateUpdateType.CREATE) {
                (uint256 value, bytes memory initcode) = abi.decode(arg, (uint256, bytes));
                address deployed;
                assembly {
                    deployed := create(value, add(initcode, 0x20), mload(initcode))
                }
                require(deployed != address(0), DeploymentFailed());
            } else if (stateUpdateType == StateUpdateType.CREATE2) {
                (bytes32 salt, uint256 value, bytes memory initcode) = abi.decode(arg, (bytes32, uint256, bytes));
                address deployed;
                assembly {
                    deployed := create2(value, add(initcode, 0x20), mload(initcode), salt)
                }
                require(deployed != address(0), DeploymentFailed());
            }
        }
    }

    /// @notice Thrown when `types` and `args` arrays have different lengths
    error InvalidArguments();

    /// @notice Thrown when a CALL operation's external call reverts
    /// @param index The zero-based position of the failing operation in the batch
    /// @param target The contract address that was called
    /// @param revertData The raw revert data returned by the failed call
    /// @param callargs The calldata that was passed to the failed call
    error RevertingContext(uint256 index, address target, bytes revertData, bytes callargs);

    /// @notice Thrown when a CREATE or CREATE2 operation returns address(0)
    error DeploymentFailed();
}

// src/StateTracker.sol

/// @title StateTracker
/// @notice Tracks the number of state transitions that have occurred in a contract
/// @dev Uses a precomputed ERC-7201-style storage slot to store the transition counter.
///      The slot is computed as: `keccak256("gasKiller.stateTracker") - 1`
///
///      Inherit this contract to enable Gas Killer state-transition tracking.
contract StateTracker {
    /// @notice Precomputed storage slot for the state transition counter
    /// @dev Computed as `keccak256("gasKiller.stateTracker") - 1`
    bytes32 internal constant STATE_TRACKER_STORAGE_LOCATION =
        0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;

    /// @notice Increment the state transition counter before executing the modified function
    /// @dev Apply this modifier to any function that constitutes a tracked state transition.
    ///      Steps: load current count → increment by 1 → store → execute function body.
    modifier trackState() {
        assembly {
            let count := sload(STATE_TRACKER_STORAGE_LOCATION)
            sstore(STATE_TRACKER_STORAGE_LOCATION, add(0x01, count))
        }
        _;
    }

    /// @notice Return the current number of state transitions that have occurred
    /// @return count The total number of tracked state transitions
    function stateTransitionCount() public view returns (uint256 count) {
        assembly {
            count := sload(STATE_TRACKER_STORAGE_LOCATION)
        }
    }
}

// lib/eigenlayer-middleware/src/interfaces/IBLSApkRegistry.sol

interface IBLSApkRegistryErrors {
    /// @notice Thrown when a non-RegistryCoordinator owner address calls a restricted function.
    error OnlyRegistryCoordinatorOwner();
    /// @notice Thrown when a non-RegistryCoordinator address calls a restricted function.
    error OnlyRegistryCoordinator();
    /// @notice Thrown when attempting to initialize a quorum that already exists.
    error QuorumAlreadyExists();
    /// @notice Thrown when a quorum does not exist.
    error QuorumDoesNotExist();
    /// @notice Thrown when a BLS pubkey provided is zero pubkey
    error ZeroPubKey();
    /// @notice Thrown when an operator has already registered a BLS pubkey.
    error OperatorAlreadyRegistered();
    /// @notice Thrown when the operator is not registered.
    error OperatorNotRegistered();
    /// @notice Thrown when a BLS pubkey has already been registered for an operator.
    error BLSPubkeyAlreadyRegistered();
    /// @notice Thrown when either the G1 signature is wrong, or G1 and G2 private key do not match.
    error InvalidBLSSignatureOrPrivateKey();
    /// @notice Thrown when the quorum apk update block number is too recent.
    error BlockNumberTooRecent();
    /// @notice Thrown when blocknumber and index provided is not the latest apk update.
    error BlockNumberNotLatest();
    /// @notice Thrown when the block number is before the first update.
    error BlockNumberBeforeFirstUpdate();
    /// @notice Thrown when a G2 pubkey has already been set for an operator
    error G2PubkeyAlreadySet();
}

interface IBLSApkRegistryTypes {
    /// @notice Tracks the history of aggregate public key updates for a quorum.
    /// @dev Each update contains a hash of the aggregate public key and block numbers for timing.
    /// @param apkHash First 24 bytes of keccak256(apk_x0, apk_x1, apk_y0, apk_y1) representing the aggregate public key.
    /// @param updateBlockNumber Block number when this update occurred (inclusive).
    /// @param nextUpdateBlockNumber Block number when the next update occurred (exclusive), or 0 if this is the latest update.
    struct ApkUpdate {
        bytes24 apkHash;
        uint32 updateBlockNumber;
        uint32 nextUpdateBlockNumber;
    }

    /// @notice Parameters required when registering a new BLS public key.
    /// @dev Contains the registration signature and both G1/G2 public key components.
    /// @param pubkeyRegistrationSignature Registration message signed by operator's private key to prove ownership.
    /// @param pubkeyG1 The operator's public key in G1 group format.
    /// @param pubkeyG2 The operator's public key in G2 group format, must correspond to the same private key as pubkeyG1.
    struct PubkeyRegistrationParams {
        BN254.G1Point pubkeyRegistrationSignature;
        BN254.G1Point pubkeyG1;
        BN254.G2Point pubkeyG2;
    }
}

interface IBLSApkRegistryEvents is IBLSApkRegistryTypes {
    /*
     * @notice Emitted when `operator` registers their BLS public key pair (`pubkeyG1` and `pubkeyG2`).
     * @param operator The address of the operator registering the keys.
     * @param pubkeyG1 The operator's G1 public key.
     * @param pubkeyG2 The operator's G2 public key.
     */
    event NewPubkeyRegistration(
        address indexed operator, BN254.G1Point pubkeyG1, BN254.G2Point pubkeyG2
    );

    /*
     * @notice Emitted when `operator`'s pubkey is registered for `quorumNumbers`.
     * @param operator The address of the operator being registered.
     * @param operatorId The unique identifier for this operator (pubkey hash).
     * @param quorumNumbers The quorum numbers the operator is being registered for.
     */
    event OperatorAddedToQuorums(address operator, bytes32 operatorId, bytes quorumNumbers);

    /*
     * @notice Emitted when `operator`'s pubkey is deregistered from `quorumNumbers`.
     * @param operator The address of the operator being deregistered.
     * @param operatorId The unique identifier for this operator (pubkey hash).
     * @param quorumNumbers The quorum numbers the operator is being deregistered from.
     */
    event OperatorRemovedFromQuorums(address operator, bytes32 operatorId, bytes quorumNumbers);

    /// @notice Emitted when a G2 public key is registered for an operator
    event NewG2PubkeyRegistration(address indexed operator, BN254.G2Point pubkeyG2);
}

interface IBLSApkRegistry is IBLSApkRegistryErrors, IBLSApkRegistryEvents {
    /* STORAGE */

    /*
     * @notice Returns the address of the registry coordinator contract.
     * @return The address of the registry coordinator.
     * @dev This value is immutable and set during contract construction.
     */
    function registryCoordinator() external view returns (address);

    /*
     * @notice Maps `operator` to their BLS public key hash (`operatorId`).
     * @param operator The address of the operator.
     * @return operatorId The hash of the operator's BLS public key.
     */
    function operatorToPubkeyHash(
        address operator
    ) external view returns (bytes32 operatorId);

    /*
     * @notice Maps `pubkeyHash` to their corresponding `operator` address.
     * @param pubkeyHash The hash of a BLS public key.
     * @return operator The address of the operator who registered this public key.
     */
    function pubkeyHashToOperator(
        bytes32 pubkeyHash
    ) external view returns (address operator);

    /*
     * @notice Maps `operator` to their BLS public key in G1.
     * @dev Returns a non-encoded BN254.G1Point.
     * @param operator The address of the operator.
     * @return The operator's BLS public key in G1.
     */
    function operatorToPubkey(
        address operator
    ) external view returns (uint256, uint256);

    /*
     * @notice Maps `operator` to their BLS public key in G2.
     * @param operator The address of the operator.
     * @return The operator's BLS public key in G2.
     */
    function getOperatorPubkeyG2(
        address operator
    ) external view returns (BN254.G2Point memory);

    /*
     * @notice Stores the history of aggregate public key updates for `quorumNumber` at `index`.
     * @dev Returns a non-encoded IBLSApkRegistryTypes.ApkUpdate.
     * @param quorumNumber The identifier of the quorum.
     * @param index The index in the history array.
     * @return The APK update entry at the specified index for the given quorum.
     * @dev Each entry contains the APK hash, update block number, and next update block number.
     */
    function apkHistory(
        uint8 quorumNumber,
        uint256 index
    ) external view returns (bytes24, uint32, uint32);

    /*
     * @notice Maps `quorumNumber` to their current aggregate public key.
     * @dev Returns a non-encoded BN254.G1Point.
     * @param quorumNumber The identifier of the quorum.
     * @return The current APK as a G1 point.
     */
    function currentApk(
        uint8 quorumNumber
    ) external view returns (uint256, uint256);

    /* ACTIONS */

    /*
     * @notice Registers `operator`'s pubkey for `quorumNumbers`.
     * @param operator The address of the operator to register.
     * @param quorumNumbers The quorum numbers to register for, where each byte is an 8-bit integer.
     * @dev Access restricted to the RegistryCoordinator.
     * @dev Preconditions (assumed, not validated):
     *      1. `quorumNumbers` has no duplicates
     *      2. `quorumNumbers.length` != 0
     *      3. `quorumNumbers` is ordered ascending
     *      4. The operator is not already registered
     */
    function registerOperator(address operator, bytes calldata quorumNumbers) external;

    /*
     * @notice Deregisters `operator`'s pubkey from `quorumNumbers`.
     * @param operator The address of the operator to deregister.
     * @param quorumNumbers The quorum numbers to deregister from, where each byte is an 8-bit integer.
     * @dev Access restricted to the RegistryCoordinator.
     * @dev Preconditions (assumed, not validated):
     *      1. `quorumNumbers` has no duplicates
     *      2. `quorumNumbers.length` != 0
     *      3. `quorumNumbers` is ordered ascending
     *      4. The operator is not already deregistered
     *      5. `quorumNumbers` is a subset of the operator's registered quorums
     */
    function deregisterOperator(address operator, bytes calldata quorumNumbers) external;

    /*
     * @notice Initializes `quorumNumber` by pushing its first APK update.
     * @param quorumNumber The number of the new quorum.
     */
    function initializeQuorum(
        uint8 quorumNumber
    ) external;

    /*
     * @notice Registers `operator` as the owner of a BLS public key using `params` and `pubkeyRegistrationMessageHash`.
     * @param operator The operator for whom the key is being registered.
     * @param params Contains the G1 & G2 public keys and ownership proof signature.
     * @param pubkeyRegistrationMessageHash The hash that must be signed to prove key ownership.
     * @return operatorId The unique identifier (pubkey hash) for this operator.
     * @dev Called by the RegistryCoordinator.
     */
    function registerBLSPublicKey(
        address operator,
        IBLSApkRegistryTypes.PubkeyRegistrationParams calldata params,
        BN254.G1Point calldata pubkeyRegistrationMessageHash
    ) external returns (bytes32 operatorId);

    /* VIEW */

    /*
     * @notice Returns the pubkey and pubkey hash of `operator`.
     * @param operator The address of the operator.
     * @return The operator's G1 public key and its hash.
     * @dev Reverts if the operator has not registered a valid pubkey.
     */
    function getRegisteredPubkey(
        address operator
    ) external view returns (BN254.G1Point memory, bytes32);

    /*
     * @notice Returns the APK indices at `blockNumber` for `quorumNumbers`.
     * @param quorumNumbers The quorum numbers to get indices for.
     * @param blockNumber The block number to query at.
     * @return Array of indices corresponding to each quorum number.
     */
    function getApkIndicesAtBlockNumber(
        bytes calldata quorumNumbers,
        uint256 blockNumber
    ) external view returns (uint32[] memory);

    /*
     * @notice Returns the current aggregate public key for `quorumNumber`.
     * @param quorumNumber The quorum to query.
     * @return The current APK as a G1 point.
     */
    function getApk(
        uint8 quorumNumber
    ) external view returns (BN254.G1Point memory);

    /*
     * @notice Returns an APK update entry for `quorumNumber` at `index`.
     * @param quorumNumber The quorum to query.
     * @param index The index in the APK history.
     * @return The APK update entry.
     */
    function getApkUpdateAtIndex(
        uint8 quorumNumber,
        uint256 index
    ) external view returns (IBLSApkRegistryTypes.ApkUpdate memory);

    /*
     * @notice Gets the 24-byte hash of `quorumNumber`'s APK at `blockNumber` and `index`.
     * @param quorumNumber The quorum to query.
     * @param blockNumber The block number to get the APK hash for.
     * @param index The index in the APK history.
     * @return The 24-byte APK hash.
     * @dev Called by checkSignatures in BLSSignatureChecker.sol.
     */
    function getApkHashAtBlockNumberAndIndex(
        uint8 quorumNumber,
        uint32 blockNumber,
        uint256 index
    ) external view returns (bytes24);

    /*
     * @notice Returns the number of APK updates for `quorumNumber`.
     * @param quorumNumber The quorum to query.
     * @return The length of the APK history.
     */
    function getApkHistoryLength(
        uint8 quorumNumber
    ) external view returns (uint32);

    /*
     * @notice Maps `operator` to their corresponding public key hash.
     * @param operator The address of the operator.
     * @return operatorId The hash of the operator's BLS public key.
     * @dev Returns bytes32(0) if the operator hasn't registered a key.
     */
    function getOperatorId(
        address operator
    ) external view returns (bytes32 operatorId);

    /*
     * @notice Maps `pubkeyHash` to their corresponding operator address.
     * @param pubkeyHash The hash of a BLS public key.
     * @return operator The address of the operator who registered this public key.
     * @dev Returns address(0) if the public key hash hasn't been registered.
     */
    function getOperatorFromPubkeyHash(
        bytes32 pubkeyHash
    ) external view returns (address operator);

    /**
     * @notice Gets an operator's ID if it exists, or registers a new BLS public key and returns the new ID
     * @param operator The address of the operator
     * @param params The parameters for registering a new BLS public key
     * @param pubkeyRegistrationMessageHash The hash of the message to sign for registration
     * @return operatorId The operator's ID (pubkey hash)
     */
    function getOrRegisterOperatorId(
        address operator,
        PubkeyRegistrationParams calldata params,
        BN254.G1Point calldata pubkeyRegistrationMessageHash
    ) external returns (bytes32 operatorId);
}

// lib/eigenlayer-middleware/lib/eigenlayer-contracts/src/contracts/interfaces/ISignatureUtilsMixin.sol

interface ISignatureUtilsMixinErrors {
    /// @notice Thrown when a signature is invalid.
    error InvalidSignature();
    /// @notice Thrown when a signature has expired.
    error SignatureExpired();
}

interface ISignatureUtilsMixinTypes {
    /// @notice Struct that bundles together a signature and an expiration time for the signature.
    /// @dev Used primarily for stack management.
    struct SignatureWithExpiry {
        // the signature itself, formatted as a single bytes object
        bytes signature;
        // the expiration timestamp (UTC) of the signature
        uint256 expiry;
    }

    /// @notice Struct that bundles together a signature, a salt for uniqueness, and an expiration time for the signature.
    /// @dev Used primarily for stack management.
    struct SignatureWithSaltAndExpiry {
        // the signature itself, formatted as a single bytes object
        bytes signature;
        // the salt used to generate the signature
        bytes32 salt;
        // the expiration timestamp (UTC) of the signature
        uint256 expiry;
    }
}

/**
 * @title The interface for common signature utilities.
 * @author Layr Labs, Inc.
 * @notice Terms of Service: https://docs.eigenlayer.xyz/overview/terms-of-service
 */
interface ISignatureUtilsMixin is ISignatureUtilsMixinErrors, ISignatureUtilsMixinTypes, ISemVerMixin {
    /// @notice Computes the EIP-712 domain separator used for signature validation.
    /// @dev The domain separator is computed according to EIP-712 specification, using:
    ///      - The hardcoded name "EigenLayer"
    ///      - The contract's version string
    ///      - The current chain ID
    ///      - This contract's address
    /// @return The 32-byte domain separator hash used in EIP-712 structured data signing.
    /// @dev See https://eips.ethereum.org/EIPS/eip-712#definition-of-domainseparator.
    function domainSeparator() external view returns (bytes32);
}

// src/examples/onchain-fly/FlyEngine.sol

/// @title FlyEngine
/// @notice Stateless, integer-only port of doomfly's LIF simulator over the complete MaleCNS v1.0
///         connectome (166,700 neurons / 25.6 M edges stored as DataContractLib chunks behind a
///         two-level directory). Reached by STATICCALL from `FlyPolicy`; nothing here ever enters a
///         Gas Killer state-update payload.
/// @dev Bit-for-bit twin of tools/fly_int.py (THE reference): Q24 int64 membrane state, Q64 decay
///      tables, round-half-up at every product, kernel.cpp's iteration order (active-list sweep with
///      in-place compaction → ring-FIFO delivery in CSR order → reset), the stateIn/stateOut wire
///      format of HANDOFF §3.4, and the commitment hashes of §3.5. Every arithmetic and ordering
///      decision that the handoff left open is pinned in fly_int.py's docstring (D-A … D-I).
///
///      Memory is laid out by hand (bases computed from N at call entry, free pointer bumped past
///      them) so the 5.4 MB working state IS the returned `stateOut` and never gets abi-copied.
contract FlyEngine {
    // ------------------------------------------------------------------ constants
    string public constant DOMAIN = "gaskiller.fly.engine.v1";
    string public constant OVERLAY_DOMAIN = "gaskiller.fly.overlay.v1";
    string public constant WARM_DOMAIN = "gaskiller.fly.amm.warm.v1";

    uint256 internal constant CHUNK = 24_575; // DataContractLib.MAX_PAYLOAD
    uint256 internal constant TBL_WORDS = 1025; // decay tables: d = 0..1024
    uint256 internal constant TB_OFF = 32_800; // 1025 * 32
    uint256 internal constant TC_OFF = 65_600;
    uint256 internal constant SCR_BYTES = 24_608; // one chunk of edges + slack

    // two's-complement 256-bit literals (inline assembly needs plain literals)
    uint256 internal constant R_Q24_W = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffcc000000; // -52 << 24
    uint256 internal constant THR_Q24_W = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffd3000000; // -45 << 24
    uint256 internal constant R_Q24_FIELD = 0xffffffffcc000000; // low 64 bits of R_Q24
    uint256 internal constant BOUND_Q16 = 0x70000; // 7 << 16
    uint256 internal constant BOUND_Q24 = 0x7000000; // 7 << 24
    uint256 internal constant A1 = 0xfeb923493e945789; // floor(e^(-1/200) * 2^64)
    uint256 internal constant B1 = 0xfaee4cdd6f62db92; // floor(e^(-1/50)  * 2^64)
    uint256 internal constant ONE64 = 0x10000000000000000;
    uint256 internal constant HALF64 = 0x8000000000000000;
    uint256 internal constant HALF56 = 0x80000000000000;
    uint256 internal constant M64 = 0xffffffffffffffff;
    uint256 internal constant MID_AND_LAST = 0xffffffffffffffffffffffffffff0000; // bits 127..16
    uint256 internal constant LOW28 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    uint256 internal constant W_NUM = 23_068_672; // 11 * 2^21

    uint256 internal constant GAIN = 30;
    uint256 internal constant HALF_SAT_Q16 = 1311;
    uint256 internal constant LAMINA_Q16 = 12 << 16;
    uint256 internal constant SUGAR_Q16 = 30 << 16;
    uint256 internal constant PPL101_Q16 = 4 << 16;
    uint256 internal constant CANVAS_W = 640;
    uint256 internal constant CANVAS_H = 480;
    uint256 internal constant STRIP_ROWS = 40;

    // ------------------------------------------------------------------ errors
    error MalformedDirectory();
    error MalformedMeta();
    error ArtifactLengthMismatch();
    error MalformedState();
    error StateHashMismatch();
    error BadDriveIn();
    error BadReadoutId();
    error BadFrame();
    error BadConfig();

    // ------------------------------------------------------------------ structs
    /// @dev Packed config decoded from the three words (see fly_int.pack_cfg)
    struct Config {
        uint256 n;
        uint256 nEdges;
        uint256 ptrChunks;
        uint256 edgeChunks;
        uint256 metaChunks;
        uint256 warmChunks;
        uint256 delay;
        uint256 rfc;
        uint256 epc;
        uint256 episodeSteps;
        uint256 pulseSteps;
        uint256 binSteps;
        uint256 alpha;
        uint256 decay;
        uint256 devRef;
        uint256 volBarRows;
    }

    /// @dev Kernel context: memory bases + scheduler registers. Field order is load-bearing for the
    ///      Yul (offset = 32 * index).
    struct Ctx {
        uint256 n; // 0x000
        uint256 sw; // 0x020 neuron words
        uint256 active; // 0x040 uint32[] packed, capacity 2n+16
        uint256 ring; // 0x060 uint32[] packed FIFO, capacity n+8
        uint256 ptr; // 0x080 uint32[n+1] packed
        uint256 ta; // 0x0a0 tables: tA at ta, tB at ta+TB_OFF, tC at ta+TC_OFF
        uint256 dir; // 0x0c0 chunk addresses, one word each: [ptr][edges][meta][warm]
        uint256 scr; // 0x0e0 edge scratch
        uint256 edgeDir; // 0x100 = dir + 32*ptrChunks
        uint256 delay; // 0x120
        uint256 rfc; // 0x140
        uint256 slots; // 0x160
        uint256 clock; // 0x180
        uint256 nActive; // 0x1a0
        uint256 head; // 0x1c0
        uint256 tail; // 0x1e0
        uint256 inflight; // 0x200
        uint256 hdr; // 0x220 wire header (32 B) + slotCount (96 B); sw = hdr + 128
        uint256 drv; // 0x240 dense int32 drives, packed
        uint256 epc; // 0x260
        uint256 metaDir; // 0x280 = dir + 32*(ptrChunks+edgeChunks)
        uint256 warmDir; // 0x2a0 = metaDir + 32*metaChunks
    }

    /// @dev Parsed meta.bin index tables (offsets into `meta`)
    struct Meta {
        bytes data;
        uint256 nReadouts;
        uint256 offR;
        uint256 nRetina;
        uint256 offRet; // first retina record
        uint256 nLamina;
        uint256 offLam; // first lamina id
        uint256 nSugar;
        uint256 offSug;
        uint256 ppl0;
        uint256 ppl1;
    }

    // ================================================================== config

    /// @notice Decode the three packed config words
    function unpack(bytes32[3] memory cfg) public pure returns (Config memory c) {
        uint256 c0 = uint256(cfg[0]);
        uint256 c1 = uint256(cfg[1]);
        uint256 c2 = uint256(cfg[2]);
        c.n = (c0 >> 224) & 0xffffffff;
        c.nEdges = (c0 >> 192) & 0xffffffff;
        c.ptrChunks = (c0 >> 176) & 0xffff;
        c.edgeChunks = (c0 >> 160) & 0xffff;
        c.metaChunks = (c0 >> 144) & 0xffff;
        c.warmChunks = (c0 >> 128) & 0xffff;
        c.delay = (c0 >> 120) & 0xff;
        c.rfc = (c0 >> 112) & 0xff;
        c.epc = (c0 >> 96) & 0xffff;
        c.episodeSteps = (c1 >> 240) & 0xffff;
        c.pulseSteps = (c1 >> 224) & 0xffff;
        c.binSteps = (c1 >> 216) & 0xff;
        c.alpha = (c1 >> 200) & 0xffff;
        c.decay = (c1 >> 184) & 0xffff;
        c.devRef = (c2 >> 160) & 0xffff;
        c.volBarRows = (c2 >> 136) & 0xffff;
        if (c.n == 0 || c.n >= (1 << 18) || c.epc == 0 || c.delay == 0 || c.rfc <= c.delay || c.rfc > 255) {
            revert BadConfig();
        }
        if (c.ptrChunks != (c.n + 1 + c.epc - 1) / c.epc || c.edgeChunks != (c.nEdges + c.epc - 1) / c.epc) {
            revert BadConfig();
        }
        if (c.metaChunks == 0 || 4 * c.epc + 3 > CHUNK) revert BadConfig();
    }

    /// @notice Derive the overlay address of chunk `i` (graph directory only)
    function overlayChunkAddress(bytes32 manifest, uint256 i) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(OVERLAY_DOMAIN, manifest, uint64(i))))));
    }

    // ================================================================== entry points

    /// @notice Inputs of `step` (one calldata struct keeps the legacy codegen inside the stack limit)
    struct StepInput {
        address graphRoot;
        bytes32 manifest; // overlay manifest when graphRoot == 0
        bytes32[3] cfg;
        bytes stateIn; // wire state (§3.4)
        bytes driveIn; // COMPLETE sorted set of nonzero drives, 8 B each: uint32 id ‖ int32 Q16 mV
        uint32[] readoutIds;
        uint256 nSteps;
        bytes32 expectStateIn; // keccak256(stateIn) or zero to skip the check
    }

    /// @notice General kernel: advance the brain `nSteps` × 0.1 ms from an explicit lazy state.
    /// @dev Does NOT materialize (D-A): step([0,t1)) ∘ step([t1,T)) == step([0,T)) exactly.
    ///      chk = keccak256(abi.encode(keccak256(DOMAIN), keccak256(stateIn), keccak256(driveIn),
    ///            keccak256(abi.encodePacked(readoutIds)), nSteps, keccak256(stateOut), keccak256(abi.encodePacked(readoutCounts))))
    function step(StepInput calldata a)
        external
        view
        returns (bytes memory stateOut, uint32[] memory readoutCounts, bytes32 chk)
    {
        if (a.expectStateIn != bytes32(0) && keccak256(a.stateIn) != a.expectStateIn) revert StateHashMismatch();
        Config memory c = unpack(a.cfg);
        Ctx memory ctx = _layout(c, 0);
        _stepLoad(ctx, c, a);
        _kernel(ctx, 0, 0);
        _kernel(ctx, 1, a.nSteps);
        _stepReturn(ctx, a);
    }

    function _stepLoad(Ctx memory ctx, Config memory c, StepInput calldata a) internal view {
        _resolve(a.graphRoot, a.manifest, c.ptrChunks + c.edgeChunks + c.metaChunks, ctx.dir);
        _loadPtr(ctx, c);
        _kernel(ctx, 3, 0);
        bytes calldata stateIn = a.stateIn;
        if (stateIn.length < 128) revert MalformedState();
        uint256 hdr = ctx.hdr;
        assembly ("memory-safe") {
            calldatacopy(hdr, stateIn.offset, stateIn.length)
        }
        _adoptWire(ctx, stateIn.length);
        _zeroCounts(ctx);
        _parseDriveIn(ctx, a.driveIn);
    }

    /// @dev Hand-built ABI return of (bytes stateOut, uint32[] readoutCounts, bytes32 chk): the wire is returned in place
    function _stepReturn(Ctx memory ctx, StepInput calldata a) internal pure {
        uint256 len = _finalizeWire(ctx);
        uint256 hdr = ctx.hdr;
        uint256 cntBase = hdr + ((len + 31) & ~uint256(31)) + 32;
        uint256 nRo = a.readoutIds.length;
        _writeCounts(ctx, a.readoutIds, cntBase);
        bytes32 chk = _chk(a, hdr, len, cntBase, nRo);
        assembly ("memory-safe") {
            mstore(add(hdr, len), 0) // zero the ABI padding after the state bytes (strict decoders check it)
            let base := sub(hdr, 128)
            mstore(base, 0x60)
            mstore(add(base, 32), sub(sub(cntBase, 32), base))
            mstore(add(base, 64), chk)
            mstore(add(base, 96), len)
            mstore(sub(cntBase, 32), nRo)
            return(base, sub(add(cntBase, shl(5, nRo)), base))
        }
    }

    function _writeCounts(Ctx memory ctx, uint32[] calldata readoutIds, uint256 cntBase) internal pure {
        uint256 n = ctx.n;
        uint256 sw = ctx.sw;
        for (uint256 k = 0; k < readoutIds.length; ++k) {
            uint256 id = readoutIds[k];
            if (id >= n) revert BadReadoutId();
            assembly ("memory-safe") {
                mstore(add(cntBase, shl(5, k)), and(shr(64, mload(add(sw, shl(5, id)))), 0xffffffff))
            }
        }
    }

    function _chk(StepInput calldata a, uint256 hdr, uint256 len, uint256 cntBase, uint256 nRo)
        internal
        pure
        returns (bytes32)
    {
        bytes32 stateHash;
        bytes32 countsHash;
        assembly ("memory-safe") {
            stateHash := keccak256(hdr, len)
            countsHash := keccak256(cntBase, shl(5, nRo))
        }
        return keccak256(
            abi.encode(
                keccak256(bytes(DOMAIN)),
                keccak256(a.stateIn),
                keccak256(a.driveIn),
                keccak256(abi.encodePacked(a.readoutIds)),
                a.nSteps,
                stateHash,
                countsHash
            )
        );
    }

    /// @dev Decoder registers carried across bins
    struct Decoder {
        uint256[4] rates;
        uint256[4] prev;
        uint256[3][4] hist; // last three bins per BCI readout (ring by bin index)
        uint256 nBins;
    }

    /// @notice AMM entry: one episode from the warm snapshot with a static frame (HANDOFF §3.5)
    function decide(
        address graphRoot,
        address warmRoot,
        bytes32[3] calldata cfg,
        bytes calldata frame,
        FlyTypes.Stimulus calldata stim,
        uint32[4] calldata rates0
    ) external view returns (FlyTypes.Readout memory r, bytes32 spikeRoot) {
        Config memory c = unpack(cfg);
        if (c.binSteps == 0 || c.episodeSteps % c.binSteps != 0 || c.warmChunks == 0) revert BadConfig();
        Ctx memory ctx = _layout(c, c.warmChunks);
        Meta memory m = _prepare(ctx, c, graphRoot, warmRoot);
        if (frame.length != 2 * m.nRetina || m.nReadouts > 14) revert BadFrame();
        Decoder memory dec;
        for (uint256 j = 0; j < 4; ++j) {
            dec.rates[j] = rates0[j];
        }
        _episode(ctx, c, m, frame, stim, dec);
        _kernel(ctx, 2, 0); // materialize
        _readout(ctx, m, dec, r);
        bytes32 stateHash = _stateHash(ctx);
        spikeRoot = keccak256(abi.encode(keccak256(bytes(DOMAIN)), keccak256(frame), stim, rates0, stateHash, r));
    }

    /// @dev Resolve both directories, load ptr/tables/meta/warm state, zero counts
    function _prepare(Ctx memory ctx, Config memory c, address graphRoot, address warmRoot)
        internal
        view
        returns (Meta memory m)
    {
        _resolve(graphRoot, bytes32(0), c.ptrChunks + c.edgeChunks + c.metaChunks, ctx.dir);
        _resolve(warmRoot, bytes32(0), c.warmChunks, ctx.warmDir);
        _loadPtr(ctx, c);
        _kernel(ctx, 3, 0);
        m = _loadMeta(ctx, c);
        _loadWarm(ctx, c);
        _zeroCounts(ctx);
    }

    /// @dev The per-bin loop: drives → pre-pass → binSteps → decoder EMA (no materialize between bins, D-B)
    function _episode(
        Ctx memory ctx,
        Config memory c,
        Meta memory m,
        bytes calldata frame,
        FlyTypes.Stimulus calldata stim,
        Decoder memory dec
    ) internal view {
        uint256[] memory lf = new uint256[](m.nRetina);
        uint256 nBins = c.episodeSteps / c.binSteps;
        dec.nBins = nBins;
        for (uint256 b = 0; b < nBins; ++b) {
            uint256 t0 = b * c.binSteps;
            _buildDrives(ctx, c, m, frame, lf, t0 < stim.rewardSteps, t0 < stim.punishSteps);
            _kernel(ctx, 0, 0);
            _kernel(ctx, 1, c.binSteps);
            _decodeBin(ctx, c, m, dec, b);
        }
    }

    function _decodeBin(Ctx memory ctx, Config memory c, Meta memory m, Decoder memory dec, uint256 b) internal pure {
        for (uint256 j = 0; j < 4; ++j) {
            uint256 cnt = _countOf(ctx, _readoutIdx(m, j));
            uint256 c4 = cnt - dec.prev[j];
            dec.prev[j] = cnt;
            dec.hist[j][b % 3] = c4;
            uint256 raw = (c4 * 10_000_000) / c.binSteps;
            dec.rates[j] = (dec.rates[j] * c.decay + raw * (65536 - c.decay)) >> 16;
        }
    }

    function _readout(Ctx memory ctx, Meta memory m, Decoder memory dec, FlyTypes.Readout memory r) internal pure {
        for (uint256 j = 0; j < 4; ++j) {
            r.rateMilliHz[j] = uint32(dec.rates[j]);
            uint256 last3 = 0;
            uint256 lim = dec.nBins < 3 ? dec.nBins : 3;
            for (uint256 k = 0; k < lim; ++k) {
                last3 += dec.hist[j][k];
            }
            r.spikesLast30ms[j] = uint32(last3);
        }
        for (uint256 j = 0; j < m.nReadouts; ++j) {
            r.windowCounts[j] = uint32(_countOf(ctx, _readoutIdx(m, j)));
        }
        r.totalSpikes = uint64(_totalSpikes(ctx));
    }

    function _stateHash(Ctx memory ctx) internal pure returns (bytes32 h) {
        uint256 len = _finalizeWire(ctx);
        uint256 hdr = ctx.hdr;
        assembly ("memory-safe") {
            h := keccak256(hdr, len)
        }
    }

    /// @notice Render the pool observation onto the retina (HANDOFF §4.2): 2 B Q16 luminance per receptor
    function rasterize(address graphRoot, bytes32[3] calldata cfg, FlyTypes.Observation calldata o)
        external
        view
        returns (bytes memory frame)
    {
        Config memory c = unpack(cfg);
        Ctx memory ctx = _layoutDir(c, 0);
        _resolve(graphRoot, bytes32(0), c.ptrChunks + c.edgeChunks + c.metaChunks, ctx.dir);
        Meta memory m = _loadMeta(ctx, c);
        frame = new bytes(2 * m.nRetina);
        for (uint256 k = 0; k < m.nRetina; ++k) {
            (, uint256 u, uint256 v) = _retina(m, k);
            uint256 lum = _sample(o, c, u, v);
            frame[2 * k] = bytes1(uint8(lum >> 8));
            frame[2 * k + 1] = bytes1(uint8(lum));
        }
    }

    /// @notice `steps` black steps from genesis (lamina tonic only), materialized: the warm snapshot
    function warmup(address graphRoot, bytes32[3] calldata cfg, uint256 steps)
        external
        view
        returns (bytes memory stateOut, bytes32 warmCommitment)
    {
        Config memory c = unpack(cfg);
        Ctx memory ctx = _layout(c, 0);
        _resolve(graphRoot, bytes32(0), c.ptrChunks + c.edgeChunks + c.metaChunks, ctx.dir);
        _loadPtr(ctx, c);
        _kernel(ctx, 3, 0);
        Meta memory m = _loadMeta(ctx, c);
        _genesisInto(ctx);
        uint256[] memory lf = new uint256[](m.nRetina);
        _buildDrives(ctx, c, m, msg.data[0:0], lf, false, false);
        _kernel(ctx, 0, 0);
        _kernel(ctx, 1, steps);
        _kernel(ctx, 2, 0);
        uint256 len = _finalizeWire(ctx);
        uint256 hdr = ctx.hdr;
        bytes32 h;
        assembly ("memory-safe") {
            h := keccak256(hdr, len)
        }
        warmCommitment = keccak256(abi.encodePacked(WARM_DOMAIN, h));
        assembly ("memory-safe") {
            mstore(add(hdr, len), 0) // zero the ABI padding after the state bytes
            let base := sub(hdr, 96)
            mstore(base, 0x40)
            mstore(add(base, 32), warmCommitment)
            mstore(add(base, 64), len)
            return(base, add(96, and(add(len, 31), not(31))))
        }
    }

    /// @notice The genesis wire state: clock 1, every neuron at rest, nothing scheduled
    function genesisState(bytes32[3] calldata cfg) external pure returns (bytes memory) {
        Config memory c = unpack(cfg);
        uint256 n = c.n;
        bytes memory out = new bytes(128 + 32 * n);
        assembly ("memory-safe") {
            let hdr := add(out, 32)
            mstore(hdr, 0)
            mstore8(hdr, 1)
            mstore(add(hdr, 1), shl(224, n))
            mstore(add(hdr, 5), shl(208, 1)) // clock = 1 (u48)
            let sw := add(hdr, 128)
            let w := shl(192, R_Q24_FIELD)
            for { let p := sw } lt(p, add(sw, shl(5, n))) { p := add(p, 32) } { mstore(p, w) }
        }
        return out;
    }

    /// @notice Validate directory shape, blob lengths, meta header and warm-snapshot length (~4,415 cold chunk reads on the real graph)
    function checkArtifacts(address graphRoot, address warmRoot, bytes32[3] calldata cfg) external view {
        Config memory c = unpack(cfg);
        Ctx memory ctx = _layoutDir(c, c.warmChunks);
        _resolve(graphRoot, bytes32(0), c.ptrChunks + c.edgeChunks + c.metaChunks, ctx.dir);
        if (_sumLengths(ctx.dir, c.ptrChunks) != 4 * (c.n + 1) + 3 * c.ptrChunks) revert ArtifactLengthMismatch();
        if (_sumLengths(ctx.edgeDir, c.edgeChunks) != 4 * c.nEdges + 3 * c.edgeChunks) revert ArtifactLengthMismatch();
        Meta memory m = _loadMeta(ctx, c);
        if (m.nReadouts > 14 || m.nRetina == 0) revert MalformedMeta();
        if (c.warmChunks != 0) {
            _resolve(warmRoot, bytes32(0), c.warmChunks, ctx.warmDir);
            uint256 total = _sumLengths(ctx.warmDir, c.warmChunks);
            // header of the first warm chunk: version, n, clock, nActive, inflight
            address first;
            uint256 warmDir = ctx.warmDir;
            assembly ("memory-safe") {
                first := mload(warmDir)
            }
            bytes memory head = new bytes(32);
            assembly ("memory-safe") {
                extcodecopy(first, add(head, 32), 1, 32)
            }
            uint256 nActive = _be32(head, 11);
            uint256 inflight = _be32(head, 15);
            if (uint8(head[0]) != 1 || _be32(head, 1) != c.n || total != 128 + 32 * c.n + 4 * (nActive + inflight)) {
                revert ArtifactLengthMismatch();
            }
        }
    }

    // ================================================================== memory layout

    function _layout(Config memory c, uint256 warmChunks) internal pure returns (Ctx memory ctx) {
        uint256 n = c.n;
        uint256 base;
        assembly ("memory-safe") {
            base := and(add(mload(0x40), 31), not(31))
        }
        ctx.n = n;
        ctx.hdr = base + 128; // 4 words of ABI head reserve before the wire
        ctx.sw = ctx.hdr + 128;
        ctx.active = ctx.sw + 32 * n;
        ctx.ring = ctx.active + _pad(8 * n + 64);
        ctx.ptr = ctx.ring + _pad(4 * n + 32);
        ctx.ta = ctx.ptr + _pad(4 * (n + 1) + 32);
        ctx.dir = ctx.ta + 3 * TBL_WORDS * 32;
        uint256 nChunks = c.ptrChunks + c.edgeChunks + c.metaChunks + warmChunks;
        ctx.scr = ctx.dir + 32 * nChunks;
        ctx.drv = ctx.scr + SCR_BYTES;
        uint256 end = ctx.drv + _pad(4 * n + 32);
        ctx.edgeDir = ctx.dir + 32 * c.ptrChunks;
        ctx.metaDir = ctx.edgeDir + 32 * c.edgeChunks;
        ctx.warmDir = ctx.metaDir + 32 * c.metaChunks;
        ctx.delay = c.delay;
        ctx.rfc = c.rfc;
        ctx.slots = c.delay + 1;
        ctx.epc = c.epc;
        ctx.clock = 1;
        assembly ("memory-safe") {
            mstore(0x40, end)
        }
    }

    /// @dev Directory-only layout for the cheap entry points (checkArtifacts, rasterize): no state memory
    function _layoutDir(Config memory c, uint256 warmChunks) internal pure returns (Ctx memory ctx) {
        uint256 base;
        assembly ("memory-safe") {
            base := and(add(mload(0x40), 31), not(31))
        }
        ctx.n = c.n;
        ctx.dir = base;
        uint256 nChunks = c.ptrChunks + c.edgeChunks + c.metaChunks + warmChunks;
        ctx.edgeDir = ctx.dir + 32 * c.ptrChunks;
        ctx.metaDir = ctx.edgeDir + 32 * c.edgeChunks;
        ctx.warmDir = ctx.metaDir + 32 * c.metaChunks;
        uint256 end = ctx.dir + 32 * nChunks;
        assembly ("memory-safe") {
            mstore(0x40, end)
        }
    }

    function _pad(uint256 x) internal pure returns (uint256) {
        return (x + 31) & ~uint256(31);
    }

    // ================================================================== directory + blobs

    /// @dev Walk root → pages → chunks, writing one address word per chunk at `dirBase`
    function _resolve(address root, bytes32 manifest, uint256 expected, uint256 dirBase) internal view {
        if (root == address(0)) {
            if (manifest == bytes32(0)) revert MalformedDirectory();
            for (uint256 i = 0; i < expected; ++i) {
                address a = overlayChunkAddress(manifest, i);
                assembly ("memory-safe") {
                    mstore(add(dirBase, shl(5, i)), a)
                }
            }
            return;
        }
        bytes memory rootBytes = DataContractLib.read(root);
        if (rootBytes.length == 0 || rootBytes.length % 20 != 0) revert MalformedDirectory();
        uint256 seen = 0;
        uint256 nPages = rootBytes.length / 20;
        for (uint256 p = 0; p < nPages; ++p) {
            bytes memory page = DataContractLib.read(_addrAt(rootBytes, p * 20));
            if (page.length % 20 != 0) revert MalformedDirectory();
            uint256 cnt = page.length / 20;
            for (uint256 i = 0; i < cnt; ++i) {
                if (seen >= expected) revert MalformedDirectory();
                address a = _addrAt(page, i * 20);
                assembly ("memory-safe") {
                    mstore(add(dirBase, shl(5, seen)), a)
                }
                ++seen;
            }
        }
        if (seen != expected) revert MalformedDirectory();
    }

    function _addrAt(bytes memory b, uint256 off) internal pure returns (address a) {
        assembly ("memory-safe") {
            a := shr(96, mload(add(add(b, 32), off)))
        }
    }

    function _sumLengths(uint256 dirBase, uint256 count) internal view returns (uint256 total) {
        for (uint256 i = 0; i < count; ++i) {
            address a;
            assembly ("memory-safe") {
                a := mload(add(dirBase, shl(5, i)))
            }
            total += DataContractLib.payloadLength(a);
        }
    }

    /// @dev Concatenate the payloads of `count` chunks starting at `dirBase`
    function _readAll(uint256 dirBase, uint256 count) internal view returns (bytes memory out) {
        uint256 total = _sumLengths(dirBase, count);
        out = new bytes(total);
        uint256 at = 0;
        for (uint256 i = 0; i < count; ++i) {
            address a;
            assembly ("memory-safe") {
                a := mload(add(dirBase, shl(5, i)))
            }
            at += DataContractLib.readInto(a, out, at);
        }
    }

    /// @dev Copy the ptr blob (6,143 entries + 3 pad bytes per chunk) into the packed PTR region
    function _loadPtr(Ctx memory ctx, Config memory c) internal view {
        uint256 entries = c.n + 1;
        uint256 epc = c.epc;
        uint256 dir = ctx.dir;
        uint256 dst = ctx.ptr;
        for (uint256 ci = 0; ci < c.ptrChunks; ++ci) {
            uint256 take = entries - ci * epc;
            if (take > epc) take = epc;
            assembly ("memory-safe") {
                let a := mload(add(dir, shl(5, ci)))
                if lt(extcodesize(a), add(1, shl(2, take))) {
                    mstore(0, 0x1a2f92f6) // ArtifactLengthMismatch()
                    revert(28, 4)
                }
                extcodecopy(a, add(dst, mul(ci, shl(2, epc))), 1, shl(2, take))
            }
        }
    }

    function _loadMeta(Ctx memory ctx, Config memory c) internal view returns (Meta memory m) {
        m.data = _readAll(ctx.metaDir, c.metaChunks);
        bytes memory d = m.data;
        if (d.length < 101 || uint8(d[0]) != 1) revert MalformedMeta();
        if (_be32(d, 1) != c.n || _be32(d, 5) != c.nEdges || _be16(d, 9) != c.epc) revert MalformedMeta();
        if (_be16(d, 11) != c.delay || _be16(d, 13) != c.rfc) revert MalformedMeta();
        m.nReadouts = _be16(d, 15);
        m.offR = _be32(d, 17);
        uint256 offRet = _be32(d, 21);
        uint256 offLam = _be32(d, 25);
        uint256 offSug = _be32(d, 29);
        uint256 offPPL = _be32(d, 33);
        m.nRetina = _be32(d, offRet);
        m.offRet = offRet + 4;
        m.nLamina = _be32(d, offLam);
        m.offLam = offLam + 4;
        m.nSugar = _be32(d, offSug);
        m.offSug = offSug + 4;
        m.ppl0 = _be32(d, offPPL);
        m.ppl1 = _be32(d, offPPL + 4);
        if (
            m.offR + 6 * m.nReadouts > d.length || m.offRet + 8 * m.nRetina > d.length
                || m.offLam + 4 * m.nLamina > d.length || m.offSug + 4 * m.nSugar > d.length || offPPL + 8 > d.length
                || m.ppl0 >= c.n || m.ppl1 >= c.n
        ) revert MalformedMeta();
    }

    function _loadWarm(Ctx memory ctx, Config memory c) internal view {
        uint256 total = _sumLengths(ctx.warmDir, c.warmChunks);
        if (total < 128) revert MalformedState();
        uint256 warmDir = ctx.warmDir;
        uint256 dst = ctx.hdr;
        for (uint256 i = 0; i < c.warmChunks; ++i) {
            address a;
            assembly ("memory-safe") {
                a := mload(add(warmDir, shl(5, i)))
            }
            uint256 len = DataContractLib.payloadLength(a);
            assembly ("memory-safe") {
                extcodecopy(a, dst, 1, len)
            }
            dst += len;
        }
        _adoptWire(ctx, total);
    }

    // ================================================================== wire format

    /// @dev The wire bytes are in place at ctx.hdr. Validate (D-D), move the ring into RING, set registers.
    function _adoptWire(Ctx memory ctx, uint256 len) internal pure {
        uint256 hdr = ctx.hdr;
        uint256 n = ctx.n;
        uint256 slots = ctx.slots;
        uint256 rfc = ctx.rfc;
        uint256 clock;
        uint256 nActive;
        uint256 inflight;
        bool bad;
        assembly ("memory-safe") {
            let h := mload(hdr)
            // version u8 | n u32 | clock u48 | nActive u32 | inflight u32 | ringHead u32 | 9 zero bytes
            bad := iszero(eq(shr(248, h), 1))
            bad := or(bad, iszero(eq(and(shr(216, h), 0xffffffff), n)))
            clock := and(shr(168, h), 0xffffffffffff)
            nActive := and(shr(136, h), 0xffffffff)
            inflight := and(shr(104, h), 0xffffffff)
            bad := or(bad, and(h, 0xffffffffffffffffffffffffff)) // ringHead + padding must be zero
            bad := or(bad, iszero(clock))
            bad := or(bad, or(gt(nActive, n), gt(inflight, n)))
            // slot counts: sum == inflight, padding zero
            let sum := 0
            for { let s := 0 } lt(s, slots) { s := add(s, 1) } {
                sum := add(sum, shr(224, mload(add(add(hdr, 32), shl(2, s)))))
            }
            bad := or(bad, iszero(eq(sum, inflight)))
            for { let p := add(add(hdr, 32), shl(2, slots)) } lt(p, add(hdr, 128)) { p := add(p, 32) } {
                let rem := sub(add(hdr, 128), p)
                let v := mload(p)
                if lt(rem, 32) { v := shr(mul(8, sub(32, rem)), v) }
                bad := or(bad, iszero(iszero(v)))
            }
        }
        if (bad || len != 128 + 32 * n + 4 * (nActive + inflight)) revert MalformedState();
        uint256 sw = ctx.sw;
        uint256 act = ctx.active;
        uint256 ring = ctx.ring;
        assembly ("memory-safe") {
            // 1. every listed active id: in range, flag set → clear it (catches duplicates)
            for { let k := 0 } lt(k, nActive) { k := add(k, 1) } {
                let i := shr(224, mload(add(act, shl(2, k))))
                bad := or(bad, iszero(lt(i, n)))
                let wp := add(sw, shl(5, i))
                let w := mload(wp)
                bad := or(bad, iszero(and(w, 1)))
                mstore(wp, and(w, not(1)))
            }
            // 2. full scan: last <= clock-1, refr <= rfc, no stray flag
            let prev := sub(clock, 1)
            for { let wp := sw } lt(wp, add(sw, shl(5, n))) { wp := add(wp, 32) } {
                let w := mload(wp)
                bad := or(bad, gt(and(shr(16, w), 0xffffffffffff), prev))
                bad := or(bad, gt(and(shr(8, w), 0xff), rfc))
                bad := or(bad, and(w, 1))
            }
            // 3. re-set the flags of the listed ids
            for { let k := 0 } lt(k, nActive) { k := add(k, 1) } {
                let i := shr(224, mload(add(act, shl(2, k))))
                if lt(i, n) {
                    let wp := add(sw, shl(5, i))
                    mstore(wp, or(mload(wp), 1))
                }
            }
            // 4. ring ids: move from act + 4*nActive to RING (forward copy, regions disjoint)
            let src := add(act, shl(2, nActive))
            for { let off := 0 } lt(off, shl(2, inflight)) { off := add(off, 32) } {
                mstore(add(ring, off), mload(add(src, off)))
            }
            for { let k := 0 } lt(k, inflight) { k := add(k, 1) } {
                bad := or(bad, iszero(lt(shr(224, mload(add(ring, shl(2, k)))), n)))
            }
        }
        if (bad) revert MalformedState();
        ctx.clock = clock;
        ctx.nActive = nActive;
        ctx.head = 0;
        ctx.tail = inflight % n;
        ctx.inflight = inflight;
    }

    /// @dev Write header registers, linearize the ring after the active list; return the wire length
    function _finalizeWire(Ctx memory ctx) internal pure returns (uint256 len) {
        uint256 hdr = ctx.hdr;
        uint256 n = ctx.n;
        uint256 nActive = ctx.nActive;
        uint256 inflight = ctx.inflight;
        uint256 head = ctx.head;
        uint256 clock = ctx.clock;
        uint256 act = ctx.active;
        uint256 ring = ctx.ring;
        assembly ("memory-safe") {
            let h := or(shl(248, 1), shl(216, n))
            h := or(h, or(shl(168, clock), or(shl(136, nActive), shl(104, inflight))))
            mstore(hdr, h)
            let dst := add(act, shl(2, nActive))
            let first := sub(n, head)
            if gt(first, inflight) { first := inflight }
            let src := add(ring, shl(2, head))
            for { let off := 0 } lt(off, shl(2, first)) { off := add(off, 32) } {
                mstore(add(dst, off), mload(add(src, off)))
            }
            let rest := sub(inflight, first)
            dst := add(dst, shl(2, first))
            for { let off := 0 } lt(off, shl(2, rest)) { off := add(off, 32) } {
                mstore(add(dst, off), mload(add(ring, off)))
            }
        }
        len = 128 + 32 * n + 4 * (nActive + inflight);
    }

    function _genesisInto(Ctx memory ctx) internal pure {
        uint256 hdr = ctx.hdr;
        uint256 n = ctx.n;
        assembly ("memory-safe") {
            mstore(hdr, or(shl(248, 1), or(shl(216, n), shl(168, 1))))
            mstore(add(hdr, 32), 0)
            mstore(add(hdr, 64), 0)
            mstore(add(hdr, 96), 0)
            let sw := add(hdr, 128)
            let w := shl(192, R_Q24_FIELD)
            for { let p := sw } lt(p, add(sw, shl(5, n))) { p := add(p, 32) } { mstore(p, w) }
        }
        ctx.clock = 1;
        ctx.nActive = 0;
        ctx.head = 0;
        ctx.tail = 0;
        ctx.inflight = 0;
    }

    function _zeroCounts(Ctx memory ctx) internal pure {
        uint256 sw = ctx.sw;
        uint256 n = ctx.n;
        assembly ("memory-safe") {
            let mask := not(shl(64, 0xffffffff))
            for { let p := sw } lt(p, add(sw, shl(5, n))) { p := add(p, 32) } { mstore(p, and(mload(p), mask)) }
        }
    }

    // ================================================================== drives

    function _parseDriveIn(Ctx memory ctx, bytes calldata driveIn) internal pure {
        if (driveIn.length % 8 != 0) revert BadDriveIn();
        uint256 n = ctx.n;
        uint256 drv = ctx.drv;
        _zeroDrives(ctx);
        bool bad;
        assembly ("memory-safe") {
            let prev := not(0)
            for { let off := 0 } lt(off, driveIn.length) { off := add(off, 8) } {
                let rec := calldataload(add(driveIn.offset, off))
                let id := shr(224, rec)
                let val := and(shr(192, rec), 0xffffffff)
                bad := or(bad, or(iszero(lt(id, n)), iszero(val)))
                bad := or(bad, and(iszero(eq(prev, not(0))), iszero(gt(id, prev))))
                prev := id
                let p := add(drv, shl(2, id))
                mstore(p, or(shl(224, val), and(mload(p), LOW28)))
            }
        }
        if (bad) revert BadDriveIn();
    }

    function _zeroDrives(Ctx memory ctx) internal pure {
        uint256 drv = ctx.drv;
        uint256 n = ctx.n;
        assembly ("memory-safe") {
            for { let p := drv } lt(p, add(drv, add(shl(2, n), 32))) { p := add(p, 32) } { mstore(p, 0) }
        }
    }

    /// @dev Rebuild the dense drive array for one bin exactly as fly_int.decide does:
    ///      zero → lamina 12 mV → retina (30·Lf<<16)/(1311+Lf) → sugar 30 mV (reward) → PPL101 += 4 mV (punish).
    ///      `lf` is updated in place (Lf += (alpha·(L−Lf)) >> 16, arithmetic shift). Empty frame = black.
    function _buildDrives(
        Ctx memory ctx,
        Config memory c,
        Meta memory m,
        bytes calldata frame,
        uint256[] memory lf,
        bool reward,
        bool punish
    ) internal pure {
        _zeroDrives(ctx);
        uint256 drv = ctx.drv;
        bytes memory d = m.data;
        for (uint256 k = 0; k < m.nLamina; ++k) {
            uint256 idx = _be32(d, m.offLam + 4 * k);
            _setDrive(drv, idx, LAMINA_Q16);
        }
        for (uint256 k = 0; k < m.nRetina; ++k) {
            (uint256 idx,,) = _retina(m, k);
            if (frame.length != 0) {
                int256 L = int256(uint256(uint8(frame[2 * k])) << 8 | uint256(uint8(frame[2 * k + 1])));
                int256 cur = int256(lf[k]);
                cur += (int256(c.alpha) * (L - cur)) >> 16;
                lf[k] = uint256(cur);
            }
            uint256 L2 = lf[k];
            _setDrive(drv, idx, ((GAIN * L2) << 16) / (HALF_SAT_Q16 + L2));
        }
        if (reward) {
            for (uint256 k = 0; k < m.nSugar; ++k) {
                _setDrive(drv, _be32(d, m.offSug + 4 * k), SUGAR_Q16);
            }
        }
        if (punish) {
            _addDrive(drv, m.ppl0, PPL101_Q16);
            _addDrive(drv, m.ppl1, PPL101_Q16);
        }
    }

    function _setDrive(uint256 drv, uint256 idx, uint256 val) internal pure {
        assembly ("memory-safe") {
            let p := add(drv, shl(2, idx))
            mstore(p, or(shl(224, and(val, 0xffffffff)), and(mload(p), LOW28)))
        }
    }

    function _addDrive(uint256 drv, uint256 idx, uint256 val) internal pure {
        assembly ("memory-safe") {
            let p := add(drv, shl(2, idx))
            let cur := signextend(3, shr(224, mload(p)))
            mstore(p, or(shl(224, and(add(cur, val), 0xffffffff)), and(mload(p), LOW28)))
        }
    }

    // ================================================================== meta accessors

    function _retina(Meta memory m, uint256 k) internal pure returns (uint256 idx, uint256 u, uint256 v) {
        bytes memory d = m.data;
        uint256 off = m.offRet + 8 * k;
        idx = _be32(d, off);
        u = _be16(d, off + 4);
        v = _be16(d, off + 6);
    }

    function _readoutIdx(Meta memory m, uint256 j) internal pure returns (uint256) {
        if (j >= m.nReadouts) revert BadReadoutId();
        return _be32(m.data, m.offR + 6 * j);
    }

    function _be32(bytes memory d, uint256 off) internal pure returns (uint256 x) {
        assembly ("memory-safe") {
            x := shr(224, mload(add(add(d, 32), off)))
        }
    }

    function _be16(bytes memory d, uint256 off) internal pure returns (uint256 x) {
        assembly ("memory-safe") {
            x := shr(240, mload(add(add(d, 32), off)))
        }
    }

    function _countOf(Ctx memory ctx, uint256 idx) internal pure returns (uint256 cnt) {
        if (idx >= ctx.n) revert BadReadoutId();
        uint256 sw = ctx.sw;
        assembly ("memory-safe") {
            cnt := and(shr(64, mload(add(sw, shl(5, idx)))), 0xffffffff)
        }
    }

    function _totalSpikes(Ctx memory ctx) internal pure returns (uint256 total) {
        uint256 sw = ctx.sw;
        uint256 n = ctx.n;
        assembly ("memory-safe") {
            for { let p := sw } lt(p, add(sw, shl(5, n))) { p := add(p, 32) } {
                total := add(total, and(shr(64, mload(p)), 0xffffffff))
            }
        }
    }

    // ================================================================== rasterizer (§4.2)

    /// @dev Procedural 640×480 canvas value at (y, x): deviation strip over rows [0,40), histogram bars below
    function _canvas(FlyTypes.Observation calldata o, Config memory c, uint256 y, uint256 x)
        internal
        pure
        returns (uint256)
    {
        uint256 spot = o.spotQ64;
        uint256 twap = o.twapQ64;
        if (y < STRIP_ROWS) {
            if (spot == twap || twap == 0) return 0;
            uint256 absDev = ((spot > twap ? spot - twap : twap - spot) * 10000) / twap;
            uint256 lit = absDev * 65535 / c.devRef;
            if (lit > 65535) lit = 65535;
            return ((x < 320) == (spot > twap)) ? lit : 0;
        }
        uint256 vol = x < 320 ? o.buyQuote[x / 20] : o.sellQuote[(x - 320) / 20];
        uint256 volRef = o.volRef;
        uint256 h = volRef == 0 ? 0 : (c.volBarRows * (vol < volRef ? vol : volRef)) / volRef;
        return y >= CANVAS_H - h ? 65535 : 0;
    }

    /// @dev Bilinear sample at receptor (uQ16, vQ16), exactly game.py retinal_samples in integers
    function _sample(FlyTypes.Observation calldata o, Config memory c, uint256 u, uint256 v)
        internal
        pure
        returns (uint256)
    {
        uint256 xq = u * (CANVAS_W - 1);
        uint256 yq = v * (CANVAS_H - 1);
        uint256 x0 = xq >> 16;
        uint256 y0 = yq >> 16;
        uint256 x1 = x0 + 1 < CANVAS_W - 1 ? x0 + 1 : CANVAS_W - 1;
        uint256 y1 = y0 + 1 < CANVAS_H - 1 ? y0 + 1 : CANVAS_H - 1;
        uint256 dx = xq & 0xffff;
        uint256 dy = yq & 0xffff;
        uint256 acc = (65536 - dx) * (65536 - dy) * _canvas(o, c, y0, x0);
        acc += dx * (65536 - dy) * _canvas(o, c, y0, x1);
        acc += (65536 - dx) * dy * _canvas(o, c, y1, x0);
        acc += dx * dy * _canvas(o, c, y1, x1);
        return acc >> 32;
    }

    // ================================================================== the kernel (Yul)

    /// @dev op 0 = pre-pass (install ctx.drv), 1 = run(arg steps), 2 = materialize, 3 = build tables.
    ///      One assembly block so the Yul helpers are defined once. Helpers re-load bases from the
    ///      context word instead of caching them: the legacy codegen has 16 reachable stack slots.
    function _kernel(Ctx memory ctxm, uint256 op, uint256 arg) internal view {
        assembly ("memory-safe") {
            function u32get(p) -> x {
                x := shr(224, mload(p))
            }
            function u32set(p, x) {
                mstore(p, or(shl(224, x), and(mload(p), LOW28)))
            }
            // x^q in Q64, right-to-left square-and-multiply from 2^64, rhu64 at every product (D-E)
            function powq(x, q) -> r {
                r := ONE64
                for {} q {} {
                    if and(q, 1) { r := shr(64, add(mul(r, x), HALF64)) }
                    x := shr(64, add(mul(x, x), HALF64))
                    q := shr(1, q)
                }
            }
            function farDecay(d, ta) -> a, b, c {
                if lt(d, 8873) {
                    let q := shr(10, d)
                    let r := and(d, 1023)
                    a := powq(mload(add(ta, 32768)), q)
                    if r { a := shr(64, add(mul(a, mload(add(ta, shl(5, r)))), HALF64)) }
                    if lt(d, 2219) {
                        b := powq(mload(add(ta, add(TB_OFF, 32768))), q)
                        if r { b := shr(64, add(mul(b, mload(add(add(ta, TB_OFF), shl(5, r)))), HALF64)) }
                    }
                    c := div(sub(a, b), 3)
                }
            }
            // evolve(i, tnow, I): lazy exact integration of one neuron word at wp; stores and returns the word
            function evolve(wp, tnow, I, ta) -> w {
                w := mload(wp)
                let d := sub(tnow, and(shr(16, w), 0xffffffffffff))
                if d {
                    let refr := and(shr(8, w), 0xff)
                    if refr {
                        let skip := sub(refr, 1)
                        if lt(d, skip) { skip := d }
                        switch lt(d, refr)
                        case 1 { refr := sub(refr, d) }
                        default { refr := 0 }
                        d := sub(d, skip)
                    }
                    let v := sar(192, w)
                    let g := signextend(7, shr(128, w))
                    if d {
                        let a, b, c
                        switch gt(d, 1024)
                        case 0 {
                            a := mload(add(ta, shl(5, d)))
                            b := mload(add(add(ta, TB_OFF), shl(5, d)))
                            c := mload(add(add(ta, TC_OFF), shl(5, d)))
                        }
                        default { a, b, c := farDecay(d, ta) }
                        v := sar(64, add(mul(sub(v, R_Q24_W), a), HALF64))
                        v := add(v, sar(56, add(mul(I, sub(ONE64, a)), HALF56)))
                        v := add(v, sar(64, add(mul(g, c), HALF64)))
                        v := add(v, R_Q24_W)
                        g := sar(64, add(mul(g, b), HALF64))
                    }
                    w := and(w, 0xffffffffffffffff00000000000000ff) // keep drive | count | flags
                    w := or(w, shl(192, and(v, M64)))
                    w := or(w, shl(128, and(g, M64)))
                    w := or(w, or(shl(16, tnow), shl(8, refr)))
                    mstore(wp, w)
                }
            }
            function ringPush(ctx, i) {
                let tail := mload(add(ctx, 0x1e0))
                u32set(add(mload(add(ctx, 0x60)), shl(2, tail)), i)
                tail := add(tail, 1)
                if eq(tail, mload(ctx)) { tail := 0 }
                mstore(add(ctx, 0x1e0), tail)
            }
            function ringPop(ctx) -> i {
                let head := mload(add(ctx, 0x1c0))
                i := u32get(add(mload(add(ctx, 0x60)), shl(2, head)))
                head := add(head, 1)
                if eq(head, mload(ctx)) { head := 0 }
                mstore(add(ctx, 0x1c0), head)
            }
            function awaken(ctx, i) {
                let na := mload(add(ctx, 0x1a0))
                u32set(add(mload(add(ctx, 0x40)), shl(2, na)), i)
                mstore(add(ctx, 0x1a0), add(na, 1))
            }
            // (2) threshold sweep over the active-list snapshot with in-place compaction
            function sweep(ctx, tnow) -> pushed {
                let act := mload(add(ctx, 0x40))
                let end := add(act, shl(2, mload(add(ctx, 0x1a0))))
                let kept := act
                for { let kp := act } lt(kp, end) { kp := add(kp, 4) } {
                    let i := shr(224, mload(kp))
                    let wp := add(mload(add(ctx, 0x20)), shl(5, i))
                    let w := evolve(wp, tnow, signextend(3, shr(96, mload(wp))), mload(add(ctx, 0xa0)))
                    let I := signextend(3, shr(96, w))
                    if and(iszero(and(w, 0xff00)), sgt(sar(192, w), THR_Q24_W)) {
                        ringPush(ctx, i)
                        pushed := add(pushed, 1)
                        w := add(w, shl(64, 1))
                        mstore(wp, w)
                    }
                    let canFire := sgt(sar(192, w), THR_Q24_W)
                    canFire := or(canFire, sgt(I, BOUND_Q16))
                    canFire := or(canFire, sgt(add(shl(8, I), signextend(7, shr(128, w))), BOUND_Q24))
                    switch canFire
                    case 1 {
                        u32set(kept, i)
                        kept := add(kept, 4)
                    }
                    default { mstore(wp, and(w, not(1))) }
                }
                mstore(add(ctx, 0x1a0), shr(2, sub(kept, act)))
            }
            // (3) deliver the edges in scratch [sp, end) to their targets
            function deliverRange(ctx, sp, end, neg, tnow) {
                for {} lt(sp, end) { sp := add(sp, 4) } {
                    let edge := shr(224, mload(sp))
                    let wp := add(mload(add(ctx, 0x20)), shl(5, shr(14, edge)))
                    let w := evolve(wp, tnow, signextend(3, shr(96, mload(wp))), mload(add(ctx, 0xa0)))
                    if iszero(and(w, 0xff00)) {
                        let wq := div(mul(and(edge, 0x3fff), W_NUM), 5)
                        if neg { wq := sub(0, wq) }
                        wq := and(add(signextend(7, shr(128, w)), wq), M64)
                        w := or(and(w, not(shl(128, M64))), shl(128, wq))
                        if iszero(and(w, 1)) {
                            w := or(w, 1)
                            awaken(ctx, shr(14, edge))
                        }
                        mstore(wp, w)
                    }
                }
            }
            // stream one presynaptic neuron's CSR row through the scratch chunk buffer
            function deliver(ctx, i, tnow) {
                let ptr := mload(add(ctx, 0x80))
                let p0 := u32get(add(ptr, shl(2, i)))
                let e1 := and(u32get(add(ptr, shl(2, add(i, 1)))), 0x7fffffff)
                let neg := shr(31, p0)
                let e := and(p0, 0x7fffffff)
                let epc := mload(add(ctx, 0x260))
                for {} lt(e, e1) {} {
                    let ci := div(e, epc)
                    let within := sub(e, mul(ci, epc))
                    let take := sub(epc, within)
                    if gt(take, sub(e1, e)) { take := sub(e1, e) }
                    let scr := mload(add(ctx, 0xe0))
                    extcodecopy(
                        mload(add(mload(add(ctx, 0x100)), shl(5, ci))),
                        scr,
                        add(1, shl(2, within)),
                        shl(2, take)
                    )
                    deliverRange(ctx, scr, add(scr, shl(2, take)), neg, tnow)
                    e := add(e, take)
                }
            }
            // (5) reset this step's spikes: ring[p, tail)
            function resetRange(ctx, p) {
                let n := mload(ctx)
                let sw := mload(add(ctx, 0x20))
                let ring := mload(add(ctx, 0x60))
                let tail := mload(add(ctx, 0x1e0))
                let rfc := mload(add(ctx, 0x140))
                for {} iszero(eq(p, tail)) {
                    p := add(p, 1)
                    if eq(p, n) { p := 0 }
                } {
                    let wp := add(sw, shl(5, u32get(add(ring, shl(2, p)))))
                    let w := and(mload(wp), or(MID_AND_LAST, 0xff))
                    mstore(wp, or(w, or(shl(192, R_Q24_FIELD), shl(8, rfc))))
                }
            }
            function run(ctx, steps) {
                let slots := mload(add(ctx, 0x160))
                let sc := add(mload(add(ctx, 0x220)), 32)
                for { let t := 0 } lt(t, steps) { t := add(t, 1) } {
                    let tnow := mload(add(ctx, 0x180))
                    let tailBefore := mload(add(ctx, 0x1e0))
                    let pushed := sweep(ctx, tnow)
                    let slot := mod(tnow, slots)
                    let nDeliver := u32get(add(sc, shl(2, slot)))
                    for { let q := 0 } lt(q, nDeliver) { q := add(q, 1) } { deliver(ctx, ringPop(ctx), tnow) }
                    u32set(add(sc, shl(2, slot)), 0)
                    resetRange(ctx, tailBefore)
                    u32set(add(sc, shl(2, mod(add(tnow, mload(add(ctx, 0x120))), slots))), pushed)
                    mstore(add(ctx, 0x200), sub(add(mload(add(ctx, 0x200)), pushed), nDeliver))
                    mstore(add(ctx, 0x180), add(tnow, 1))
                }
            }
            // (P) pre-pass: settle history under the old drive, install the new one, awaken
            function setDrives(ctx) {
                let n := mload(ctx)
                let drv := mload(add(ctx, 0x240))
                let prev := sub(mload(add(ctx, 0x180)), 1)
                for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                    let nd := signextend(3, shr(224, mload(add(drv, shl(2, i)))))
                    let wp := add(mload(add(ctx, 0x20)), shl(5, i))
                    let od := signextend(3, shr(96, mload(wp)))
                    if iszero(eq(nd, od)) {
                        let w := evolve(wp, prev, od, mload(add(ctx, 0xa0)))
                        w := or(and(w, not(shl(96, 0xffffffff))), shl(96, and(nd, 0xffffffff)))
                        if iszero(and(w, 1)) {
                            w := or(w, 1)
                            awaken(ctx, i)
                        }
                        mstore(wp, w)
                    }
                }
            }
            // (M) materialize every neuron at clock-1
            function materialize(ctx) {
                let sw := mload(add(ctx, 0x20))
                let ta := mload(add(ctx, 0xa0))
                let prev := sub(mload(add(ctx, 0x180)), 1)
                for { let wp := sw } lt(wp, add(sw, shl(5, mload(ctx)))) { wp := add(wp, 32) } {
                    pop(evolve(wp, prev, signextend(3, shr(96, mload(wp))), ta))
                }
            }
            function buildTables(ta) {
                mstore(ta, ONE64)
                mstore(add(ta, TB_OFF), ONE64)
                mstore(add(ta, TC_OFF), 0)
                let a := ONE64
                let b := ONE64
                for { let d := 1 } lt(d, 1025) { d := add(d, 1) } {
                    a := shr(64, add(mul(a, A1), HALF64))
                    b := shr(64, add(mul(b, B1), HALF64))
                    mstore(add(ta, shl(5, d)), a)
                    mstore(add(add(ta, TB_OFF), shl(5, d)), b)
                    mstore(add(add(ta, TC_OFF), shl(5, d)), div(sub(a, b), 3))
                }
            }
            switch op
            case 0 { setDrives(ctxm) }
            case 1 { run(ctxm, arg) }
            case 2 { materialize(ctxm) }
            default { buildTables(mload(add(ctxm, 0xa0))) }
        }
    }
}

// lib/eigenlayer-middleware/lib/eigenlayer-contracts/src/contracts/libraries/SlashingLib.sol

/// @dev All scaling factors have `1e18` as an initial/default value. This value is represented
/// by the constant `WAD`, which is used to preserve precision with uint256 math.
///
/// When applying scaling factors, they are typically multiplied/divided by `WAD`, allowing this
/// constant to act as a "1" in mathematical formulae.
uint64 constant WAD = 1e18;

/*
 * There are 2 types of shares:
 *      1. deposit shares
 *          - These can be converted to an amount of tokens given a strategy
 *              - by calling `sharesToUnderlying` on the strategy address (they're already tokens 
 *              in the case of EigenPods)
 *          - These live in the storage of the EigenPodManager and individual StrategyManager strategies 
 *      2. withdrawable shares
 *          - For a staker, this is the amount of shares that they can withdraw
 *          - For an operator, the shares delegated to them are equal to the sum of their stakers'
 *            withdrawable shares
 *
 * Along with a slashing factor, the DepositScalingFactor is used to convert between the two share types.
 */
struct DepositScalingFactor {
    uint256 _scalingFactor;
}

using SlashingLib for DepositScalingFactor global;

library SlashingLib {
    using Math for uint256;
    using SlashingLib for uint256;
    using SafeCastUpgradeable for uint256;

    // WAD MATH

    function mulWad(uint256 x, uint256 y) internal pure returns (uint256) {
        return x.mulDiv(y, WAD);
    }

    function divWad(uint256 x, uint256 y) internal pure returns (uint256) {
        return x.mulDiv(WAD, y);
    }

    /**
     * @notice Used explicitly for calculating slashed magnitude, we want to ensure even in the
     * situation where an operator is slashed several times and precision has been lost over time,
     * an incoming slashing request isn't rounded down to 0 and an operator is able to avoid slashing penalties.
     */
    function mulWadRoundUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return x.mulDiv(y, WAD, Math.Rounding.Up);
    }

    // GETTERS

    function scalingFactor(
        DepositScalingFactor memory dsf
    ) internal pure returns (uint256) {
        return dsf._scalingFactor == 0 ? WAD : dsf._scalingFactor;
    }

    function scaleForQueueWithdrawal(
        DepositScalingFactor memory dsf,
        uint256 depositSharesToWithdraw
    ) internal pure returns (uint256) {
        return depositSharesToWithdraw.mulWad(dsf.scalingFactor());
    }

    function scaleForCompleteWithdrawal(uint256 scaledShares, uint256 slashingFactor) internal pure returns (uint256) {
        return scaledShares.mulWad(slashingFactor);
    }

    /**
     * @notice Scales shares according to the difference in an operator's magnitude before and
     * after being slashed. This is used to calculate the number of slashable shares in the
     * withdrawal queue.
     * NOTE: max magnitude is guaranteed to only ever decrease.
     */
    function scaleForBurning(
        uint256 scaledShares,
        uint64 prevMaxMagnitude,
        uint64 newMaxMagnitude
    ) internal pure returns (uint256) {
        return scaledShares.mulWad(prevMaxMagnitude - newMaxMagnitude);
    }

    function update(
        DepositScalingFactor storage dsf,
        uint256 prevDepositShares,
        uint256 addedShares,
        uint256 slashingFactor
    ) internal {
        if (prevDepositShares == 0) {
            // If this is the staker's first deposit or they are delegating to an operator,
            // the slashing factor is inverted and applied to the existing DSF. This has the
            // effect of "forgiving" prior slashing for any subsequent deposits.
            dsf._scalingFactor = dsf.scalingFactor().divWad(slashingFactor);
            return;
        }

        /**
         * Base Equations:
         * (1) newShares = currentShares + addedShares
         * (2) newDepositShares = prevDepositShares + addedShares
         * (3) newShares = newDepositShares * newDepositScalingFactor * slashingFactor
         *
         * Plugging (1) into (3):
         * (4) newDepositShares * newDepositScalingFactor * slashingFactor = currentShares + addedShares
         *
         * Solving for newDepositScalingFactor
         * (5) newDepositScalingFactor = (currentShares + addedShares) / (newDepositShares * slashingFactor)
         *
         * Plugging in (2) into (5):
         * (7) newDepositScalingFactor = (currentShares + addedShares) / ((prevDepositShares + addedShares) * slashingFactor)
         * Note that magnitudes must be divided by WAD for precision. Thus,
         *
         * (8) newDepositScalingFactor = WAD * (currentShares + addedShares) / ((prevDepositShares + addedShares) * slashingFactor / WAD)
         * (9) newDepositScalingFactor = (currentShares + addedShares) * WAD / (prevDepositShares + addedShares) * WAD / slashingFactor
         */

        // Step 1: Calculate Numerator
        uint256 currentShares = dsf.calcWithdrawable(prevDepositShares, slashingFactor);

        // Step 2: Compute currentShares + addedShares
        uint256 newShares = currentShares + addedShares;

        // Step 3: Calculate newDepositScalingFactor
        /// forgefmt: disable-next-item
        uint256 newDepositScalingFactor = newShares
            .divWad(prevDepositShares + addedShares)
            .divWad(slashingFactor);

        dsf._scalingFactor = newDepositScalingFactor;
    }

    /// @dev Reset the staker's DSF for a strategy by setting it to 0. This is the same
    /// as setting it to WAD (see the `scalingFactor` getter above).
    ///
    /// A DSF is reset when a staker reduces their deposit shares to 0, either by queueing
    /// a withdrawal, or undelegating from their operator. This ensures that subsequent
    /// delegations/deposits do not use a stale DSF (e.g. from a prior operator).
    function reset(
        DepositScalingFactor storage dsf
    ) internal {
        dsf._scalingFactor = 0;
    }

    // CONVERSION

    function calcWithdrawable(
        DepositScalingFactor memory dsf,
        uint256 depositShares,
        uint256 slashingFactor
    ) internal pure returns (uint256) {
        /// forgefmt: disable-next-item
        return depositShares
            .mulWad(dsf.scalingFactor())
            .mulWad(slashingFactor);
    }

    function calcDepositShares(
        DepositScalingFactor memory dsf,
        uint256 withdrawableShares,
        uint256 slashingFactor
    ) internal pure returns (uint256) {
        /// forgefmt: disable-next-item
        return withdrawableShares
            .divWad(dsf.scalingFactor())
            .divWad(slashingFactor);
    }

    function calcSlashedAmount(
        uint256 operatorShares,
        uint256 prevMaxMagnitude,
        uint256 newMaxMagnitude
    ) internal pure returns (uint256) {
        // round up mulDiv so we don't overslash
        return operatorShares - operatorShares.mulDiv(newMaxMagnitude, prevMaxMagnitude, Math.Rounding.Up);
    }
}

// lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol

// OpenZeppelin Contracts (last updated v4.9.0) (token/ERC20/utils/SafeERC20.sol)

/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    using Address for address;

    /**
     * @dev Transfer `value` amount of `token` from the calling contract to `to`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    /**
     * @dev Transfer `value` amount of `token` from `from` to `to`, spending the approval given by `from` to the
     * calling contract. If `token` returns no value, non-reverting calls are assumed to be successful.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        require(
            (value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    /**
     * @dev Increase the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, oldAllowance + value));
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        unchecked {
            uint256 oldAllowance = token.allowance(address(this), spender);
            require(oldAllowance >= value, "SafeERC20: decreased allowance below zero");
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, oldAllowance - value));
        }
    }

    /**
     * @dev Set the calling contract's allowance toward `spender` to `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful. Compatible with tokens that require the approval to be set to
     * 0 before setting it to a non-zero value.
     */
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        bytes memory approvalCall = abi.encodeWithSelector(token.approve.selector, spender, value);

        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, 0));
            _callOptionalReturn(token, approvalCall);
        }
    }

    /**
     * @dev Use a ERC-2612 signature to set the `owner` approval toward `spender` on `token`.
     * Revert on invalid signature.
     */
    function safePermit(
        IERC20Permit token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        uint256 nonceBefore = token.nonces(owner);
        token.permit(owner, spender, value, deadline, v, r, s);
        uint256 nonceAfter = token.nonces(owner);
        require(nonceAfter == nonceBefore + 1, "SafeERC20: permit did not succeed");
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address-functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        require(returndata.length == 0 || abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturn} that silents catches all reverts and returns a bool instead.
     */
    function _callOptionalReturnBool(IERC20 token, bytes memory data) private returns (bool) {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We cannot use {Address-functionCall} here since this should return false
        // and not revert is the subcall reverts.

        (bool success, bytes memory returndata) = address(token).call(data);
        return
            success && (returndata.length == 0 || abi.decode(returndata, (bool))) && Address.isContract(address(token));
    }
}

// src/examples/onchain-fly/FlyAMM.sol

/// @notice What the pool reads from the fly policy (one SLOAD on the policy side)
interface IFlyPolicyParams {
    function params()
        external
        view
        returns (uint16 feeBps, int16 skewBps, bool rebalance, uint32 windowId, uint32 epoch);
}

/// @title FlyAMM
/// @notice A plain x·y = k pool whose fee and directional skew are read from `FlyPolicy` under hard
///         clamps (HANDOFF §4.1, §4.6, §4.7). NOT a Gas Killer consumer: it never inherits the SDK,
///         so a colluding operator quorum can at worst pin the fee inside [MIN_FEE, MAX_FEE] — never
///         touch reserves.
/// @dev Windows are WINDOW_BLOCKS long. The first pool interaction in a new window CLOSES the previous
///      one: its buy/sell quote volume lands in a 16-window histogram ring, and its TWAP, fee income,
///      LP loss and closing spot are snapshotted. `observe()` returns ONLY closed-window data from
///      storage, so the fly's input is identical at every reference block inside a window and reads no
///      block environment. Volumes in the observation are in units of OBS_UNIT quote wei so they fit
///      the uint64 fields of the handoff's `Observation`.
contract FlyAMM {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ the security boundary
    uint16 public constant MIN_FEE_BPS = 5;
    uint16 public constant MAX_FEE_BPS = 100;
    uint16 public constant MAX_SKEW_BPS = 30;
    uint16 public constant REBAL_SKEW_BPS = 30;
    uint16 public constant DEFAULT_FEE_BPS = 30;
    uint32 public constant MAX_LAG_WINDOWS = 2;
    uint32 public constant WINDOW_BLOCKS = 25;
    uint256 public constant OBS_UNIT = 1e12; // quote wei per observation volume unit
    uint256 internal constant BPS = 10_000;

    // ------------------------------------------------------------------ tokens / policy
    IERC20 public immutable base;
    IERC20 public immutable quote;
    address public immutable deployer;
    IFlyPolicyParams public policy; // set once after the policy is deployed (it needs this pool's address)

    // ------------------------------------------------------------------ reserves + LP shares
    uint128 public reserveBase;
    uint128 public reserveQuote;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    // ------------------------------------------------------------------ open window accumulators
    uint32 public curWindowId; // 0 = never opened
    uint64 internal curBuy; // OBS_UNIT quote units
    uint64 internal curSell;
    uint64 internal curFee;
    uint128 internal openBase;
    uint128 internal openQuote;
    uint256 internal openCum;
    uint64 internal openBlock;
    uint256 internal priceCumQ64; // Σ spotQ64 × blocks
    uint64 internal lastCumBlock;

    // ------------------------------------------------------------------ closed window
    struct Closed {
        uint32 windowId;
        uint64 volRef;
        uint128 spotQ64;
        uint128 twapQ64;
        uint64 feeIncomeQuote;
        uint64 lpLossQuote;
    }

    Closed public closed;
    uint64[16] internal buyHist; // indexed by windowId % 16
    uint64[16] internal sellHist;

    // ------------------------------------------------------------------ events / errors
    event Swap(
        address indexed sender, address indexed to, bool buyBase, uint256 amountIn, uint256 amountOut, uint16 feeBps
    );
    event LiquidityAdded(address indexed to, uint256 baseIn, uint256 quoteIn, uint256 lp);
    event LiquidityRemoved(address indexed to, uint256 baseOut, uint256 quoteOut, uint256 lp);
    event WindowClosed(
        uint32 indexed windowId,
        uint64 buy,
        uint64 sell,
        uint64 feeIncome,
        uint64 lpLoss,
        uint128 twapQ64,
        uint64 volRef
    );

    error PolicyAlreadySet();
    error NotDeployer();
    error InsufficientOutput();
    error InsufficientLiquidity();
    error ZeroAmount();

    constructor(IERC20 _base, IERC20 _quote) {
        base = _base;
        quote = _quote;
        deployer = msg.sender;
    }

    /// @notice One-shot wiring of the fly policy (which needs this pool's address at its construction)
    function setPolicy(IFlyPolicyParams _policy) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (address(policy) != address(0)) revert PolicyAlreadySet();
        policy = _policy;
    }

    // ================================================================== trading

    /// @notice Swap `amountIn` of quote for base (`buyBase`) or base for quote
    function swap(bool buyBase, uint256 amountIn, uint256 minOut, address to) external returns (uint256 out) {
        if (amountIn == 0) revert ZeroAmount();
        _touch();
        uint16 fee = effectiveFee(buyBase);
        uint256 rB = reserveBase;
        uint256 rQ = reserveQuote;
        if (rB == 0 || rQ == 0) revert InsufficientLiquidity();
        uint256 inAfter = amountIn * (BPS - fee) / BPS;
        if (buyBase) {
            quote.safeTransferFrom(msg.sender, address(this), amountIn);
            out = rB * inAfter / (rQ + inAfter);
            if (out < minOut || out >= rB) revert InsufficientOutput();
            reserveQuote = uint128(rQ + amountIn);
            reserveBase = uint128(rB - out);
            base.safeTransfer(to, out);
            curBuy = _sat64(uint256(curBuy) + amountIn / OBS_UNIT);
            curFee = _sat64(uint256(curFee) + (amountIn - inAfter) / OBS_UNIT);
        } else {
            base.safeTransferFrom(msg.sender, address(this), amountIn);
            out = rQ * inAfter / (rB + inAfter);
            if (out < minOut || out >= rQ) revert InsufficientOutput();
            uint256 spotBefore = (rQ << 64) / rB;
            reserveBase = uint128(rB + amountIn);
            reserveQuote = uint128(rQ - out);
            quote.safeTransfer(to, out);
            curSell = _sat64(uint256(curSell) + out / OBS_UNIT);
            curFee = _sat64(uint256(curFee) + (((amountIn - inAfter) * spotBefore) >> 64) / OBS_UNIT);
        }
        emit Swap(msg.sender, to, buyBase, amountIn, out, fee);
    }

    function addLiquidity(uint256 baseIn, uint256 quoteIn, address to) external returns (uint256 lp) {
        if (baseIn == 0 || quoteIn == 0) revert ZeroAmount();
        _touch();
        base.safeTransferFrom(msg.sender, address(this), baseIn);
        quote.safeTransferFrom(msg.sender, address(this), quoteIn);
        uint256 supply = totalSupply;
        if (supply == 0) {
            lp = _sqrt(baseIn * quoteIn);
        } else {
            uint256 a = baseIn * supply / reserveBase;
            uint256 b = quoteIn * supply / reserveQuote;
            lp = a < b ? a : b;
        }
        if (lp == 0) revert InsufficientLiquidity();
        reserveBase += uint128(baseIn);
        reserveQuote += uint128(quoteIn);
        totalSupply = supply + lp;
        balanceOf[to] += lp;
        emit LiquidityAdded(to, baseIn, quoteIn, lp);
    }

    function removeLiquidity(uint256 lp, address to) external returns (uint256 baseOut, uint256 quoteOut) {
        if (lp == 0) revert ZeroAmount();
        _touch();
        uint256 supply = totalSupply;
        baseOut = lp * reserveBase / supply;
        quoteOut = lp * reserveQuote / supply;
        balanceOf[msg.sender] -= lp;
        totalSupply = supply - lp;
        reserveBase -= uint128(baseOut);
        reserveQuote -= uint128(quoteOut);
        base.safeTransfer(to, baseOut);
        quote.safeTransfer(to, quoteOut);
        emit LiquidityRemoved(to, baseOut, quoteOut, lp);
    }

    // ================================================================== the fly's view

    /// @notice The last CLOSED window, storage reads only (no block environment): the fly's input
    function observe() external view returns (FlyTypes.Observation memory o) {
        Closed memory c = closed;
        o.windowId = c.windowId;
        for (uint256 k = 0; k < 16; ++k) {
            if (uint256(c.windowId) + k < 15) continue; // window would be negative
            uint256 w = uint256(c.windowId) + k - 15;
            if (w == 0) continue;
            o.buyQuote[k] = buyHist[w % 16];
            o.sellQuote[k] = sellHist[w % 16];
        }
        o.volRef = c.volRef;
        o.spotQ64 = c.spotQ64;
        o.twapQ64 = c.twapQ64;
        o.feeIncomeQuote = c.feeIncomeQuote;
        o.lpLossQuote = c.lpLossQuote;
    }

    /// @notice The fee a trade pays now: clamps FlyPolicy.params(), staleness, rebalance override (§4.7)
    function effectiveFee(bool buyBase) public view returns (uint16) {
        if (address(policy) == address(0)) return DEFAULT_FEE_BPS;
        (uint16 fee, int16 skew, bool rebal, uint32 wid,) = policy.params();
        uint32 now_ = _windowId();
        if (wid > now_ || now_ - wid > MAX_LAG_WINDOWS || fee < MIN_FEE_BPS || fee > MAX_FEE_BPS) {
            return DEFAULT_FEE_BPS;
        }
        int256 s = skew;
        if (s > int256(uint256(MAX_SKEW_BPS))) s = int256(uint256(MAX_SKEW_BPS));
        if (s < -int256(uint256(MAX_SKEW_BPS))) s = -int256(uint256(MAX_SKEW_BPS));
        if (rebal && closed.windowId != 0 && reserveBase != 0) {
            // surcharge the direction that moves spot AWAY from the last closed TWAP
            uint256 spot = (uint256(reserveQuote) << 64) / reserveBase;
            s = spot > closed.twapQ64 ? int256(uint256(REBAL_SKEW_BPS)) : -int256(uint256(REBAL_SKEW_BPS));
        }
        int256 f = int256(uint256(fee)) + (buyBase ? s : -s);
        if (f < int256(uint256(MIN_FEE_BPS))) f = int256(uint256(MIN_FEE_BPS));
        if (f > int256(uint256(MAX_FEE_BPS))) f = int256(uint256(MAX_FEE_BPS));
        return uint16(uint256(f));
    }

    /// @notice Current spot price, quote per base, Q64
    function spotQ64() public view returns (uint128) {
        if (reserveBase == 0) return 0;
        return uint128((uint256(reserveQuote) << 64) / reserveBase);
    }

    function currentWindowId() external view returns (uint32) {
        return _windowId();
    }

    // ================================================================== windows

    function _windowId() internal view returns (uint32) {
        return uint32(block.number / WINDOW_BLOCKS);
    }

    /// @dev Accrue the TWAP accumulator and roll the window if the block moved into a new one
    function _touch() internal {
        uint32 w = _windowId();
        uint256 spot = spotQ64();
        if (lastCumBlock != 0 && block.number > lastCumBlock) {
            priceCumQ64 += spot * (block.number - lastCumBlock);
        }
        lastCumBlock = uint64(block.number);
        if (curWindowId == 0) {
            curWindowId = w;
            _openWindow();
            return;
        }
        if (w != curWindowId) {
            _closeWindow(spot);
            curWindowId = w;
            _openWindow();
        }
    }

    function _openWindow() internal {
        openBase = reserveBase;
        openQuote = reserveQuote;
        openCum = priceCumQ64;
        openBlock = uint64(block.number);
        curBuy = 0;
        curSell = 0;
        curFee = 0;
    }

    function _closeWindow(uint256 spot) internal {
        uint32 wid = curWindowId;
        uint256 blocks = block.number - openBlock;
        uint256 twap = blocks == 0 ? spot : (priceCumQ64 - openCum) / blocks;
        // volRef: EMA of window volume, α = 1/8 (first window seeds it)
        uint256 vol = uint256(curBuy) + curSell;
        uint256 volRef = closed.windowId == 0 ? vol : uint256(closed.volRef) + vol / 8 - uint256(closed.volRef) / 8;
        // LP loss at the window TWAP: max(0, x0·P + y0 − x1·P − y1), in OBS_UNIT quote units
        uint256 v0 = ((uint256(openBase) * twap) >> 64) + openQuote;
        uint256 v1 = ((uint256(reserveBase) * twap) >> 64) + reserveQuote;
        uint256 lpLoss = v0 > v1 ? (v0 - v1) / OBS_UNIT : 0;
        // zero histogram slots of windows that never closed (no activity) since the previous close
        uint256 prevWid = closed.windowId;
        if (prevWid != 0 && wid > prevWid + 1) {
            uint256 gap = wid - prevWid - 1;
            if (gap > 16) gap = 16;
            for (uint256 g = 1; g <= gap; ++g) {
                buyHist[(prevWid + g) % 16] = 0;
                sellHist[(prevWid + g) % 16] = 0;
            }
        }
        buyHist[wid % 16] = curBuy;
        sellHist[wid % 16] = curSell;
        closed = Closed({
            windowId: wid,
            volRef: _sat64(volRef),
            spotQ64: uint128(spot),
            twapQ64: uint128(twap),
            feeIncomeQuote: curFee,
            lpLossQuote: _sat64(lpLoss)
        });
        emit WindowClosed(wid, curBuy, curSell, curFee, _sat64(lpLoss), uint128(twap), _sat64(volRef));
    }

    // ================================================================== helpers

    function _sat64(uint256 x) internal pure returns (uint64) {
        return x > type(uint64).max ? type(uint64).max : uint64(x);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

// lib/eigenlayer-middleware/lib/eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol

interface IStrategyErrors {
    /// @dev Thrown when called by an account that is not strategy manager.
    error OnlyStrategyManager();
    /// @dev Thrown when new shares value is zero.
    error NewSharesZero();
    /// @dev Thrown when total shares exceeds max.
    error TotalSharesExceedsMax();
    /// @dev Thrown when amount shares is greater than total shares.
    error WithdrawalAmountExceedsTotalDeposits();
    /// @dev Thrown when attempting an action with a token that is not accepted.
    error OnlyUnderlyingToken();

    /// StrategyBaseWithTVLLimits

    /// @dev Thrown when `maxPerDeposit` exceeds max.
    error MaxPerDepositExceedsMax();
    /// @dev Thrown when balance exceeds max total deposits.
    error BalanceExceedsMaxTotalDeposits();
}

interface IStrategyEvents {
    /**
     * @notice Used to emit an event for the exchange rate between 1 share and underlying token in a strategy contract
     * @param rate is the exchange rate in wad 18 decimals
     * @dev Tokens that do not have 18 decimals must have offchain services scale the exchange rate by the proper magnitude
     */
    event ExchangeRateEmitted(uint256 rate);

    /**
     * Used to emit the underlying token and its decimals on strategy creation
     * @notice token
     * @param token is the ERC20 token of the strategy
     * @param decimals are the decimals of the ERC20 token in the strategy
     */
    event StrategyTokenSet(IERC20 token, uint8 decimals);
}

/**
 * @title Minimal interface for an `Strategy` contract.
 * @author Layr Labs, Inc.
 * @notice Terms of Service: https://docs.eigenlayer.xyz/overview/terms-of-service
 * @notice Custom `Strategy` implementations may expand extensively on this interface.
 */
interface IStrategy is IStrategyErrors, IStrategyEvents, ISemVerMixin {
    /**
     * @notice Used to deposit tokens into this Strategy
     * @param token is the ERC20 token being deposited
     * @param amount is the amount of token being deposited
     * @dev This function is only callable by the strategyManager contract. It is invoked inside of the strategyManager's
     * `depositIntoStrategy` function, and individual share balances are recorded in the strategyManager as well.
     * @return newShares is the number of new shares issued at the current exchange ratio.
     */
    function deposit(IERC20 token, uint256 amount) external returns (uint256);

    /**
     * @notice Used to withdraw tokens from this Strategy, to the `recipient`'s address
     * @param recipient is the address to receive the withdrawn funds
     * @param token is the ERC20 token being transferred out
     * @param amountShares is the amount of shares being withdrawn
     * @dev This function is only callable by the strategyManager contract. It is invoked inside of the strategyManager's
     * other functions, and individual share balances are recorded in the strategyManager as well.
     */
    function withdraw(address recipient, IERC20 token, uint256 amountShares) external;

    /**
     * @notice Used to convert a number of shares to the equivalent amount of underlying tokens for this strategy.
     * For a staker using this function and trying to calculate the amount of underlying tokens they have in total they
     * should input into `amountShares` their withdrawable shares read from the `DelegationManager` contract.
     * @notice In contrast to `sharesToUnderlyingView`, this function **may** make state modifications
     * @param amountShares is the amount of shares to calculate its conversion into the underlying token
     * @return The amount of underlying tokens corresponding to the input `amountShares`
     * @dev Implementation for these functions in particular may vary significantly for different strategies
     */
    function sharesToUnderlying(
        uint256 amountShares
    ) external returns (uint256);

    /**
     * @notice Used to convert an amount of underlying tokens to the equivalent amount of shares in this strategy.
     * @notice In contrast to `underlyingToSharesView`, this function **may** make state modifications
     * @param amountUnderlying is the amount of `underlyingToken` to calculate its conversion into strategy shares
     * @return The amount of shares corresponding to the input `amountUnderlying`.  This is used as deposit shares
     * in the `StrategyManager` contract.
     * @dev Implementation for these functions in particular may vary significantly for different strategies
     */
    function underlyingToShares(
        uint256 amountUnderlying
    ) external returns (uint256);

    /**
     * @notice convenience function for fetching the current underlying value of all of the `user`'s shares in
     * this strategy. In contrast to `userUnderlyingView`, this function **may** make state modifications
     */
    function userUnderlying(
        address user
    ) external returns (uint256);

    /**
     * @notice convenience function for fetching the current total shares of `user` in this strategy, by
     * querying the `strategyManager` contract
     */
    function shares(
        address user
    ) external view returns (uint256);

    /**
     * @notice Used to convert a number of shares to the equivalent amount of underlying tokens for this strategy.
     * For a staker using this function and trying to calculate the amount of underlying tokens they have in total they
     * should input into `amountShares` their withdrawable shares read from the `DelegationManager` contract.
     * @notice In contrast to `sharesToUnderlying`, this function guarantees no state modifications
     * @param amountShares is the amount of shares to calculate its conversion into the underlying token
     * @return The amount of underlying tokens corresponding to the input `amountShares`
     * @dev Implementation for these functions in particular may vary significantly for different strategies
     */
    function sharesToUnderlyingView(
        uint256 amountShares
    ) external view returns (uint256);

    /**
     * @notice Used to convert an amount of underlying tokens to the equivalent amount of shares in this strategy.
     * @notice In contrast to `underlyingToShares`, this function guarantees no state modifications
     * @param amountUnderlying is the amount of `underlyingToken` to calculate its conversion into strategy shares
     * @return The amount of shares corresponding to the input `amountUnderlying`. This is used as deposit shares
     * in the `StrategyManager` contract.
     * @dev Implementation for these functions in particular may vary significantly for different strategies
     */
    function underlyingToSharesView(
        uint256 amountUnderlying
    ) external view returns (uint256);

    /**
     * @notice convenience function for fetching the current underlying value of all of the `user`'s shares in
     * this strategy. In contrast to `userUnderlying`, this function guarantees no state modifications
     */
    function userUnderlyingView(
        address user
    ) external view returns (uint256);

    /// @notice The underlying token for shares in this Strategy
    function underlyingToken() external view returns (IERC20);

    /// @notice The total number of extant shares in this Strategy
    function totalShares() external view returns (uint256);

    /// @notice Returns either a brief string explaining the strategy's goal & purpose, or a link to metadata that explains in more detail.
    function explanation() external view returns (string memory);
}

// lib/eigenlayer-middleware/lib/eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol

interface IDelegationManagerErrors {
    /// @dev Thrown when caller is neither the StrategyManager or EigenPodManager contract.
    error OnlyStrategyManagerOrEigenPodManager();
    /// @dev Thrown when msg.sender is not the EigenPodManager
    error OnlyEigenPodManager();
    /// @dev Throw when msg.sender is not the AllocationManager
    error OnlyAllocationManager();

    /// Delegation Status

    /// @dev Thrown when an operator attempts to undelegate.
    error OperatorsCannotUndelegate();
    /// @dev Thrown when an account is actively delegated.
    error ActivelyDelegated();
    /// @dev Thrown when an account is not actively delegated.
    error NotActivelyDelegated();
    /// @dev Thrown when `operator` is not a registered operator.
    error OperatorNotRegistered();

    /// Invalid Inputs

    /// @dev Thrown when attempting to execute an action that was not queued.
    error WithdrawalNotQueued();
    /// @dev Thrown when caller cannot undelegate on behalf of a staker.
    error CallerCannotUndelegate();
    /// @dev Thrown when two array parameters have mismatching lengths.
    error InputArrayLengthMismatch();
    /// @dev Thrown when input arrays length is zero.
    error InputArrayLengthZero();

    /// Slashing

    /// @dev Thrown when an operator has been fully slashed(maxMagnitude is 0) for a strategy.
    /// or if the staker has had been natively slashed to the point of their beaconChainScalingFactor equalling 0.
    error FullySlashed();

    /// Signatures

    /// @dev Thrown when attempting to spend a spent eip-712 salt.
    error SaltSpent();

    /// Withdrawal Processing

    /// @dev Thrown when attempting to withdraw before delay has elapsed.
    error WithdrawalDelayNotElapsed();
    /// @dev Thrown when withdrawer is not the current caller.
    error WithdrawerNotCaller();
}

interface IDelegationManagerTypes {
    // @notice Struct used for storing information about a single operator who has registered with EigenLayer
    struct OperatorDetails {
        /// @notice DEPRECATED -- this field is no longer used, payments are handled in RewardsCoordinator.sol
        address __deprecated_earningsReceiver;
        /**
         * @notice Address to verify signatures when a staker wishes to delegate to the operator, as well as controlling "forced undelegations".
         * @dev Signature verification follows these rules:
         * 1) If this address is left as address(0), then any staker will be free to delegate to the operator, i.e. no signature verification will be performed.
         * 2) If this address is an EOA (i.e. it has no code), then we follow standard ECDSA signature verification for delegations to the operator.
         * 3) If this address is a contract (i.e. it has code) then we forward a call to the contract and verify that it returns the correct EIP-1271 "magic value".
         */
        address delegationApprover;
        /// @notice DEPRECATED -- this field is no longer used. An analogous field is the `allocationDelay` stored in the AllocationManager
        uint32 __deprecated_stakerOptOutWindowBlocks;
    }

    /**
     * @notice Abstract struct used in calculating an EIP712 signature for an operator's delegationApprover to approve that a specific staker delegate to the operator.
     * @dev Used in computing the `DELEGATION_APPROVAL_TYPEHASH` and as a reference in the computation of the approverDigestHash in the `_delegate` function.
     */
    struct DelegationApproval {
        // the staker who is delegating
        address staker;
        // the operator being delegated to
        address operator;
        // the operator's provided salt
        bytes32 salt;
        // the expiration timestamp (UTC) of the signature
        uint256 expiry;
    }

    /**
     * @dev A struct representing an existing queued withdrawal. After the withdrawal delay has elapsed, this withdrawal can be completed via `completeQueuedWithdrawal`.
     * A `Withdrawal` is created by the `DelegationManager` when `queueWithdrawals` is called. The `withdrawalRoots` hashes returned by `queueWithdrawals` can be used
     * to fetch the corresponding `Withdrawal` from storage (via `getQueuedWithdrawal`).
     *
     * @param staker The address that queued the withdrawal
     * @param delegatedTo The address that the staker was delegated to at the time the withdrawal was queued. Used to determine if additional slashing occurred before
     * this withdrawal became completable.
     * @param withdrawer The address that will call the contract to complete the withdrawal. Note that this will always equal `staker`; alternate withdrawers are not
     * supported at this time.
     * @param nonce The staker's `cumulativeWithdrawalsQueued` at time of queuing. Used to ensure withdrawals have unique hashes.
     * @param startBlock The block number when the withdrawal was queued.
     * @param strategies The strategies requested for withdrawal when the withdrawal was queued
     * @param scaledShares The staker's deposit shares requested for withdrawal, scaled by the staker's `depositScalingFactor`. Upon completion, these will be
     * scaled by the appropriate slashing factor as of the withdrawal's completable block. The result is what is actually withdrawable.
     */
    struct Withdrawal {
        address staker;
        address delegatedTo;
        address withdrawer;
        uint256 nonce;
        uint32 startBlock;
        IStrategy[] strategies;
        uint256[] scaledShares;
    }

    /**
     * @param strategies The strategies to withdraw from
     * @param depositShares For each strategy, the number of deposit shares to withdraw. Deposit shares can
     * be queried via `getDepositedShares`.
     * NOTE: The number of shares ultimately received when a withdrawal is completed may be lower depositShares
     * if the staker or their delegated operator has experienced slashing.
     * @param __deprecated_withdrawer This field is ignored. The only party that may complete a withdrawal
     * is the staker that originally queued it. Alternate withdrawers are not supported.
     */
    struct QueuedWithdrawalParams {
        IStrategy[] strategies;
        uint256[] depositShares;
        address __deprecated_withdrawer;
    }
}

interface IDelegationManagerEvents is IDelegationManagerTypes {
    // @notice Emitted when a new operator registers in EigenLayer and provides their delegation approver.
    event OperatorRegistered(address indexed operator, address delegationApprover);

    /// @notice Emitted when an operator updates their delegation approver
    event DelegationApproverUpdated(address indexed operator, address newDelegationApprover);

    /**
     * @notice Emitted when @param operator indicates that they are updating their MetadataURI string
     * @dev Note that these strings are *never stored in storage* and are instead purely emitted in events for off-chain indexing
     */
    event OperatorMetadataURIUpdated(address indexed operator, string metadataURI);

    /// @notice Emitted whenever an operator's shares are increased for a given strategy. Note that shares is the delta in the operator's shares.
    event OperatorSharesIncreased(address indexed operator, address staker, IStrategy strategy, uint256 shares);

    /// @notice Emitted whenever an operator's shares are decreased for a given strategy. Note that shares is the delta in the operator's shares.
    event OperatorSharesDecreased(address indexed operator, address staker, IStrategy strategy, uint256 shares);

    /// @notice Emitted when @param staker delegates to @param operator.
    event StakerDelegated(address indexed staker, address indexed operator);

    /// @notice Emitted when @param staker undelegates from @param operator.
    event StakerUndelegated(address indexed staker, address indexed operator);

    /// @notice Emitted when @param staker is undelegated via a call not originating from the staker themself
    event StakerForceUndelegated(address indexed staker, address indexed operator);

    /// @notice Emitted when a staker's depositScalingFactor is updated
    event DepositScalingFactorUpdated(address staker, IStrategy strategy, uint256 newDepositScalingFactor);

    /**
     * @notice Emitted when a new withdrawal is queued.
     * @param withdrawalRoot Is the hash of the `withdrawal`.
     * @param withdrawal Is the withdrawal itself.
     * @param sharesToWithdraw Is an array of the expected shares that were queued for withdrawal corresponding to the strategies in the `withdrawal`.
     */
    event SlashingWithdrawalQueued(bytes32 withdrawalRoot, Withdrawal withdrawal, uint256[] sharesToWithdraw);

    /// @notice Emitted when a queued withdrawal is completed
    event SlashingWithdrawalCompleted(bytes32 withdrawalRoot);

    /// @notice Emitted whenever an operator's shares are slashed for a given strategy
    event OperatorSharesSlashed(address indexed operator, IStrategy strategy, uint256 totalSlashedShares);
}

/**
 * @title DelegationManager
 * @author Layr Labs, Inc.
 * @notice Terms of Service: https://docs.eigenlayer.xyz/overview/terms-of-service
 * @notice  This is the contract for delegation in EigenLayer. The main functionalities of this contract are
 * - enabling anyone to register as an operator in EigenLayer
 * - allowing operators to specify parameters related to stakers who delegate to them
 * - enabling any staker to delegate its stake to the operator of its choice (a given staker can only delegate to a single operator at a time)
 * - enabling a staker to undelegate its assets from the operator it is delegated to (performed as part of the withdrawal process, initiated through the StrategyManager)
 */
interface IDelegationManager is ISignatureUtilsMixin, IDelegationManagerErrors, IDelegationManagerEvents {
    /**
     * @dev Initializes the initial owner and paused status.
     */
    function initialize(address initialOwner, uint256 initialPausedStatus) external;

    /**
     * @notice Registers the caller as an operator in EigenLayer.
     * @param initDelegationApprover is an address that, if set, must provide a signature when stakers delegate
     * to an operator.
     * @param allocationDelay The delay before allocations take effect.
     * @param metadataURI is a URI for the operator's metadata, i.e. a link providing more details on the operator.
     *
     * @dev Once an operator is registered, they cannot 'deregister' as an operator, and they will forever be considered "delegated to themself".
     * @dev This function will revert if the caller is already delegated to an operator.
     * @dev Note that the `metadataURI` is *never stored * and is only emitted in the `OperatorMetadataURIUpdated` event
     */
    function registerAsOperator(
        address initDelegationApprover,
        uint32 allocationDelay,
        string calldata metadataURI
    ) external;

    /**
     * @notice Updates an operator's stored `delegationApprover`.
     * @param operator is the operator to update the delegationApprover for
     * @param newDelegationApprover is the new delegationApprover for the operator
     *
     * @dev The caller must have previously registered as an operator in EigenLayer.
     */
    function modifyOperatorDetails(address operator, address newDelegationApprover) external;

    /**
     * @notice Called by an operator to emit an `OperatorMetadataURIUpdated` event indicating the information has updated.
     * @param operator The operator to update metadata for
     * @param metadataURI The URI for metadata associated with an operator
     * @dev Note that the `metadataURI` is *never stored * and is only emitted in the `OperatorMetadataURIUpdated` event
     */
    function updateOperatorMetadataURI(address operator, string calldata metadataURI) external;

    /**
     * @notice Caller delegates their stake to an operator.
     * @param operator The account (`msg.sender`) is delegating its assets to for use in serving applications built on EigenLayer.
     * @param approverSignatureAndExpiry (optional) Verifies the operator approves of this delegation
     * @param approverSalt (optional) A unique single use value tied to an individual signature.
     * @dev The signature/salt are used ONLY if the operator has configured a delegationApprover.
     * If they have not, these params can be left empty.
     */
    function delegateTo(
        address operator,
        SignatureWithExpiry memory approverSignatureAndExpiry,
        bytes32 approverSalt
    ) external;

    /**
     * @notice Undelegates the staker from their operator and queues a withdrawal for all of their shares
     * @param staker The account to be undelegated
     * @return withdrawalRoots The roots of the newly queued withdrawals, if a withdrawal was queued. Returns
     * an empty array if none was queued.
     *
     * @dev Reverts if the `staker` is also an operator, since operators are not allowed to undelegate from themselves.
     * @dev Reverts if the caller is not the staker, nor the operator who the staker is delegated to, nor the operator's specified "delegationApprover"
     * @dev Reverts if the `staker` is not delegated to an operator
     */
    function undelegate(
        address staker
    ) external returns (bytes32[] memory withdrawalRoots);

    /**
     * @notice Undelegates the staker from their current operator, and redelegates to `newOperator`
     * Queues a withdrawal for all of the staker's withdrawable shares. These shares will only be
     * delegated to `newOperator` AFTER the withdrawal is completed.
     * @dev This method acts like a call to `undelegate`, then `delegateTo`
     * @param newOperator the new operator that will be delegated all assets
     * @dev NOTE: the following 2 params are ONLY checked if `newOperator` has a `delegationApprover`.
     * If not, they can be left empty.
     * @param newOperatorApproverSig A signature from the operator's `delegationApprover`
     * @param approverSalt A unique single use value tied to the approver's signature
     */
    function redelegate(
        address newOperator,
        SignatureWithExpiry memory newOperatorApproverSig,
        bytes32 approverSalt
    ) external returns (bytes32[] memory withdrawalRoots);

    /**
     * @notice Allows a staker to queue a withdrawal of their deposit shares. The withdrawal can be
     * completed after the MIN_WITHDRAWAL_DELAY_BLOCKS via either of the completeQueuedWithdrawal methods.
     *
     * While in the queue, these shares are removed from the staker's balance, as well as from their operator's
     * delegated share balance (if applicable). Note that while in the queue, deposit shares are still subject
     * to slashing. If any slashing has occurred, the shares received may be less than the queued deposit shares.
     *
     * @dev To view all the staker's strategies/deposit shares that can be queued for withdrawal, see `getDepositedShares`
     * @dev To view the current conversion between a staker's deposit shares and withdrawable shares, see `getWithdrawableShares`
     */
    function queueWithdrawals(
        QueuedWithdrawalParams[] calldata params
    ) external returns (bytes32[] memory);

    /**
     * @notice Used to complete a queued withdrawal
     * @param withdrawal The withdrawal to complete
     * @param tokens Array in which the i-th entry specifies the `token` input to the 'withdraw' function of the i-th Strategy in the `withdrawal.strategies` array.
     * @param tokens For each `withdrawal.strategies`, the underlying token of the strategy
     * NOTE: if `receiveAsTokens` is false, the `tokens` array is unused and can be filled with default values. However, `tokens.length` MUST still be equal to `withdrawal.strategies.length`.
     * NOTE: For the `beaconChainETHStrategy`, the corresponding `tokens` value is ignored (can be 0).
     * @param receiveAsTokens If true, withdrawn shares will be converted to tokens and sent to the caller. If false, the caller receives shares that can be delegated to an operator.
     * NOTE: if the caller receives shares and is currently delegated to an operator, the received shares are
     * automatically delegated to the caller's current operator.
     */
    function completeQueuedWithdrawal(
        Withdrawal calldata withdrawal,
        IERC20[] calldata tokens,
        bool receiveAsTokens
    ) external;

    /**
     * @notice Used to complete multiple queued withdrawals
     * @param withdrawals Array of Withdrawals to complete. See `completeQueuedWithdrawal` for the usage of a single Withdrawal.
     * @param tokens Array of tokens for each Withdrawal. See `completeQueuedWithdrawal` for the usage of a single array.
     * @param receiveAsTokens Whether or not to complete each withdrawal as tokens. See `completeQueuedWithdrawal` for the usage of a single boolean.
     * @dev See `completeQueuedWithdrawal` for relevant dev tags
     */
    function completeQueuedWithdrawals(
        Withdrawal[] calldata withdrawals,
        IERC20[][] calldata tokens,
        bool[] calldata receiveAsTokens
    ) external;

    /**
     * @notice Called by a share manager when a staker's deposit share balance in a strategy increases.
     * This method delegates any new shares to an operator (if applicable), and updates the staker's
     * deposit scaling factor regardless.
     * @param staker The address whose deposit shares have increased
     * @param strategy The strategy in which shares have been deposited
     * @param prevDepositShares The number of deposit shares the staker had in the strategy prior to the increase
     * @param addedShares The number of deposit shares added by the staker
     *
     * @dev Note that if the either the staker's current operator has been slashed 100% for `strategy`, OR the
     * staker has been slashed 100% on the beacon chain such that the calculated slashing factor is 0, this
     * method WILL REVERT.
     */
    function increaseDelegatedShares(
        address staker,
        IStrategy strategy,
        uint256 prevDepositShares,
        uint256 addedShares
    ) external;

    /**
     * @notice If the staker is delegated, decreases its operator's shares in response to
     * a decrease in balance in the beaconChainETHStrategy
     * @param staker the staker whose operator's balance will be decreased
     * @param curDepositShares the current deposit shares held by the staker
     * @param beaconChainSlashingFactorDecrease the amount that the staker's beaconChainSlashingFactor has decreased by
     * @dev Note: `beaconChainSlashingFactorDecrease` are assumed to ALWAYS be < 1 WAD.
     * These invariants are maintained in the EigenPodManager.
     */
    function decreaseDelegatedShares(
        address staker,
        uint256 curDepositShares,
        uint64 beaconChainSlashingFactorDecrease
    ) external;

    /**
     * @notice Decreases the operators shares in storage after a slash and increases the burnable shares by calling
     * into either the StrategyManager or EigenPodManager (if the strategy is beaconChainETH).
     * @param operator The operator to decrease shares for
     * @param strategy The strategy to decrease shares for
     * @param prevMaxMagnitude the previous maxMagnitude of the operator
     * @param newMaxMagnitude the new maxMagnitude of the operator
     * @dev Callable only by the AllocationManager
     * @dev Note: Assumes `prevMaxMagnitude <= newMaxMagnitude`. This invariant is maintained in
     * the AllocationManager.
     */
    function slashOperatorShares(
        address operator,
        IStrategy strategy,
        uint64 prevMaxMagnitude,
        uint64 newMaxMagnitude
    ) external;

    /**
     *
     *                         VIEW FUNCTIONS
     *
     */

    /**
     * @notice returns the address of the operator that `staker` is delegated to.
     * @notice Mapping: staker => operator whom the staker is currently delegated to.
     * @dev Note that returning address(0) indicates that the staker is not actively delegated to any operator.
     */
    function delegatedTo(
        address staker
    ) external view returns (address);

    /**
     * @notice Mapping: delegationApprover => 32-byte salt => whether or not the salt has already been used by the delegationApprover.
     * @dev Salts are used in the `delegateTo` function. Note that this function only processes the delegationApprover's
     * signature + the provided salt if the operator being delegated to has specified a nonzero address as their `delegationApprover`.
     */
    function delegationApproverSaltIsSpent(address _delegationApprover, bytes32 salt) external view returns (bool);

    /// @notice Mapping: staker => cumulative number of queued withdrawals they have ever initiated.
    /// @dev This only increments (doesn't decrement), and is used to help ensure that otherwise identical withdrawals have unique hashes.
    function cumulativeWithdrawalsQueued(
        address staker
    ) external view returns (uint256);

    /**
     * @notice Returns 'true' if `staker` *is* actively delegated, and 'false' otherwise.
     */
    function isDelegated(
        address staker
    ) external view returns (bool);

    /**
     * @notice Returns true is an operator has previously registered for delegation.
     */
    function isOperator(
        address operator
    ) external view returns (bool);

    /**
     * @notice Returns the delegationApprover account for an operator
     */
    function delegationApprover(
        address operator
    ) external view returns (address);

    /**
     * @notice Returns the shares that an operator has delegated to them in a set of strategies
     * @param operator the operator to get shares for
     * @param strategies the strategies to get shares for
     */
    function getOperatorShares(
        address operator,
        IStrategy[] memory strategies
    ) external view returns (uint256[] memory);

    /**
     * @notice Returns the shares that a set of operators have delegated to them in a set of strategies
     * @param operators the operators to get shares for
     * @param strategies the strategies to get shares for
     */
    function getOperatorsShares(
        address[] memory operators,
        IStrategy[] memory strategies
    ) external view returns (uint256[][] memory);

    /**
     * @notice Returns amount of withdrawable shares from an operator for a strategy that is still in the queue
     * and therefore slashable. Note that the *actual* slashable amount could be less than this value as this doesn't account
     * for amounts that have already been slashed. This assumes that none of the shares have been slashed.
     * @param operator the operator to get shares for
     * @param strategy the strategy to get shares for
     * @return the amount of shares that are slashable in the withdrawal queue for an operator and a strategy
     */
    function getSlashableSharesInQueue(address operator, IStrategy strategy) external view returns (uint256);

    /**
     * @notice Given a staker and a set of strategies, return the shares they can queue for withdrawal and the
     * corresponding depositShares.
     * This value depends on which operator the staker is delegated to.
     * The shares amount returned is the actual amount of Strategy shares the staker would receive (subject
     * to each strategy's underlying shares to token ratio).
     */
    function getWithdrawableShares(
        address staker,
        IStrategy[] memory strategies
    ) external view returns (uint256[] memory withdrawableShares, uint256[] memory depositShares);

    /**
     * @notice Returns the number of shares in storage for a staker and all their strategies
     */
    function getDepositedShares(
        address staker
    ) external view returns (IStrategy[] memory, uint256[] memory);

    /**
     * @notice Returns the scaling factor applied to a staker's deposits for a given strategy
     */
    function depositScalingFactor(address staker, IStrategy strategy) external view returns (uint256);

    /**
     * @notice Returns the Withdrawal associated with a `withdrawalRoot`.
     * @param withdrawalRoot The hash identifying the queued withdrawal.
     * @return withdrawal The withdrawal details.
     */
    function queuedWithdrawals(
        bytes32 withdrawalRoot
    ) external view returns (Withdrawal memory withdrawal);

    /**
     * @notice Returns the Withdrawal and corresponding shares associated with a `withdrawalRoot`
     * @param withdrawalRoot The hash identifying the queued withdrawal
     * @return withdrawal The withdrawal details
     * @return shares Array of shares corresponding to each strategy in the withdrawal
     * @dev The shares are what a user would receive from completing a queued withdrawal, assuming all slashings are applied
     * @dev Withdrawals queued before the slashing release cannot be queried with this method
     */
    function getQueuedWithdrawal(
        bytes32 withdrawalRoot
    ) external view returns (Withdrawal memory withdrawal, uint256[] memory shares);

    /**
     * @notice Returns all queued withdrawals and their corresponding shares for a staker.
     * @param staker The address of the staker to query withdrawals for.
     * @return withdrawals Array of Withdrawal structs containing details about each queued withdrawal.
     * @return shares 2D array of shares, where each inner array corresponds to the strategies in the withdrawal.
     * @dev The shares are what a user would receive from completing a queued withdrawal, assuming all slashings are applied.
     */
    function getQueuedWithdrawals(
        address staker
    ) external view returns (Withdrawal[] memory withdrawals, uint256[][] memory shares);

    /// @notice Returns a list of queued withdrawal roots for the `staker`.
    /// NOTE that this only returns withdrawals queued AFTER the slashing release.
    function getQueuedWithdrawalRoots(
        address staker
    ) external view returns (bytes32[] memory);

    /**
     * @notice Converts shares for a set of strategies to deposit shares, likely in order to input into `queueWithdrawals`.
     * This function will revert from a division by 0 error if any of the staker's strategies have a slashing factor of 0.
     * @param staker the staker to convert shares for
     * @param strategies the strategies to convert shares for
     * @param withdrawableShares the shares to convert
     * @return the deposit shares
     * @dev will be a few wei off due to rounding errors
     */
    function convertToDepositShares(
        address staker,
        IStrategy[] memory strategies,
        uint256[] memory withdrawableShares
    ) external view returns (uint256[] memory);

    /// @notice Returns the keccak256 hash of `withdrawal`.
    function calculateWithdrawalRoot(
        Withdrawal memory withdrawal
    ) external pure returns (bytes32);

    /**
     * @notice Calculates the digest hash to be signed by the operator's delegationApprove and used in the `delegateTo` function.
     * @param staker The account delegating their stake
     * @param operator The account receiving delegated stake
     * @param _delegationApprover the operator's `delegationApprover` who will be signing the delegationHash (in general)
     * @param approverSalt A unique and single use value associated with the approver signature.
     * @param expiry Time after which the approver's signature becomes invalid
     */
    function calculateDelegationApprovalDigestHash(
        address staker,
        address operator,
        address _delegationApprover,
        bytes32 approverSalt,
        uint256 expiry
    ) external view returns (bytes32);

    /// @notice return address of the beaconChainETHStrategy
    function beaconChainETHStrategy() external view returns (IStrategy);

    /**
     * @notice Returns the minimum withdrawal delay in blocks to pass for withdrawals queued to be completable.
     * Also applies to legacy withdrawals so any withdrawals not completed prior to the slashing upgrade will be subject
     * to this longer delay.
     * @dev Backwards-compatible interface to return the internal `MIN_WITHDRAWAL_DELAY_BLOCKS` value
     * @dev Previous value in storage was deprecated. See `__deprecated_minWithdrawalDelayBlocks`
     */
    function minWithdrawalDelayBlocks() external view returns (uint32);

    /// @notice The EIP-712 typehash for the DelegationApproval struct used by the contract
    function DELEGATION_APPROVAL_TYPEHASH() external view returns (bytes32);
}

// lib/eigenlayer-middleware/lib/eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol

interface IAllocationManagerErrors {
    /// Input Validation

    /// @dev Thrown when `wadToSlash` is zero or greater than 1e18
    error InvalidWadToSlash();
    /// @dev Thrown when two array parameters have mismatching lengths.
    error InputArrayLengthMismatch();
    /// @dev Thrown when the AVSRegistrar is not correctly configured to prevent an AVSRegistrar contract
    /// from being used with the wrong AVS
    error InvalidAVSRegistrar();

    /// Caller

    /// @dev Thrown when caller is not authorized to call a function.
    error InvalidCaller();

    /// Operator Status

    /// @dev Thrown when an invalid operator is provided.
    error InvalidOperator();
    /// @dev Thrown when an invalid avs whose metadata is not registered is provided.
    error NonexistentAVSMetadata();
    /// @dev Thrown when an operator's allocation delay has yet to be set.
    error UninitializedAllocationDelay();
    /// @dev Thrown when attempting to slash an operator when they are not slashable.
    error OperatorNotSlashable();
    /// @dev Thrown when trying to add an operator to a set they are already a member of
    error AlreadyMemberOfSet();
    /// @dev Thrown when trying to slash/remove an operator from a set they are not a member of
    error NotMemberOfSet();

    /// Operator Set Status

    /// @dev Thrown when an invalid operator set is provided.
    error InvalidOperatorSet();
    /// @dev Thrown when provided `strategies` are not in ascending order.
    error StrategiesMustBeInAscendingOrder();
    /// @dev Thrown when trying to add a strategy to an operator set that already contains it.
    error StrategyAlreadyInOperatorSet();
    /// @dev Thrown when a strategy is referenced that does not belong to an operator set.
    error StrategyNotInOperatorSet();

    /// Modifying Allocations

    /// @dev Thrown when an operator attempts to set their allocation for an operatorSet to the same value
    error SameMagnitude();
    /// @dev Thrown when an allocation is attempted for a given operator when they have pending allocations or deallocations.
    error ModificationAlreadyPending();
    /// @dev Thrown when an allocation is attempted that exceeds a given operators total allocatable magnitude.
    error InsufficientMagnitude();
}

interface IAllocationManagerTypes {
    /**
     * @notice Defines allocation information from a strategy to an operator set, for an operator
     * @param currentMagnitude the current magnitude allocated from the strategy to the operator set
     * @param pendingDiff a pending change in magnitude, if it exists (0 otherwise)
     * @param effectBlock the block at which the pending magnitude diff will take effect
     */
    struct Allocation {
        uint64 currentMagnitude;
        int128 pendingDiff;
        uint32 effectBlock;
    }

    /**
     * @notice Struct containing allocation delay metadata for a given operator.
     * @param delay Current allocation delay
     * @param isSet Whether the operator has initially set an allocation delay. Note that this could be false but the
     * block.number >= effectBlock in which we consider their delay to be configured and active.
     * @param pendingDelay The delay that will take effect after `effectBlock`
     * @param effectBlock The block number after which a pending delay will take effect
     */
    struct AllocationDelayInfo {
        uint32 delay;
        bool isSet;
        uint32 pendingDelay;
        uint32 effectBlock;
    }

    /**
     * @notice Contains registration details for an operator pertaining to an operator set
     * @param registered Whether the operator is currently registered for the operator set
     * @param slashableUntil If the operator is not registered, they are still slashable until
     * this block is reached.
     */
    struct RegistrationStatus {
        bool registered;
        uint32 slashableUntil;
    }

    /**
     * @notice Contains allocation info for a specific strategy
     * @param maxMagnitude the maximum magnitude that can be allocated between all operator sets
     * @param encumberedMagnitude the currently-allocated magnitude for the strategy
     */
    struct StrategyInfo {
        uint64 maxMagnitude;
        uint64 encumberedMagnitude;
    }

    /**
     * @notice Struct containing parameters to slashing
     * @param operator the address to slash
     * @param operatorSetId the ID of the operatorSet the operator is being slashed on behalf of
     * @param strategies the set of strategies to slash
     * @param wadsToSlash the parts in 1e18 to slash, this will be proportional to the operator's
     * slashable stake allocation for the operatorSet
     * @param description the description of the slashing provided by the AVS for legibility
     */
    struct SlashingParams {
        address operator;
        uint32 operatorSetId;
        IStrategy[] strategies;
        uint256[] wadsToSlash;
        string description;
    }

    /**
     * @notice struct used to modify the allocation of slashable magnitude to an operator set
     * @param operatorSet the operator set to modify the allocation for
     * @param strategies the strategies to modify allocations for
     * @param newMagnitudes the new magnitude to allocate for each strategy to this operator set
     */
    struct AllocateParams {
        OperatorSet operatorSet;
        IStrategy[] strategies;
        uint64[] newMagnitudes;
    }

    /**
     * @notice Parameters used to register for an AVS's operator sets
     * @param avs the AVS being registered for
     * @param operatorSetIds the operator sets within the AVS to register for
     * @param data extra data to be passed to the AVS to complete registration
     */
    struct RegisterParams {
        address avs;
        uint32[] operatorSetIds;
        bytes data;
    }

    /**
     * @notice Parameters used to deregister from an AVS's operator sets
     * @param operator the operator being deregistered
     * @param avs the avs being deregistered from
     * @param operatorSetIds the operator sets within the AVS being deregistered from
     */
    struct DeregisterParams {
        address operator;
        address avs;
        uint32[] operatorSetIds;
    }

    /**
     * @notice Parameters used by an AVS to create new operator sets
     * @param operatorSetId the id of the operator set to create
     * @param strategies the strategies to add as slashable to the operator set
     */
    struct CreateSetParams {
        uint32 operatorSetId;
        IStrategy[] strategies;
    }
}

interface IAllocationManagerEvents is IAllocationManagerTypes {
    /// @notice Emitted when operator updates their allocation delay.
    event AllocationDelaySet(address operator, uint32 delay, uint32 effectBlock);

    /// @notice Emitted when an operator's magnitude is updated for a given operatorSet and strategy
    event AllocationUpdated(
        address operator, OperatorSet operatorSet, IStrategy strategy, uint64 magnitude, uint32 effectBlock
    );

    /// @notice Emitted when operator's encumbered magnitude is updated for a given strategy
    event EncumberedMagnitudeUpdated(address operator, IStrategy strategy, uint64 encumberedMagnitude);

    /// @notice Emitted when an operator's max magnitude is updated for a given strategy
    event MaxMagnitudeUpdated(address operator, IStrategy strategy, uint64 maxMagnitude);

    /// @notice Emitted when an operator is slashed by an operator set for a strategy
    /// `wadSlashed` is the proportion of the operator's total delegated stake that was slashed
    event OperatorSlashed(
        address operator, OperatorSet operatorSet, IStrategy[] strategies, uint256[] wadSlashed, string description
    );

    /// @notice Emitted when an AVS configures the address that will handle registration/deregistration
    event AVSRegistrarSet(address avs, IAVSRegistrar registrar);

    /// @notice Emitted when an AVS updates their metadata URI (Uniform Resource Identifier).
    /// @dev The URI is never stored; it is simply emitted through an event for off-chain indexing.
    event AVSMetadataURIUpdated(address indexed avs, string metadataURI);

    /// @notice Emitted when an operator set is created by an AVS.
    event OperatorSetCreated(OperatorSet operatorSet);

    /// @notice Emitted when an operator is added to an operator set.
    event OperatorAddedToOperatorSet(address indexed operator, OperatorSet operatorSet);

    /// @notice Emitted when an operator is removed from an operator set.
    event OperatorRemovedFromOperatorSet(address indexed operator, OperatorSet operatorSet);

    /// @notice Emitted when a strategy is added to an operator set.
    event StrategyAddedToOperatorSet(OperatorSet operatorSet, IStrategy strategy);

    /// @notice Emitted when a strategy is removed from an operator set.
    event StrategyRemovedFromOperatorSet(OperatorSet operatorSet, IStrategy strategy);
}

interface IAllocationManager is IAllocationManagerErrors, IAllocationManagerEvents, ISemVerMixin {
    /**
     * @dev Initializes the initial owner and paused status.
     */
    function initialize(address initialOwner, uint256 initialPausedStatus) external;

    /**
     * @notice Called by an AVS to slash an operator in a given operator set. The operator must be registered
     * and have slashable stake allocated to the operator set.
     *
     * @param avs The AVS address initiating the slash.
     * @param params The slashing parameters, containing:
     *  - operator: The operator to slash.
     *  - operatorSetId: The ID of the operator set the operator is being slashed from.
     *  - strategies: Array of strategies to slash allocations from (must be in ascending order).
     *  - wadsToSlash: Array of proportions to slash from each strategy (must be between 0 and 1e18).
     *  - description: Description of why the operator was slashed.
     *
     * @dev For each strategy:
     *      1. Reduces the operator's current allocation magnitude by wadToSlash proportion.
     *      2. Reduces the strategy's max and encumbered magnitudes proportionally.
     *      3. If there is a pending deallocation, reduces it proportionally.
     *      4. Updates the operator's shares in the DelegationManager.
     *
     * @dev Small slashing amounts may not result in actual token burns due to
     *      rounding, which will result in small amounts of tokens locked in the contract
     *      rather than fully burning through the burn mechanism.
     */
    function slashOperator(address avs, SlashingParams calldata params) external;

    /**
     * @notice Modifies the proportions of slashable stake allocated to an operator set from a list of strategies
     * Note that deallocations remain slashable for DEALLOCATION_DELAY blocks therefore when they are cleared they may
     * free up less allocatable magnitude than initially deallocated.
     * @param operator the operator to modify allocations for
     * @param params array of magnitude adjustments for one or more operator sets
     * @dev Updates encumberedMagnitude for the updated strategies
     */
    function modifyAllocations(address operator, AllocateParams[] calldata params) external;

    /**
     * @notice This function takes a list of strategies and for each strategy, removes from the deallocationQueue
     * all clearable deallocations up to max `numToClear` number of deallocations, updating the encumberedMagnitude
     * of the operator as needed.
     *
     * @param operator address to clear deallocations for
     * @param strategies a list of strategies to clear deallocations for
     * @param numToClear a list of number of pending deallocations to clear for each strategy
     *
     * @dev can be called permissionlessly by anyone
     */
    function clearDeallocationQueue(
        address operator,
        IStrategy[] calldata strategies,
        uint16[] calldata numToClear
    ) external;

    /**
     * @notice Allows an operator to register for one or more operator sets for an AVS. If the operator
     * has any stake allocated to these operator sets, it immediately becomes slashable.
     * @dev After registering within the ALM, this method calls the AVS Registrar's `IAVSRegistrar.
     * registerOperator` method to complete registration. This call MUST succeed in order for
     * registration to be successful.
     */
    function registerForOperatorSets(address operator, RegisterParams calldata params) external;

    /**
     * @notice Allows an operator or AVS to deregister the operator from one or more of the AVS's operator sets.
     * If the operator has any slashable stake allocated to the AVS, it remains slashable until the
     * DEALLOCATION_DELAY has passed.
     * @dev After deregistering within the ALM, this method calls the AVS Registrar's `IAVSRegistrar.
     * deregisterOperator` method to complete deregistration. This call MUST succeed in order for
     * deregistration to be successful.
     */
    function deregisterFromOperatorSets(
        DeregisterParams calldata params
    ) external;

    /**
     * @notice Called by the delegation manager OR an operator to set an operator's allocation delay.
     * This is set when the operator first registers, and is the number of blocks between an operator
     * allocating magnitude to an operator set, and the magnitude becoming slashable.
     * @param operator The operator to set the delay on behalf of.
     * @param delay the allocation delay in blocks
     */
    function setAllocationDelay(address operator, uint32 delay) external;

    /**
     * @notice Called by an AVS to configure the address that is called when an operator registers
     * or is deregistered from the AVS's operator sets. If not set (or set to 0), defaults
     * to the AVS's address.
     * @param registrar the new registrar address
     */
    function setAVSRegistrar(address avs, IAVSRegistrar registrar) external;

    /**
     *  @notice Called by an AVS to emit an `AVSMetadataURIUpdated` event indicating the information has updated.
     *
     *  @param metadataURI The URI for metadata associated with an AVS.
     *
     *  @dev Note that the `metadataURI` is *never stored* and is only emitted in the `AVSMetadataURIUpdated` event.
     */
    function updateAVSMetadataURI(address avs, string calldata metadataURI) external;

    /**
     * @notice Allows an AVS to create new operator sets, defining strategies that the operator set uses
     */
    function createOperatorSets(address avs, CreateSetParams[] calldata params) external;

    /**
     * @notice Allows an AVS to add strategies to an operator set
     * @dev Strategies MUST NOT already exist in the operator set
     * @param avs the avs to set strategies for
     * @param operatorSetId the operator set to add strategies to
     * @param strategies the strategies to add
     */
    function addStrategiesToOperatorSet(address avs, uint32 operatorSetId, IStrategy[] calldata strategies) external;

    /**
     * @notice Allows an AVS to remove strategies from an operator set
     * @dev Strategies MUST already exist in the operator set
     * @param avs the avs to remove strategies for
     * @param operatorSetId the operator set to remove strategies from
     * @param strategies the strategies to remove
     */
    function removeStrategiesFromOperatorSet(
        address avs,
        uint32 operatorSetId,
        IStrategy[] calldata strategies
    ) external;

    /**
     *
     *                         VIEW FUNCTIONS
     *
     */

    /**
     * @notice Returns the number of operator sets for the AVS
     * @param avs the AVS to query
     */
    function getOperatorSetCount(
        address avs
    ) external view returns (uint256);

    /**
     * @notice Returns the list of operator sets the operator has current or pending allocations/deallocations in
     * @param operator the operator to query
     * @return the list of operator sets the operator has current or pending allocations/deallocations in
     */
    function getAllocatedSets(
        address operator
    ) external view returns (OperatorSet[] memory);

    /**
     * @notice Returns the list of strategies an operator has current or pending allocations/deallocations from
     * given a specific operator set.
     * @param operator the operator to query
     * @param operatorSet the operator set to query
     * @return the list of strategies
     */
    function getAllocatedStrategies(
        address operator,
        OperatorSet memory operatorSet
    ) external view returns (IStrategy[] memory);

    /**
     * @notice Returns the current/pending stake allocation an operator has from a strategy to an operator set
     * @param operator the operator to query
     * @param operatorSet the operator set to query
     * @param strategy the strategy to query
     * @return the current/pending stake allocation
     */
    function getAllocation(
        address operator,
        OperatorSet memory operatorSet,
        IStrategy strategy
    ) external view returns (Allocation memory);

    /**
     * @notice Returns the current/pending stake allocations for multiple operators from a strategy to an operator set
     * @param operators the operators to query
     * @param operatorSet the operator set to query
     * @param strategy the strategy to query
     * @return each operator's allocation
     */
    function getAllocations(
        address[] memory operators,
        OperatorSet memory operatorSet,
        IStrategy strategy
    ) external view returns (Allocation[] memory);

    /**
     * @notice Given a strategy, returns a list of operator sets and corresponding stake allocations.
     * @dev Note that this returns a list of ALL operator sets the operator has allocations in. This means
     * some of the returned allocations may be zero.
     * @param operator the operator to query
     * @param strategy the strategy to query
     * @return the list of all operator sets the operator has allocations for
     * @return the corresponding list of allocations from the specific `strategy`
     */
    function getStrategyAllocations(
        address operator,
        IStrategy strategy
    ) external view returns (OperatorSet[] memory, Allocation[] memory);

    /**
     * @notice For a strategy, get the amount of magnitude that is allocated across one or more operator sets
     * @param operator the operator to query
     * @param strategy the strategy to get allocatable magnitude for
     * @return currently allocated magnitude
     */
    function getEncumberedMagnitude(address operator, IStrategy strategy) external view returns (uint64);

    /**
     * @notice For a strategy, get the amount of magnitude not currently allocated to any operator set
     * @param operator the operator to query
     * @param strategy the strategy to get allocatable magnitude for
     * @return magnitude available to be allocated to an operator set
     */
    function getAllocatableMagnitude(address operator, IStrategy strategy) external view returns (uint64);

    /**
     * @notice Returns the maximum magnitude an operator can allocate for the given strategy
     * @dev The max magnitude of an operator starts at WAD (1e18), and is decreased anytime
     * the operator is slashed. This value acts as a cap on the max magnitude of the operator.
     * @param operator the operator to query
     * @param strategy the strategy to get the max magnitude for
     * @return the max magnitude for the strategy
     */
    function getMaxMagnitude(address operator, IStrategy strategy) external view returns (uint64);

    /**
     * @notice Returns the maximum magnitude an operator can allocate for the given strategies
     * @dev The max magnitude of an operator starts at WAD (1e18), and is decreased anytime
     * the operator is slashed. This value acts as a cap on the max magnitude of the operator.
     * @param operator the operator to query
     * @param strategies the strategies to get the max magnitudes for
     * @return the max magnitudes for each strategy
     */
    function getMaxMagnitudes(
        address operator,
        IStrategy[] calldata strategies
    ) external view returns (uint64[] memory);

    /**
     * @notice Returns the maximum magnitudes each operator can allocate for the given strategy
     * @dev The max magnitude of an operator starts at WAD (1e18), and is decreased anytime
     * the operator is slashed. This value acts as a cap on the max magnitude of the operator.
     * @param operators the operators to query
     * @param strategy the strategy to get the max magnitudes for
     * @return the max magnitudes for each operator
     */
    function getMaxMagnitudes(
        address[] calldata operators,
        IStrategy strategy
    ) external view returns (uint64[] memory);

    /**
     * @notice Returns the maximum magnitude an operator can allocate for the given strategies
     * at a given block number
     * @dev The max magnitude of an operator starts at WAD (1e18), and is decreased anytime
     * the operator is slashed. This value acts as a cap on the max magnitude of the operator.
     * @param operator the operator to query
     * @param strategies the strategies to get the max magnitudes for
     * @param blockNumber the blockNumber at which to check the max magnitudes
     * @return the max magnitudes for each strategy
     */
    function getMaxMagnitudesAtBlock(
        address operator,
        IStrategy[] calldata strategies,
        uint32 blockNumber
    ) external view returns (uint64[] memory);

    /**
     * @notice Returns the time in blocks between an operator allocating slashable magnitude
     * and the magnitude becoming slashable. If the delay has not been set, `isSet` will be false.
     * @dev The operator must have a configured delay before allocating magnitude
     * @param operator The operator to query
     * @return isSet Whether the operator has configured a delay
     * @return delay The time in blocks between allocating magnitude and magnitude becoming slashable
     */
    function getAllocationDelay(
        address operator
    ) external view returns (bool isSet, uint32 delay);

    /**
     * @notice Returns a list of all operator sets the operator is registered for
     * @param operator The operator address to query.
     */
    function getRegisteredSets(
        address operator
    ) external view returns (OperatorSet[] memory operatorSets);

    /**
     * @notice Returns whether the operator is registered for the operator set
     * @param operator The operator to query
     * @param operatorSet The operator set to query
     */
    function isMemberOfOperatorSet(address operator, OperatorSet memory operatorSet) external view returns (bool);

    /**
     * @notice Returns whether the operator set exists
     */
    function isOperatorSet(
        OperatorSet memory operatorSet
    ) external view returns (bool);

    /**
     * @notice Returns all the operators registered to an operator set
     * @param operatorSet The operatorSet to query.
     */
    function getMembers(
        OperatorSet memory operatorSet
    ) external view returns (address[] memory operators);

    /**
     * @notice Returns the number of operators registered to an operatorSet.
     * @param operatorSet The operatorSet to get the member count for
     */
    function getMemberCount(
        OperatorSet memory operatorSet
    ) external view returns (uint256);

    /**
     * @notice Returns the address that handles registration/deregistration for the AVS
     * If not set, defaults to the input address (`avs`)
     */
    function getAVSRegistrar(
        address avs
    ) external view returns (IAVSRegistrar);

    /**
     * @notice Returns an array of strategies in the operatorSet.
     * @param operatorSet The operatorSet to query.
     */
    function getStrategiesInOperatorSet(
        OperatorSet memory operatorSet
    ) external view returns (IStrategy[] memory strategies);

    /**
     * @notice Returns the minimum amount of stake that will be slashable as of some future block,
     * according to each operator's allocation from each strategy to the operator set. Note that this function
     * will return 0 for the slashable stake if the operator is not slashable at the time of the call.
     * @dev This method queries actual delegated stakes in the DelegationManager and applies
     * each operator's allocation to the stake to produce the slashable stake each allocation
     * represents. This method does not consider slashable stake in the withdrawal queue even though there could be
     * slashable stake in the queue.
     * @dev This minimum takes into account `futureBlock`, and will omit any pending magnitude
     * diffs that will not be in effect as of `futureBlock`. NOTE that in order to get the true
     * minimum slashable stake as of some future block, `futureBlock` MUST be greater than block.number
     * @dev NOTE that `futureBlock` should be fewer than `DEALLOCATION_DELAY` blocks in the future,
     * or the values returned from this method may not be accurate due to deallocations.
     * @param operatorSet the operator set to query
     * @param operators the list of operators whose slashable stakes will be returned
     * @param strategies the strategies that each slashable stake corresponds to
     * @param futureBlock the block at which to get allocation information. Should be a future block.
     */
    function getMinimumSlashableStake(
        OperatorSet memory operatorSet,
        address[] memory operators,
        IStrategy[] memory strategies,
        uint32 futureBlock
    ) external view returns (uint256[][] memory slashableStake);

    /**
     * @notice Returns the current allocated stake, irrespective of the operator's slashable status for the operatorSet.
     * @param operatorSet the operator set to query
     * @param operators the operators to query
     * @param strategies the strategies to query
     */
    function getAllocatedStake(
        OperatorSet memory operatorSet,
        address[] memory operators,
        IStrategy[] memory strategies
    ) external view returns (uint256[][] memory slashableStake);

    /**
     * @notice Returns whether an operator is slashable by an operator set.
     * This returns true if the operator is registered or their slashableUntil block has not passed.
     * This is because even when operators are deregistered, they still remain slashable for a period of time.
     * @param operator the operator to check slashability for
     * @param operatorSet the operator set to check slashability for
     */
    function isOperatorSlashable(address operator, OperatorSet memory operatorSet) external view returns (bool);
}

// lib/eigenlayer-middleware/src/interfaces/IStakeRegistry.sol

/// @notice Interface containing all error definitions for the StakeRegistry contract.
interface IStakeRegistryErrors {
    /// @dev Thrown when the caller is not the registry coordinator
    error OnlySlashingRegistryCoordinator();
    /// @dev Thrown when the caller is not the owner of the registry coordinator
    error OnlySlashingRegistryCoordinatorOwner();
    /// @dev Thrown when the stake is below the minimum required for a quorum
    error BelowMinimumStakeRequirement();
    /// @notice Thrown when attempting to create a quorum that already exists.
    error QuorumAlreadyExists();
    /// @notice Thrown when attempting to interact with a quorum that does not exist.
    error QuorumDoesNotExist();
    /// @notice Thrown when two array parameters have mismatching lengths.
    error InputArrayLengthMismatch();
    /// @notice Thrown when an input array has zero length.
    error InputArrayLengthZero();
    /// @notice Thrown when a duplicate strategy is provided in an input array.
    error InputDuplicateStrategy();
    /// @notice Thrown when a multiplier input is zero.
    error InputMultiplierZero();
    /// @notice Thrown when the provided block number is invalid for the stake update.
    error InvalidBlockNumber();
    /// @notice Thrown when attempting to access stake history that doesn't exist for a quorum.
    error EmptyStakeHistory();
    /// @notice Thrown when the quorum is not slashable and the caller attempts to set the look ahead period.
    error QuorumNotSlashable();
    /// @notice Thrown when the look ahead period is too long.
    error LookAheadPeriodTooLong();
}

interface IStakeRegistryTypes {
    /// @notice Defines the type of stake being tracked.
    /// @param TOTAL_DELEGATED Represents the total delegated stake.
    /// @param TOTAL_SLASHABLE Represents the total slashable stake.
    enum StakeType {
        TOTAL_DELEGATED,
        TOTAL_SLASHABLE
    }

    /// @notice Stores stake information for an operator or total stakes at a specific block.
    /// @param updateBlockNumber The block number at which the stake amounts were updated.
    /// @param nextUpdateBlockNumber The block number at which the next update occurred (0 if no next update).
    /// @param stake The stake weight for the quorum.
    struct StakeUpdate {
        uint32 updateBlockNumber;
        uint32 nextUpdateBlockNumber;
        uint96 stake;
    }

    /// @notice Parameters for weighing a particular strategy's stake.
    /// @param strategy The strategy contract address.
    /// @param multiplier The weight multiplier applied to the strategy's stake.
    struct StrategyParams {
        IStrategy strategy;
        uint96 multiplier;
    }
}

interface IStakeRegistryEvents is IStakeRegistryTypes {
    /**
     * @notice Emitted when an operator's stake is updated.
     * @param operatorId The unique identifier of the operator (indexed).
     * @param quorumNumber The quorum number for which the stake was updated.
     * @param stake The new stake amount.
     */
    event OperatorStakeUpdate(bytes32 indexed operatorId, uint8 quorumNumber, uint96 stake);

    /**
     * @notice Emitted when the look ahead period for checking operator shares is updated.
     * @param oldLookAheadBlocks The previous look ahead period.
     * @param newLookAheadBlocks The new look ahead period.
     */
    event LookAheadPeriodChanged(uint32 oldLookAheadBlocks, uint32 newLookAheadBlocks);

    /**
     * @notice Emitted when the stake type is updated.
     * @param newStakeType The new stake type being set.
     */
    event StakeTypeSet(StakeType newStakeType);

    /**
     * @notice Emitted when the minimum stake for a quorum is updated.
     * @param quorumNumber The quorum number being updated (indexed).
     * @param minimumStake The new minimum stake requirement.
     */
    event MinimumStakeForQuorumUpdated(uint8 indexed quorumNumber, uint96 minimumStake);

    /**
     * @notice Emitted when a new quorum is created.
     * @param quorumNumber The number of the newly created quorum (indexed).
     */
    event QuorumCreated(uint8 indexed quorumNumber);

    /**
     * @notice Emitted when a strategy is added to a quorum.
     * @param quorumNumber The quorum number the strategy was added to (indexed).
     * @param strategy The strategy contract that was added.
     */
    event StrategyAddedToQuorum(uint8 indexed quorumNumber, IStrategy strategy);

    /**
     * @notice Emitted when a strategy is removed from a quorum.
     * @param quorumNumber The quorum number the strategy was removed from (indexed).
     * @param strategy The strategy contract that was removed.
     */
    event StrategyRemovedFromQuorum(uint8 indexed quorumNumber, IStrategy strategy);

    /**
     * @notice Emitted when a strategy's multiplier is updated.
     * @param quorumNumber The quorum number for the strategy update (indexed).
     * @param strategy The strategy contract being updated.
     * @param multiplier The new multiplier value.
     */
    event StrategyMultiplierUpdated(
        uint8 indexed quorumNumber, IStrategy strategy, uint256 multiplier
    );
}

interface IStakeRegistry is IStakeRegistryErrors, IStakeRegistryEvents {
    /// STATE

    /**
     * @notice Returns the EigenLayer delegation manager contract.
     */
    function delegation() external view returns (IDelegationManager);

    /// ACTIONS

    /**
     * @notice Registers the `operator` with `operatorId` for the specified `quorumNumbers`.
     * @param operator The address of the operator to register.
     * @param operatorId The id of the operator to register.
     * @param quorumNumbers The quorum numbers the operator is registering for, where each byte is an 8 bit integer quorumNumber.
     * @return operatorStakes The operator's current stake for each quorum.
     * @return totalStakes The total stake for each quorum.
     * @dev Access restricted to the RegistryCoordinator.
     * @dev Preconditions (these are assumed, not validated in this contract):
     *     1) `quorumNumbers` has no duplicates.
     *     2) `quorumNumbers.length` != 0.
     *     3) `quorumNumbers` is ordered in ascending order.
     *     4) The operator is not already registered.
     */
    function registerOperator(
        address operator,
        bytes32 operatorId,
        bytes memory quorumNumbers
    ) external returns (uint96[] memory operatorStakes, uint96[] memory totalStakes);

    /**
     * @notice Deregisters the operator with `operatorId` for the specified `quorumNumbers`.
     * @param operatorId The id of the operator to deregister.
     * @param quorumNumbers The quorum numbers the operator is deregistering from, where each byte is an 8 bit integer quorumNumber.
     * @dev Access restricted to the RegistryCoordinator.
     * @dev Preconditions (these are assumed, not validated in this contract):
     *     1) `quorumNumbers` has no duplicates.
     *     2) `quorumNumbers.length` != 0.
     *     3) `quorumNumbers` is ordered in ascending order.
     *     4) The operator is not already deregistered.
     *     5) `quorumNumbers` is a subset of the quorumNumbers that the operator is registered for.
     */
    function deregisterOperator(bytes32 operatorId, bytes memory quorumNumbers) external;

    /**
     * @notice Called by the registry coordinator to update the stake of a list of operators for a specific quorum.
     * @param operators The addresses of the operators to update.
     * @param operatorIds The ids of the operators to update.
     * @param quorumNumber The quorum number to update the stake for.
     * @return A list of bools, true if the corresponding operator should be deregistered since they no longer meet the minimum stake requirement.
     */
    function updateOperatorsStake(
        address[] memory operators,
        bytes32[] memory operatorIds,
        uint8 quorumNumber
    ) external returns (bool[] memory);

    /**
     * @notice Initialize a new quorum created by the registry coordinator by setting strategies, weights, and minimum stake.
     * @param quorumNumber The number of the quorum to initialize.
     * @param minimumStake The minimum stake required for the quorum.
     * @param strategyParams The initial strategy parameters for the quorum.
     */
    function initializeDelegatedStakeQuorum(
        uint8 quorumNumber,
        uint96 minimumStake,
        StrategyParams[] memory strategyParams
    ) external;

    /**
     * @notice Initialize a new quorum and push its first history update.
     * @param quorumNumber The number of the quorum to initialize.
     * @param minimumStake The minimum stake required for the quorum.
     * @param lookAheadPeriod The look ahead period for checking operator shares.
     * @param strategyParams The initial strategy parameters for the quorum.
     */
    function initializeSlashableStakeQuorum(
        uint8 quorumNumber,
        uint96 minimumStake,
        uint32 lookAheadPeriod,
        StrategyParams[] memory strategyParams
    ) external;

    /**
     * @notice Sets the minimum stake requirement for a quorum `quorumNumber`.
     * @param quorumNumber The quorum number to set the minimum stake for.
     * @param minimumStake The new minimum stake requirement.
     */
    function setMinimumStakeForQuorum(uint8 quorumNumber, uint96 minimumStake) external;

    /**
     * @notice Sets the look ahead time to `lookAheadBlocks` for checking operator shares for a specific quorum.
     * @param quorumNumber The quorum number to set the look ahead period for.
     * @param lookAheadBlocks The number of blocks to look ahead when checking shares.
     */
    function setSlashableStakeLookahead(uint8 quorumNumber, uint32 lookAheadBlocks) external;

    /**
     * @notice Adds new strategies and their associated multipliers to the specified quorum.
     * @dev Checks to make sure that the *same* strategy cannot be added multiple times (checks against both against existing and new strategies).
     * @dev This function has no check to make sure that the strategies for a single quorum have the same underlying asset. This is a concious choice,
     * since a middleware may want, e.g., a stablecoin quorum that accepts USDC, USDT, DAI, etc. as underlying assets and trades them as "equivalent".
     * @param quorumNumber The quorum number to add strategies to.
     * @param strategyParams The strategy parameters to add.
     */
    function addStrategies(uint8 quorumNumber, StrategyParams[] memory strategyParams) external;

    /**
     * @notice Removes strategies and their associated weights from the specified quorum.
     * @param quorumNumber The quorum number to remove strategies from.
     * @param indicesToRemove The indices of strategies to remove.
     * @dev Higher indices should be *first* in the list of `indicesToRemove`, since otherwise
     *     the removal of lower index entries will cause a shift in the indices of the other strategiesToRemove.
     */
    function removeStrategies(uint8 quorumNumber, uint256[] calldata indicesToRemove) external;

    /**
     * @notice Modifies the weights of strategies that are already in the mapping strategyParams.
     * @param quorumNumber The quorum number to change the strategy for.
     * @param strategyIndices The indices of the strategies to change.
     * @param newMultipliers The new multipliers for the strategies.
     */
    function modifyStrategyParams(
        uint8 quorumNumber,
        uint256[] calldata strategyIndices,
        uint96[] calldata newMultipliers
    ) external;

    /// VIEW

    /**
     * @notice Returns the minimum stake requirement for a quorum `quorumNumber`.
     * @dev In order to register for a quorum i, an operator must have at least `minimumStakeForQuorum[i]`.
     * @param quorumNumber The quorum number to query.
     * @return The minimum stake requirement.
     */
    function minimumStakeForQuorum(
        uint8 quorumNumber
    ) external view returns (uint96);

    /**
     * @notice Returns the length of the dynamic array stored in `strategyParams[quorumNumber]`.
     * @param quorumNumber The quorum number to query.
     * @return The number of strategies for the quorum.
     */
    function strategyParamsLength(
        uint8 quorumNumber
    ) external view returns (uint256);

    /**
     * @notice Returns the strategy and weight multiplier for the `index`'th strategy in the quorum.
     * @param quorumNumber The quorum number to query.
     * @param index The index of the strategy to query.
     * @return The strategy parameters.
     */
    function strategyParamsByIndex(
        uint8 quorumNumber,
        uint256 index
    ) external view returns (StrategyParams memory);

    /**
     * @notice Returns the length of the stake history for an operator in a quorum.
     * @param operatorId The id of the operator to query.
     * @param quorumNumber The quorum number to query.
     * @return The length of the stake history array.
     */
    function getStakeHistoryLength(
        bytes32 operatorId,
        uint8 quorumNumber
    ) external view returns (uint256);

    /**
     * @notice Computes the total weight of the operator in the specified quorum.
     * @param quorumNumber The quorum number to query.
     * @param operator The operator address to query.
     * @return The total weight of the operator.
     * @dev Reverts if `quorumNumber` is greater than or equal to `quorumCount`.
     */
    function weightOfOperatorForQuorum(
        uint8 quorumNumber,
        address operator
    ) external view returns (uint96);

    /**
     * @notice Returns the entire stake history array for an operator in a quorum.
     * @param operatorId The id of the operator of interest.
     * @param quorumNumber The quorum number to get the stake for.
     * @return The array of stake updates.
     */
    function getStakeHistory(
        bytes32 operatorId,
        uint8 quorumNumber
    ) external view returns (StakeUpdate[] memory);

    /**
     * @notice Returns the length of the total stake history for a quorum.
     * @param quorumNumber The quorum number to query.
     * @return The length of the total stake history array.
     */
    function getTotalStakeHistoryLength(
        uint8 quorumNumber
    ) external view returns (uint256);

    /**
     * @notice Returns the stake update at the specified index in the total stake history.
     * @param quorumNumber The quorum number to query.
     * @param index The index to query.
     * @return The stake update at the specified index.
     */
    function getTotalStakeUpdateAtIndex(
        uint8 quorumNumber,
        uint256 index
    ) external view returns (StakeUpdate memory);

    /**
     * @notice Returns the index of the operator's stake update at the specified block number.
     * @param operatorId The id of the operator to query.
     * @param quorumNumber The quorum number to query.
     * @param blockNumber The block number to query.
     * @return The index of the stake update.
     */
    function getStakeUpdateIndexAtBlockNumber(
        bytes32 operatorId,
        uint8 quorumNumber,
        uint32 blockNumber
    ) external view returns (uint32);

    /**
     * @notice Returns the indices of total stakes for the provided quorums at the given block number.
     * @param blockNumber The block number to query.
     * @param quorumNumbers The quorum numbers to query.
     * @return The array of stake update indices.
     */
    function getTotalStakeIndicesAtBlockNumber(
        uint32 blockNumber,
        bytes calldata quorumNumbers
    ) external view returns (uint32[] memory);

    /**
     * @notice Returns the stake update at the specified index for an operator in a quorum.
     * @param quorumNumber The quorum number to query.
     * @param operatorId The id of the operator to query.
     * @param index The index to query.
     * @return The stake update at the specified index.
     * @dev Function will revert if `index` is out-of-bounds.
     */
    function getStakeUpdateAtIndex(
        uint8 quorumNumber,
        bytes32 operatorId,
        uint256 index
    ) external view returns (StakeUpdate memory);

    /**
     * @notice Returns the most recent stake update for an operator in a quorum.
     * @param operatorId The id of the operator to query.
     * @param quorumNumber The quorum number to query.
     * @return The most recent stake update.
     * @dev Returns a StakeUpdate struct with all entries equal to 0 if the operator has no stake history.
     */
    function getLatestStakeUpdate(
        bytes32 operatorId,
        uint8 quorumNumber
    ) external view returns (StakeUpdate memory);

    /**
     * @notice Returns the stake at the specified block number and index for an operator in a quorum.
     * @param quorumNumber The quorum number to query.
     * @param blockNumber The block number to query.
     * @param operatorId The id of the operator to query.
     * @param index The index to query.
     * @return The stake amount.
     * @dev Function will revert if `index` is out-of-bounds.
     * @dev Used by the BLSSignatureChecker to get past stakes of signing operators.
     */
    function getStakeAtBlockNumberAndIndex(
        uint8 quorumNumber,
        uint32 blockNumber,
        bytes32 operatorId,
        uint256 index
    ) external view returns (uint96);

    /**
     * @notice Returns the total stake at the specified block number and index for a quorum.
     * @param quorumNumber The quorum number to query.
     * @param blockNumber The block number to query.
     * @param index The index to query.
     * @return The total stake amount.
     * @dev Function will revert if `index` is out-of-bounds.
     * @dev Used by the BLSSignatureChecker to get past stakes of signing operators.
     */
    function getTotalStakeAtBlockNumberFromIndex(
        uint8 quorumNumber,
        uint32 blockNumber,
        uint256 index
    ) external view returns (uint96);

    /**
     * @notice Returns the current stake for an operator in a quorum.
     * @param operatorId The id of the operator to query.
     * @param quorumNumber The quorum number to query.
     * @return The current stake amount.
     * @dev Returns 0 if the operator has no stake history.
     */
    function getCurrentStake(
        bytes32 operatorId,
        uint8 quorumNumber
    ) external view returns (uint96);

    /**
     * @notice Returns the stake of an operator at a specific block number.
     * @param operatorId The id of the operator to query.
     * @param quorumNumber The quorum number to query.
     * @param blockNumber The block number to query.
     * @return The stake amount at the specified block.
     */
    function getStakeAtBlockNumber(
        bytes32 operatorId,
        uint8 quorumNumber,
        uint32 blockNumber
    ) external view returns (uint96);

    /**
     * @notice Returns the current total stake for a quorum.
     * @param quorumNumber The quorum number to query.
     * @return The current total stake amount.
     * @dev Will revert if `_totalStakeHistory[quorumNumber]` is empty.
     */
    function getCurrentTotalStake(
        uint8 quorumNumber
    ) external view returns (uint96);
}

// lib/eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol

interface ISlashingRegistryCoordinatorErrors {
    /// @notice Thrown when array lengths in input parameters don't match.
    error InputLengthMismatch();
    /// @notice Thrown when an invalid registration type is provided.
    error InvalidRegistrationType();
    /// @notice Thrown when non-allocation manager calls restricted function.
    error OnlyAllocationManager();
    /// @notice Thrown when non-ejector calls restricted function.
    error OnlyEjector();
    /// @notice Thrown when operating on a non-existent quorum.
    error QuorumDoesNotExist();
    /// @notice Thrown when registering/deregistering with empty bitmap.
    error BitmapEmpty();
    /// @notice Thrown when registering for already registered quorums.
    error AlreadyRegisteredForQuorums();
    /// @notice Thrown when registering before ejection cooldown expires.
    error CannotReregisterYet();
    /// @notice Thrown when unregistered operator attempts restricted operation.
    error NotRegistered();
    /// @notice Thrown when operator attempts self-churn.
    error CannotChurnSelf();
    /// @notice Thrown when operator count doesn't match quorum requirements.
    error QuorumOperatorCountMismatch();
    /// @notice Thrown when operator has insufficient stake for churn.
    error InsufficientStakeForChurn();
    /// @notice Thrown when attempting to kick operator above stake threshold.
    error CannotKickOperatorAboveThreshold();
    /// @notice Thrown when updating to zero bitmap.
    error BitmapCannotBeZero();
    /// @notice Thrown when deregistering from unregistered quorum.
    error NotRegisteredForQuorum();
    /// @notice Thrown when churn approver salt is already used.
    error ChurnApproverSaltUsed();
    /// @notice Thrown when operators or quorums list is not sorted ascending.
    error NotSorted();
    /// @notice Thrown when maximum quorum count is reached.
    error MaxQuorumsReached();
    /// @notice Thrown when the provided AVS address does not match the expected one.
    error InvalidAVS();
    /// @notice Thrown when attempting to kick an operator that is not registered.
    error OperatorNotRegistered();
    /// @notice Thrown when lookAheadPeriod is greater than or equal to DEALLOCATION_DELAY.
    error LookAheadPeriodTooLong();
    /// @notice Thrown when the number of operators in a quorum would exceed the maximum allowed.
    error MaxOperatorCountReached();
    /// @notice Thrown when the operator is not registered for the quorum.
    error OperatorNotRegisteredForQuorum();
}

interface ISlashingRegistryCoordinatorTypes {
    /// @notice Core data structure for tracking operator information.
    /// @dev Links an operator's unique identifier with their current registration status.
    /// @param operatorId Unique identifier for the operator, typically derived from their BLS public key.
    /// @param status Current registration state of the operator in the system.
    struct OperatorInfo {
        bytes32 operatorId;
        OperatorStatus status;
    }

    /// @notice Records historical changes to an operator's quorum registrations.
    /// @dev Used for querying an operator's quorum memberships at specific block numbers.
    /// @param updateBlockNumber Block number when this update occurred (inclusive).
    /// @param nextUpdateBlockNumber Block number when the next update occurred (exclusive), or 0 if this is the latest update.
    /// @param quorumBitmap Bitmap where each bit represents registration in a specific quorum (1 = registered, 0 = not registered).
    struct QuorumBitmapUpdate {
        uint32 updateBlockNumber;
        uint32 nextUpdateBlockNumber;
        uint192 quorumBitmap;
    }

    /// @notice Configuration parameters for operator management within a quorum.
    /// @dev All BIPs (Basis Points) values are in relation to BIPS_DENOMINATOR (10000).
    /// @param maxOperatorCount Maximum number of operators allowed in the quorum.
    /// @param kickBIPsOfOperatorStake Required stake ratio (in BIPs) between new and existing operator for churn.
    ///        Example: 10500 means new operator needs 105% of existing operator's stake.
    /// @param kickBIPsOfTotalStake Minimum stake ratio (in BIPs) of total quorum stake an operator must maintain.
    ///        Example: 100 means operator needs 1% of total quorum stake to avoid being churned.
    struct OperatorSetParam {
        uint32 maxOperatorCount;
        uint16 kickBIPsOfOperatorStake;
        uint16 kickBIPsOfTotalStake;
    }

    /// @notice Parameters for removing an operator during churn.
    /// @dev Used in registerOperatorWithChurn to specify which operator to replace.
    /// @param quorumNumber The quorum from which to remove the operator.
    /// @param operator Address of the operator to be removed.
    struct OperatorKickParam {
        uint8 quorumNumber;
        address operator;
    }

    /// @notice Represents the registration state of an operator.
    /// @dev Used to track an operator's lifecycle in the system.
    /// @custom:enum NEVER_REGISTERED The operator has never registered with the system.
    /// @custom:enum REGISTERED The operator is currently registered and active.
    /// @custom:enum DEREGISTERED The operator was previously registered but has since deregistered.
    enum OperatorStatus {
        NEVER_REGISTERED,
        REGISTERED,
        DEREGISTERED
    }

    /**
     * @notice Enum representing the type of operator registration.
     * @custom:enum NORMAL Represents a normal operator registration.
     * @custom:enum CHURN Represents an operator registration during a churn event.
     */
    enum RegistrationType {
        NORMAL,
        CHURN
    }

    /**
     * @notice Data structure for storing the results of a registerOperator call.
     * @dev Contains arrays storing per-quorum information about operator counts and stakes.
     * @param numOperatorsPerQuorum For each quorum the operator registered for, stores the number of operators registered.
     * @param operatorStakes For each quorum the operator registered for, stores the stake of the operator in the quorum.
     * @param totalStakes For each quorum the operator registered for, stores the total stake of the quorum.
     */
    struct RegisterResults {
        uint32[] numOperatorsPerQuorum;
        uint96[] operatorStakes;
        uint96[] totalStakes;
    }
}

interface ISlashingRegistryCoordinatorEvents is ISlashingRegistryCoordinatorTypes {
    /**
     * @notice Emitted when an operator registers for service in one or more quorums.
     * @dev Emitted in _registerOperator() and _registerOperatorToOperatorSet().
     * @param operator The address of the registered operator.
     * @param operatorId The unique identifier of the operator (BLS public key hash).
     */
    event OperatorRegistered(address indexed operator, bytes32 indexed operatorId);

    /**
     * @notice Emitted when an operator deregisters from service in one or more quorums.
     * @dev Emitted in _deregisterOperator().
     * @param operator The address of the deregistered operator.
     * @param operatorId The unique identifier of the operator (BLS public key hash).
     */
    event OperatorDeregistered(address indexed operator, bytes32 indexed operatorId);

    /**
     * @notice Emitted when a new quorum is created.
     * @param quorumNumber The identifier of the quorum being created.
     * @param operatorSetParams The operator set parameters for the quorum.
     * @param minimumStake The minimum stake required for operators in this quorum.
     * @param strategyParams The strategy parameters for stake calculation.
     * @param stakeType The type of stake being tracked (TOTAL_DELEGATED or TOTAL_SLASHABLE).
     * @param lookAheadPeriod The number of blocks to look ahead when calculating slashable stake (only used for TOTAL_SLASHABLE).
     */
    event QuorumCreated(
        uint8 indexed quorumNumber,
        OperatorSetParam operatorSetParams,
        uint96 minimumStake,
        IStakeRegistryTypes.StrategyParams[] strategyParams,
        IStakeRegistryTypes.StakeType stakeType,
        uint32 lookAheadPeriod
    );

    /**
     * @notice Emitted when a quorum's operator set parameters are updated.
     * @dev Emitted in _setOperatorSetParams().
     * @param quorumNumber The identifier of the quorum being updated.
     * @param operatorSetParams The new operator set parameters for the quorum.
     */
    event OperatorSetParamsUpdated(uint8 indexed quorumNumber, OperatorSetParam operatorSetParams);

    /**
     * @notice Emitted when the churn approver address is updated.
     * @dev Emitted in _setChurnApprover().
     * @param prevChurnApprover The previous churn approver address.
     * @param newChurnApprover The new churn approver address.
     */
    event ChurnApproverUpdated(address prevChurnApprover, address newChurnApprover);

    /**
     * @notice Emitted when the AVS address is updated.
     * @param prevAVS The previous AVS address.
     * @param newAVS The new AVS address.
     */
    event AVSUpdated(address prevAVS, address newAVS);

    /**
     * @notice Emitted when the ejector address is updated.
     * @dev Emitted in _setEjector().
     * @param prevEjector The previous ejector address.
     * @param newEjector The new ejector address.
     */
    event EjectorUpdated(address prevEjector, address newEjector);

    /**
     * @notice Emitted when all operators in a quorum are updated simultaneously.
     * @dev Emitted in updateOperatorsForQuorum().
     * @param quorumNumber The identifier of the quorum being updated.
     * @param blocknumber The block number at which the quorum update occurred.
     */
    event QuorumBlockNumberUpdated(uint8 indexed quorumNumber, uint256 blocknumber);

    /**
     * @notice Emitted when an operator's socket is updated.
     * @dev Emitted in updateSocket().
     * @param operatorId The unique identifier of the operator (BLS public key hash).
     * @param socket The new socket address for the operator (typically an IP address).
     */
    event OperatorSocketUpdate(bytes32 indexed operatorId, string socket);

    /**
     * @notice Emitted when the ejection cooldown period is updated.
     * @dev Emitted in setEjectionCooldown().
     * @param prevEjectionCooldown The previous cooldown duration in seconds.
     * @param newEjectionCooldown The new cooldown duration in seconds.
     */
    event EjectionCooldownUpdated(uint256 prevEjectionCooldown, uint256 newEjectionCooldown);
}

interface ISlashingRegistryCoordinator is
    IAVSRegistrar,
    ISlashingRegistryCoordinatorErrors,
    ISlashingRegistryCoordinatorEvents
{
    /// IMMUTABLES & CONSTANTS

    /**
     * @notice EIP-712 typehash for operator churn approval signatures.
     * @return The typehash constant.
     */
    function OPERATOR_CHURN_APPROVAL_TYPEHASH() external view returns (bytes32);

    /**
     * @notice EIP-712 typehash for pubkey registration signatures.
     * @return The typehash constant.
     */
    function PUBKEY_REGISTRATION_TYPEHASH() external view returns (bytes32);

    /**
     * @notice Reference to the BLSApkRegistry contract.
     * @return The BLSApkRegistry contract interface.
     */
    function blsApkRegistry() external view returns (IBLSApkRegistry);

    /**
     * @notice Reference to the StakeRegistry contract.
     * @return The StakeRegistry contract interface.
     */
    function stakeRegistry() external view returns (IStakeRegistry);

    /**
     * @notice Reference to the IndexRegistry contract.
     * @return The IndexRegistry contract interface.
     */
    function indexRegistry() external view returns (IIndexRegistry);

    /**
     * @notice Reference to the AllocationManager contract.
     * @return The AllocationManager contract interface.
     * @dev This is only relevant for Slashing AVSs
     */
    function allocationManager() external view returns (IAllocationManager);

    /**
     * @notice Reference to the SocketRegistry contract.
     * @return The SocketRegistry contract interface.
     */
    function socketRegistry() external view returns (ISocketRegistry);

    /// STORAGE

    /**
     * @notice The total number of quorums that have been created.
     * @return The count of quorums.
     */
    function quorumCount() external view returns (uint8);

    /**
     * @notice Checks if a churn approver salt has been used.
     * @param salt The salt to check.
     * @return True if the salt has been used, false otherwise.
     */
    function isChurnApproverSaltUsed(
        bytes32 salt
    ) external view returns (bool);

    /**
     * @notice Gets the last block number when all operators in a quorum were updated.
     * @param quorumNumber The quorum identifier.
     * @return The block number of the last update.
     */
    function quorumUpdateBlockNumber(
        uint8 quorumNumber
    ) external view returns (uint256);

    /**
     * @notice The address authorized to approve operator churn operations.
     * @return The churn approver address.
     */
    function churnApprover() external view returns (address);

    /**
     * @notice The address authorized to forcibly eject operators.
     * @return The ejector address.
     */
    function ejector() external view returns (address);

    /**
     * @notice Gets the timestamp of an operator's last ejection.
     * @param operator The operator address.
     * @return The timestamp of the last ejection.
     */
    function lastEjectionTimestamp(
        address operator
    ) external view returns (uint256);

    /**
     * @notice The cooldown period after ejection before an operator can re-register.
     * @return The cooldown duration in seconds.
     */
    function ejectionCooldown() external view returns (uint256);

    /// ACTIONS

    /**
     * @notice Updates stake weights for specified operators. If any operator is found to be below
     * the minimum stake for their registered quorums, they are deregistered from those quorums.
     * @param operators The operators whose stakes should be updated.
     * @dev Stakes are queried from the Eigenlayer core DelegationManager contract.
     * @dev WILL BE DEPRECATED IN FAVOR OF updateOperatorsForQuorum
     */
    function updateOperators(
        address[] memory operators
    ) external;

    /**
     * @notice For each quorum in `quorumNumbers`, updates the StakeRegistry's view of ALL its registered operators' stakes.
     * Each quorum's `quorumUpdateBlockNumber` is also updated, which tracks the most recent block number when ALL registered
     * operators were updated.
     * @dev stakes are queried from the Eigenlayer core DelegationManager contract
     * @param operatorsPerQuorum for each quorum in `quorumNumbers`, this has a corresponding list of operators to update.
     * @dev Each list of operator addresses MUST be sorted in ascending order
     * @dev Each list of operator addresses MUST represent the entire list of registered operators for the corresponding quorum
     * @param quorumNumbers is an ordered byte array containing the quorum numbers being updated
     * @dev invariant: Each list of `operatorsPerQuorum` MUST be a sorted version of `IndexRegistry.getOperatorListAtBlockNumber`
     * for the corresponding quorum.
     * @dev note on race condition: if an operator registers/deregisters for any quorum in `quorumNumbers` after a txn to
     * this method is broadcast (but before it is executed), the method will fail
     */
    function updateOperatorsForQuorum(
        address[][] memory operatorsPerQuorum,
        bytes calldata quorumNumbers
    ) external;

    /**
     * @notice Updates the socket of the msg.sender given they are a registered operator.
     * @param socket The new socket address for the operator (typically an IP address).
     * @dev Will revert if msg.sender is not a registered operator.
     */
    function updateSocket(
        string memory socket
    ) external;

    /**
     * @notice Forcibly removes an operator from specified quorums and sets their ejection timestamp.
     * @param operator The operator address to eject.
     * @param quorumNumbers The quorum numbers to eject the operator from.
     * @dev Can only be called by the ejector address.
     * @dev The operator cannot re-register until ejectionCooldown period has passed.
     */
    function ejectOperator(address operator, bytes memory quorumNumbers) external;

    /**
     * @notice Creates a new quorum that tracks total delegated stake for operators.
     * @param operatorSetParams Configures the quorum's max operator count and churn parameters.
     * @param minimumStake Sets the minimum stake required for an operator to register or remain registered.
     * @param strategyParams A list of strategies and multipliers used by the StakeRegistry to calculate
     * an operator's stake weight for the quorum.
     * @dev For m2 AVS this function has the same behavior as createQuorum before.
     * @dev For migrated AVS that enable operator sets this will create a quorum that measures total delegated stake for operator set.
     */
    function createTotalDelegatedStakeQuorum(
        OperatorSetParam memory operatorSetParams,
        uint96 minimumStake,
        IStakeRegistryTypes.StrategyParams[] memory strategyParams
    ) external;

    /**
     * @notice Creates a new quorum that tracks slashable stake for operators.
     * @param operatorSetParams Configures the quorum's max operator count and churn parameters.
     * @param minimumStake Sets the minimum stake required for an operator to register or remain registered.
     * @param strategyParams A list of strategies and multipliers used by the StakeRegistry to calculate
     * an operator's stake weight for the quorum.
     * @param lookAheadPeriod The number of blocks to look ahead when calculating slashable stake.
     * @dev Can only be called when operator sets are enabled.
     */
    function createSlashableStakeQuorum(
        OperatorSetParam memory operatorSetParams,
        uint96 minimumStake,
        IStakeRegistryTypes.StrategyParams[] memory strategyParams,
        uint32 lookAheadPeriod
    ) external;

    /**
     * @notice Updates the configuration parameters for an existing operator set quorum.
     * @param quorumNumber The identifier of the quorum to update.
     * @param operatorSetParams The new operator set parameters to apply.
     * @dev Can only be called by the contract owner.
     */
    function setOperatorSetParams(
        uint8 quorumNumber,
        OperatorSetParam memory operatorSetParams
    ) external;

    /**
     * @notice Updates the address authorized to approve operator churn operations.
     * @param _churnApprover The new churn approver address.
     * @dev Can only be called by the contract owner.
     * @dev The churn approver is responsible for signing off on operator replacements in full quorums.
     */
    function setChurnApprover(
        address _churnApprover
    ) external;

    /**
     * @notice Updates the address authorized to forcibly eject operators.
     * @param _ejector The new ejector address.
     * @dev Can only be called by the contract owner.
     * @dev The ejector can force-remove operators from quorums regardless of their stake.
     */
    function setEjector(
        address _ejector
    ) external;

    /**
     * @notice Updates the duration operators must wait after ejection before re-registering.
     * @param _ejectionCooldown The new cooldown duration in seconds.
     * @dev Can only be called by the contract owner.
     */
    function setEjectionCooldown(
        uint256 _ejectionCooldown
    ) external;

    /**
     * @notice Updates the avs address for this AVS (used for UAM integration in EigenLayer)
     * @param _avs The new avs address
     * @dev Can only be called by the contract owner
     * @dev NOTE: Updating this value will break existing OperatorSets and UAM integration. This value should only be set once.
     */
    function setAVS(
        address _avs
    ) external;

    /// VIEW

    /**
     * @notice Returns the hash of the message that operators must sign with their BLS key to register
     * @param operator The operator's Ethereum address
     */
    function calculatePubkeyRegistrationMessageHash(
        address operator
    ) external view returns (bytes32);

    /**
     * @notice Returns the operator set parameters for a given quorum.
     * @param quorumNumber The identifier of the quorum to query.
     * @return The OperatorSetParam struct containing max operator count and churn thresholds.
     */
    function getOperatorSetParams(
        uint8 quorumNumber
    ) external view returns (OperatorSetParam memory);

    /**
     * @notice Returns the complete operator information for a given address.
     * @param operator The operator address to query.
     * @return An OperatorInfo struct containing the operator's ID and registration status.
     */
    function getOperator(
        address operator
    ) external view returns (OperatorInfo memory);

    /**
     * @notice Returns the unique identifier for a given operator address.
     * @param operator The operator address to query.
     * @return The operator's ID (derived from their BLS public key hash).
     */
    function getOperatorId(
        address operator
    ) external view returns (bytes32);

    /**
     * @notice Returns the operator address associated with a given operator ID.
     * @param operatorId The unique identifier to look up.
     * @return The operator's address.
     * @dev Returns address(0) if the ID is not registered.
     */
    function getOperatorFromId(
        bytes32 operatorId
    ) external view returns (address);

    /**
     * @notice Returns the current registration status for a given operator.
     * @param operator The operator address to query.
     * @return The operator's status (NEVER_REGISTERED, REGISTERED, or DEREGISTERED).
     */
    function getOperatorStatus(
        address operator
    ) external view returns (OperatorStatus);

    /**
     * @notice Returns the indices needed to look up quorum bitmaps for operators at a specific block.
     * @param blockNumber The historical block number to query.
     * @param operatorIds Array of operator IDs to get indices for.
     * @return Array of indices corresponding to each operator ID.
     * @dev Reverts if any operator had not yet registered at the specified block.
     * @dev This function is designed to find proper inputs for getQuorumBitmapAtBlockNumberByIndex.
     */
    function getQuorumBitmapIndicesAtBlockNumber(
        uint32 blockNumber,
        bytes32[] memory operatorIds
    ) external view returns (uint32[] memory);

    /**
     * @notice Returns the quorum bitmap for an operator at a specific historical block.
     * @param operatorId The operator's unique identifier.
     * @param blockNumber The historical block number to query.
     * @param index The index in the operator's bitmap history (from getQuorumBitmapIndicesAtBlockNumber).
     * @return The quorum bitmap showing which quorums the operator was registered for.
     * @dev Reverts if the index is incorrect for the specified block number.
     */
    function getQuorumBitmapAtBlockNumberByIndex(
        bytes32 operatorId,
        uint32 blockNumber,
        uint256 index
    ) external view returns (uint192);

    /**
     * @notice Returns a specific update from an operator's quorum bitmap history.
     * @param operatorId The operator's unique identifier.
     * @param index The index in the bitmap history to query.
     * @return The QuorumBitmapUpdate struct at that index.
     */
    function getQuorumBitmapUpdateByIndex(
        bytes32 operatorId,
        uint256 index
    ) external view returns (QuorumBitmapUpdate memory);

    /**
     * @notice Returns the current quorum bitmap for an operator.
     * @param operatorId The operator's unique identifier.
     * @return A bitmap where each bit represents registration in a specific quorum.
     * @dev Returns 0 if the operator is not registered for any quorums.
     */
    function getCurrentQuorumBitmap(
        bytes32 operatorId
    ) external view returns (uint192);

    /**
     * @notice Returns the number of updates in an operator's bitmap history.
     * @param operatorId The operator's unique identifier.
     * @return The length of the bitmap history array.
     */
    function getQuorumBitmapHistoryLength(
        bytes32 operatorId
    ) external view returns (uint256);

    /**
     * @notice Calculates the digest hash that must be signed by the churn approver.
     * @param registeringOperator The address of the operator attempting to register.
     * @param registeringOperatorId The unique ID of the registering operator.
     * @param operatorKickParams Parameters specifying which operators to replace in full quorums.
     * @param salt Random value to ensure signature uniqueness.
     * @param expiry Timestamp after which the signature becomes invalid.
     * @return The EIP-712 typed data hash to be signed.
     */
    function calculateOperatorChurnApprovalDigestHash(
        address registeringOperator,
        bytes32 registeringOperatorId,
        OperatorKickParam[] memory operatorKickParams,
        bytes32 salt,
        uint256 expiry
    ) external view returns (bytes32);

    /**
     * @notice Returns the message hash that an operator must sign to register their BLS public key.
     * @param operator The address of the operator registering their key.
     * @return A point on the G1 curve representing the message hash.
     */
    function pubkeyRegistrationMessageHash(
        address operator
    ) external view returns (BN254.G1Point memory);

    /**
     * @notice Returns the avs address for this AVS (used for UAM integration in EigenLayer)
     * @dev NOTE: Updating this value will break existing OperatorSets and UAM integration. This value should only be set once.
     * @return The avs address
     */
    function avs() external view returns (address);
}

// lib/eigenlayer-middleware/src/interfaces/IBLSSignatureChecker.sol

interface IBLSSignatureCheckerErrors {
    /// @notice Thrown when the caller is not the registry coordinator owner.
    error OnlyRegistryCoordinatorOwner();
    /// @notice Thrown when the quorum numbers input in is empty.
    error InputEmptyQuorumNumbers();
    /// @notice Thrown when two array parameters have mismatching lengths.
    error InputArrayLengthMismatch();
    /// @notice Thrown when the non-signer pubkey length does not match non-signer bitmap indices length.
    error InputNonSignerLengthMismatch();
    /// @notice Thrown when the reference block number is invalid.
    error InvalidReferenceBlocknumber();
    /// @notice Thrown when the non signer pubkeys are not sorted.
    error NonSignerPubkeysNotSorted();
    /// @notice Thrown when the quorum apk hash in storage does not match provided quorum apk.
    error InvalidQuorumApkHash();
    /// @notice Thrown when BLS pairing precompile call fails.
    error InvalidBLSPairingKey();
    /// @notice Thrown when BLS signature is invalid.
    error InvalidBLSSignature();
}

interface IBLSSignatureCheckerTypes {
    /// @notice Contains bitmap and pubkey hash information for non-signing operators.
    /// @param quorumBitmaps Array of bitmaps indicating which quorums each non-signer was registered for.
    /// @param pubkeyHashes Array of BLS public key hashes for each non-signer.
    struct NonSignerInfo {
        uint256[] quorumBitmaps;
        bytes32[] pubkeyHashes;
    }

    /// @notice Contains non-signer information and aggregated signature data for BLS verification.
    /// @param nonSignerQuorumBitmapIndices The indices of all non-signer quorum bitmaps.
    /// @param nonSignerPubkeys The G1 public keys of all non-signers.
    /// @param quorumApks The aggregate G1 public key of each quorum.
    /// @param apkG2 The aggregate G2 public key of all signers.
    /// @param sigma The aggregate G1 signature of all signers.
    /// @param quorumApkIndices The indices of each quorum's aggregate public key in the APK registry.
    /// @param totalStakeIndices The indices of each quorum's total stake in the stake registry.
    /// @param nonSignerStakeIndices The indices of each non-signer's stake within each quorum.
    /// @dev Used as input to checkSignatures() to verify BLS signatures.
    struct NonSignerStakesAndSignature {
        uint32[] nonSignerQuorumBitmapIndices;
        BN254.G1Point[] nonSignerPubkeys;
        BN254.G1Point[] quorumApks;
        BN254.G2Point apkG2;
        BN254.G1Point sigma;
        uint32[] quorumApkIndices;
        uint32[] totalStakeIndices;
        uint32[][] nonSignerStakeIndices;
    }

    /// @notice Records the total stake amounts for operators in each quorum.
    /// @param signedStakeForQuorum Array of total stake amounts from operators who signed, per quorum.
    /// @param totalStakeForQuorum Array of total stake amounts from all operators, per quorum.
    /// @dev Used to track stake distribution and calculate quorum thresholds. Array indices correspond to quorum numbers.
    struct QuorumStakeTotals {
        uint96[] signedStakeForQuorum;
        uint96[] totalStakeForQuorum;
    }
}

interface IBLSSignatureChecker is IBLSSignatureCheckerErrors, IBLSSignatureCheckerTypes {
    /* STATE */

    /*
     * @notice Returns the address of the registry coordinator contract.
     * @return The address of the registry coordinator.
     * @dev This value is immutable and set during contract construction.
     */
    function registryCoordinator() external view returns (ISlashingRegistryCoordinator);

    /*
     * @notice Returns the address of the stake registry contract.
     * @return The address of the stake registry.
     * @dev This value is immutable and set during contract construction.
     */
    function stakeRegistry() external view returns (IStakeRegistry);

    /*
     * @notice Returns the address of the BLS APK registry contract.
     * @return The address of the BLS APK registry.
     * @dev This value is immutable and set during contract construction.
     */
    function blsApkRegistry() external view returns (IBLSApkRegistry);

    /*
     * @notice Returns the address of the delegation manager contract.
     * @return The address of the delegation manager.
     * @dev This value is immutable and set during contract construction.
     */
    function delegation() external view returns (IDelegationManager);

    /* VIEW */

    /*
     * @notice This function is called by disperser when it has aggregated all the signatures of the operators
     * that are part of the quorum for a particular taskNumber and is asserting them into onchain. The function
     * checks that the claim for aggregated signatures are valid.
     *
     * The thesis of this procedure entails:
     * 1. Getting the aggregated pubkey of all registered nodes at the time of pre-commit by the
     * disperser (represented by apk in the parameters)
     * 2. Subtracting the pubkeys of all non-signers (nonSignerPubkeys) and storing
     * the output in apk to get aggregated pubkey of all operators that are part of quorum
     * 3. Using this aggregated pubkey to verify the aggregated signature under BLS scheme
     *
     * @param msgHash The hash of the message that was signed. NOTE: Be careful to ensure msgHash is
     * collision-resistant! This method does not hash msgHash in any way, so if an attacker is able
     * to pass in an arbitrary value, they may be able to tamper with signature verification.
     * @param quorumNumbers The quorum numbers to verify signatures for, where each byte is an 8-bit integer.
     * @param referenceBlockNumber The block number at which the stake information is being verified
     * @param nonSignerStakesAndSignature Contains non-signer information and aggregated signature data.
     * @return quorumStakeTotals The struct containing the total and signed stake for each quorum
     * @return signatoryRecordHash The hash of the signatory record, which is used for fraud proofs
     * @dev Before signature verification, the function verifies operator stake information. This includes
     * ensuring that the provided referenceBlockNumber is valid and recent enough, and that the stake is
     * either the most recent update for the total stake (of the operator) or latest before the referenceBlockNumber.
     */
    function checkSignatures(
        bytes32 msgHash,
        bytes calldata quorumNumbers,
        uint32 referenceBlockNumber,
        NonSignerStakesAndSignature memory nonSignerStakesAndSignature
    ) external view returns (QuorumStakeTotals memory, bytes32);

    /*
     * @notice Attempts to verify signature `sigma` against message hash `msgHash` using aggregate public keys `apk` and `apkG2`.
     * @param msgHash The hash of the message that was signed.
     * @param apk The aggregate public key in G1.
     * @param apkG2 The aggregate public key in G2.
     * @param sigma The signature to verify.
     * @return pairingSuccessful True if the pairing check succeeded.
     * @return siganatureIsValid True if the signature is valid.
     */
    function trySignatureAndApkVerification(
        bytes32 msgHash,
        BN254.G1Point memory apk,
        BN254.G2Point memory apkG2,
        BN254.G1Point memory sigma
    ) external view returns (bool pairingSuccessful, bool siganatureIsValid);
}

// src/interface/IGasKillerSDK.sol

/// @title IGasKillerSDK
/// @notice Interface for GasKillerSDK contracts
/// @dev Defines the core functionality that GasKillerSDK implementations must provide
interface IGasKillerSDK is IERC165 {
    // Custom errors

    /// @notice Thrown when `transitionIndex + 1` does not equal the current `stateTransitionCount`
    error InvalidTransitionIndex();

    /// @notice Thrown when the reconstructed message hash does not match `msgHash`
    error InvalidSignature();

    /// @notice Thrown when the provided storage updates cannot be decoded or applied
    error InvalidStorageUpdates();

    /// @notice Thrown when an unrecognised state update operation type is encountered
    error InvalidOperation();

    /// @notice Thrown when signatories hold less than `QUORUM_THRESHOLD`% of stake for any quorum
    error InsufficientQuorumThreshold();

    /// @notice Thrown when `referenceBlockNumber` is older than `blockStaleMeasure` blocks ago
    error StaleBlockNumber();

    /// @notice Thrown when `referenceBlockNumber` is greater than or equal to the current block number
    error FutureBlockNumber();

    /// @notice Verify BLS quorum signatures and apply the encoded state updates
    /// @param msgHash The hash of the message to verify
    /// @param quorumNumbers The quorum numbers to check signatures for
    /// @param referenceBlockNumber The block number to use as reference for operator set
    /// @param storageUpdates The storage updates to verify
    /// @param transitionIndex The transition index
    /// @param targetFunction The target function selector
    /// @param nonSignerStakesAndSignature The non-signer stakes and signature data computed off-chain
    function verifyAndUpdate(
        bytes32 msgHash,
        bytes calldata quorumNumbers,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes4 targetFunction,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature calldata nonSignerStakesAndSignature
    ) external;
}

// src/GasKillerSDK.sol

/// @title GasKillerSDK
/// @notice Base SDK for implementing Gas Killer functionality in contracts
/// @dev Inherit from this contract to add Gas Killer capabilities to your contract
abstract contract GasKillerSDK is StateTracker, IGasKillerSDK {
    /// @custom:storage-location erc7201:gaskiller.GasKillerSDK.storage
    struct GasKillerSDKStorage {
        /// @notice Namespace derived from the AVS address; used to scope this contract within the AVS
        bytes namespace;
        /// @notice The AVS service manager address
        address avsAddress;
        /// @notice The BLS signature checker contract used to verify operator signatures
        IBLSSignatureChecker blsSignatureChecker;
        /// @notice Maximum number of blocks a reference block may lag behind the current block
        uint256 blockStaleMeasure;
    }

    // keccak256(abi.encode(uint256(keccak256("gaskiller.GasKillerSDK.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant GAS_KILLER_SDK_STORAGE_LOCATION =
        0x321ebf629ed2e1e368f0890e8fdd95cf9a2ae5961b66a1805f0b2ec84e21d000;

    /// @notice Denominator used when evaluating stake percentage thresholds (representing 100%)
    uint8 public constant THRESHOLD_DENOMINATOR = 100;

    /// @notice Minimum percentage of quorum stake that must have signed to approve a state update (QUORUM_THRESHOLD/THRESHOLD_DENOMINATOR)
    uint8 public constant QUORUM_THRESHOLD = 66;

    /// @notice Default maximum age (in blocks) a reference block is considered valid when none is configured
    uint256 private constant DEFAULT_BLOCK_STALE_MEASURE = 300;

    /// @notice Verify BLS quorum signatures and apply the encoded state updates
    /// @param msgHash The hash of the message to verify
    /// @param quorumNumbers The quorum numbers to check signatures for
    /// @param referenceBlockNumber The block number to use as reference for operator set
    /// @param storageUpdates The storage updates to verify
    /// @param transitionIndex The transition index
    /// @param targetFunction The target function selector
    /// @param nonSignerStakesAndSignature The non-signer stakes and signature data computed off-chain
    function verifyAndUpdate(
        bytes32 msgHash,
        bytes calldata quorumNumbers,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes4 targetFunction,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature calldata nonSignerStakesAndSignature
    ) external trackState {
        GasKillerSDKStorage storage $ = _getGasKillerSDKStorage();

        // Check block number validity
        require(referenceBlockNumber < block.number, FutureBlockNumber());
        require((uint256(referenceBlockNumber) + _getBlockStaleMeasure()) >= block.number, StaleBlockNumber());

        // Verify transition index and message hash
        require(transitionIndex + 1 == stateTransitionCount(), InvalidTransitionIndex());
        bytes32 expectedHash = sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates));
        require(expectedHash == msgHash, InvalidSignature());

        // Verify the signatures using checkSignatures
        (IBLSSignatureCheckerTypes.QuorumStakeTotals memory stakeTotals,) = $.blsSignatureChecker
            .checkSignatures(msgHash, quorumNumbers, referenceBlockNumber, nonSignerStakesAndSignature);

        // Check that signatories own at least 66% of each quorum
        for (uint256 i = 0; i < quorumNumbers.length; i++) {
            require(
                stakeTotals.signedStakeForQuorum[i] * THRESHOLD_DENOMINATOR
                    >= stakeTotals.totalStakeForQuorum[i] * QUORUM_THRESHOLD,
                InsufficientQuorumThreshold()
            );
        }

        // Apply the state changes
        _stateChangeHandler(storageUpdates);
    }

    /// @notice Query if a contract implements an interface
    /// @dev Supports ERC-165 and IGasKillerSDK interface detection
    /// @param interfaceId The interface identifier, as specified in ERC-165
    /// @return `true` if the contract implements `interfaceId` and `false` otherwise
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IGasKillerSDK).interfaceId;
    }

    /// @notice Compute the expected message hash for a given transition, function, and storage updates
    /// @param transitionIndex The transition index
    /// @param targetFunction The target function selector
    /// @param storageUpdates The ABI-encoded storage updates
    /// @return The expected SHA-256 hash
    function getMessageHash(uint256 transitionIndex, bytes4 targetFunction, bytes calldata storageUpdates)
        external
        view
        returns (bytes32)
    {
        return sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates));
    }

    /// @notice Return the configured AVS service manager address
    /// @return The AVS address
    function avsAddress() external view returns (address) {
        return _getGasKillerSDKStorage().avsAddress;
    }

    /// @notice Return the configured BLS signature checker address
    /// @return The BLS signature checker address
    function blsSignatureChecker() external view returns (address) {
        return address(_getGasKillerSDKStorage().blsSignatureChecker);
    }

    /// @notice Return the namespace bytes derived from the AVS address
    /// @return The namespace
    function namespace() external view returns (bytes memory) {
        return _getGasKillerSDKStorage().namespace;
    }

    /// @notice Return the configured block stale measure (or the default if unset)
    /// @return The block stale measure
    function blockStaleMeasure() external view returns (uint256) {
        return _getBlockStaleMeasure();
    }

    /// @notice Decode and execute ABI-encoded storage updates
    /// @param storageUpdates ABI-encoded `(StateUpdateType[], bytes[])` pair
    function _stateChangeHandler(bytes calldata storageUpdates) internal {
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        StateChangeHandlerLib._runStateUpdates(types, args);
    }

    /// @notice Set the AVS address and derive the namespace from it
    /// @dev The namespace is `abi.encodePacked(avsAddress, "gaskiller")`
    /// @param _avsAddress The new AVS service manager address
    function _setAvsAddress(address _avsAddress) internal {
        GasKillerSDKStorage storage $ = _getGasKillerSDKStorage();
        $.avsAddress = _avsAddress;
        $.namespace = abi.encodePacked($.avsAddress, "gaskiller");
    }

    /// @notice Set the BLS signature checker contract
    /// @param _blsSignatureChecker The new BLS signature checker address
    function _setBlsSignatureChecker(address _blsSignatureChecker) internal {
        GasKillerSDKStorage storage $ = _getGasKillerSDKStorage();
        $.blsSignatureChecker = IBLSSignatureChecker(_blsSignatureChecker);
    }

    /// @notice Set the maximum number of blocks a reference block may lag behind the current block
    /// @param _blockStaleMeasure The new block stale measure value
    function _setBlockStaleMeasure(uint256 _blockStaleMeasure) internal {
        _getGasKillerSDKStorage().blockStaleMeasure = _blockStaleMeasure;
    }

    /// @notice Return the block stale measure, falling back to the default when unset
    /// @return The effective block stale measure
    function _getBlockStaleMeasure() internal view returns (uint256) {
        uint256 value = _getGasKillerSDKStorage().blockStaleMeasure;
        return value == 0 ? DEFAULT_BLOCK_STALE_MEASURE : value;
    }

    /// @notice Load the ERC-7201 storage struct for GasKillerSDK
    /// @return $ The GasKillerSDK storage struct
    function _getGasKillerSDKStorage() private pure returns (GasKillerSDKStorage storage $) {
        assembly {
            $.slot := GAS_KILLER_SDK_STORAGE_LOCATION
        }
    }
}

// src/examples/onchain-fly/FlyPolicy.sol

/// @title FlyPolicy
/// @notice The Gas Killer consumer of the fly-connectome AMM: one tracked function, `decide`, runs a
///         300 ms episode of the complete fly brain (a multi-Ggas STATICCALL into the stateless
///         `FlyEngine`) on the pool's last closed window and settles ONE packed word — fee, skew,
///         flags, window, epoch and a 160-bit commitment to the full `FlyState` (HANDOFF §4.5, §4.7).
/// @dev Invariants (GasKillerChat pattern):
///        - `decide` mutates only FLY_SLOT (the StateTracker counter is gate-exempt);
///        - the brain is a STATICCALL into a stateless engine; graph and warm snapshot are EXTCODECOPY
///          reads of immutable data contracts — never in the payload;
///        - no block-environment reads (the epoch is `stateTransitionCount()`; the pool's `observe()`
///          returns closed-window storage only);
///        - the pool never inherits the SDK and clamps everything it reads: a colluding quorum can
///          pin the fee inside the band, never drain reserves. Do not merge the two contracts.
contract FlyPolicy is GasKillerSDK {
    /// @notice Domain separator of the packed word chain
    bytes32 public constant FLY_DOMAIN = keccak256("gaskiller.fly.amm.policy.v1");

    /// @notice The single mutable app slot
    /// @dev keccak256(abi.encode(uint256(keccak256("gaskiller.FlyPolicy.flyWord")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 public constant FLY_SLOT = 0xcbecd64d5226c3b53f872ce956484768a63c3b8a34d2c1088c069f9663d00d00;

    /// @notice keccak256("") — the memory root while ETA == 0 (no plasticity in v1)
    bytes32 public constant MEMORY_ROOT_ZERO = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    uint8 public constant FLAG_REBALANCE = 1;
    uint8 public constant FLAG_PUNISH_NEXT = 2;
    uint8 public constant FLAG_REWARD_NEXT = 4;

    FlyEngine public immutable engine;
    address public immutable graphRoot;
    address public immutable warmRoot;
    FlyAMM public immutable pool;
    bytes32 private immutable _cfg0;
    bytes32 private immutable _cfg1;
    bytes32 private immutable _cfg2;

    // fee-band parameters, decoded from cfg[2] at construction (design targets: 5/100/30/25 bps)
    uint256 public immutable minFeeBps;
    uint256 public immutable maxFeeBps;
    uint256 public immutable maxSkewBps;
    uint256 public immutable rebalThresholdBps;
    uint256 public immutable pulseSteps;

    /// @notice Emitted by every settled decision; the full state lives here, its packed word in FLY_SLOT
    event FlyDecided(
        uint256 indexed transitionIndex,
        bytes32 indexed flyWord,
        bytes32 indexed spikeRoot,
        FlyTypes.FlyState next,
        bytes frame,
        FlyTypes.Readout readout
    );

    error StateMismatch();
    error WindowNotClosed();

    constructor(
        address _avsAddress,
        address _blsSigChecker,
        FlyEngine _engine,
        address _graphRoot,
        address _warmRoot,
        bytes32[3] memory _packedConfig,
        FlyAMM _pool
    ) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
        engine = _engine;
        graphRoot = _graphRoot;
        warmRoot = _warmRoot;
        pool = _pool;
        _cfg0 = _packedConfig[0];
        _cfg1 = _packedConfig[1];
        _cfg2 = _packedConfig[2];
        uint256 c2 = uint256(_packedConfig[2]);
        minFeeBps = (c2 >> 240) & 0xffff;
        maxFeeBps = (c2 >> 224) & 0xffff;
        maxSkewBps = (c2 >> 208) & 0xffff;
        rebalThresholdBps = (c2 >> 176) & 0xffff;
        pulseSteps = (uint256(_packedConfig[1]) >> 224) & 0xffff;
        _validateArtifacts();
    }

    /// @notice Artifact validation hook (≈22 M gas on the real graph: fine in a constructor)
    function _validateArtifacts() internal view virtual {
        engine.checkArtifacts(graphRoot, warmRoot, [_cfg0, _cfg1, _cfg2]);
    }

    // ================================================================== the tracked function

    /// @notice Run one episode on the last closed window and settle the next packed word.
    /// @dev The ONLY tracked function. Operators simulate it under the unbounded profile and sign
    ///      the single-STORE (+ log) diff; the brain never executes in the applying transaction.
    /// @param prev The previous FlyState (from the last FlyDecided log); its packed word must be in FLY_SLOT
    function decide(FlyTypes.FlyState calldata prev) external trackState {
        bytes32 word = flyWord();
        if (!_matches(word, prev)) revert StateMismatch();
        (FlyTypes.FlyState memory next, bytes memory frame, FlyTypes.Readout memory r, bytes32 spikeRoot) =
            _compute(prev);
        next.prevWord = word;
        bytes32 newWord = pack(next);
        assembly ("memory-safe") {
            sstore(FLY_SLOT, newWord)
        }
        emit FlyDecided(stateTransitionCount(), newWord, spikeRoot, next, frame, r);
    }

    /// @notice The decision without touching state (eth_call / operators / tests)
    function dryRun(FlyTypes.FlyState calldata prev)
        external
        view
        returns (
            FlyTypes.FlyState memory next,
            bytes32 word,
            bytes memory frame,
            FlyTypes.Readout memory r,
            bytes32 spikeRoot
        )
    {
        (next, frame, r, spikeRoot) = _compute(prev);
        next.prevWord = flyWord();
        word = pack(next);
    }

    function _compute(FlyTypes.FlyState calldata prev)
        internal
        view
        returns (FlyTypes.FlyState memory next, bytes memory frame, FlyTypes.Readout memory r, bytes32 spikeRoot)
    {
        FlyTypes.Observation memory o = pool.observe(); // STATICCALL, storage-only
        if (o.windowId <= prev.windowId) revert WindowNotClosed(); // one decision per closed window
        bytes32[3] memory cfg = [_cfg0, _cfg1, _cfg2];
        frame = engine.rasterize(graphRoot, cfg, o);
        FlyTypes.Stimulus memory s = FlyTypes.Stimulus({
            punishSteps: (prev.flags & FLAG_PUNISH_NEXT) != 0 ? uint16(pulseSteps) : 0,
            rewardSteps: (prev.flags & FLAG_REWARD_NEXT) != 0 ? uint16(pulseSteps) : 0
        });
        (r, spikeRoot) = engine.decide(graphRoot, warmRoot, cfg, frame, s, prev.rateMilliHz); // the Ggas call
        // §4.3: DNp20 R−L → skew, DNpe017 sum → fee, DNpe017 spikes in the last 30 ms + deviation → rebalance
        int256 turn = _clamp(
            int256(120) * (int256(uint256(r.rateMilliHz[0])) - int256(uint256(r.rateMilliHz[1]))) / 1000, -6000, 6000
        );
        uint256 fwd = _clampU(400 * (uint256(r.rateMilliHz[2]) + r.rateMilliHz[3]) / 1000, 0, 20000);
        next.epoch = prev.epoch + 1;
        next.windowId = o.windowId;
        next.skewBps = int16(turn * int256(maxSkewBps) / 6000);
        next.feeBps = uint16(minFeeBps + fwd * (maxFeeBps - minFeeBps) / 20000);
        bool rebal = (uint256(r.spikesLast30ms[2]) + r.spikesLast30ms[3]) > 0
            && _absDevBps(o.spotQ64, o.twapQ64) > rebalThresholdBps;
        next.flags = (rebal ? FLAG_REBALANCE : 0) | (o.lpLossQuote > 0 ? FLAG_PUNISH_NEXT : 0)
            | (o.feeIncomeQuote > 0 ? FLAG_REWARD_NEXT : 0);
        next.rateMilliHz = r.rateMilliHz;
        next.memoryRoot = MEMORY_ROOT_ZERO;
    }

    /// @notice The state the very first decision extends (FLY_SLOT == 0)
    function genesisState() public pure returns (FlyTypes.FlyState memory s) {
        s.memoryRoot = MEMORY_ROOT_ZERO;
    }

    /// @dev `prev` is the state committed in `word`; a zero word commits to `genesisState()`
    function _matches(bytes32 word, FlyTypes.FlyState calldata prev) internal pure returns (bool) {
        bytes32 h = keccak256(abi.encode(prev));
        if (word == bytes32(0)) return h == keccak256(abi.encode(genesisState()));
        return uint160(uint256(word)) == uint160(uint256(h));
    }

    // ================================================================== the packed word

    /// @notice Parameters the pool reads with one SLOAD
    function params()
        external
        view
        returns (uint16 feeBps, int16 skewBps, bool rebalance, uint32 windowId, uint32 epoch)
    {
        uint256 w = uint256(flyWord());
        feeBps = uint16(w >> 240);
        skewBps = int16(uint16(w >> 224));
        rebalance = ((w >> 216) & FLAG_REBALANCE) != 0;
        windowId = uint32(w >> 184);
        epoch = uint32((w >> 160) & 0xffffff);
    }

    /// @notice The packed word in FLY_SLOT (the contract's only mutable app state)
    function flyWord() public view returns (bytes32 word) {
        assembly ("memory-safe") {
            word := sload(FLY_SLOT)
        }
    }

    /// @notice feeBps[255:240] | skewBps[239:224] | flags[223:216] | windowId[215:184] | epoch[183:160] | keccak(state)[159:0]
    function pack(FlyTypes.FlyState memory s) public pure returns (bytes32) {
        uint256 w = uint256(uint160(uint256(keccak256(abi.encode(s)))));
        w |= uint256(s.epoch & 0xffffff) << 160;
        w |= uint256(s.windowId) << 184;
        w |= uint256(s.flags) << 216;
        w |= uint256(uint16(s.skewBps)) << 224;
        w |= uint256(s.feeBps) << 240;
        return bytes32(w);
    }

    /// @notice The packed model config words
    function packedConfig() external view returns (bytes32[3] memory) {
        return [_cfg0, _cfg1, _cfg2];
    }

    // ================================================================== helpers

    function _absDevBps(uint256 spot, uint256 twap) internal pure returns (uint256) {
        if (twap == 0) return 0;
        return ((spot > twap ? spot - twap : twap - spot) * 10000) / twap;
    }

    function _clamp(int256 x, int256 lo, int256 hi) internal pure returns (int256) {
        return x < lo ? lo : (x > hi ? hi : x);
    }

    function _clampU(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return x < lo ? lo : (x > hi ? hi : x);
    }
}
