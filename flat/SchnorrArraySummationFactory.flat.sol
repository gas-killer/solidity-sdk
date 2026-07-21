// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.6.2 ^0.8.0 ^0.8.27;

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
        uint256 length = types.length;
        require(length == args.length, InvalidArguments());
        for (uint256 i = 0; i < length; ++i) {
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
                assembly {
                    success := call(gas(), target, value, add(callargs, 0x20), mload(callargs), 0, 0)
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
                // `_validateLogArg` checks that `arg` is a canonical, in-bounds encoding before this reads
                // directly out of its buffer. The `data` length word sits at `base + canonicalOffset`, and
                // any topics sit inline in the head at `base + 0x20*k`.
                _validateLogArg(arg, 0x20);
                assembly {
                    let dataPtr := add(add(arg, 0x20), 0x20)
                    log0(add(dataPtr, 0x20), mload(dataPtr))
                }
            } else if (stateUpdateType == StateUpdateType.LOG1) {
                _validateLogArg(arg, 0x40);
                assembly {
                    let base := add(arg, 0x20)
                    let dataPtr := add(base, 0x40)
                    log1(add(dataPtr, 0x20), mload(dataPtr), mload(add(base, 0x20)))
                }
            } else if (stateUpdateType == StateUpdateType.LOG2) {
                _validateLogArg(arg, 0x60);
                assembly {
                    let base := add(arg, 0x20)
                    let dataPtr := add(base, 0x60)
                    log2(add(dataPtr, 0x20), mload(dataPtr), mload(add(base, 0x20)), mload(add(base, 0x40)))
                }
            } else if (stateUpdateType == StateUpdateType.LOG3) {
                _validateLogArg(arg, 0x80);
                assembly {
                    let base := add(arg, 0x20)
                    let dataPtr := add(base, 0x80)
                    log3(
                        add(dataPtr, 0x20),
                        mload(dataPtr),
                        mload(add(base, 0x20)),
                        mload(add(base, 0x40)),
                        mload(add(base, 0x60))
                    )
                }
            } else if (stateUpdateType == StateUpdateType.LOG4) {
                _validateLogArg(arg, 0xa0);
                assembly {
                    let base := add(arg, 0x20)
                    let dataPtr := add(base, 0xa0)
                    log4(
                        add(dataPtr, 0x20),
                        mload(dataPtr),
                        mload(add(base, 0x20)),
                        mload(add(base, 0x40)),
                        mload(add(base, 0x60)),
                        mload(add(base, 0x80))
                    )
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

    /// @notice Validate that `arg` is a canonical, in-bounds ABI encoding of a LOG payload
    /// @dev Reverts with `MalformedLogPayload` on a truncated head, a non-canonical `data` offset, or a
    ///      `data` length that runs past the end of `arg`. `canonicalOffset` is the encoding's head size
    ///      `0x20 * (numTopics + 1)` (0x20 for LOG0, 0x40 for LOG1, ... 0xa0 for LOG4); it is also where the
    ///      `data` length word lives, and every fixed `bytes32` topic sits within the head before it.
    /// @param arg The ABI-encoded LOG payload to validate
    /// @param canonicalOffset The expected offset of the `data` field (equals the encoding's head size)
    function _validateLogArg(bytes memory arg, uint256 canonicalOffset) private pure {
        uint256 len = arg.length;
        // The head (offset word + topics) and the `data` length word must both be readable.
        if (len < canonicalOffset + 0x20) revert MalformedLogPayload();
        uint256 off;
        uint256 dataLen;
        assembly {
            let base := add(arg, 0x20)
            off := mload(base)
            dataLen := mload(add(base, canonicalOffset))
        }
        // Offset must match what abi.encode produces, and the data bytes must fit inside `arg`.
        // `len >= canonicalOffset + 0x20` above makes the subtraction below safe.
        if (off != canonicalOffset) revert MalformedLogPayload();
        if (dataLen > len - canonicalOffset - 0x20) revert MalformedLogPayload();
    }

    /// @notice Thrown when `types` and `args` arrays have different lengths
    error InvalidArguments();

    /// @notice Thrown when a LOG operation's payload is not a canonical, in-bounds ABI encoding
    error MalformedLogPayload();

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

// src/schnorr/interface/ISchnorrGasKillerSDK.sol

/// @title ISchnorrGasKillerSDK
/// @notice Interface for SchnorrGasKillerSDK contracts
/// @dev Defines the core functionality that SchnorrGasKillerSDK implementations must
///      provide. State updates are approved by an operator quorum expressed as a
///      **single** aggregate Schnorr signature verified by a `SchnorrStakeRegistry`
///      (constant gas, non-signer subtraction) instead of `N` per-operator ECDSA
///      signatures. Deliberately single-function so
///      `type(ISchnorrGasKillerSDK).interfaceId` equals the `verifyAndUpdate`
///      selector — the router's ERC-165 preflight probes exactly this ID.
interface ISchnorrGasKillerSDK is IERC165 {
    /// @notice Verify the operators' aggregate Schnorr quorum signature and apply the
    ///         encoded state updates
    /// @param msgHash The hash of the message to verify (sha256 of the encoded task)
    /// @param referenceBlockNumber The block number at which operator keys and stake
    ///        weights are evaluated by the stake registry
    /// @param storageUpdates The storage updates to verify and apply
    /// @param transitionIndex The transition index
    /// @param targetFunction The target function selector
    /// @param s Aggregate Schnorr response scalar
    /// @param Raddr Aggregate nonce address `address(R)`
    /// @param nonSigners Operators that did not sign, in strictly ascending order
    function verifyAndUpdate(
        bytes32 msgHash,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes4 targetFunction,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners
    ) external;
}

// src/schnorr/SchnorrGasKillerSDK.sol

/// @title SchnorrGasKillerSDK
/// @notice Aggregate-Schnorr variant of `GasKillerSDK`. Identical task-hash and
///         state-update semantics; the only change is `_verifyQuorum`, which authorises a
///         state transition with a **single** aggregate Schnorr signature verified against
///         a `SchnorrStakeRegistry` (constant gas, non-signer subtraction) instead of `N`
///         per-operator ECDSA signatures verified against `ECDSAStakeRegistry`.
///
/// @dev The signed message is unchanged — `sha256(abi.encode(transitionIndex,
///      address(this), targetFunction, storageUpdates))` — so the off-chain digest and the
///      slashing/fraud-proof machinery are scheme-agnostic. The calldata swaps
///      `(operators[], signatures[])` for `(s, Raddr, nonSigners[])`.
abstract contract SchnorrGasKillerSDK is StateTracker, ISchnorrGasKillerSDK {
    struct SchnorrSDKStorage {
        address avsAddress;
        ISchnorrStakeRegistry registry;
        uint96 blockStaleMeasure;
    }

    // keccak256(abi.encode(uint256(keccak256("gaskiller.SchnorrGasKillerSDK.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION = 0x1d6f9f139320a34a32f3b29eb8638270178e831962a74100c9e8b433f21e1200;

    uint256 private constant DEFAULT_BLOCK_STALE_MEASURE = 300;

    error FutureBlockNumber();
    error StaleBlockNumber();
    error InvalidTransitionIndex();
    error InvalidSignature();
    error InvalidQuorumSignature();

    /// @notice Verify an aggregate Schnorr quorum signature and apply the state updates.
    /// @param msgHash             the task digest (recomputed and checked below).
    /// @param referenceBlockNumber block at which stake/keys are evaluated by the registry.
    /// @param storageUpdates      ABI-encoded `(StateUpdateType[], bytes[])`.
    /// @param transitionIndex     expected `stateTransitionCount() - 1`.
    /// @param targetFunction      selector bound into the digest.
    /// @param s                   aggregate Schnorr response scalar.
    /// @param Raddr               aggregate nonce address `address(R)`.
    /// @param nonSigners          operators that did not sign, strictly ascending.
    function verifyAndUpdate(
        bytes32 msgHash,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes4 targetFunction,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners
    ) external trackState {
        require(referenceBlockNumber < block.number, FutureBlockNumber());
        require((uint256(referenceBlockNumber) + _getBlockStaleMeasure()) >= block.number, StaleBlockNumber());

        require(transitionIndex + 1 == stateTransitionCount(), InvalidTransitionIndex());
        bytes32 expectedHash = sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates));
        require(expectedHash == msgHash, InvalidSignature());

        _verifyQuorum(msgHash, s, Raddr, nonSigners, referenceBlockNumber);

        _stateChangeHandler(storageUpdates);
    }

    function _verifyQuorum(
        bytes32 msgHash,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners,
        uint32 referenceBlockNumber
    ) private view {
        bool ok = _sto().registry.isValidSignature(msgHash, s, Raddr, nonSigners, referenceBlockNumber);
        require(ok, InvalidQuorumSignature());
    }

    function _stateChangeHandler(bytes calldata storageUpdates) internal {
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        StateChangeHandlerLib._runStateUpdates(types, args);
    }

    /// @notice Query if a contract implements an interface
    /// @dev Supports ERC-165 and ISchnorrGasKillerSDK interface detection (the router's
    ///      preflight probes the schnorr `verifyAndUpdate` selector before submitting)
    /// @param interfaceId The interface identifier, as specified in ERC-165
    /// @return `true` if the contract implements `interfaceId` and `false` otherwise
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(ISchnorrGasKillerSDK).interfaceId;
    }

    /// @notice Compute the expected message hash for a given transition, function, and storage updates
    /// @dev Exact mirror of the ECDSA `GasKillerSDK.getMessageHash` — the digest is
    ///      scheme-agnostic, so off-chain parity checks work unchanged.
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

    function schnorrRegistry() external view returns (address) {
        return address(_sto().registry);
    }

    function avsAddress() external view returns (address) {
        return _sto().avsAddress;
    }

    function blockStaleMeasure() external view returns (uint256) {
        return _getBlockStaleMeasure();
    }

    function _setAvsAddress(address _avsAddress) internal {
        _sto().avsAddress = _avsAddress;
    }

    function _setSchnorrRegistry(address _registry) internal {
        _sto().registry = ISchnorrStakeRegistry(_registry);
    }

    function _setBlockStaleMeasure(uint256 _blockStaleMeasure) internal {
        require(_blockStaleMeasure <= type(uint96).max, "stale measure overflow");
        _sto().blockStaleMeasure = uint96(_blockStaleMeasure);
    }

    function _getBlockStaleMeasure() internal view returns (uint256) {
        uint256 v = _sto().blockStaleMeasure;
        return v == 0 ? DEFAULT_BLOCK_STALE_MEASURE : v;
    }

    function _sto() private pure returns (SchnorrSDKStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}

// src/examples/array-summation/SchnorrArraySummation.sol

/// @title SchnorrArraySummation
/// @notice Example Gas Killer SDK consumer that maintains an on-chain array and computes sums off-chain
/// @dev Aggregate-Schnorr port of `ArraySummation`: identical array/sum semantics, but the
///      `verifyAndUpdate` path is inherited from `SchnorrGasKillerSDK`, so state updates are
///      approved by a single aggregate Schnorr signature verified against a
///      `SchnorrStakeRegistry` instead of `N` per-operator ECDSA signatures.
contract SchnorrArraySummation is SchnorrGasKillerSDK {
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

    /// @notice Deploy a new SchnorrArraySummation contract and initialise the array
    /// @param _avsAddress The AVS service manager address this contract is scoped to
    /// @param _schnorrStakeRegistry The Schnorr stake registry verifying aggregate operator quorums
    /// @param _arraySize Number of elements to generate; must be > 0
    /// @param _maxValue Exclusive upper bound for element values; must be > 0
    /// @param _seed Seed for pseudorandom generation; 0 falls back to `block.timestamp`
    constructor(
        address _avsAddress,
        address _schnorrStakeRegistry,
        uint256 _arraySize,
        uint256 _maxValue,
        uint256 _seed
    ) {
        _setAvsAddress(_avsAddress);
        _setSchnorrRegistry(_schnorrStakeRegistry);

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

// src/examples/array-summation/SchnorrArraySummationFactory.sol

/// @title SchnorrArraySummationFactory
/// @notice Factory contract for deploying SchnorrArraySummation contracts
/// @dev Allows permissionless deployment of new array summation contracts
///      and provides tracking functionality for deployed contracts
contract SchnorrArraySummationFactory {
    /// @notice Emitted when a new SchnorrArraySummation contract is deployed via this factory
    /// @param contractAddress Address of the newly deployed SchnorrArraySummation contract
    /// @param avsAddress The AVS service manager address passed to the contract
    /// @param schnorrStakeRegistry The Schnorr stake registry passed to the contract
    /// @param arraySize Number of elements in the initialised array
    /// @param maxValue Upper bound used for element generation
    /// @param seed Entropy seed used for array initialisation
    /// @param deploymentIndex Zero-based position of this deployment in `deployedContracts`
    event SchnorrArraySummationDeployed(
        address indexed contractAddress,
        address indexed avsAddress,
        address indexed schnorrStakeRegistry,
        uint256 arraySize,
        uint256 maxValue,
        uint256 seed,
        uint256 deploymentIndex
    );

    /// @notice Ordered list of all SchnorrArraySummation contracts deployed through this factory
    address[] public deployedContracts;

    /// @notice Quick membership check — true if an address was deployed by this factory
    mapping(address => bool) public isDeployedContract;

    /// @notice Deployment metadata keyed by contract address
    mapping(address => ContractInfo) public contractInfo;

    /// @notice Metadata recorded at deployment time for each SchnorrArraySummation contract
    struct ContractInfo {
        /// @notice The AVS service manager address the contract was configured with
        address avsAddress;
        /// @notice The Schnorr stake registry the contract was configured with
        address schnorrStakeRegistry;
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

    /// @notice Deploy a new SchnorrArraySummation contract
    /// @param _avsAddress The AVS service manager address for the new contract
    /// @param _schnorrStakeRegistry The Schnorr stake registry verifying aggregate operator quorums
    /// @param _arraySize The size of the array to initialize
    /// @param _maxValue The maximum value for array elements
    /// @param _seed The seed for array initialization
    /// @return contractAddress The address of the deployed contract
    function deploySchnorrArraySummation(
        address _avsAddress,
        address _schnorrStakeRegistry,
        uint256 _arraySize,
        uint256 _maxValue,
        uint256 _seed
    ) external returns (address contractAddress) {
        require(_avsAddress != address(0), "Invalid AVS address");

        // Deploy the new contract
        SchnorrArraySummation newContract =
            new SchnorrArraySummation(_avsAddress, _schnorrStakeRegistry, _arraySize, _maxValue, _seed);
        contractAddress = address(newContract);

        // Track the deployment
        uint256 deploymentIndex = deployedContracts.length;
        deployedContracts.push(contractAddress);
        isDeployedContract[contractAddress] = true;

        contractInfo[contractAddress] = ContractInfo({
            avsAddress: _avsAddress,
            schnorrStakeRegistry: _schnorrStakeRegistry,
            arraySize: _arraySize,
            maxValue: _maxValue,
            seed: _seed,
            deploymentIndex: deploymentIndex,
            deploymentTimestamp: block.timestamp
        });

        emit SchnorrArraySummationDeployed(
            contractAddress, _avsAddress, _schnorrStakeRegistry, _arraySize, _maxValue, _seed, deploymentIndex
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
