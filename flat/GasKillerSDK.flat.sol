// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.6.2 ^0.8.0 ^0.8.27;

// lib/eigenlayer-middleware/lib/openzeppelin-contracts-upgradeable/contracts/interfaces/IERC1271Upgradeable.sol

// OpenZeppelin Contracts v4.4.1 (interfaces/IERC1271.sol)

/**
 * @dev Interface of the ERC1271 standard signature validation method for
 * contracts as defined in https://eips.ethereum.org/EIPS/eip-1271[ERC-1271].
 *
 * _Available since v4.1._
 */
interface IERC1271Upgradeable {
    /**
     * @dev Should return whether the signature provided is valid for the provided data
     * @param hash      Hash of the data to be signed
     * @param signature Signature byte array associated with _data
     */
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue);
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

// src/interface/IGasKillerForwardee.sol

/// @title IGasKillerForwardee
/// @notice Interface for GasKiller contracts that accept storage updates forwarded by a
///         trusted peer as part of a multi-call bundle
/// @dev In multi-call mode, a forwarder embeds the callee's sub-payload as an ordinary
///      CALL update inside its own quorum-signed `storageUpdates` blob. The bundle root's
///      ECDSA quorum signature therefore transitively commits to every forwarded byte,
///      including the callee's expected transition index. The callee authorizes the
///      delivery via a per-contract trusted-forwarder allowlist.
///
///      This is intentionally a separate interface from `IGasKillerSDK` so that
///      multi-call-capable contracts remain distinguishable on-chain from older
///      deployments via ERC-165.
interface IGasKillerForwardee {
    /// @notice Thrown when `applyForwardedUpdates` is called by an address that is not an
    ///         allowlisted forwarder
    /// @param caller The unauthorized caller
    error UntrustedForwarder(address caller);

    /// @notice Thrown when attempting to allowlist a forwarder that has no code (an EOA or
    ///         an undeployed address); only deployed contracts may be trusted forwarders
    /// @param forwarder The address that was rejected
    error InvalidForwarder(address forwarder);

    /// @notice Thrown when a forwarded STORE operation targets a reserved slot
    ///         (the state-transition counter or the SDK configuration slots)
    /// @param index The zero-based position of the offending operation in the batch
    /// @param slot The reserved storage slot that was targeted
    error ReservedSlot(uint256 index, bytes32 slot);

    /// @notice Emitted after a forwarded update batch has been applied
    /// @param forwarder The trusted forwarder that delivered the updates
    /// @param transitionIndex The transition index the batch was applied at
    event ForwardedUpdatesApplied(address indexed forwarder, uint256 indexed transitionIndex);

    /// @notice Apply storage updates forwarded by a trusted GasKiller peer
    /// @dev Payable so a forwarding CALL update can carry the ETH the original call
    ///      transferred. Reverts unless `msg.sender` is an allowlisted forwarder and
    ///      `expectedTransitionIndex` matches this contract's pre-call transition count.
    /// @param storageUpdates ABI-encoded `(StateUpdateType[], bytes[])` pair
    /// @param expectedTransitionIndex The transition count this contract must have had
    ///        immediately before this call
    function applyForwardedUpdates(bytes calldata storageUpdates, uint256 expectedTransitionIndex) external payable;

    /// @notice Query whether an address is an allowlisted forwarder
    /// @param forwarder The address to query
    /// @return `true` if `forwarder` may call `applyForwardedUpdates`
    function isTrustedForwarder(address forwarder) external view returns (bool);
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

// src/interface/IGasKillerSDK.sol

/// @title IGasKillerSDK
/// @notice Interface for GasKillerSDK contracts
/// @dev Defines the core functionality that GasKillerSDK implementations must provide.
///      State updates are approved by an ECDSA operator quorum verified by EigenLayer's
///      `ECDSAStakeRegistry` (ERC-1271 `isValidSignature`): operators sign the task
///      digest with their registered signing keys, and the registry checks each
///      signature and the signed stake weight at the reference block.
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

    /// @notice Thrown when the stake registry does not return the ERC-1271 magic value
    error InvalidQuorumSignature();

    /// @notice Thrown when `referenceBlockNumber` is older than `blockStaleMeasure` blocks ago
    error StaleBlockNumber();

    /// @notice Thrown when `referenceBlockNumber` is greater than or equal to the current block number
    error FutureBlockNumber();

    /// @notice Verify the operators' ECDSA quorum signatures and apply the encoded state updates
    /// @param msgHash The hash of the message to verify (sha256 of the encoded task)
    /// @param referenceBlockNumber The block number at which operator signing keys and
    ///        stake weights are evaluated by the stake registry
    /// @param storageUpdates The storage updates to verify and apply
    /// @param transitionIndex The transition index
    /// @param targetFunction The target function selector
    /// @param operators Operator addresses that signed, in strictly ascending order
    /// @param signatures 65-byte `r || s || v` ECDSA signatures over `msgHash`,
    ///        index-aligned with `operators`
    function verifyAndUpdate(
        bytes32 msgHash,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes4 targetFunction,
        address[] calldata operators,
        bytes[] calldata signatures
    ) external;
}

// src/GasKillerSDK.sol

/// @title GasKillerSDK
/// @notice Base SDK for implementing Gas Killer functionality in contracts
/// @dev Inherit from this contract to add Gas Killer capabilities to your contract.
///
///      State updates are authorised by an ECDSA operator quorum verified by
///      EigenLayer's `ECDSAStakeRegistry` (eigenlayer-middleware). The registry is
///      the source of truth for the operator set, per-operator signing keys, and
///      stake weights: `verifyAndUpdate` forwards the operators' 65-byte
///      `r || s || v` signatures to the registry's ERC-1271 `isValidSignature`,
///      which validates each signature against the operator's registered signing
///      key at `referenceBlockNumber` and enforces the configured stake-weight
///      threshold at that block.
abstract contract GasKillerSDK is StateTracker, IGasKillerSDK, IGasKillerForwardee {
    /// @custom:storage-location erc7201:gaskiller.GasKillerSDKECDSA.storage
    struct GasKillerSDKStorage {
        /// @notice Namespace derived from the AVS address; used to scope this contract within the AVS
        bytes namespace;
        /// @notice The AVS service manager address
        address avsAddress;
        /// @notice The EigenLayer ECDSA stake registry used to verify operator quorum signatures
        IERC1271Upgradeable ecdsaStakeRegistry;
        /// @notice Maximum number of blocks a reference block may lag behind the current block
        uint256 blockStaleMeasure;
        /// @notice Peers allowed to deliver forwarded updates via `applyForwardedUpdates`
        /// @dev Append-only struct: new fields must be added after this one, never reordered
        mapping(address => bool) trustedForwarders;
    }

    // keccak256(abi.encode(uint256(keccak256("gaskiller.GasKillerSDKECDSA.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant GAS_KILLER_SDK_STORAGE_LOCATION =
        0x6056deb87cab365bf76a6725b8b096dec334581845ea9d3c2627f8b0efdde700;

    /// @notice Number of fixed storage slots occupied by `GasKillerSDKStorage`; these are
    ///         reserved and may not be written by forwarded STORE operations
    uint256 private constant GAS_KILLER_SDK_STORAGE_SLOT_COUNT = 5;

    /// @notice Default maximum age (in blocks) a reference block is considered valid when none is configured
    uint256 private constant DEFAULT_BLOCK_STALE_MEASURE = 300;

    /// @notice Verify the operators' ECDSA quorum signatures and apply the encoded state updates
    /// @param msgHash The hash of the message to verify
    /// @param referenceBlockNumber The block number at which operator signing keys and
    ///        stake weights are evaluated by the stake registry
    /// @param storageUpdates The storage updates to verify and apply
    /// @param transitionIndex The transition index
    /// @param targetFunction The target function selector
    /// @param operators Operator addresses that signed, in strictly ascending order
    /// @param signatures 65-byte `r || s || v` ECDSA signatures over `msgHash`,
    ///        index-aligned with `operators`
    function verifyAndUpdate(
        bytes32 msgHash,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes4 targetFunction,
        address[] calldata operators,
        bytes[] calldata signatures
    ) external trackState {
        // Check block number validity
        require(referenceBlockNumber < block.number, FutureBlockNumber());
        require((uint256(referenceBlockNumber) + _getBlockStaleMeasure()) >= block.number, StaleBlockNumber());

        // Verify transition index and message hash
        require(transitionIndex + 1 == stateTransitionCount(), InvalidTransitionIndex());
        bytes32 expectedHash = sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates));
        require(expectedHash == msgHash, InvalidSignature());

        // Verify the quorum signatures via EigenLayer's ECDSAStakeRegistry
        _verifyQuorum(msgHash, referenceBlockNumber, operators, signatures);

        // Apply the state changes
        _stateChangeHandler(storageUpdates);
    }

    /// @notice Verify an operator quorum via the stake registry's ERC-1271 endpoint
    /// @dev The registry checks: operators strictly ascending, every signature valid
    ///      against the operator's signing key at the reference block, and signed
    ///      stake weight >= the configured threshold at that block. It reverts on
    ///      any failure; the magic-value check guards against a misconfigured
    ///      registry address.
    function _verifyQuorum(
        bytes32 msgHash,
        uint32 referenceBlockNumber,
        address[] calldata operators,
        bytes[] calldata signatures
    ) private view {
        IERC1271Upgradeable registry = _getGasKillerSDKStorage().ecdsaStakeRegistry;
        // A registry accidentally set to an EOA or address(0) would make the high-level
        // call below revert opaquely during return-data decoding. Guard so misconfiguration
        // surfaces the intended error deterministically instead of an empty revert.
        require(address(registry).code.length > 0, InvalidQuorumSignature());
        bytes4 magicValue = registry.isValidSignature(msgHash, abi.encode(operators, signatures, referenceBlockNumber));
        require(magicValue == IERC1271Upgradeable.isValidSignature.selector, InvalidQuorumSignature());
    }

    /// @notice Apply storage updates forwarded by a trusted GasKiller peer
    /// @dev Multi-call mode: the forwarder embeds this call as an ordinary CALL update
    ///      inside its own quorum-signed `storageUpdates`, so the bundle root's ECDSA
    ///      quorum signature transitively commits to both `storageUpdates` and
    ///      `expectedTransitionIndex`. Freshness is gated once at the bundle root's
    ///      `verifyAndUpdate`; this entrypoint enforces caller trust, transition
    ///      sequencing, and the reserved-slot policy. Payable so the forwarding CALL can
    ///      carry the ETH the original call transferred. Sub-payloads may themselves
    ///      contain forwarding CALLs, so bundles recurse across the call graph.
    /// @param storageUpdates ABI-encoded `(StateUpdateType[], bytes[])` pair
    /// @param expectedTransitionIndex The transition count this contract must have had
    ///        immediately before this call
    function applyForwardedUpdates(bytes calldata storageUpdates, uint256 expectedTransitionIndex)
        external
        payable
        trackState
    {
        require(_getGasKillerSDKStorage().trustedForwarders[msg.sender], UntrustedForwarder(msg.sender));
        require(expectedTransitionIndex + 1 == stateTransitionCount(), InvalidTransitionIndex());

        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        require(types.length == args.length, StateChangeHandlerLib.InvalidArguments());
        for (uint256 i = 0; i < types.length; i++) {
            if (types[i] == StateUpdateType.STORE) {
                (bytes32 slot,) = abi.decode(args[i], (bytes32, bytes32));
                require(!_isReservedSlot(slot), ReservedSlot(i, slot));
            }
        }
        StateChangeHandlerLib._runStateUpdates(types, args);

        emit ForwardedUpdatesApplied(msg.sender, expectedTransitionIndex);
    }

    /// @notice Query whether an address is an allowlisted forwarder
    /// @param forwarder The address to query
    /// @return `true` if `forwarder` may call `applyForwardedUpdates`
    function isTrustedForwarder(address forwarder) external view returns (bool) {
        return _getGasKillerSDKStorage().trustedForwarders[forwarder];
    }

    /// @notice Query if a contract implements an interface
    /// @dev Supports ERC-165, IGasKillerSDK, and IGasKillerForwardee interface detection
    /// @param interfaceId The interface identifier, as specified in ERC-165
    /// @return `true` if the contract implements `interfaceId` and `false` otherwise
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IGasKillerSDK).interfaceId
            || interfaceId == type(IGasKillerForwardee).interfaceId;
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

    /// @notice Return the configured EigenLayer ECDSA stake registry address
    /// @return The stake registry address
    function ecdsaStakeRegistry() external view returns (address) {
        return address(_getGasKillerSDKStorage().ecdsaStakeRegistry);
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

    /// @notice Set the EigenLayer ECDSA stake registry contract
    /// @param _ecdsaStakeRegistry The new stake registry address
    function _setECDSAStakeRegistry(address _ecdsaStakeRegistry) internal {
        _getGasKillerSDKStorage().ecdsaStakeRegistry = IERC1271Upgradeable(_ecdsaStakeRegistry);
    }

    /// @notice Allow or revoke a peer for `applyForwardedUpdates`
    /// @dev An allowlisted forwarder can write any non-reserved storage slot of this
    ///      contract, so only allowlist immutable, unmodified-SDK contracts. An EOA (or any
    ///      address with no code) can never be a valid forwarder — it would be able to call
    ///      `applyForwardedUpdates` directly and write arbitrary non-reserved state with no
    ///      quorum verification — so granting trust to a codeless address is rejected as a
    ///      misconfiguration. This also means a forwarder must already be deployed before it
    ///      is allowlisted (allowlisting a CREATE2-precomputed-but-undeployed address is not
    ///      supported, and is unsafe anyway since its code cannot yet be inspected). Post-deploy
    ///      changes need no extra admin root: the quorum can toggle an entry with a signed
    ///      STORE to `keccak256(abi.encode(forwarder, uint256(GAS_KILLER_SDK_STORAGE_LOCATION) + 4))`
    ///      through this contract's own `verifyAndUpdate` (that path bypasses this guard, so
    ///      the operator-side signing policy must apply the same code-presence check).
    /// @param forwarder The forwarder address
    /// @param trusted Whether the forwarder should be trusted
    function _setTrustedForwarder(address forwarder, bool trusted) internal {
        require(!trusted || forwarder.code.length > 0, InvalidForwarder(forwarder));
        _getGasKillerSDKStorage().trustedForwarders[forwarder] = trusted;
    }

    /// @notice Check whether a slot may not be written by a forwarded STORE
    /// @dev Covers the state-transition counter and the fixed `GasKillerSDKStorage` slots.
    ///      Mapping entries (e.g. individual `trustedForwarders` keys) live at
    ///      keccak-derived slots that cannot be enumerated from a slot value alone, so this
    ///      range check cannot block them. Consequently a forwarded STORE can, in principle,
    ///      write `trustedForwarders[x] = true` for an arbitrary `x` (even an EOA), which
    ///      would let `x` call `applyForwardedUpdates` directly without a fresh quorum
    ///      verification — i.e. mint a new non-quorum writer. This is the sharpest form of
    ///      the accepted risk that "an allowlisted forwarder is root over this contract"
    ///      (see design/multicall-mode.md, risk R1). It is bounded, not eliminated, by two
    ///      facts: (1) emitting such a STORE still requires a quorum-signed forwarded
    ///      bundle, so it is no more powerful than the quorum writing the same slot through
    ///      this contract's own `verifyAndUpdate`; and (2) the honest analyzer only forwards
    ///      a peer's *observed* state diff, which never touches the peer's allowlist — so the
    ///      vector requires a malicious/buggy analyzer AND a colluding quorum. The
    ///      compensating control is policy: allowlist only immutable, unmodified-SDK peers,
    ///      whose code provably never forwards a STORE into another contract's allowlist.
    ///      Fully closing it (so a forwarded STORE can never grant a forwarder even under
    ///      quorum collusion) requires a tamper-evident, enumerable allowlist whose
    ///      membership is anchored in a reserved (range-checkable) length slot; that is a
    ///      storage-layout change tracked as a follow-up rather than part of this change.
    /// @param slot The storage slot to check
    /// @return `true` if the slot is reserved
    function _isReservedSlot(bytes32 slot) internal pure returns (bool) {
        if (slot == STATE_TRACKER_STORAGE_LOCATION) return true;
        uint256 base = uint256(GAS_KILLER_SDK_STORAGE_LOCATION);
        return uint256(slot) >= base && uint256(slot) < base + GAS_KILLER_SDK_STORAGE_SLOT_COUNT;
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
