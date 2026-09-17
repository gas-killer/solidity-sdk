// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.4;

// Typed errors of the gkvm precompile (UNBOUNDED_V3). The precompile reverts with these as
// ABI-encoded returndata and `GkVm.exec` bubbles them unchanged, so consumers and tests match
// on the selectors declared here. See src/examples/onchain-llm/UNBOUNDED_V3_NATIVE.md
// (§ Error semantics).

/// @notice No gkvm precompile answered at the target address
/// @dev On any real chain the gkvm address is an empty account: the STATICCALL succeeds with
///      empty returndata. Raised by `GkVm.exec` itself (never by the precompile) whenever the
///      returndata lacks the mandatory `GKVM_OK_TAG` prefix.
error GkVmUnavailable();

/// @notice The guest called `gk_abort(code, msg)`, or hit a spec'd trap (illegal instruction, bad ELF semantics)
/// @param code Guest-chosen abort code, or a spec'd trap code
/// @param data Guest-supplied abort message bytes
error GkGuestTrap(uint32 code, bytes data);

/// @notice The guest exhausted its cycle budget
/// @param used Cycles the guest retired
/// @param limit Cycle budget derived from the call's gas
error GkGuestOutOfCycles(uint64 used, uint64 limit);

/// @notice The call payload exceeds `GKVM_INPUT_BYTES_CAP`
error GkVmInputOverflow();

/// @notice The guest output exceeds `GKVM_OUTPUT_BYTES_CAP`
error GkVmOutputOverflow();

/// @notice The precompile was invoked outside a STATICCALL
error GkVmStaticOnly();
