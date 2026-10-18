// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.4;

// src/gkvm/IGkVmConsumer.sol

/// @title IGkVmConsumer
/// @notice What a gkvm consumer tells operators about the guest program its tracked functions run
/// @dev Program distribution (UNBOUNDED_V3): an operator serving a task calls these two getters on
///      the consumer at the task's block height, fetches the ELF by hash from the mirrors it knows
///      (`<mirror>/<programHash hex>.elf`, what `gk publish` writes) and verifies
///      `keccak256(elf) == programHash()` before installing it — so deploying the consumer is the
///      whole on-chain publication step, and no operator-edited program list is involved. One
///      program per consumer in this version. A consumer that already exposes the uppercase
///      `PROGRAM_HASH()` public constant (the generated bindings' name) is recognized as well.
interface IGkVmConsumer {
    /// @notice keccak256 of the guest ELF this consumer's tracked functions run through the gkvm
    ///         precompile
    function programHash() external view returns (bytes32);

    /// @notice Merkle v3 root of the artifact bundle the guest reads; zero when the guest reads none
    function artifactRoot() external view returns (bytes32);
}
