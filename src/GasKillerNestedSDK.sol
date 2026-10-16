// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {GasKillerSDK} from "./GasKillerSDK.sol";
import {StateChangeHandlerLib, StateUpdateType, NestedContext} from "./StateChangeHandlerLib.sol";
import {ISchnorrApprovalRegistry} from "./interface/ISchnorrApprovalRegistry.sol";
import {IGasKillerNested, TreeSubmission} from "./interface/IGasKillerNested.sol";
import {NestedFrames} from "./libraries/NestedFrames.sol";

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
    ///      other's signatures. Payable on the same terms as `verifyAndUpdate`; value moved by
    ///      `NESTED` ops comes out of this contract's balance just as a `CALL` op's does.
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
            submission.transitionIndex, address(this), submission.targetFunction, submission.storageUpdates
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
