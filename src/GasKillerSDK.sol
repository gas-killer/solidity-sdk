// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {
    IBLSSignatureChecker,
    IBLSSignatureCheckerTypes
} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";

import {IGasKillerSDK} from "./interface/IGasKillerSDK.sol";
import {IGasKillerForwardee} from "./interface/IGasKillerForwardee.sol";
import {StateTracker} from "./StateTracker.sol";
import {StateChangeHandlerLib, StateUpdateType} from "./StateChangeHandlerLib.sol";

/// @title GasKillerSDK
/// @notice Base SDK for implementing Gas Killer functionality in contracts
/// @dev Inherit from this contract to add Gas Killer capabilities to your contract
abstract contract GasKillerSDK is StateTracker, IGasKillerSDK, IGasKillerForwardee {
    /// @custom:storage-location erc7201:gaskiller.GasKillerSDK.storage
    struct GasKillerSDKStorage {
        /// @notice Namespace derived from the AVS address; used to scope this contract within the AVS
        bytes namespace;
        /// @notice The AVS service manager address
        address avsAddress;
        /// @notice The BLS signature checker contract used to verify operator signatures
        IBLSSignatureChecker blsSignatureChecker;
        /// @notice Maximum number of blocks a reference block may lag behind the current block
        uint256 blockStaleMeasure;
        /// @notice Peers allowed to deliver forwarded updates via `applyForwardedUpdates`
        /// @dev Append-only struct: new fields must be added after this one, never reordered
        mapping(address => bool) trustedForwarders;
    }

    // keccak256(abi.encode(uint256(keccak256("gaskiller.GasKillerSDK.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant GAS_KILLER_SDK_STORAGE_LOCATION =
        0x321ebf629ed2e1e368f0890e8fdd95cf9a2ae5961b66a1805f0b2ec84e21d000;

    /// @notice Number of fixed storage slots occupied by `GasKillerSDKStorage`; these are
    ///         reserved and may not be written by forwarded STORE operations
    uint256 private constant GAS_KILLER_SDK_STORAGE_SLOT_COUNT = 5;

    /// @notice Denominator used when evaluating stake percentage thresholds (representing 100%)
    uint8 public constant THRESHOLD_DENOMINATOR = 100;

    /// @notice Minimum percentage of quorum stake that must have signed to approve a state update (QUORUM_THRESHOLD/THRESHOLD_DENOMINATOR)
    uint8 public constant QUORUM_THRESHOLD = 66;

    /// @notice Default maximum age (in blocks) a reference block is considered valid when none is configured
    uint256 private constant DEFAULT_BLOCK_STALE_MEASURE = 300;

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

        // An empty quorum list would skip the stake-threshold loop entirely
        require(quorumNumbers.length > 0, EmptyQuorumNumbers());

        // Verify transition index and message hash
        require(transitionIndex + 1 == stateTransitionCount(), InvalidTransitionIndex());
        bytes32 expectedHash = sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates));
        require(expectedHash == msgHash, InvalidSignature());

        // Verify the signatures using checkSignatures
        (IBLSSignatureCheckerTypes.QuorumStakeTotals memory stakeTotals,) = $.blsSignatureChecker
            .checkSignatures(msgHash, quorumNumbers, referenceBlockNumber, nonSignerStakesAndSignature);

        // Check that signatories own at least 66% of each quorum
        for (uint256 i = 0; i < quorumNumbers.length; i++) {
            require(
                stakeTotals.signedStakeForQuorum[i] * THRESHOLD_DENOMINATOR
                    >= stakeTotals.totalStakeForQuorum[i] * QUORUM_THRESHOLD,
                InsufficientQuorumThreshold()
            );
        }

        // Apply the state changes
        _stateChangeHandler(storageUpdates);
    }

    /// @notice Apply storage updates forwarded by a trusted GasKiller peer
    /// @dev Multi-call mode: the forwarder embeds this call as an ordinary CALL update
    ///      inside its own quorum-signed `storageUpdates`, so the bundle root's BLS
    ///      signature transitively commits to both `storageUpdates` and
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

        (StateUpdateType[] memory types, bytes[] memory args) =
            abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
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

    /// @notice Set the AVS address and derive the namespace from it
    /// @dev The namespace is `abi.encodePacked(avsAddress, "gaskiller")`
    /// @param _avsAddress The new AVS service manager address
    function _setAvsAddress(address _avsAddress) internal {
        GasKillerSDKStorage storage $ = _getGasKillerSDKStorage();
        $.avsAddress = _avsAddress;
        $.namespace = abi.encodePacked($.avsAddress, "gaskiller");
    }

    /// @notice Set the BLS signature checker contract
    /// @param _blsSignatureChecker The new BLS signature checker address
    function _setBlsSignatureChecker(address _blsSignatureChecker) internal {
        GasKillerSDKStorage storage $ = _getGasKillerSDKStorage();
        $.blsSignatureChecker = IBLSSignatureChecker(_blsSignatureChecker);
    }

    /// @notice Allow or revoke a peer for `applyForwardedUpdates`
    /// @dev An allowlisted forwarder can write any non-reserved storage slot of this
    ///      contract, so only allowlist immutable, unmodified-SDK contracts. Post-deploy
    ///      changes need no extra admin root: the quorum can toggle an entry with a signed
    ///      STORE to `keccak256(abi.encode(forwarder, uint256(GAS_KILLER_SDK_STORAGE_LOCATION) + 4))`
    ///      through this contract's own `verifyAndUpdate`.
    /// @param forwarder The forwarder address
    /// @param trusted Whether the forwarder should be trusted
    function _setTrustedForwarder(address forwarder, bool trusted) internal {
        _getGasKillerSDKStorage().trustedForwarders[forwarder] = trusted;
    }

    /// @notice Check whether a slot may not be written by a forwarded STORE
    /// @dev Covers the state-transition counter and the fixed `GasKillerSDKStorage` slots.
    ///      Mapping entries (e.g. individual `trustedForwarders` keys) live at
    ///      keccak-derived slots and cannot be enumerated here; the allowlist itself
    ///      remains the trust boundary.
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
