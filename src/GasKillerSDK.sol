// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {
    IBLSSignatureChecker,
    IBLSSignatureCheckerTypes
} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";

import {BLSQuorumLib} from "./BLSQuorumLib.sol";
import {IGasKillerSDK} from "./interface/IGasKillerSDK.sol";
import {IGasKillerSlasher} from "./interface/IGasKillerSlasher.sol";
import {StateTracker} from "./StateTracker.sol";
import {TransitionGuard} from "./TransitionGuard.sol";
import {StateChangeHandlerLib, StateUpdateType} from "./StateChangeHandlerLib.sol";

/// @title GasKillerSDK
/// @notice Base SDK for implementing Gas Killer functionality in contracts
/// @dev Inherit from this contract to add Gas Killer capabilities to your contract.
///
///      `verifyAndUpdate` is `guardTransition`-protected (see `TransitionGuard`): a `CALL`
///      state update runs arbitrary external code mid-transition, so re-entering
///      `verifyAndUpdate` with the *next* transition's valid quorum signature would
///      otherwise interleave two signed transitions. The same transient flag is queryable
///      as `inTransition()` so external readers can reject mid-transition state.
abstract contract GasKillerSDK is StateTracker, TransitionGuard, IGasKillerSDK {
    /// @custom:storage-location erc7201:gaskiller.GasKillerSDK.storage
    struct GasKillerSDKStorage {
        /// @notice Deprecated. Maintained to preserve storage layout. Now derived on read by `namespace()`
        bytes __deprecated_namespace;
        /// @notice The AVS service manager address
        address avsAddress;
        /// @notice The BLS signature checker contract used to verify operator signatures
        IBLSSignatureChecker blsSignatureChecker;
        /// @notice Maximum number of blocks a reference block may lag behind the current block
        uint256 blockStaleMeasure;
        /// @notice Optional Gas Killer slasher; when set, applied commitments are recorded for challenge-window tracking
        IGasKillerSlasher slasher;
    }

    // keccak256(abi.encode(uint256(keccak256("gaskiller.GasKillerSDK.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant GAS_KILLER_SDK_STORAGE_LOCATION =
        0x321ebf629ed2e1e368f0890e8fdd95cf9a2ae5961b66a1805f0b2ec84e21d000;

    /// @notice Denominator used when evaluating stake percentage thresholds (representing 100%)
    /// @dev Exposed for integrators; the value itself lives in `BLSQuorumLib`, which owns the
    ///      admission rule shared with `GasKillerBLSSlasher`.
    uint8 public constant THRESHOLD_DENOMINATOR = BLSQuorumLib.THRESHOLD_DENOMINATOR;

    /// @notice Minimum percentage of quorum stake that must have signed to approve a state update (QUORUM_THRESHOLD/THRESHOLD_DENOMINATOR)
    /// @dev See [`THRESHOLD_DENOMINATOR`] on where the value is defined.
    uint8 public constant QUORUM_THRESHOLD = BLSQuorumLib.QUORUM_THRESHOLD;

    /// @notice Default maximum age (in blocks) a reference block is considered valid when none is configured
    uint256 private constant DEFAULT_BLOCK_STALE_MEASURE = 300;

    /// @notice Verify BLS quorum signatures and apply the encoded state updates
    /// @dev The signed message binds the full execution context (anchor block, caller, calldata)
    ///      so that incorrect storage updates are provable — and slashable — after the fact via
    ///      an SP1 execution proof (see `GasKillerSlasher`)
    ///
    ///      Payable so a caller can fund value-bearing `CALL`/`CREATE`/`CREATE2` state updates
    ///      out of `msg.value`. The value each update moves is fixed inside the quorum-signed
    ///      `storageUpdates`, so `msg.value` only tops up this contract's balance — it cannot
    ///      redirect value anywhere the quorum did not sign. Under-funding reverts the whole
    ///      transition (`RevertingContext` for a CALL, `DeploymentFailed` for a CREATE/CREATE2).
    ///      Over-funding is NOT refunded: whatever the updates do not consume simply stays in
    ///      this contract. Inheriting contracts whose callers may over-send must provide their
    ///      own recovery path (e.g. a withdrawal function, or a refund executed as a signed
    ///      CALL update in a later transition).
    /// @param msgHash The hash of the message to verify
    /// @param quorumNumbers The quorum numbers to check signatures for
    /// @param referenceBlockNumber The block number to use as reference for operator set
    /// @param storageUpdates The storage updates to verify
    /// @param transitionIndex The transition index
    /// @param anchorHash The hash of the block the off-chain execution was anchored to
    /// @param callerAddress The msg.sender of the original call
    /// @param contractCalldata The full calldata of the original call
    /// @param nonSignerStakesAndSignature The non-signer stakes and signature data computed off-chain
    function verifyAndUpdate(
        bytes32 msgHash,
        bytes calldata quorumNumbers,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes32 anchorHash,
        address callerAddress,
        bytes calldata contractCalldata,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature calldata nonSignerStakesAndSignature
    ) external payable guardTransition trackState {
        // Check block number validity
        require(referenceBlockNumber < block.number, FutureBlockNumber());
        require((uint256(referenceBlockNumber) + _getBlockStaleMeasure()) >= block.number, StaleBlockNumber());

        // Verify transition index and message hash
        require(transitionIndex + 1 == stateTransitionCount(), InvalidTransitionIndex());
        require(
            _computeMessageHash(transitionIndex, anchorHash, callerAddress, contractCalldata, storageUpdates)
                == msgHash,
            InvalidSignature()
        );

        // Verify the signatures and the quorum threshold
        _verifyQuorumSignatures(msgHash, quorumNumbers, referenceBlockNumber, nonSignerStakesAndSignature);

        // Record the commitment for challenge-window tracking when a slasher is configured
        _recordCommitment(msgHash);

        // Apply the state changes
        _stateChangeHandler(storageUpdates);
    }

    /// @notice Verify the aggregate BLS signature and require the quorum threshold on every quorum
    /// @dev Delegates to `BLSQuorumLib` so the admission rule here is the exact one
    ///      `GasKillerBLSSlasher` re-checks when attributing a fraudulent commitment.
    /// @param msgHash The signed message hash
    /// @param quorumNumbers The quorum numbers to check signatures for
    /// @param referenceBlockNumber The block number to use as reference for operator set
    /// @param nonSignerStakesAndSignature The non-signer stakes and signature data computed off-chain
    function _verifyQuorumSignatures(
        bytes32 msgHash,
        bytes calldata quorumNumbers,
        uint32 referenceBlockNumber,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature calldata nonSignerStakesAndSignature
    ) internal view {
        BLSQuorumLib.verifyQuorum(
            _getGasKillerSDKStorage().blsSignatureChecker,
            msgHash,
            quorumNumbers,
            referenceBlockNumber,
            nonSignerStakesAndSignature
        );
    }

    /// @notice Record an applied commitment with the configured slasher, if any
    /// @param commitmentHash The verified message hash
    function _recordCommitment(bytes32 commitmentHash) internal {
        IGasKillerSlasher gasKillerSlasher = _getGasKillerSDKStorage().slasher;
        if (address(gasKillerSlasher) != address(0)) {
            gasKillerSlasher.recordCommitment(commitmentHash);
        }
    }

    /// @notice Query if a contract implements an interface
    /// @dev Supports ERC-165 and IGasKillerSDK interface detection
    /// @param interfaceId The interface identifier, as specified in ERC-165
    /// @return `true` if the contract implements `interfaceId` and `false` otherwise
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IGasKillerSDK).interfaceId;
    }

    /// @notice Compute the expected message hash for a given transition and execution context
    /// @param transitionIndex The transition index
    /// @param anchorHash The hash of the block the off-chain execution was anchored to
    /// @param callerAddress The msg.sender of the original call
    /// @param contractCalldata The full calldata of the original call
    /// @param storageUpdates The ABI-encoded storage updates
    /// @return The expected SHA-256 hash
    function getMessageHash(
        uint256 transitionIndex,
        bytes32 anchorHash,
        address callerAddress,
        bytes calldata contractCalldata,
        bytes calldata storageUpdates
    ) external view returns (bytes32) {
        return _computeMessageHash(transitionIndex, anchorHash, callerAddress, contractCalldata, storageUpdates);
    }

    /// @notice Return the configured AVS service manager address
    /// @return The AVS address
    function avsAddress() external view returns (address) {
        return _getGasKillerSDKStorage().avsAddress;
    }

    /// @notice Return the configured BLS signature checker address
    /// @return The BLS signature checker address
    function blsSignatureChecker() external view returns (address) {
        return address(_getGasKillerSDKStorage().blsSignatureChecker);
    }

    /// @notice Return the namespace bytes derived from the AVS address
    /// @dev Computed on read as `abi.encodePacked(avsAddress, "gaskiller")`, avoiding a dynamic-bytes SSTORE
    ///      at configuration time. Returns empty bytes when the AVS address is unset.
    /// @return The namespace
    function namespace() external view returns (bytes memory) {
        address _avsAddress = _getGasKillerSDKStorage().avsAddress;
        if (_avsAddress == address(0)) {
            return "";
        }
        return abi.encodePacked(_avsAddress, "gaskiller");
    }

    /// @notice Return the configured block stale measure (or the default if unset)
    /// @return The block stale measure
    function blockStaleMeasure() external view returns (uint256) {
        return _getBlockStaleMeasure();
    }

    /// @notice Return the configured Gas Killer slasher address (zero when unset)
    /// @return The slasher address
    function slasher() external view returns (address) {
        return address(_getGasKillerSDKStorage().slasher);
    }

    /// @notice Compute the signed message hash for a transition and its execution context
    /// @param transitionIndex The transition index
    /// @param anchorHash The hash of the block the off-chain execution was anchored to
    /// @param callerAddress The msg.sender of the original call
    /// @param contractCalldata The full calldata of the original call
    /// @param storageUpdates The ABI-encoded storage updates
    /// @return The expected SHA-256 hash
    function _computeMessageHash(
        uint256 transitionIndex,
        bytes32 anchorHash,
        address callerAddress,
        bytes calldata contractCalldata,
        bytes calldata storageUpdates
    ) internal view returns (bytes32) {
        return sha256(
            abi.encode(transitionIndex, address(this), anchorHash, callerAddress, contractCalldata, storageUpdates)
        );
    }

    /// @notice Decode and execute ABI-encoded storage updates
    /// @param storageUpdates ABI-encoded `(StateUpdateType[], bytes[])` pair
    function _stateChangeHandler(bytes calldata storageUpdates) internal {
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        StateChangeHandlerLib._runStateUpdates(types, args);
    }

    /// @notice Set the AVS address
    /// @dev `namespace()` derives its value from `avsAddress` on read, so no additional storage write happens here.
    /// @param _avsAddress The new AVS service manager address
    function _setAvsAddress(address _avsAddress) internal {
        _getGasKillerSDKStorage().avsAddress = _avsAddress;
    }

    /// @notice Set the BLS signature checker contract
    /// @param _blsSignatureChecker The new BLS signature checker address
    function _setBlsSignatureChecker(address _blsSignatureChecker) internal {
        GasKillerSDKStorage storage $ = _getGasKillerSDKStorage();
        $.blsSignatureChecker = IBLSSignatureChecker(_blsSignatureChecker);
    }

    /// @notice Set the maximum number of blocks a reference block may lag behind the current block
    /// @param _blockStaleMeasure The new block stale measure value
    function _setBlockStaleMeasure(uint256 _blockStaleMeasure) internal {
        _getGasKillerSDKStorage().blockStaleMeasure = _blockStaleMeasure;
    }

    /// @notice Set the Gas Killer slasher used for challenge-window recording (zero to disable)
    /// @param _slasher The new slasher address
    function _setSlasher(address _slasher) internal {
        _getGasKillerSDKStorage().slasher = IGasKillerSlasher(_slasher);
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
