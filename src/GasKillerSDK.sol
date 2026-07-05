// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {IERC1271Upgradeable} from "@openzeppelin-upgrades/contracts/interfaces/IERC1271Upgradeable.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";

import {IGasKillerSDK} from "./interface/IGasKillerSDK.sol";
import {IGasKillerForwardee} from "./interface/IGasKillerForwardee.sol";
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
