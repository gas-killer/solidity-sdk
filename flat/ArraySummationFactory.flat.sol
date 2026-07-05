// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.6.2 ^0.8.0 ^0.8.13 ^0.8.27;

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
abstract contract GasKillerSDK is StateTracker, IGasKillerSDK {
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
    }

    // keccak256(abi.encode(uint256(keccak256("gaskiller.GasKillerSDKECDSA.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant GAS_KILLER_SDK_STORAGE_LOCATION =
        0x6056deb87cab365bf76a6725b8b096dec334581845ea9d3c2627f8b0efdde700;

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

// src/examples/array-summation/ArraySummation.sol

/// @title ArraySummation
/// @notice Example Gas Killer SDK consumer that maintains an on-chain array and computes sums off-chain
/// @dev Demonstrates how to integrate GasKillerSDK: the `sum` and `setArrayElement` functions
///      are guarded by `trackState` so off-chain operators can propose the state update via
///      `verifyAndUpdate` rather than running the computation on-chain.
contract ArraySummation is GasKillerSDK {
    /// @notice Thrown when constructor arguments would produce an unusable contract
    error InvalidConfiguration();

    /// @notice Emitted whenever a new sum is computed and stored
    /// @param newSum The newly computed sum
    /// @param timestamp The block timestamp at the time of computation
    event SumCalculated(uint256 newSum, uint256 timestamp);

    /// @notice Emitted once during construction after the array is populated
    /// @param size The number of elements initialised in the array
    event ArrayInitialized(uint256 size);

    /// @notice Number of elements in `values`; fixed at construction
    uint256 public immutable arraySize;

    /// @notice Upper bound (exclusive) for randomly generated array element values
    uint256 public immutable maxValue;

    /// @notice The most recently computed sum of selected array elements
    uint256 public currentSum;

    /// @notice The underlying array of pseudorandom values
    uint256[] public values;

    /// @notice Deploy a new ArraySummation contract and initialise the array
    /// @param _avsAddress The AVS service manager address used for ECDSA quorum validation
    /// @param _ecdsaStakeRegistry The EigenLayer ECDSA stake registry address
    /// @param _arraySize Number of elements to generate; must be > 0
    /// @param _maxValue Exclusive upper bound for element values; must be > 0
    /// @param _seed Seed for pseudorandom generation; 0 falls back to `block.timestamp`
    constructor(
        address _avsAddress,
        address _ecdsaStakeRegistry,
        uint256 _arraySize,
        uint256 _maxValue,
        uint256 _seed
    ) {
        _setAvsAddress(_avsAddress);
        _setECDSAStakeRegistry(_ecdsaStakeRegistry);

        if (_arraySize == 0 || _maxValue == 0) {
            revert InvalidConfiguration();
        }

        arraySize = _arraySize;
        maxValue = _maxValue;

        _initializeArray(_seed);
    }

    /// @notice Populate `values` with `arraySize` pseudorandom entries bounded by `maxValue`
    /// @param _seed Entropy source; falls back to `block.timestamp` when 0
    function _initializeArray(uint256 _seed) private {
        if (_seed == 0) {
            _seed = block.timestamp;
        }

        uint256 hashedSeed = uint256(keccak256(abi.encode(_seed)));
        for (uint256 i = 0; i < arraySize; i++) {
            values.push(uint256(keccak256(abi.encode(hashedSeed, i))) % maxValue);
        }

        emit ArrayInitialized(arraySize);
    }

    /// @notice Calculate the sum of specified array elements and record the state transition
    /// @dev Pass an empty `indexes` array to sum all elements
    /// @param indexes Zero-based positions in `values` to include in the sum
    function sum(uint256[] calldata indexes) public trackState {
        _calculateSum(indexes);
    }

    /// @notice Compute the sum of the specified elements and store it in `currentSum`
    /// @param indexes Zero-based positions to sum; sums the full array when empty
    function _calculateSum(uint256[] calldata indexes) internal {
        uint256 total = 0;

        if (indexes.length == 0) {
            // If no indexes provided, sum all elements
            for (uint256 i = 0; i < values.length; i++) {
                total += values[i];
            }
        } else {
            // Sum only specified indexes
            for (uint256 i = 0; i < indexes.length; i++) {
                require(indexes[i] < values.length, "Index out of bounds");
                total += values[indexes[i]];
            }
        }

        currentSum = total;
        emit SumCalculated(total, block.timestamp);
    }

    /// @notice Return the value at a specific array index
    /// @param index Zero-based position in `values`
    /// @return The element stored at `index`
    function getArrayElement(uint256 index) public view returns (uint256) {
        require(index < values.length, "Index out of bounds");
        return values[index];
    }

    /// @notice Return the number of elements in `values`
    /// @return The length of the array
    function getArrayLength() public view returns (uint256) {
        return values.length;
    }

    /// @notice Return a memory copy of the full `values` array
    /// @return The entire array of stored values
    function getFullArray() public view returns (uint256[] memory) {
        return values;
    }

    /// @notice Overwrite a single array element and record the state transition
    /// @param index Zero-based position in `values` to update
    /// @param newValue Replacement value to store at `index`
    function setArrayElement(uint256 index, uint256 newValue) public trackState {
        require(index < values.length, "Index out of bounds");
        values[index] = newValue;
    }

    /// @notice Clear the array and reinitialise it with a new seed, recording the state transition
    /// @param _seed Entropy source for regeneration; 0 falls back to `block.timestamp`
    function resetArray(uint256 _seed) public trackState {
        delete values;
        _initializeArray(_seed);
    }
}

// src/examples/array-summation/ArraySummationFactory.sol

/// @title ArraySummationFactory
/// @notice Factory contract for deploying ArraySummation contracts
/// @dev Allows permissionless deployment of new array summation contracts
///      and provides tracking functionality for deployed contracts
contract ArraySummationFactory {
    /// @notice Emitted when a new ArraySummation contract is deployed via this factory
    /// @param contractAddress Address of the newly deployed ArraySummation contract
    /// @param avsAddress The AVS service manager address passed to the contract
    /// @param ecdsaStakeRegistry The ECDSA stake registry address passed to the contract
    /// @param arraySize Number of elements in the initialised array
    /// @param maxValue Upper bound used for element generation
    /// @param seed Entropy seed used for array initialisation
    /// @param deploymentIndex Zero-based position of this deployment in `deployedContracts`
    event ArraySummationDeployed(
        address indexed contractAddress,
        address indexed avsAddress,
        address indexed ecdsaStakeRegistry,
        uint256 arraySize,
        uint256 maxValue,
        uint256 seed,
        uint256 deploymentIndex
    );

    /// @notice Ordered list of all ArraySummation contracts deployed through this factory
    address[] public deployedContracts;

    /// @notice Quick membership check — true if an address was deployed by this factory
    mapping(address => bool) public isDeployedContract;

    /// @notice Deployment metadata keyed by contract address
    mapping(address => ContractInfo) public contractInfo;

    /// @notice Metadata recorded at deployment time for each ArraySummation contract
    struct ContractInfo {
        /// @notice The AVS service manager address the contract was configured with
        address avsAddress;
        /// @notice The ECDSA stake registry address the contract was configured with
        address ecdsaStakeRegistry;
        /// @notice Number of elements in the contract's array
        uint256 arraySize;
        /// @notice Upper bound used for element generation
        uint256 maxValue;
        /// @notice Entropy seed used at deployment
        uint256 seed;
        /// @notice Zero-based index of this contract in `deployedContracts`
        uint256 deploymentIndex;
        /// @notice `block.timestamp` at the time of deployment
        uint256 deploymentTimestamp;
    }

    /// @notice Deploy a new ArraySummation contract
    /// @param _avsAddress The AVS service manager address for the new contract
    /// @param _ecdsaStakeRegistry The ECDSA stake registry address for the new contract
    /// @param _arraySize The size of the array to initialize
    /// @param _maxValue The maximum value for array elements
    /// @param _seed The seed for array initialization
    /// @return contractAddress The address of the deployed contract
    function deployArraySummation(
        address _avsAddress,
        address _ecdsaStakeRegistry,
        uint256 _arraySize,
        uint256 _maxValue,
        uint256 _seed
    ) external returns (address contractAddress) {
        require(_avsAddress != address(0), "Invalid AVS address");

        // Deploy the new contract
        ArraySummation newContract = new ArraySummation(_avsAddress, _ecdsaStakeRegistry, _arraySize, _maxValue, _seed);
        contractAddress = address(newContract);

        // Track the deployment
        uint256 deploymentIndex = deployedContracts.length;
        deployedContracts.push(contractAddress);
        isDeployedContract[contractAddress] = true;

        contractInfo[contractAddress] = ContractInfo({
            avsAddress: _avsAddress,
            ecdsaStakeRegistry: _ecdsaStakeRegistry,
            arraySize: _arraySize,
            maxValue: _maxValue,
            seed: _seed,
            deploymentIndex: deploymentIndex,
            deploymentTimestamp: block.timestamp
        });

        emit ArraySummationDeployed(
            contractAddress, _avsAddress, _ecdsaStakeRegistry, _arraySize, _maxValue, _seed, deploymentIndex
        );
    }

    /// @notice Return the total number of contracts deployed by this factory
    /// @return count The number of deployed contracts
    function getDeployedContractCount() external view returns (uint256 count) {
        return deployedContracts.length;
    }

    /// @notice Return all contract addresses deployed by this factory
    /// @return addresses Array of all deployed contract addresses
    function getAllDeployedContracts() external view returns (address[] memory addresses) {
        return deployedContracts;
    }

    /// @notice Return a slice of deployed contract addresses
    /// @param _startIndex Starting index (inclusive)
    /// @param _endIndex Ending index (exclusive)
    /// @return addresses Array of contract addresses in the specified range
    function getDeployedContractsRange(uint256 _startIndex, uint256 _endIndex)
        external
        view
        returns (address[] memory addresses)
    {
        require(_startIndex < deployedContracts.length, "Start index out of bounds");
        require(_endIndex <= deployedContracts.length, "End index out of bounds");
        require(_startIndex < _endIndex, "Invalid range");

        uint256 length = _endIndex - _startIndex;
        addresses = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            addresses[i] = deployedContracts[_startIndex + i];
        }
    }

    /// @notice Return the deployment metadata for a specific contract
    /// @param _contractAddress The address of the deployed contract
    /// @return info The contract information
    function getContractInfo(address _contractAddress) external view returns (ContractInfo memory info) {
        require(isDeployedContract[_contractAddress], "Contract not deployed by factory");
        return contractInfo[_contractAddress];
    }

    /// @notice Return all contracts deployed for a given AVS address
    /// @param _avsAddress The AVS address to filter by
    /// @return addresses Array of contract addresses deployed by the AVS
    function getContractsByAVS(address _avsAddress) external view returns (address[] memory addresses) {
        uint256 count = 0;

        // First pass: count matching contracts
        for (uint256 i = 0; i < deployedContracts.length; i++) {
            if (contractInfo[deployedContracts[i]].avsAddress == _avsAddress) {
                count++;
            }
        }

        // Second pass: collect addresses
        addresses = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < deployedContracts.length; i++) {
            if (contractInfo[deployedContracts[i]].avsAddress == _avsAddress) {
                addresses[index] = deployedContracts[i];
                index++;
            }
        }
    }

    /// @notice Check whether a contract was deployed by this factory
    /// @param _contractAddress The address to verify
    /// @return deployed True if the contract was deployed by this factory
    function isContractDeployedByFactory(address _contractAddress) external view returns (bool deployed) {
        return isDeployedContract[_contractAddress];
    }
}
