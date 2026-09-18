// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.12;

import {GkVm, GKVM_ADDRESS} from "../../src/gkvm/GkVm.sol";

/// @title GkVmParityConsumer
/// @notice Tracked-function stand-in for the M3 ffi ≡ precompile differential: the same bytecode
///         runs here against GkVmFfiShim and in gas-analyzer's local executor against the real
///         precompile, and both must extract the same encoded `StateUpdate` payload
/// @dev TEST ONLY. Keeps the single-slot shape the unbounded profiles require (one fold into
///      `answerRoot`, one event), with `GkVm.exec` where GasKillerChat calls `engine.chat`.
contract GkVmParityConsumer {
    address internal immutable GKVM;

    /// @notice Running fold of every answer (or recorded failure) — the one tracked slot
    bytes32 public answerRoot;

    event Answered(bytes32 indexed programHash, bytes32 indexed payloadHash, bytes output);
    event GuestFailed(bytes32 indexed programHash, bytes32 indexed payloadHash, bytes err);

    /// @param gkvm The Phase A seam: a GkVmFfiShim under forge, zero for the production constant
    constructor(address gkvm) {
        GKVM = gkvm == address(0) ? GKVM_ADDRESS : gkvm;
    }

    /// @notice The production shape: guest failures bubble and revert the tracked call
    function ask(bytes32 programHash, bytes32 artifactRoot, bytes calldata payload) external {
        _answered(programHash, payload, GkVm.exec(GKVM, programHash, artifactRoot, payload));
    }

    /// @notice As `ask`, but a guest failure is folded and logged instead of bubbling, so the typed
    ///         error bytes themselves land in the extracted payload
    /// @param guestGas Gas forwarded to the guest call, zero for everything available. Out of cycles
    ///        burns all of it, and the precompile's cycle budget is a function of it.
    function probe(bytes32 programHash, bytes32 artifactRoot, bytes calldata payload, uint256 guestGas) external {
        try this.execView{gas: guestGas == 0 ? gasleft() : guestGas}(programHash, artifactRoot, payload) returns (
            bytes memory output
        ) {
            _answered(programHash, payload, output);
        } catch (bytes memory err) {
            answerRoot = keccak256(abi.encode(answerRoot, keccak256(err)));
            emit GuestFailed(programHash, keccak256(payload), err);
        }
    }

    function execView(bytes32 programHash, bytes32 artifactRoot, bytes calldata payload)
        external
        view
        returns (bytes memory)
    {
        return GkVm.exec(GKVM, programHash, artifactRoot, payload);
    }

    function _answered(bytes32 programHash, bytes calldata payload, bytes memory output) private {
        answerRoot = keccak256(abi.encode(answerRoot, keccak256(output)));
        emit Answered(programHash, keccak256(payload), output);
    }
}
