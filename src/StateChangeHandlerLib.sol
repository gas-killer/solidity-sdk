// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

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
/// @dev Processes ABI-encoded arrays of typed state updates; supports STORE, CALL, and LOG0-LOG4
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
