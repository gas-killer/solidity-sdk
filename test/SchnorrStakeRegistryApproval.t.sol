// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SchnorrStakeRegistry} from "../src/SchnorrStakeRegistry.sol";
import {ISchnorrApprovalRegistry, QuorumSignature} from "../src/interface/ISchnorrApprovalRegistry.sol";
import {NestedFrames} from "../src/libraries/NestedFrames.sol";
import {SchnorrSigner} from "./utils/SchnorrSigner.sol";
import {MerkleBuilder} from "./utils/MerkleBuilder.sol";

/// @notice `verifyAndApprove` / `approvedRefBlock`: the per-transaction root approval that
///         nested frames read instead of re-verifying the quorum signature.
contract SchnorrStakeRegistryApprovalTest is Test {
    SchnorrStakeRegistry registry;

    uint256 constant OPERATOR_KEY = 0xA11CE5;
    uint256 constant LATE_OPERATOR_KEY = 0xB0B5;
    address constant ROOT_CONTRACT = address(0xC0FFEE);

    bytes32[] leaves;
    bytes32 root;
    uint256 expiryBlock;

    function setUp() public {
        vm.roll(1000);
        registry = new SchnorrStakeRegistry(2, 3, address(this), 0);
        _register(OPERATOR_KEY, 1);
        vm.roll(block.number + 10);

        expiryBlock = block.number + 50;
        leaves.push(NestedFrames.expiryLeaf(ROOT_CONTRACT, expiryBlock));
        leaves.push(keccak256("root frame"));
        leaves.push(keccak256("child frame"));
        root = MerkleBuilder.root(leaves);
    }

    function test_signerProducesSignaturesTheRegistryAccepts() public {
        bytes32 message = keccak256("any digest");
        (uint256 s, address r) = SchnorrSigner.sign(OPERATOR_KEY, 77, message);
        assertTrue(registry.isValidSignature(message, s, r, new address[](0), block.number - 1));
    }

    function test_approveRecordsRefBlock() public {
        uint256 refBlock = block.number - 1;
        registry.verifyAndApprove(root, ROOT_CONTRACT, expiryBlock, _expiryProof(), _sign(root, refBlock));
        (bool approved, uint256 got) = registry.approvedRefBlock(root);
        assertTrue(approved);
        assertEq(got, refBlock);
    }

    function test_unapprovedRootReportsFalse() public view {
        (bool approved, uint256 refBlock) = registry.approvedRefBlock(root);
        assertFalse(approved);
        assertEq(refBlock, 0);
    }

    function test_invalidSignatureRevertsAndApprovesNothing() public {
        QuorumSignature memory sig = _sign(keccak256("other root"), block.number - 1);
        bytes32[] memory proof = _expiryProof();
        vm.expectRevert(ISchnorrApprovalRegistry.InvalidApprovalSignature.selector);
        registry.verifyAndApprove(root, ROOT_CONTRACT, expiryBlock, proof, sig);
        (bool approved,) = registry.approvedRefBlock(root);
        assertFalse(approved);
    }

    function test_unmetThresholdReverts() public {
        _register(LATE_OPERATOR_KEY, 2);
        vm.roll(block.number + 1);
        // The original operator alone holds 1/3 of the weight, below the 2/3 threshold.
        address[] memory nonSigners = new address[](1);
        nonSigners[0] = _identity(LATE_OPERATOR_KEY);
        QuorumSignature memory sig = _sign(root, block.number - 1);
        sig.nonSigners = nonSigners;
        bytes32[] memory proof = _expiryProof();
        vm.expectRevert(ISchnorrApprovalRegistry.InvalidApprovalSignature.selector);
        registry.verifyAndApprove(root, ROOT_CONTRACT, expiryBlock, proof, sig);
    }

    function test_futureAndStaleReferenceBlocksRevert() public {
        bytes32[] memory proof = _expiryProof();
        QuorumSignature memory future = _sign(root, block.number);
        vm.expectRevert(SchnorrStakeRegistry.FutureReferenceBlock.selector);
        registry.verifyAndApprove(root, ROOT_CONTRACT, expiryBlock, proof, future);

        QuorumSignature memory stale = _sign(root, 900);
        vm.expectRevert(SchnorrStakeRegistry.StaleSnapshot.selector);
        registry.verifyAndApprove(root, ROOT_CONTRACT, expiryBlock, proof, stale);
    }

    function test_approvalAfterExpiryReverts() public {
        QuorumSignature memory sig = _sign(root, block.number - 1);
        bytes32[] memory proof = _expiryProof();
        vm.roll(expiryBlock + 1);
        vm.expectRevert(abi.encodeWithSelector(ISchnorrApprovalRegistry.ApprovalExpired.selector, expiryBlock));
        registry.verifyAndApprove(root, ROOT_CONTRACT, expiryBlock, proof, sig);
    }

    function test_approvalAtExpiryBlockSucceeds() public {
        vm.roll(expiryBlock);
        registry.verifyAndApprove(root, ROOT_CONTRACT, expiryBlock, _expiryProof(), _sign(root, block.number - 1));
        (bool approved,) = registry.approvedRefBlock(root);
        assertTrue(approved);
    }

    function test_expiryLeafNotInRootReverts() public {
        QuorumSignature memory sig = _sign(root, block.number - 1);
        bytes32[] memory proof = _expiryProof();
        vm.expectRevert(ISchnorrApprovalRegistry.InvalidExpiryProof.selector);
        registry.verifyAndApprove(root, ROOT_CONTRACT, expiryBlock + 1, proof, sig);
        vm.expectRevert(ISchnorrApprovalRegistry.InvalidExpiryProof.selector);
        registry.verifyAndApprove(root, address(0xBAD), expiryBlock, proof, sig);
    }

    function test_secondApprovalKeepsFirstRefBlock() public {
        uint256 first = block.number - 1;
        registry.verifyAndApprove(root, ROOT_CONTRACT, expiryBlock, _expiryProof(), _sign(root, first));
        vm.roll(block.number + 5);
        registry.verifyAndApprove(root, ROOT_CONTRACT, expiryBlock, _expiryProof(), _sign(root, block.number - 1));
        (, uint256 got) = registry.approvedRefBlock(root);
        assertEq(got, first);
    }

    function test_secondApprovalStillChecksTheSignature() public {
        registry.verifyAndApprove(root, ROOT_CONTRACT, expiryBlock, _expiryProof(), _sign(root, block.number - 1));
        QuorumSignature memory bad = _sign(keccak256("other root"), block.number - 1);
        bytes32[] memory proof = _expiryProof();
        vm.expectRevert(ISchnorrApprovalRegistry.InvalidApprovalSignature.selector);
        registry.verifyAndApprove(root, ROOT_CONTRACT, expiryBlock, proof, bad);
    }

    function test_operatorSetMutationAfterApprovalFailsClosed() public {
        registry.verifyAndApprove(root, ROOT_CONTRACT, expiryBlock, _expiryProof(), _sign(root, block.number - 1));
        _register(LATE_OPERATOR_KEY, 1);
        (bool approved,) = registry.approvedRefBlock(root);
        assertFalse(approved);
    }

    /// forge-config: default.isolate = true
    function test_approvalDoesNotSurviveTheTransaction() public {
        registry.verifyAndApprove(root, ROOT_CONTRACT, expiryBlock, _expiryProof(), _sign(root, block.number - 1));
        (bool approved,) = registry.approvedRefBlock(root);
        assertFalse(approved);
    }

    function test_gas_warmLookupIsCheap() public {
        registry.verifyAndApprove(root, ROOT_CONTRACT, expiryBlock, _expiryProof(), _sign(root, block.number - 1));
        uint256 before = gasleft();
        registry.approvedRefBlock(root);
        uint256 used = before - gasleft();
        assertLt(used, 3_000, "warm approval lookup");
    }

    function _register(uint256 key, uint256 weight) private {
        (uint256 px, uint256 py) = SchnorrSigner.publicKey(key);
        (uint256 popS, address popR) =
            SchnorrSigner.sign(key, uint256(keccak256(abi.encode("pop", key))), registry.popMessage(_identity(key)));
        registry.registerOperator(px, py, weight, popS, popR);
    }

    function _identity(uint256 key) private returns (address) {
        (uint256 px, uint256 py) = SchnorrSigner.publicKey(key);
        return registry.pointAddress(px, py);
    }

    function _sign(bytes32 message, uint256 refBlock) private returns (QuorumSignature memory sig) {
        (uint256 s, address r) =
            SchnorrSigner.sign(OPERATOR_KEY, uint256(keccak256(abi.encode(message, refBlock))), message);
        sig = QuorumSignature(s, r, new address[](0), refBlock);
    }

    function _expiryProof() private view returns (bytes32[] memory) {
        return MerkleBuilder.proof(leaves, 0);
    }
}
