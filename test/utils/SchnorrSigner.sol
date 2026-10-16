// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Vm} from "forge-std/Vm.sol";
import {SchnorrVerify} from "../../src/libraries/SchnorrVerify.sol";

/// @notice Signs arbitrary digests under the `SchnorrVerify` convention at test time, so tests
///         can exercise real signatures over values that only exist at runtime (Merkle roots,
///         digests bound to a deployed address). Test-only: nonces are caller-chosen.
/// @dev e = keccak256(Xx ‖ Xparity ‖ message ‖ Raddr) mod n, s = k − e·x mod n, Raddr = addr(k·G).
library SchnorrSigner {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function publicKey(uint256 x) internal returns (uint256 px, uint256 py) {
        Vm.Wallet memory w = vm.createWallet(x);
        return (w.publicKeyX, w.publicKeyY);
    }

    function sign(uint256 x, uint256 k, bytes32 message) internal returns (uint256 s, address Raddr) {
        (uint256 px, uint256 py) = publicKey(x);
        Raddr = vm.addr(k);
        uint256 n = SchnorrVerify.N;
        uint256 e = uint256(keccak256(abi.encodePacked(px, uint8(py & 1), message, Raddr))) % n;
        s = addmod(k, n - mulmod(e, x, n), n);
    }
}
