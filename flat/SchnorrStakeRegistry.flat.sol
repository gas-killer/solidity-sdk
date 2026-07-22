// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

// src/schnorr/interface/ISchnorrStakeRegistry.sol

/// @title ISchnorrStakeRegistry
/// @notice Verification surface the `SchnorrGasKillerSDK` depends on. Kept minimal (and
///         separate from the concrete registry) so the SDK can be unit-tested against a
///         mock, mirroring how `GasKillerSDK` depends on ERC-1271 `isValidSignature`.
interface ISchnorrStakeRegistry {
    /// @notice Verify an aggregate Schnorr quorum signature over `message`.
    /// @param message     the signed 32-byte task digest.
    /// @param s           aggregate response scalar.
    /// @param Raddr       aggregate nonce address `address(R)`.
    /// @param nonSigners  operator identities that did not sign, strictly ascending.
    /// @param refBlock    reference block; must be `>= effectiveBlock` and `< block.number`.
    function isValidSignature(
        bytes32 message,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners,
        uint256 refBlock
    ) external view returns (bool);
}

// src/schnorr/libraries/SchnorrVerify.sol

/// @title SchnorrVerify
/// @notice Constant-gas verification of an aggregate secp256k1 Schnorr signature using the
///         audited Chronicle/MakerDAO "Scribe" `ecrecover` trick — the EVM performs **one**
///         `ecrecover` and no elliptic-curve scalar multiplication.
/// @dev The signing/verification convention is fixed and must match the Rust signer
///      (`common/src/schnorr`) byte-for-byte:
///
///        e = keccak256(Xx ‖ Xparity ‖ message ‖ Raddr) mod n      (Xparity a single 0/1 byte)
///        s = k − e·x (mod n)   ⇒   R = s·G + e·X
///        verify: ecrecover(−s·Xx mod n, 27+Xparity, Xx, e·Xx mod n) == Raddr
library SchnorrVerify {
    /// secp256k1 group order `n`.
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// @notice Verifies `sig = (s, Raddr)` over `message` against the aggregate key
    ///         `(Xx, Xparity)`.
    /// @param Xx        x-coordinate of the aggregate public key `X` (must be `< n`).
    /// @param Xparity   y-parity of `X`: `0` if even, `1` if odd.
    /// @param message   the 32-byte signed message (the task digest).
    /// @param s         the aggregate response scalar (`0 < s < n`).
    /// @param Raddr     `address(R)` — the nonce point's Ethereum address (non-zero).
    /// @return ok       true iff the signature is valid.
    function verify(uint256 Xx, uint8 Xparity, bytes32 message, uint256 s, address Raddr)
        internal
        pure
        returns (bool ok)
    {
        // Scribe validity domain: Xx a usable `r` (< n and non-zero), canonical s, real R,
        // and a defined parity bit.
        if (Xx == 0 || Xx >= N) return false;
        if (s == 0 || s >= N) return false;
        if (Raddr == address(0)) return false;
        if (Xparity > 1) return false;

        uint256 e = uint256(keccak256(abi.encodePacked(Xx, Xparity, message, Raddr))) % N;
        if (e == 0) return false;

        // h = −s·Xx (mod n) ; sp = e·Xx (mod n). Both non-zero because s,e,Xx ∈ (0,n), n prime.
        uint256 sXx = mulmod(s, Xx, N);
        if (sXx == 0) return false;
        bytes32 h = bytes32(N - sXx);
        bytes32 sp = bytes32(mulmod(e, Xx, N));

        address recovered = ecrecover(h, Xparity == 0 ? 27 : 28, bytes32(Xx), sp);
        return recovered != address(0) && recovered == Raddr;
    }
}

// src/schnorr/libraries/Secp256k1.sol

/// @title Secp256k1
/// @notice Minimal affine secp256k1 point arithmetic over the base field, used by
///         `SchnorrStakeRegistry` to maintain the aggregate operator public key and to
///         subtract non-signers from it. The identity (point at infinity) is represented
///         as `(0, 0)`.
/// @dev Signature *verification* does not use this library — that goes through the
///      `ecrecover` trick in `SchnorrVerify`. Point math is only needed for aggregation
///      (register/deregister) and per-non-signer subtraction at verify time (zero cost at
///      full participation). Modular inversion uses the `modexp` (0x05) precompile.
library Secp256k1 {
    /// secp256k1 base field prime `p`.
    uint256 internal constant P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    /// secp256k1 curve constant `b` (a = 0).
    uint256 internal constant B = 7;

    error NotOnCurve();

    /// @notice `y² == x³ + 7 (mod p)` with `0 < x,y < p`.
    function isOnCurve(uint256 x, uint256 y) internal pure returns (bool) {
        if (x == 0 || y == 0 || x >= P || y >= P) return false;
        uint256 lhs = mulmod(y, y, P);
        uint256 rhs = addmod(mulmod(mulmod(x, x, P), x, P), B, P);
        return lhs == rhs;
    }

    /// @notice The negation `-P = (x, p - y)` (identity maps to identity).
    function negate(uint256 x, uint256 y) internal pure returns (uint256, uint256) {
        if (x == 0 && y == 0) return (0, 0);
        return (x, P - y);
    }

    /// @notice Affine point addition `(x1,y1) + (x2,y2)`, handling identities, doubling and
    ///         the `P + (-P) = O` case.
    function add(uint256 x1, uint256 y1, uint256 x2, uint256 y2) internal view returns (uint256 x3, uint256 y3) {
        if (x1 == 0 && y1 == 0) return (x2, y2);
        if (x2 == 0 && y2 == 0) return (x1, y1);

        uint256 lambda;
        if (x1 == x2) {
            // Same x: either doubling (y1 == y2) or inverse (y1 == p - y2 → identity).
            if (addmod(y1, y2, P) == 0) return (0, 0);
            // lambda = 3·x1² / (2·y1)
            uint256 num = mulmod(3, mulmod(x1, x1, P), P);
            uint256 den = mulmod(2, y1, P);
            lambda = mulmod(num, _inv(den), P);
        } else {
            // lambda = (y2 - y1) / (x2 - x1)
            uint256 num = _sub(y2, y1);
            uint256 den = _sub(x2, x1);
            lambda = mulmod(num, _inv(den), P);
        }
        // x3 = lambda² - x1 - x2
        x3 = _sub(_sub(mulmod(lambda, lambda, P), x1), x2);
        // y3 = lambda·(x1 - x3) - y1
        y3 = _sub(mulmod(lambda, _sub(x1, x3), P), y1);
    }

    /// @notice Point subtraction `(x1,y1) - (x2,y2)`.
    function sub(uint256 x1, uint256 y1, uint256 x2, uint256 y2) internal view returns (uint256, uint256) {
        (uint256 nx, uint256 ny) = negate(x2, y2);
        return add(x1, y1, nx, ny);
    }

    /// @notice `(a - b) mod p` for `a, b < p`.
    function _sub(uint256 a, uint256 b) private pure returns (uint256) {
        return addmod(a, P - b, P);
    }

    /// @notice Modular inverse `a^(p-2) mod p` via the `modexp` precompile (0x05).
    function _inv(uint256 a) private view returns (uint256 result) {
        uint256 p = P;
        uint256 expo = P - 2;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x20) // len(base)
            mstore(add(ptr, 0x20), 0x20) // len(exp)
            mstore(add(ptr, 0x40), 0x20) // len(mod)
            mstore(add(ptr, 0x60), a)
            mstore(add(ptr, 0x80), expo)
            mstore(add(ptr, 0xa0), p)
            if iszero(staticcall(gas(), 0x05, ptr, 0xc0, ptr, 0x20)) { revert(0, 0) }
            result := mload(ptr)
        }
    }
}

// src/schnorr/SchnorrStakeRegistry.sol

/// @title SchnorrStakeRegistry
/// @notice Stake registry for the **aggregate Schnorr** quorum scheme — the Schnorr
///         equivalent of EigenLayer's `ECDSAStakeRegistry`. Instead of verifying `N`
///         individual signatures, it maintains a watermark-snapshotted **aggregate**
///         operator public key `X_all = Σ X_i` (a single current value, not a per-block
///         history) and verifies a single aggregate signature against
///         `X_agg = X_all − Σ non-signers` in constant gas.
///
/// @dev Mirrors the "aggressive snapshot" registry-cache design from the ECDSA gas-opt
///      work (service #311): a `_effectiveBlock` watermark records the last operator-set
///      mutation, and verification is **fail-closed** — it requires
///      `refBlock >= _effectiveBlock` so the cached aggregate/weights are guaranteed equal
///      to their historical values at `refBlock`. Plain (linear) key aggregation is safe
///      here only because registration requires a **proof of possession**, which defeats
///      rogue-key attacks (the same guarantee `BLSApkRegistry` enforces for BLS).
///
///      This is a self-contained implementation (no EigenLayer base classes) so the whole
///      verify + subtraction + threshold path is unit-testable; production would layer the
///      operator/AVS registration lifecycle on top, exactly as `ECDSAStakeRegistry` does.
contract SchnorrStakeRegistry is ISchnorrStakeRegistry {
    /// Domain tag for the proof-of-possession message — must equal the Rust `POP_TAG`.
    bytes internal constant POP_TAG = "gas-killer/schnorr/pop/v1";

    struct Operator {
        uint256 x; // pubkey x
        uint256 y; // pubkey y
        // `weight` and `registered` share a slot: the verification loop reads a
        // non-signer's whole record, so packing saves one cold SLOAD per non-signer.
        // uint96 matches EigenLayer's stake-weight width.
        uint96 weight; // stake weight
        bool registered;
    }

    /// operator Ethereum address (= address of its pubkey point) → operator record.
    mapping(address => Operator) public operators;

    /// Running aggregate public key `X_all = Σ X_i` (identity = `(0,0)`).
    uint256 public aggX;
    uint256 public aggY;
    /// Total registered stake weight.
    uint256 public totalWeight;
    /// Block of the last operator-set mutation (verification fail-closes below this).
    uint256 public effectiveBlock;

    /// Threshold as a fraction `num/den` of total weight required to sign (e.g. 2/3).
    uint256 public immutable thresholdNum;
    uint256 public immutable thresholdDen;

    /// @notice The registry owner, allowed to register operators (stands in for the
    ///         EigenLayer registration lifecycle).
    address public immutable owner;

    error NotOwner();
    error AlreadyRegistered();
    error NotOnCurve();
    error InvalidProofOfPossession();
    error NotRegistered(address operator);
    error NonSignersNotSorted();
    error FutureReferenceBlock();
    error StaleSnapshot();
    error ZeroWeight();
    error WeightOverflow();

    event OperatorRegistered(address indexed operator, uint256 weight);

    constructor(uint256 _thresholdNum, uint256 _thresholdDen, address _owner) {
        require(_thresholdDen != 0 && _thresholdNum <= _thresholdDen, "bad threshold");
        thresholdNum = _thresholdNum;
        thresholdDen = _thresholdDen;
        owner = _owner;
        effectiveBlock = block.number;
    }

    /// @notice The Ethereum address of a public-key point (`keccak256(x‖y)[12:]`). This is
    ///         the operator identity used to look up non-signers.
    function pointAddress(uint256 x, uint256 y) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(x, y)))));
    }

    /// @notice The proof-of-possession message for an operator identity.
    function popMessage(address operator) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(POP_TAG, operator));
    }

    /// @notice Register an operator's Schnorr key with a proof of possession.
    /// @param x       pubkey x-coordinate.
    /// @param y       pubkey y-coordinate.
    /// @param weight  stake weight to credit.
    /// @param popS    PoP signature scalar `s`.
    /// @param popR    PoP nonce address `address(R)`.
    function registerOperator(uint256 x, uint256 y, uint256 weight, uint256 popS, address popR) external {
        if (msg.sender != owner) revert NotOwner();
        if (weight == 0) revert ZeroWeight();
        if (weight > type(uint96).max) revert WeightOverflow();
        if (!Secp256k1.isOnCurve(x, y)) revert NotOnCurve();

        address id = pointAddress(x, y);
        if (operators[id].registered) revert AlreadyRegistered();

        // Proof of possession: a single-key Schnorr signature over popMessage(id), verified
        // against this very key. Without it, plain key aggregation would be rogue-key-forgeable.
        uint8 parity = uint8(y & 1);
        if (!SchnorrVerify.verify(x, parity, popMessage(id), popS, popR)) {
            revert InvalidProofOfPossession();
        }

        // casting to 'uint96' is safe: bounds-checked against type(uint96).max above
        // forge-lint: disable-next-line(unsafe-typecast)
        operators[id] = Operator({x: x, y: y, weight: uint96(weight), registered: true});
        (aggX, aggY) = Secp256k1.add(aggX, aggY, x, y);
        totalWeight += weight;
        effectiveBlock = block.number;

        emit OperatorRegistered(id, weight);
    }

    /// @notice Verify an aggregate Schnorr signature for `message`, accounting for the
    ///         declared non-signers.
    /// @param message     the signed 32-byte task digest.
    /// @param s           aggregate response scalar.
    /// @param Raddr       aggregate nonce address `address(R)`.
    /// @param nonSigners  operator identities that did NOT sign, strictly ascending.
    /// @param refBlock    reference block; must be `>= effectiveBlock` and `< block.number`.
    /// @return ok         true iff the quorum signed and the signature verifies.
    function isValidSignature(
        bytes32 message,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners,
        uint256 refBlock
    ) external view override returns (bool ok) {
        if (refBlock >= block.number) revert FutureReferenceBlock();
        // Fail-closed: the cached aggregate/weights only equal their value at refBlock when
        // no operator-set mutation happened after it.
        if (refBlock < effectiveBlock) revert StaleSnapshot();

        // Start from the full aggregate, subtract each non-signer's key and weight.
        uint256 xAgg = aggX;
        uint256 yAgg = aggY;
        uint256 signedWeight = totalWeight;

        address last = address(0);
        uint256 nonSignersLength = nonSigners.length;
        for (uint256 i = 0; i < nonSignersLength; ++i) {
            address ns = nonSigners[i];
            if (ns <= last) revert NonSignersNotSorted();
            last = ns;
            Operator storage op = operators[ns];
            if (!op.registered) revert NotRegistered(ns);
            (xAgg, yAgg) = Secp256k1.sub(xAgg, yAgg, op.x, op.y);
            signedWeight -= op.weight;
        }

        // Stake threshold: signedWeight/total >= num/den.
        if (signedWeight * thresholdDen < totalWeight * thresholdNum) return false;

        // If every operator is a non-signer the aggregate is the identity — reject.
        if (xAgg == 0 && yAgg == 0) return false;

        return SchnorrVerify.verify(xAgg, uint8(yAgg & 1), message, s, Raddr);
    }
}
