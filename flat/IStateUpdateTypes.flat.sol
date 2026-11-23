// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

// src/interface/IStateUpdateTypes.sol

/// @title IStateUpdateTypes
/// @notice Typed structs representing each `StateUpdateType` operation payload
/// @dev Only relevant for off-chain ABI consumers (e.g. alloy); mirrors the encoding
///      expected by `StateChangeHandlerLib._runStateUpdates`
// NOTE: only relevant for alloy
interface IStateUpdateTypes {
    /// @notice Payload for a STORE operation — write `value` to `slot`
    struct Store {
        /// @notice The 32-byte storage slot to write to
        bytes32 slot;
        /// @notice The 32-byte value to write into the slot
        bytes32 value;
    }

    /// @notice Payload for a CALL operation — external call with optional ETH transfer
    struct Call {
        /// @notice The contract address to call
        address target;
        /// @notice ETH value (in wei) to forward with the call
        uint256 value;
        /// @notice ABI-encoded calldata to pass to the target
        bytes callargs;
        /// @notice `keccak256(abi.encodePacked(success, returndata))` the trace observed, or zero
        ///         to require success without checking the return data
        bytes32 resultHash;
        /// @notice The gas operand the traced CALL passed, replayed as is: 0 for a `transfer` or
        ///         `send` (the EVM adds the stipend), the cap for `f{gas: n}()`, and the large
        ///         `gas()` the trace saw for a call that forwarded everything
        uint256 gasLimit;
    }

    /// @notice Payload for a CREATE operation — deploy with a nonce-derived address
    struct Create {
        /// @notice ETH value (in wei) to endow the new contract with
        uint256 value;
        /// @notice The initcode to run
        bytes initcode;
        /// @notice The address the trace deployed to, or zero to leave it unchecked
        address expected;
    }

    /// @notice Payload for a CREATE2 operation — deploy with a salt-derived address
    struct Create2 {
        /// @notice The salt
        bytes32 salt;
        /// @notice ETH value (in wei) to endow the new contract with
        uint256 value;
        /// @notice The initcode to run
        bytes initcode;
    }

    /// @notice Payload for a LOG0 operation — emit a log with no indexed topics
    struct Log0 {
        /// @notice Unindexed log data
        bytes data;
    }

    /// @notice Payload for a LOG1 operation — emit a log with one indexed topic
    struct Log1 {
        /// @notice Unindexed log data
        bytes data;
        /// @notice First indexed topic
        bytes32 topic1;
    }

    /// @notice Payload for a LOG2 operation — emit a log with two indexed topics
    struct Log2 {
        /// @notice Unindexed log data
        bytes data;
        /// @notice First indexed topic
        bytes32 topic1;
        /// @notice Second indexed topic
        bytes32 topic2;
    }

    /// @notice Payload for a LOG3 operation — emit a log with three indexed topics
    struct Log3 {
        /// @notice Unindexed log data
        bytes data;
        /// @notice First indexed topic
        bytes32 topic1;
        /// @notice Second indexed topic
        bytes32 topic2;
        /// @notice Third indexed topic
        bytes32 topic3;
    }

    /// @notice Payload for a LOG4 operation — emit a log with four indexed topics
    struct Log4 {
        /// @notice Unindexed log data
        bytes data;
        /// @notice First indexed topic
        bytes32 topic1;
        /// @notice Second indexed topic
        bytes32 topic2;
        /// @notice Third indexed topic
        bytes32 topic3;
        /// @notice Fourth indexed topic
        bytes32 topic4;
    }

    /// @notice Payload for a NESTED operation — apply a callee's own signed frame of the tree
    struct Nested {
        /// @notice The SDK-enabled callee whose frame this is
        address target;
        /// @notice ETH value (in wei) forwarded to the callee, as in the native call
        uint256 value;
        /// @notice The callee frame's leaf hash, signed as part of this program
        bytes32 childLeaf;
    }

    /// @notice Payload for a STATICCALL_CHECK operation — re-run a read and check its result
    struct StaticCallCheck {
        /// @notice The contract the trace read from
        address target;
        /// @notice The read's calldata
        bytes data;
        /// @notice `keccak256(abi.encodePacked(success, returndata))` the trace observed
        bytes32 resultHash;
    }

    /// @notice Payload for a BALANCE_CHECK operation — check an account's ETH balance
    struct BalanceCheck {
        /// @notice The account, the running contract included
        address account;
        /// @notice The balance the trace observed
        uint256 balance;
    }

    /// @notice Payload for a CODEHASH_CHECK operation — check an account's code hash
    struct CodehashCheck {
        /// @notice The account
        address account;
        /// @notice The code hash the trace observed; zero for an empty account
        bytes32 codehash;
    }
}
