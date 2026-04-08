// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {
    IBLSSignatureChecker,
    IBLSSignatureCheckerTypes
} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";

import {IGasKillerSDK} from "./interface/IGasKillerSDK.sol";
import {IGasKillerServiceManager} from "./interface/IGasKillerServiceManager.sol";
import {StateTracker} from "./StateTracker.sol";
import {StateChangeHandlerLib, StateUpdateType} from "./StateChangeHandlerLib.sol";

/// @title GasKillerSDK
/// @notice Base SDK for implementing Gas Killer functionality in contracts
/// @dev Inherit from this contract to add Gas Killer capabilities to your contract
abstract contract GasKillerSDK is StateTracker, IGasKillerSDK {
    /// @custom:storage-location erc7201:gaskiller.GasKillerSDK.storage
    struct GasKillerSDKStorage {
        /// @notice Namespace derived from the AVS service manager address; used to scope this contract within the AVS
        bytes namespace;
        /// @notice The AVS service manager contract
        IGasKillerServiceManager avsServiceManager;
        /// @notice The BLS signature checker contract used to verify operator signatures
        IBLSSignatureChecker blsSignatureChecker;
        /// @notice Maximum number of blocks a reference block may lag behind the current block; 0 defers to avsServiceManager.BLOCK_STALE_MEASURE()
        uint256 blockStaleMeasure;
    }

    // keccak256(abi.encode(uint256(keccak256("gaskiller.GasKillerSDK.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant GAS_KILLER_SDK_STORAGE_LOCATION =
        0x321ebf629ed2e1e368f0890e8fdd95cf9a2ae5961b66a1805f0b2ec84e21d000;

    /// @notice Verify BLS quorum signatures and apply the encoded state updates
    /// @param msgHash The hash of the message to verify
    /// @param quorumNumbers The quorum numbers to check signatures for
    /// @param referenceBlockNumber The block number to use as reference for operator set
    /// @param storageUpdates The storage updates to verify
    /// @param transitionIndex The transition index
    /// @param targetFunction The target function selector
    /// @param nonSignerStakesAndSignature The non-signer stakes and signature data computed off-chain
    function verifyAndUpdate(
        bytes32 msgHash,
        bytes calldata quorumNumbers,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes4 targetFunction,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature calldata nonSignerStakesAndSignature
    ) external trackState {
        GasKillerSDKStorage storage $ = _getGasKillerSDKStorage();

        // Check block number validity
        require(referenceBlockNumber < block.number, FutureBlockNumber());
        require((uint256(referenceBlockNumber) + _getBlockStaleMeasure()) >= block.number, StaleBlockNumber());

        // Verify transition index and message hash
        require(transitionIndex + 1 == stateTransitionCount(), InvalidTransitionIndex());
        bytes32 expectedHash = sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates));
        require(expectedHash == msgHash, InvalidSignature());

        // Verify the signatures using checkSignatures
        (IBLSSignatureCheckerTypes.QuorumStakeTotals memory stakeTotals,) = $.blsSignatureChecker
            .checkSignatures(msgHash, quorumNumbers, referenceBlockNumber, nonSignerStakesAndSignature);

        // Check that signatories meet the quorum threshold defined by the service manager
        uint256 quorumThreshold = $.avsServiceManager.QUORUM_THRESHOLD();
        uint256 thresholdDenominator = $.avsServiceManager.THRESHOLD_DENOMINATOR();
        for (uint256 i = 0; i < quorumNumbers.length; i++) {
            require(
                stakeTotals.signedStakeForQuorum[i] * thresholdDenominator
                    >= stakeTotals.totalStakeForQuorum[i] * quorumThreshold,
                InsufficientQuorumThreshold()
            );
        }

        // Apply the state changes
        _stateChangeHandler(storageUpdates);
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

    /// @notice Return the configured AVS service manager contract
    /// @return The AVS service manager
    function avsServiceManager() external view returns (address) {
        return address(_getGasKillerSDKStorage().avsServiceManager);
    }

    /// @notice Return the configured BLS signature checker address
    /// @return The BLS signature checker address
    function blsSignatureChecker() external view returns (address) {
        return address(_getGasKillerSDKStorage().blsSignatureChecker);
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

    /// @notice Set the AVS service manager and derive the namespace from its address
    /// @dev The namespace is `abi.encodePacked(address(avsServiceManager), "gaskiller")`
    /// @param _avsServiceManager The new AVS service manager contract
    function _setAvsServiceManager(address _avsServiceManager) internal {
        GasKillerSDKStorage storage $ = _getGasKillerSDKStorage();
        $.avsServiceManager = IGasKillerServiceManager(_avsServiceManager);
        $.namespace = abi.encodePacked(_avsServiceManager, "gaskiller");
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

    /// @notice Return the block stale measure, falling back to the service manager's value when unset
    /// @return The effective block stale measure
    function _getBlockStaleMeasure() internal view returns (uint256) {
        GasKillerSDKStorage storage $ = _getGasKillerSDKStorage();
        uint256 value = $.blockStaleMeasure;
        return value == 0 ? $.avsServiceManager.BLOCK_STALE_MEASURE() : value;
    }

    /// @notice Load the ERC-7201 storage struct for GasKillerSDK
    /// @return $ The GasKillerSDK storage struct
    function _getGasKillerSDKStorage() private pure returns (GasKillerSDKStorage storage $) {
        assembly {
            $.slot := GAS_KILLER_SDK_STORAGE_LOCATION
        }
    }
}
