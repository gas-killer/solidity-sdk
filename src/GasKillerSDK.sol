// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IERC1271Upgradeable} from "@openzeppelin-upgrades/contracts/interfaces/IERC1271Upgradeable.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";

import {IGasKillerSDK} from "./interface/IGasKillerSDK.sol";
import {StateTracker} from "./StateTracker.sol";
import {StateChangeHandlerLib, StateUpdateType} from "./StateChangeHandlerLib.sol";

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
