// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0 ^0.8.27;

// lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol

// OpenZeppelin Contracts v4.4.1 (utils/introspection/IERC165.sol)

/**
 * @dev Interface of the ERC165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[EIP].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// src/interface/IGasKillerSDKBatch.sol

/// @notice One independently quorum-signed state transition, as submitted to
///         `verifyAndUpdateBatch`. The arguments of `IGasKillerSDK.verifyAndUpdate` plus the
///         `value` it would have been sent with, so the signed digest is the same either way
///         and the off-chain signing path does not know or care whether a transition settles
///         alone or in a batch.
struct TaskSubmission {
    bytes32 msgHash;
    uint32 referenceBlockNumber;
    bytes storageUpdates;
    uint256 transitionIndex;
    bytes4 targetFunction;
    uint256 s;
    address Raddr;
    address[] nonSigners;
    uint256 value;
}

/// @title IGasKillerSDKBatch
/// @notice Optional batching + in-transition-latch extension of `IGasKillerSDK`.
/// @dev Kept separate from `IGasKillerSDK` on purpose: that interface is
///      deliberately single-function so `type(IGasKillerSDK).interfaceId` equals
///      the `verifyAndUpdate` selector, which the router's ERC-165 preflight probes.
///      Contracts supporting this extension report **both** interface IDs.
///
///      Batching amortizes the per-transaction fixed costs across N transitions: the
///      21,000 intrinsic, the cold-access warm-up of the registry account + its aggregate
///      key/weight/watermark slots, and the SDK's own config slots — everything after the
///      first sub-transition runs at warm-access prices (measured: the registry verify
///      alone drops from ~17.0k cold to ~6.5k warm at full participation).
///
///      Batch assemblers (the off-chain router composing `submissions`) should be aware
///      that `StateChangeHandlerLib`'s `CALL` update forwards *all* remaining gas to its
///      target with no cap. A greedy or griefing CALL target in an early sub-transition can
///      consume enough gas to starve every later sub-transition, reverting the whole
///      (atomic) batch — no partial-state hazard, since it's all-or-nothing, but it does
///      nullify the amortization this extension exists for. Ordering submissions with
///      untrusted CALL targets last, or excluding them from batches entirely, avoids this.
interface IGasKillerSDKBatch {
    /// @notice Verify and apply a sequence of independently signed state transitions.
    /// @dev Transitions apply in calldata order with consecutive `transitionIndex`es.
    ///      Submissions whose index is already settled are skipped (front-run/redelivery
    ///      tolerance — settlement is permissionless, so without the skip one lifted
    ///      submission settled standalone would revert the whole batch); an index gap or
    ///      any failing applied sub-transition reverts the whole batch. The in-transition
    ///      latch is held across the entire batch.
    ///
    ///      Payable. Each submission's digest binds its own `value`, and `msg.value` must cover
    ///      the sum over the submissions actually applied. A skipped (already-settled)
    ///      submission adds nothing to that sum. The surplus, such as a front-run item's
    ///      share, is refunded to `msg.sender`; a sender that can't accept ETH leaves it in
    ///      the contract instead of reverting the batch.
    /// @param submissions The transitions to apply, in order.
    function verifyAndUpdateBatch(TaskSubmission[] calldata submissions) external payable;

    /// @notice True while a state transition (or batch) is being applied — external
    ///         readers should treat mid-transition state as unsigned and fail closed.
    function inTransition() external view returns (bool);
}

// src/interface/ISchnorrStakeRegistry.sol

/// @title ISchnorrStakeRegistry
/// @notice Verification surface the `GasKillerSDK` depends on. Kept minimal (and
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

// lib/openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol

// OpenZeppelin Contracts (last updated v4.9.0) (utils/cryptography/MerkleProof.sol)

/**
 * @dev These functions deal with verification of Merkle Tree proofs.
 *
 * The tree and the proofs can be generated using our
 * https://github.com/OpenZeppelin/merkle-tree[JavaScript library].
 * You will find a quickstart guide in the readme.
 *
 * WARNING: You should avoid using leaf values that are 64 bytes long prior to
 * hashing, or use a hash function other than keccak256 for hashing leaves.
 * This is because the concatenation of a sorted pair of internal nodes in
 * the merkle tree could be reinterpreted as a leaf value.
 * OpenZeppelin's JavaScript library generates merkle trees that are safe
 * against this attack out of the box.
 */
library MerkleProof {
    /**
     * @dev Returns true if a `leaf` can be proved to be a part of a Merkle tree
     * defined by `root`. For this, a `proof` must be provided, containing
     * sibling hashes on the branch from the leaf to the root of the tree. Each
     * pair of leaves and each pair of pre-images are assumed to be sorted.
     */
    function verify(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        return processProof(proof, leaf) == root;
    }

    /**
     * @dev Calldata version of {verify}
     *
     * _Available since v4.7._
     */
    function verifyCalldata(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        return processProofCalldata(proof, leaf) == root;
    }

    /**
     * @dev Returns the rebuilt hash obtained by traversing a Merkle tree up
     * from `leaf` using `proof`. A `proof` is valid if and only if the rebuilt
     * hash matches the root of the tree. When processing the proof, the pairs
     * of leafs & pre-images are assumed to be sorted.
     *
     * _Available since v4.4._
     */
    function processProof(bytes32[] memory proof, bytes32 leaf) internal pure returns (bytes32) {
        bytes32 computedHash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            computedHash = _hashPair(computedHash, proof[i]);
        }
        return computedHash;
    }

    /**
     * @dev Calldata version of {processProof}
     *
     * _Available since v4.7._
     */
    function processProofCalldata(bytes32[] calldata proof, bytes32 leaf) internal pure returns (bytes32) {
        bytes32 computedHash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            computedHash = _hashPair(computedHash, proof[i]);
        }
        return computedHash;
    }

    /**
     * @dev Returns true if the `leaves` can be simultaneously proven to be a part of a merkle tree defined by
     * `root`, according to `proof` and `proofFlags` as described in {processMultiProof}.
     *
     * CAUTION: Not all merkle trees admit multiproofs. See {processMultiProof} for details.
     *
     * _Available since v4.7._
     */
    function multiProofVerify(
        bytes32[] memory proof,
        bool[] memory proofFlags,
        bytes32 root,
        bytes32[] memory leaves
    ) internal pure returns (bool) {
        return processMultiProof(proof, proofFlags, leaves) == root;
    }

    /**
     * @dev Calldata version of {multiProofVerify}
     *
     * CAUTION: Not all merkle trees admit multiproofs. See {processMultiProof} for details.
     *
     * _Available since v4.7._
     */
    function multiProofVerifyCalldata(
        bytes32[] calldata proof,
        bool[] calldata proofFlags,
        bytes32 root,
        bytes32[] memory leaves
    ) internal pure returns (bool) {
        return processMultiProofCalldata(proof, proofFlags, leaves) == root;
    }

    /**
     * @dev Returns the root of a tree reconstructed from `leaves` and sibling nodes in `proof`. The reconstruction
     * proceeds by incrementally reconstructing all inner nodes by combining a leaf/inner node with either another
     * leaf/inner node or a proof sibling node, depending on whether each `proofFlags` item is true or false
     * respectively.
     *
     * CAUTION: Not all merkle trees admit multiproofs. To use multiproofs, it is sufficient to ensure that: 1) the tree
     * is complete (but not necessarily perfect), 2) the leaves to be proven are in the opposite order they are in the
     * tree (i.e., as seen from right to left starting at the deepest layer and continuing at the next layer).
     *
     * _Available since v4.7._
     */
    function processMultiProof(
        bytes32[] memory proof,
        bool[] memory proofFlags,
        bytes32[] memory leaves
    ) internal pure returns (bytes32 merkleRoot) {
        // This function rebuilds the root hash by traversing the tree up from the leaves. The root is rebuilt by
        // consuming and producing values on a queue. The queue starts with the `leaves` array, then goes onto the
        // `hashes` array. At the end of the process, the last hash in the `hashes` array should contain the root of
        // the merkle tree.
        uint256 leavesLen = leaves.length;
        uint256 totalHashes = proofFlags.length;

        // Check proof validity.
        require(leavesLen + proof.length - 1 == totalHashes, "MerkleProof: invalid multiproof");

        // The xxxPos values are "pointers" to the next value to consume in each array. All accesses are done using
        // `xxx[xxxPos++]`, which return the current value and increment the pointer, thus mimicking a queue's "pop".
        bytes32[] memory hashes = new bytes32[](totalHashes);
        uint256 leafPos = 0;
        uint256 hashPos = 0;
        uint256 proofPos = 0;
        // At each step, we compute the next hash using two values:
        // - a value from the "main queue". If not all leaves have been consumed, we get the next leaf, otherwise we
        //   get the next hash.
        // - depending on the flag, either another value from the "main queue" (merging branches) or an element from the
        //   `proof` array.
        for (uint256 i = 0; i < totalHashes; i++) {
            bytes32 a = leafPos < leavesLen ? leaves[leafPos++] : hashes[hashPos++];
            bytes32 b = proofFlags[i]
                ? (leafPos < leavesLen ? leaves[leafPos++] : hashes[hashPos++])
                : proof[proofPos++];
            hashes[i] = _hashPair(a, b);
        }

        if (totalHashes > 0) {
            unchecked {
                return hashes[totalHashes - 1];
            }
        } else if (leavesLen > 0) {
            return leaves[0];
        } else {
            return proof[0];
        }
    }

    /**
     * @dev Calldata version of {processMultiProof}.
     *
     * CAUTION: Not all merkle trees admit multiproofs. See {processMultiProof} for details.
     *
     * _Available since v4.7._
     */
    function processMultiProofCalldata(
        bytes32[] calldata proof,
        bool[] calldata proofFlags,
        bytes32[] memory leaves
    ) internal pure returns (bytes32 merkleRoot) {
        // This function rebuilds the root hash by traversing the tree up from the leaves. The root is rebuilt by
        // consuming and producing values on a queue. The queue starts with the `leaves` array, then goes onto the
        // `hashes` array. At the end of the process, the last hash in the `hashes` array should contain the root of
        // the merkle tree.
        uint256 leavesLen = leaves.length;
        uint256 totalHashes = proofFlags.length;

        // Check proof validity.
        require(leavesLen + proof.length - 1 == totalHashes, "MerkleProof: invalid multiproof");

        // The xxxPos values are "pointers" to the next value to consume in each array. All accesses are done using
        // `xxx[xxxPos++]`, which return the current value and increment the pointer, thus mimicking a queue's "pop".
        bytes32[] memory hashes = new bytes32[](totalHashes);
        uint256 leafPos = 0;
        uint256 hashPos = 0;
        uint256 proofPos = 0;
        // At each step, we compute the next hash using two values:
        // - a value from the "main queue". If not all leaves have been consumed, we get the next leaf, otherwise we
        //   get the next hash.
        // - depending on the flag, either another value from the "main queue" (merging branches) or an element from the
        //   `proof` array.
        for (uint256 i = 0; i < totalHashes; i++) {
            bytes32 a = leafPos < leavesLen ? leaves[leafPos++] : hashes[hashPos++];
            bytes32 b = proofFlags[i]
                ? (leafPos < leavesLen ? leaves[leafPos++] : hashes[hashPos++])
                : proof[proofPos++];
            hashes[i] = _hashPair(a, b);
        }

        if (totalHashes > 0) {
            unchecked {
                return hashes[totalHashes - 1];
            }
        } else if (leavesLen > 0) {
            return leaves[0];
        } else {
            return proof[0];
        }
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? _efficientHash(a, b) : _efficientHash(b, a);
    }

    function _efficientHash(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }
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

// src/TransitionGuard.sol

/// @title TransitionGuard
/// @notice EIP-1153 transient-storage reentrancy guard that doubles as an
///         "in transition" latch external contracts can query.
/// @dev Two holes in the unguarded settlement path, one mechanism:
///
///      1. **Reentrancy.** `StateChangeHandlerLib`'s `CALL` update forwards all remaining
///         gas to an arbitrary target *mid-transition* — after `trackState` has already
///         bumped the counter and before the transition's later updates have executed. A
///         re-entrant `verifyAndUpdate` carrying transition N+1's valid quorum signature
///         would pass the transition-index check and interleave N+1's updates inside N.
///         `guardTransition` makes the re-entrant call revert instead.
///
///      2. **Midway state.** During a `CALL` update the called contract observes storage
///         that never existed per the signed semantics: the transition counter already
///         shows N+1 while only a prefix of transition N's updates have landed. The quorum
///         signed the *final* post-transition state, not this intermediate one. The same
///         transient flag is exposed as `inTransition()`, so integrators reading a Gas
///         Killer contract can fail closed (revert or fall back) while a transition is
///         being applied, for one warm TLOAD (~100 gas) paid by the reader.
///
///      Transient storage clears automatically at the end of the transaction, so the
///      guard costs ~3 transient ops (~300 gas) per guarded call and never leaves a
///      dirty storage slot behind. Requires an EVM with EIP-1153 (Cancun or later).
///
///      The slot holds the active nested-settlement root rather than a flag, so a call tree
///      that re-enters this contract (A → B → A) can apply its second frame here while every
///      other re-entry still reverts. Single-transition and batch settlement hold
///      `EXCLUSIVE_MARKER`, a value no root (a hash output) can take.
abstract contract TransitionGuard {
    /// @notice Precomputed transient-storage slot for the guard flag
    /// @dev Computed as `keccak256("gasKiller.transitionGuard") - 1`, mirroring
    ///      `StateTracker`'s slot-derivation convention.
    bytes32 internal constant TRANSITION_GUARD_SLOT =
        0x577f51c71236185614d2425ce0aefc41d4e67f3a91a20821f72674b76f8d3ec0;

    bytes32 internal constant EXCLUSIVE_MARKER = bytes32(uint256(1));

    /// @notice Thrown when a guarded function is re-entered while a transition is applying
    error ReentrantTransition();

    /// @notice Reverts on re-entry and holds the in-transition latch for the duration of
    ///         the function body (a batch entrypoint holds it across the whole batch).
    modifier guardTransition() {
        _enterExclusive(EXCLUSIVE_MARKER);
        _;
        _exitTransition(bytes32(0));
    }

    /// @notice True while a state transition (or batch of transitions) is being applied
    /// @dev External contracts that read Gas Killer state and can be called mid-transition
    ///      (directly or transitively via a `CALL` update) should check this and fail
    ///      closed — mid-transition storage is not a quorum-signed state.
    function inTransition() public view virtual returns (bool locked) {
        return _activeRoot() != bytes32(0);
    }

    function _activeRoot() internal view returns (bytes32 root) {
        assembly {
            root := tload(TRANSITION_GUARD_SLOT)
        }
    }

    /// @dev For entrypoints that start a transition: reverts if any transition is applying.
    function _enterExclusive(bytes32 root) internal {
        if (_activeRoot() != bytes32(0)) revert ReentrantTransition();
        _setActiveRoot(root);
    }

    /// @dev For a nested frame: allowed when idle, or when re-entered by a frame of the same
    ///      root. Returns the value to restore on exit, so an inner frame of a cycle leaves the
    ///      outer frame's latch in place.
    function _enterNested(bytes32 root) internal returns (bytes32 previous) {
        previous = _activeRoot();
        if (previous != bytes32(0) && previous != root) revert ReentrantTransition();
        _setActiveRoot(root);
    }

    function _exitTransition(bytes32 previous) internal {
        _setActiveRoot(previous);
    }

    function _setActiveRoot(bytes32 root) private {
        assembly {
            tstore(TRANSITION_GUARD_SLOT, root)
        }
    }
}

// lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol

// OpenZeppelin Contracts v4.4.1 (utils/introspection/ERC165.sol)

/**
 * @dev Implementation of the {IERC165} interface.
 *
 * Contracts that want to implement ERC165 should inherit from this contract and override {supportsInterface} to check
 * for the additional interface id that will be supported. For example:
 *
 * ```solidity
 * function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
 *     return interfaceId == type(MyInterface).interfaceId || super.supportsInterface(interfaceId);
 * }
 * ```
 *
 * Alternatively, {ERC165Storage} provides an easier to use but more expensive implementation.
 */
abstract contract ERC165 is IERC165 {
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

// lib/openzeppelin-contracts/contracts/utils/introspection/ERC165Checker.sol

// OpenZeppelin Contracts (last updated v4.9.0) (utils/introspection/ERC165Checker.sol)

/**
 * @dev Library used to query support of an interface declared via {IERC165}.
 *
 * Note that these functions return the actual result of the query: they do not
 * `revert` if an interface is not supported. It is up to the caller to decide
 * what to do in these cases.
 */
library ERC165Checker {
    // As per the EIP-165 spec, no interface should ever match 0xffffffff
    bytes4 private constant _INTERFACE_ID_INVALID = 0xffffffff;

    /**
     * @dev Returns true if `account` supports the {IERC165} interface.
     */
    function supportsERC165(address account) internal view returns (bool) {
        // Any contract that implements ERC165 must explicitly indicate support of
        // InterfaceId_ERC165 and explicitly indicate non-support of InterfaceId_Invalid
        return
            supportsERC165InterfaceUnchecked(account, type(IERC165).interfaceId) &&
            !supportsERC165InterfaceUnchecked(account, _INTERFACE_ID_INVALID);
    }

    /**
     * @dev Returns true if `account` supports the interface defined by
     * `interfaceId`. Support for {IERC165} itself is queried automatically.
     *
     * See {IERC165-supportsInterface}.
     */
    function supportsInterface(address account, bytes4 interfaceId) internal view returns (bool) {
        // query support of both ERC165 as per the spec and support of _interfaceId
        return supportsERC165(account) && supportsERC165InterfaceUnchecked(account, interfaceId);
    }

    /**
     * @dev Returns a boolean array where each value corresponds to the
     * interfaces passed in and whether they're supported or not. This allows
     * you to batch check interfaces for a contract where your expectation
     * is that some interfaces may not be supported.
     *
     * See {IERC165-supportsInterface}.
     *
     * _Available since v3.4._
     */
    function getSupportedInterfaces(
        address account,
        bytes4[] memory interfaceIds
    ) internal view returns (bool[] memory) {
        // an array of booleans corresponding to interfaceIds and whether they're supported or not
        bool[] memory interfaceIdsSupported = new bool[](interfaceIds.length);

        // query support of ERC165 itself
        if (supportsERC165(account)) {
            // query support of each interface in interfaceIds
            for (uint256 i = 0; i < interfaceIds.length; i++) {
                interfaceIdsSupported[i] = supportsERC165InterfaceUnchecked(account, interfaceIds[i]);
            }
        }

        return interfaceIdsSupported;
    }

    /**
     * @dev Returns true if `account` supports all the interfaces defined in
     * `interfaceIds`. Support for {IERC165} itself is queried automatically.
     *
     * Batch-querying can lead to gas savings by skipping repeated checks for
     * {IERC165} support.
     *
     * See {IERC165-supportsInterface}.
     */
    function supportsAllInterfaces(address account, bytes4[] memory interfaceIds) internal view returns (bool) {
        // query support of ERC165 itself
        if (!supportsERC165(account)) {
            return false;
        }

        // query support of each interface in interfaceIds
        for (uint256 i = 0; i < interfaceIds.length; i++) {
            if (!supportsERC165InterfaceUnchecked(account, interfaceIds[i])) {
                return false;
            }
        }

        // all interfaces supported
        return true;
    }

    /**
     * @notice Query if a contract implements an interface, does not check ERC165 support
     * @param account The address of the contract to query for support of an interface
     * @param interfaceId The interface identifier, as specified in ERC-165
     * @return true if the contract at account indicates support of the interface with
     * identifier interfaceId, false otherwise
     * @dev Assumes that account contains a contract that supports ERC165, otherwise
     * the behavior of this method is undefined. This precondition can be checked
     * with {supportsERC165}.
     *
     * Some precompiled contracts will falsely indicate support for a given interface, so caution
     * should be exercised when using this function.
     *
     * Interface identification is specified in ERC-165.
     */
    function supportsERC165InterfaceUnchecked(address account, bytes4 interfaceId) internal view returns (bool) {
        // prepare call
        bytes memory encodedParams = abi.encodeWithSelector(IERC165.supportsInterface.selector, interfaceId);

        // perform static call
        bool success;
        uint256 returnSize;
        uint256 returnValue;
        assembly {
            success := staticcall(30000, account, add(encodedParams, 0x20), mload(encodedParams), 0x00, 0x20)
            returnSize := returndatasize()
            returnValue := mload(0x00)
        }

        return success && returnSize >= 0x20 && returnValue > 0;
    }
}

// src/interface/IGasKillerSDK.sol

/// @title IGasKillerSDK
/// @notice Interface for GasKillerSDK contracts
/// @dev Defines the core functionality that GasKillerSDK implementations must
///      provide. State updates are approved by an operator quorum expressed as a
///      **single** aggregate Schnorr signature verified by a `SchnorrStakeRegistry`
///      (constant gas, non-signer subtraction) instead of `N` per-operator ECDSA
///      signatures. Deliberately single-function so
///      `type(IGasKillerSDK).interfaceId` equals the `verifyAndUpdate`
///      selector — the router's ERC-165 preflight probes exactly this ID.
interface IGasKillerSDK is IERC165 {
    /// @notice Verify the operators' aggregate Schnorr quorum signature and apply the
    ///         encoded state updates
    /// @dev Payable, and `msg.value` is part of the signed digest: the transition settles only
    ///      with exactly the value the task was analyzed with, so a function that credits
    ///      `msg.value` cannot be settled without its ETH. Value moved by state updates is fixed
    ///      inside the signed `storageUpdates`; a shortfall reverts the whole transition.
    ///
    ///      `payable` does not change the function selector, so
    ///      `type(IGasKillerSDK).interfaceId` — which the router's ERC-165 preflight
    ///      probes — is unaffected.
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
    ) external payable;
}

// src/interface/ISchnorrApprovalRegistry.sol

/// @notice An aggregate Schnorr quorum signature and the reference block it is checked at.
struct QuorumSignature {
    uint256 s;
    address Raddr;
    address[] nonSigners;
    uint256 refBlock;
}

/// @title ISchnorrApprovalRegistry
/// @notice Per-transaction root approvals for nested settlement. The root of a nested tree
///         is verified once, and every frame of the tree checks the cached approval in its own
///         registry instead of re-verifying the signature.
/// @dev Kept separate from `ISchnorrStakeRegistry` so consumers that never nest, and the
///      mocks they are tested against, see no new surface. Implementations must report this
///      interface through ERC-165: a consumer reports `IGasKillerNested` only when its registry
///      does.
interface ISchnorrApprovalRegistry is ISchnorrStakeRegistry {
    error ApprovalExpired(uint256 expiryBlock);
    error InvalidExpiryProof();
    error InvalidApprovalSignature();

    /// @notice Verify a quorum signature over `root` and approve it for the rest of this
    ///         transaction.
    /// @dev Reverts unless the signature verifies exactly as `isValidSignature` would, the
    ///      expiry leaf for `(rootContract, expiryBlock)` is in the tree, and the expiry has not
    ///      passed. A repeat call re-runs every check but keeps the first approved `refBlock`.
    /// @param root         the signed Merkle root.
    /// @param rootContract the contract whose tree entrypoint settles the root.
    /// @param expiryBlock  the last block at which the tree may settle.
    /// @param expiryProof  Merkle proof of the expiry leaf.
    /// @param sig          the quorum signature over `root`.
    function verifyAndApprove(
        bytes32 root,
        address rootContract,
        uint256 expiryBlock,
        bytes32[] calldata expiryProof,
        QuorumSignature calldata sig
    ) external;

    /// @notice Whether `root` was approved earlier in this transaction, and at which reference
    ///         block.
    /// @dev Reports unapproved once an operator-set change has moved `effectiveBlock` past the
    ///      approved `refBlock`, so a mid-transaction mutation fails closed.
    function approvedRefBlock(bytes32 root) external view returns (bool approved, uint256 refBlock);
}

// src/libraries/NestedFrames.sol

/// @title NestedFrames
/// @notice Leaf hashing, tree membership and witness decoding for nested settlement, where
///         one quorum signature over a Merkle root authorizes every frame of a call tree.
/// @dev A tree's leaves are an expiry leaf followed by one leaf per frame in execution order.
///      Internal nodes use OpenZeppelin's sorted-pair keccak. Every leaf is a sha256 digest
///      computed here from typed fields, so callers never hand in a leaf hash and an internal
///      node can never be presented as a leaf.
///
///      Three leaf types:
///        - root leaf:   the single-transition digest, value included, so a consumer settled
///                       without nesting signs exactly what it signs for `verifyAndUpdate`;
///        - nested leaf: a callee frame, binding chain, contract, caller, value and index;
///        - expiry leaf: the block after which neither the root nor any frame may settle.
///      The nested and expiry tags are keccak-derived words in the first slot of their
///      preimages, where the root leaf carries a transition index, so no preimage of one type
///      can equal a preimage of another.
library NestedFrames {
    /// keccak256("gaskiller.nested.leaf.v1")
    bytes32 internal constant NESTED_LEAF_TAG = 0x292ca629b989c44a85e556e7c24acc26f9ab093b2b23c689f951e91718228c18;
    /// keccak256("gaskiller.nested.expiry.v1")
    bytes32 internal constant EXPIRY_LEAF_TAG = 0xc5763e3656f5ee85e7416218ca476fe6364ba9f67d13b29c7331d1d1131dd88a;

    /// @notice The only frame mode this build accepts: transition-counter pinning.
    /// @dev Compiled in, never read from a witness, so a contract built before a new mode
    ///      cannot be made to accept leaves signed for it.
    uint8 internal constant MODE = 0;

    /// @notice The unsigned data a parent passes to a child alongside the child's leaf hash.
    /// @dev `children` are opaque `abi.encode(Witness)` blobs because the ABI cannot express a
    ///      recursive struct. Everything here is authenticated through the leaf and the proof;
    ///      `calldataHash` is recorded for fraud proofs and re-derived by nothing on-chain.
    struct Witness {
        bytes32 calldataHash;
        bytes storageUpdates;
        bytes32[] proof;
        bytes[] children;
    }

    /// @dev Must stay byte-identical to `GasKillerSDK`'s digest, zero-value encoding included.
    function rootLeaf(
        uint256 transitionIndex,
        address target,
        bytes4 targetFunction,
        bytes memory storageUpdates,
        uint256 value
    ) internal pure returns (bytes32) {
        if (value == 0) {
            return sha256(abi.encode(transitionIndex, target, targetFunction, storageUpdates));
        }
        return sha256(abi.encode(transitionIndex, target, targetFunction, storageUpdates, value));
    }

    function nestedLeaf(
        address target,
        uint256 transitionIndex,
        address caller,
        uint256 value,
        bytes32 calldataHash,
        bytes memory storageUpdates
    ) internal view returns (bytes32) {
        return sha256(
            abi.encode(
                NESTED_LEAF_TAG,
                block.chainid,
                target,
                transitionIndex,
                caller,
                value,
                calldataHash,
                MODE,
                storageUpdates
            )
        );
    }

    function expiryLeaf(address rootContract, uint256 expiryBlock) internal view returns (bytes32) {
        return sha256(abi.encode(EXPIRY_LEAF_TAG, block.chainid, rootContract, expiryBlock));
    }

    function isMember(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        return MerkleProof.verify(proof, root, leaf);
    }

    function isMemberCalldata(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        return MerkleProof.verifyCalldata(proof, root, leaf);
    }

    /// @dev `abi.decode` bounds-checks every offset and length, so a malformed witness reverts
    ///      rather than decoding garbage.
    function decodeWitness(bytes memory encoded) internal pure returns (Witness memory) {
        return abi.decode(encoded, (Witness));
    }
}

// src/interface/IGasKillerNested.sol

/// @notice Everything the root contract needs to settle a nested tree.
/// @param root            the signed Merkle root.
/// @param expiryBlock     the last block at which the tree may settle.
/// @param expiryProof     Merkle proof of the expiry leaf.
/// @param sig             the quorum signature over `root`.
/// @param transitionIndex expected `stateTransitionCount() - 1` of the root contract.
/// @param targetFunction  selector bound into the root leaf.
/// @param storageUpdates  the root frame's program.
/// @param proof           Merkle proof of the root leaf.
/// @param children        one `abi.encode(NestedFrames.Witness)` per `NESTED` op in the root
///                        frame's program, in program order.
struct TreeSubmission {
    bytes32 root;
    uint256 expiryBlock;
    bytes32[] expiryProof;
    QuorumSignature sig;
    uint256 transitionIndex;
    bytes4 targetFunction;
    bytes storageUpdates;
    bytes32[] proof;
    bytes[] children;
}

/// @title IGasKillerNested
/// @notice Nested settlement: one quorum signature over a Merkle root authorizes a tree of
///         frames across SDK-enabled contracts, each applied by the contract it belongs to.
/// @dev An ERC-165 extension separate from `IGasKillerSDK`, whose interface ID must stay equal
///      to the `verifyAndUpdate` selector the router probes.
interface IGasKillerNested {
    error NotApproved(bytes32 root);
    error LeafMismatch(bytes32 expected, bytes32 computed);
    error NotPendingChild(address parent, bytes32 leaf);
    error NotTreeMember(bytes32 leaf);

    /// @notice Settle a tree whose root frame belongs to this contract.
    function verifyAndUpdateTree(TreeSubmission calldata submission) external payable;

    /// @notice Apply this contract's frame of an approved tree. Called by the frame's signed
    ///         parent while it executes the `NESTED` op that names this frame.
    /// @param root         the approved root.
    /// @param expectedLeaf the leaf hash the parent's signed program names.
    /// @param witness      `abi.encode(NestedFrames.Witness)` for this frame.
    /// @return             `applyNested.selector`; the parent rejects any other return.
    function applyNested(bytes32 root, bytes32 expectedLeaf, bytes calldata witness) external payable returns (bytes4);

    /// @notice The leaf of the child this contract is calling right now, or zero.
    function pendingChild() external view returns (bytes32);
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
    CREATE2,
    /// @notice Apply an SDK-enabled callee's own signed frame of a nested tree
    NESTED
}

/// @notice The tree a program runs inside, when it runs inside one.
/// @dev `root` is zero for single-transition settlement, where `NESTED` ops are rejected.
///      `children` holds one witness per `NESTED` op in program order; `consumed` counts the
///      ones handed out so far.
struct NestedContext {
    bytes32 root;
    bytes[] children;
    uint256 consumed;
}

/// @title StateChangeHandlerLib
/// @notice Library for decoding and executing batched state update operations
/// @dev Processes ABI-encoded arrays of typed state updates; supports STORE, CALL, LOG0-LOG4, CREATE, CREATE2 and NESTED
library StateChangeHandlerLib {
    /// keccak256("gasKiller.pendingChild") - 1, following `StateTracker`'s slot convention.
    bytes32 internal constant PENDING_CHILD_SLOT = 0x70b036af5917f7c22df33faec4b5fd311a27d9e8310987dea3cc060d66152963;

    function _pendingChild() internal view returns (bytes32 leaf) {
        assembly {
            leaf := tload(PENDING_CHILD_SLOT)
        }
    }

    function _setPendingChild(bytes32 leaf) private {
        assembly {
            tstore(PENDING_CHILD_SLOT, leaf)
        }
    }

    /// @dev Runs a program outside any tree, rejecting every NESTED op. Dispatching NESTED
    ///      through a function pointer keeps `_runNested` out of consumers that never nest.
    function _runStateUpdates(StateUpdateType[] memory types, bytes[] memory args) internal {
        NestedContext memory none;
        _run(types, args, none, _rejectNested);
    }

    /// @dev Runs a program inside the tree in `ctx`.
    function _runStateUpdates(StateUpdateType[] memory types, bytes[] memory args, NestedContext memory ctx) internal {
        _run(types, args, ctx, _runNested);
    }

    /// @notice Decodes and executes a series of state updates
    /// @dev This function processes an array of state updates, executing them in sequence. Each update can be one of:
    ///      - STORE: Direct storage writes using assembly
    ///      - CALL: External contract calls with value transfer
    ///      - LOG0-LOG4: Event emission with 0-4 indexed topics
    ///      - CREATE: Contract deployment via CREATE opcode
    ///      - CREATE2: Deterministic contract deployment via CREATE2 opcode
    ///      - NESTED: Hand a callee its own signed frame of the tree in `ctx`
    /// @param types Array of StateUpdateType enums indicating the type of each state update operation
    /// @param args Array of ABI-encoded arguments corresponding to each operation type
    /// @param ctx The tree this program runs inside; a zero root rejects every NESTED op
    /// @param nested The NESTED handler: `_runNested` inside a tree, `_rejectNested` outside one
    /// @dev types and args arrays must be equal length, with args[i] containing the encoded parameters for types[i]
    function _run(
        StateUpdateType[] memory types,
        bytes[] memory args,
        NestedContext memory ctx,
        function(uint256, bytes memory, NestedContext memory) nested
    ) private {
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
                // Forwards all remaining gas (no stipend cap). In a batched settlement
                // (e.g. GasKillerSDK.verifyAndUpdateBatch) this is amplified: a
                // greedy or griefing target in an earlier sub-transition's CALL can consume
                // enough gas to starve every later sub-transition in the same batch,
                // reverting the whole (atomic) batch. No partial-state hazard — it's all or
                // nothing — but it does nullify the batch's cost amortization. See
                // IGasKillerSDKBatch for the batch-assembly-side note.
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
            } else if (stateUpdateType == StateUpdateType.NESTED) {
                nested(i, arg, ctx);
            }
        }
        if (ctx.consumed != ctx.children.length) revert UnconsumedWitnesses(ctx.children.length, ctx.consumed);
    }

    function _rejectNested(uint256, bytes memory, NestedContext memory) private pure {
        revert NestedOutsideTree();
    }

    /// @dev The child checks `pendingChild()` on its caller before applying anything, which is
    ///      what stops a frame from being applied anywhere but this op. The previous value is
    ///      restored afterwards because a cycle can nest pending children on one contract.
    ///      A call to an address without code, or to a permissive fallback, also succeeds, so
    ///      success alone does not show the frame applied; the child must echo its selector.
    function _runNested(uint256 i, bytes memory arg, NestedContext memory ctx) private {
        if (ctx.root == bytes32(0)) revert NestedOutsideTree();
        (address target, uint256 value, bytes32 childLeaf) = abi.decode(arg, (address, uint256, bytes32));
        if (ctx.consumed >= ctx.children.length) revert MissingWitness(i);
        bytes memory callargs =
            abi.encodeCall(IGasKillerNested.applyNested, (ctx.root, childLeaf, ctx.children[ctx.consumed++]));

        bytes32 previous = _pendingChild();
        _setPendingChild(childLeaf);
        bool success;
        bytes32 ack;
        assembly {
            success := call(gas(), target, value, add(callargs, 0x20), mload(callargs), 0, 0)
            if eq(returndatasize(), 0x20) {
                returndatacopy(0, 0, 0x20)
                ack := mload(0)
            }
        }
        _setPendingChild(previous);

        if (!success) {
            uint256 size;
            assembly {
                size := returndatasize()
            }
            bytes memory revertData = new bytes(size);
            assembly {
                returndatacopy(add(revertData, 0x20), 0, size)
            }
            revert RevertingContext(i, target, revertData, callargs);
        }
        if (ack != bytes32(IGasKillerNested.applyNested.selector)) revert NestedNotApplied(i, target);
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

    /// @notice Thrown when a NESTED operation appears in a program settled outside a tree
    error NestedOutsideTree();

    /// @notice Thrown when a NESTED operation has no witness left to hand its child
    /// @param index The zero-based position of the NESTED operation in the batch
    error MissingWitness(uint256 index);

    /// @notice Thrown when a NESTED operation's call succeeds without the child acknowledging it
    /// @param index The zero-based position of the NESTED operation in the batch
    /// @param target The address the NESTED operation called
    error NestedNotApplied(uint256 index, address target);

    /// @notice Thrown when a program finishes with witnesses no NESTED operation consumed
    error UnconsumedWitnesses(uint256 supplied, uint256 consumed);

    /// @notice Thrown when a CREATE or CREATE2 operation returns address(0)
    error DeploymentFailed();
}

// src/GasKillerSDK.sol

/// @title GasKillerSDK
/// @notice Base contract for Gas Killer targets. Authorises a state transition with a
///         **single** aggregate Schnorr signature verified against a `SchnorrStakeRegistry`
///         (constant gas, non-signer subtraction) and applies the signed state updates.
///
/// @dev The signed message is `sha256(abi.encode(transitionIndex, address(this),
///      targetFunction, storageUpdates))` for a transition settled with no ETH, and
///      `sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates,
///      value))` for one settled with `value` wei. It is independent of the signature scheme,
///      so the off-chain digest and the slashing/fraud-proof machinery do not depend on it.
///
///      Binding the value is what makes inbound ETH safe: a tracked function that credits
///      `msg.value` replays as plain `STORE` updates, so without it anyone could settle a
///      deposit while sending nothing. A zero-value transition keeps the original four-field
///      encoding, so every zero-value signature is unchanged; the two encodings cannot collide
///      because their heads differ in length.
///
///      Both entrypoints are `guardTransition`-protected (see `TransitionGuard`): a `CALL`
///      state update runs arbitrary external code mid-transition, so re-entering
///      `verifyAndUpdate` with the *next* transition's valid signature would otherwise
///      interleave two signed transitions. The same transient flag is queryable as
///      `inTransition()` so external readers can reject mid-transition state.
///
///      Both entrypoints are also `payable`. The value is part of what the quorum signs, so a
///      transition settles only with the value it was analyzed with; see the per-function docs.
///
///      Nested settlement is opt-in through `GasKillerNestedSDK`, so a consumer that never
///      nests does not carry its bytecode; a `NESTED` op settled here reverts.
abstract contract GasKillerSDK is StateTracker, TransitionGuard, ERC165, IGasKillerSDK, IGasKillerSDKBatch {
    struct GasKillerSDKStorage {
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
    error EmptyBatch();
    error InsufficientBatchValue(uint256 sent, uint256 required);
    error BlockStaleMeasureOverflow();

    /// @notice Verify an aggregate Schnorr quorum signature and apply the state updates.
    /// @dev `msg.value` is bound into the digest, so the transition settles only with exactly
    ///      the value the task was analyzed with: a deposit cannot be credited without its ETH,
    ///      and no surplus can be sent. Value moved by `CALL`/`CREATE`/`CREATE2` updates is fixed
    ///      inside the signed `storageUpdates` and paid out of this contract's balance, which
    ///      includes `msg.value`; a shortfall reverts the whole transition (`RevertingContext` for
    ///      a CALL, `DeploymentFailed` for a CREATE/CREATE2).
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
    ) external payable guardTransition {
        _verifyAndUpdateOne(
            msgHash,
            referenceBlockNumber,
            storageUpdates,
            transitionIndex,
            targetFunction,
            msg.value,
            s,
            Raddr,
            nonSigners
        );
    }

    /// @notice Verify and apply a sequence of independently signed state transitions in
    ///         one transaction, amortizing the intrinsic and cold-access costs across the
    ///         batch (sub-transitions after the first verify at warm-access prices).
    /// @dev Each applied submission is checked exactly as a standalone `verifyAndUpdate`
    ///      would check it — same digest, same registry verification — so batching changes
    ///      nothing for the off-chain signing path. Transitions apply in order; the
    ///      `guardTransition` latch is held across the whole batch, and any failing
    ///      sub-transition reverts the entire batch.
    ///
    ///      A submission whose `transitionIndex` is already settled is SKIPPED (not
    ///      validated, not applied) rather than reverting the batch: settlement is
    ///      permissionless, so a third party who lifts one submission from the mempool
    ///      and settles it standalone could otherwise nullify the whole batch with one
    ///      cheap front-run. An index can only ever be consumed by a quorum-signed
    ///      transition for this contract, so a skipped item's transition has already
    ///      happened. Reverts (`InvalidTransitionIndex`) only on a genuine gap — an index
    ///      above the next expected one.
    ///
    ///      Batch assemblers: a `CALL` state update forwards all remaining gas to its target
    ///      with no cap (see `StateChangeHandlerLib`). A greedy/griefing target in an early
    ///      sub-transition can therefore starve every later one in the same batch, reverting
    ///      the whole (atomic) batch — no partial-state hazard, but it does nullify the
    ///      amortization this function exists for.
    ///
    ///      Each submission's digest binds its own `value`, and `msg.value` must cover the sum
    ///      over the submissions actually applied (`InsufficientBatchValue` otherwise), so no
    ///      applied transition is credited ETH the batch did not bring. The check is "covers"
    ///      rather than "equals" because a skipped submission must not revert the batch. The
    ///      surplus, such as a front-run item's share, is refunded to `msg.sender` once every
    ///      update has applied. A sender that can't accept it leaves it in this contract
    ///      rather than reverting the batch.
    /// @param submissions The transitions to apply, in order of ascending transition index.
    function verifyAndUpdateBatch(TaskSubmission[] calldata submissions) external payable guardTransition {
        uint256 len = submissions.length;
        require(len != 0, EmptyBatch());
        uint256 required;
        for (uint256 i = 0; i < len; ++i) {
            TaskSubmission calldata sub = submissions[i];
            // Already settled (e.g. front-run or redelivered) → skip, don't poison the batch.
            if (sub.transitionIndex + 1 <= stateTransitionCount()) continue;
            required += sub.value;
            _verifyAndUpdateOne(
                sub.msgHash,
                sub.referenceBlockNumber,
                sub.storageUpdates,
                sub.transitionIndex,
                sub.targetFunction,
                sub.value,
                sub.s,
                sub.Raddr,
                sub.nonSigners
            );
        }
        require(msg.value >= required, InsufficientBatchValue(msg.value, required));
        if (msg.value > required) {
            // Under the latch, so the refund can't re-enter settlement. A sender that rejects ETH
            // keeps the surplus here rather than reverting a batch the skip exists to protect.
            (bool refunded,) = msg.sender.call{value: msg.value - required}("");
            refunded;
        }
    }

    /// @dev The single-transition settlement path shared by both entrypoints. Callers must
    ///      hold the `guardTransition` latch.
    function _verifyAndUpdateOne(
        bytes32 msgHash,
        uint32 referenceBlockNumber,
        bytes calldata storageUpdates,
        uint256 transitionIndex,
        bytes4 targetFunction,
        uint256 value,
        uint256 s,
        address Raddr,
        address[] calldata nonSigners
    ) private trackState {
        require(referenceBlockNumber < block.number, FutureBlockNumber());
        require((uint256(referenceBlockNumber) + _getBlockStaleMeasure()) >= block.number, StaleBlockNumber());

        require(transitionIndex + 1 == stateTransitionCount(), InvalidTransitionIndex());
        require(_digest(transitionIndex, targetFunction, storageUpdates, value) == msgHash, InvalidSignature());

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
        bool ok = _schnorrRegistry().isValidSignature(msgHash, s, Raddr, nonSigners, referenceBlockNumber);
        require(ok, InvalidQuorumSignature());
    }

    function _stateChangeHandler(bytes calldata storageUpdates) internal {
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        StateChangeHandlerLib._runStateUpdates(types, args);
    }

    /// @notice Query if a contract implements an interface
    /// @dev Supports ERC-165, IGasKillerSDK detection (the router's preflight
    ///      probes the schnorr `verifyAndUpdate` selector before submitting), and the
    ///      IGasKillerSDKBatch batching/latch extension. Defers to `super` so a
    ///      contract inheriting both this SDK and another OpenZeppelin ERC-165 module reports
    ///      the union of both ID sets.
    /// @param interfaceId The interface identifier, as specified in ERC-165
    /// @return `true` if the contract implements `interfaceId` and `false` otherwise
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IGasKillerSDK).interfaceId || interfaceId == type(IGasKillerSDKBatch).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @notice Compute the expected message hash for a transition settled with no ETH
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
        return _digest(transitionIndex, targetFunction, storageUpdates, 0);
    }

    /// @notice Compute the expected message hash for a transition settled with `value` wei
    /// @dev Named apart from `getMessageHash` because an overload would rename the generated
    ///      off-chain binding of the existing function.
    /// @param transitionIndex The transition index
    /// @param targetFunction The target function selector
    /// @param storageUpdates The ABI-encoded storage updates
    /// @param value The `msg.value` the transition settles with
    /// @return The expected SHA-256 hash
    function getMessageHashWithValue(
        uint256 transitionIndex,
        bytes4 targetFunction,
        bytes calldata storageUpdates,
        uint256 value
    ) external view returns (bytes32) {
        return _digest(transitionIndex, targetFunction, storageUpdates, value);
    }

    /// @dev Mirrored by `NestedFrames.rootLeaf`, which must stay byte-identical.
    function _digest(uint256 transitionIndex, bytes4 targetFunction, bytes calldata storageUpdates, uint256 value)
        private
        view
        returns (bytes32)
    {
        if (value == 0) return sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates));
        return sha256(abi.encode(transitionIndex, address(this), targetFunction, storageUpdates, value));
    }

    /// @inheritdoc TransitionGuard
    function inTransition() public view override(TransitionGuard, IGasKillerSDKBatch) returns (bool locked) {
        return TransitionGuard.inTransition();
    }

    function schnorrRegistry() external view returns (address) {
        return address(_schnorrRegistry());
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

    function _schnorrRegistry() internal view returns (ISchnorrStakeRegistry) {
        return _sto().registry;
    }

    function _setBlockStaleMeasure(uint256 _blockStaleMeasure) internal {
        require(_blockStaleMeasure <= type(uint96).max, BlockStaleMeasureOverflow());
        _sto().blockStaleMeasure = uint96(_blockStaleMeasure);
    }

    function _getBlockStaleMeasure() internal view returns (uint256) {
        uint256 v = _sto().blockStaleMeasure;
        return v == 0 ? DEFAULT_BLOCK_STALE_MEASURE : v;
    }

    function _sto() private pure returns (GasKillerSDKStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
}

// src/GasKillerNestedSDK.sol

/// @title GasKillerNestedSDK
/// @notice `GasKillerSDK` plus nested settlement. Inherit this instead of `GasKillerSDK` in
///         every contract that roots a tree or applies a frame of one.
/// @dev Nested settlement (`IGasKillerNested`) extends settlement down a client's call stack:
///      one quorum signature over a Merkle root covers a frame per SDK-enabled contract, the
///      root contract settles through `verifyAndUpdateTree`, and each callee applies its own
///      frame through `applyNested`. Nested settlement needs the registry to implement
///      `ISchnorrApprovalRegistry`; `verifyAndUpdate` and `verifyAndUpdateBatch` do not.
abstract contract GasKillerNestedSDK is GasKillerSDK, IGasKillerNested {
    /// @notice Settle a nested tree whose root frame belongs to this contract.
    /// @dev The registry checks the signature and the signed expiry once and caches the
    ///      approval for the rest of the transaction; every callee frame reads that approval
    ///      instead of re-verifying. A tree always carries an expiry leaf, so its root can never
    ///      equal a single-transition digest and the two settlement paths cannot replay each
    ///      other's signatures. The root leaf binds `msg.value` exactly as `verifyAndUpdate`'s
    ///      digest does, so the tree settles only with the value it was analyzed with; value
    ///      moved by `NESTED` ops comes out of this contract's balance just as a `CALL` op's does.
    function verifyAndUpdateTree(TreeSubmission calldata submission) external payable {
        _enterExclusive(submission.root);
        _settleRoot(submission);
        _exitTransition(bytes32(0));
    }

    /// @notice Apply this contract's frame of an approved tree.
    /// @dev Contract, caller, value and transition index are taken from the call itself and
    ///      hashed into the leaf, so a frame applied by anyone but its signed parent, with any
    ///      other value, or out of order fails the leaf check. The parent must also report this
    ///      leaf as its pending child, which it does only while executing the `NESTED` op that
    ///      names it; without that, a parent that forwards arbitrary calls could be made to
    ///      apply the frame outside its tree.
    function applyNested(bytes32 root, bytes32 expectedLeaf, bytes calldata witness) external payable returns (bytes4) {
        (bool approved, uint256 refBlock) = _approvalRegistry().approvedRefBlock(root);
        require(approved, NotApproved(root));
        require(refBlock + _getBlockStaleMeasure() >= block.number, StaleBlockNumber());
        bytes32 previous = _enterNested(root);
        _applyFrame(root, expectedLeaf, witness);
        _exitTransition(previous);
        return IGasKillerNested.applyNested.selector;
    }

    /// @inheritdoc IGasKillerNested
    function pendingChild() external view returns (bytes32) {
        return StateChangeHandlerLib._pendingChild();
    }

    /// @notice Query if a contract implements an interface
    /// @dev Adds the `IGasKillerNested` extension, which the router probes on every frame
    ///      contract of a tree; a root that does not report it settles flat.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        if (interfaceId == type(IGasKillerNested).interfaceId) return _registrySupportsNesting();
        return super.supportsInterface(interfaceId);
    }

    function _settleRoot(TreeSubmission calldata submission) private trackState {
        uint256 refBlock = submission.sig.refBlock;
        require(refBlock < block.number, FutureBlockNumber());
        require(refBlock + _getBlockStaleMeasure() >= block.number, StaleBlockNumber());
        require(submission.transitionIndex + 1 == stateTransitionCount(), InvalidTransitionIndex());

        bytes32 leaf = NestedFrames.rootLeaf(
            submission.transitionIndex, address(this), submission.targetFunction, submission.storageUpdates, msg.value
        );
        require(NestedFrames.isMemberCalldata(submission.proof, submission.root, leaf), NotTreeMember(leaf));

        _approvalRegistry()
            .verifyAndApprove(
                submission.root, address(this), submission.expiryBlock, submission.expiryProof, submission.sig
            );
        _runProgram(submission.storageUpdates, NestedContext(submission.root, submission.children, 0));
    }

    function _applyFrame(bytes32 root, bytes32 expectedLeaf, bytes calldata encodedWitness) private trackState {
        NestedFrames.Witness memory witness = NestedFrames.decodeWitness(encodedWitness);
        bytes32 leaf = NestedFrames.nestedLeaf(
            address(this),
            stateTransitionCount() - 1,
            msg.sender,
            msg.value,
            witness.calldataHash,
            witness.storageUpdates
        );
        require(leaf == expectedLeaf, LeafMismatch(expectedLeaf, leaf));
        require(IGasKillerNested(msg.sender).pendingChild() == leaf, NotPendingChild(msg.sender, leaf));
        require(NestedFrames.isMember(witness.proof, root, leaf), NotTreeMember(leaf));
        _runProgram(witness.storageUpdates, NestedContext(root, witness.children, 0));
    }

    function _runProgram(bytes memory storageUpdates, NestedContext memory ctx) private {
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        StateChangeHandlerLib._runStateUpdates(types, args, ctx);
    }

    /// @dev Nested settlement reverts against a registry without `ISchnorrApprovalRegistry`, and
    ///      the router plans trees from the nested ID alone, so the ID follows the registry. The
    ///      unchecked probe returns false for a registry without ERC-165 rather than reverting.
    function _registrySupportsNesting() private view returns (bool) {
        return ERC165Checker.supportsERC165InterfaceUnchecked(
            address(_schnorrRegistry()), type(ISchnorrApprovalRegistry).interfaceId
        );
    }

    function _approvalRegistry() private view returns (ISchnorrApprovalRegistry) {
        return ISchnorrApprovalRegistry(address(_schnorrRegistry()));
    }
}
