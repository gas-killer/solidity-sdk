// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {
    IArbiter,
    ArbiterCapabilities,
    ICommitmentManagerMinimal,
    IOperatorRegistryMinimal,
    ISP1Verifier
} from "./interfaces/ICommitmentsMinimal.sol";
import {SchnorrCommitmentsAdapter} from "./SchnorrCommitmentsAdapter.sol";

/// @title GasKillerSP1Arbiter
/// @notice The Commitments arbiter for Gas Killer slashing: an SP1 fraud proof (an operator
///         signed a task result that faithful re-execution contradicts) authorizes opening
///         two-phase forfeits against the operator's stake commitments, and ejects the
///         operator's key from the Schnorr signer set in the same transaction. The
///         >= 1-day forfeit challenge window therefore delays only the capital slash —
///         a proven-equivocating key stops counting toward quorums immediately.
///
///         The contract is a non-upgradeable shell per Commitments arbiter doctrine, with
///         one deliberate mutable slot: the SP1 program vkey, behind a guardian-proposed
///         timelock at least as long as the unbonding path, so every operator can observe
///         a hostile vkey proposal and fully exit before it could slash them. This is the
///         escape from `OperatorRegistry.requiredArbiter` being immutable while the SP1
///         guest program evolves.
///
/// @dev Deploy order (the registry bakes this address in immutably): deploy the arbiter
///      first with `operatorRegistry`/`adapter` unset, initialize the Commitments
///      `OperatorRegistry` with this address as `requiredArbiter`, then `wireService`.
contract GasKillerSP1Arbiter is IArbiter {
    /// @notice The CommitmentManager this arbiter dispatches forfeits to (IArbiter).
    address public immutable override commitmentManager;

    /// @notice Succinct SP1 verifier gateway.
    ISP1Verifier public immutable sp1Verifier;

    /// @notice Governance for vkey rotation, forfeit cancellation, and metadata.
    address public immutable guardian;

    /// @notice Seconds a proposed vkey must wait before activation. Size it >= the
    ///         operator exit path (unbonding period + Schnorr notice window) so no key can
    ///         be slashed by a program it never had the chance to exit ahead of.
    uint256 public immutable vkeyDelay;

    /// @notice Penalty applied per proven offense, in basis points of each commitment.
    uint16 public immutable slashPenaltyBps;

    /// @notice Active SP1 program vkey.
    bytes32 public vkey;

    /// @notice Pending vkey rotation (zero when none).
    bytes32 public pendingVkey;
    uint256 public pendingVkeyActiveAt;

    /// @notice Commitments operator registry (one-shot wire; see deploy order above).
    IOperatorRegistryMinimal public operatorRegistry;

    /// @notice Schnorr lifecycle adapter used for immediate ejection (one-shot wire).
    SchnorrCommitmentsAdapter public adapter;

    /// @notice Offense ledger: `offenseKey = keccak256(operator, faultDigest)` records that
    ///         a valid proof was consumed for that (operator, offense) pair. Follow-up
    ///         forfeits for commitments missed in the first submission (e.g. delegations
    ///         indexed late) go through `slashMore` without re-verifying the proof.
    struct Offense {
        address operator;
        uint64 recordedAt;
        bool recorded;
    }

    mapping(bytes32 => Offense) public offenses;

    string internal metadataURI;

    error NotGuardian();
    error AlreadyWired();
    error NotWired();
    error ZeroAddress();
    error OffenseAlreadyRecorded(bytes32 offenseKey);
    error OffenseNotRecorded(bytes32 offenseKey);
    error CommitmentNotOperators(uint256 commitmentId, address operator);
    error NoForfeitsInitiated();
    error NoForfeitsExecuted();
    error NoPendingVkey();
    error VkeyTimelockActive(uint256 activeAt);

    event ServiceWired(address indexed operatorRegistry, address indexed adapter);
    event OffenseRecorded(bytes32 indexed offenseKey, address indexed operator, bytes32 faultDigest);
    event ForfeitOpened(bytes32 indexed offenseKey, uint256 indexed commitmentId, uint16 penaltyBps);
    event ForfeitAttemptFailed(bytes32 indexed offenseKey, uint256 indexed commitmentId, bytes reason);
    event ForfeitCancelled(uint256 indexed commitmentId);
    event ForfeitExecuted(uint256 indexed commitmentId);
    event ForfeitExecutionFailed(uint256 indexed commitmentId, bytes reason);
    event VkeyProposed(bytes32 indexed newVkey, uint256 activeAt);
    event VkeyActivated(bytes32 indexed newVkey);
    event VkeyProposalCancelled(bytes32 indexed cancelledVkey);
    event MetadataURIUpdated(string uri);

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    constructor(
        address _commitmentManager,
        address _sp1Verifier,
        bytes32 _vkey,
        address _guardian,
        uint256 _vkeyDelay,
        uint16 _slashPenaltyBps
    ) {
        if (_commitmentManager == address(0) || _sp1Verifier == address(0) || _guardian == address(0)) {
            revert ZeroAddress();
        }
        require(_slashPenaltyBps > 0 && _slashPenaltyBps <= 10_000, "bad penalty");
        commitmentManager = _commitmentManager;
        sp1Verifier = ISP1Verifier(_sp1Verifier);
        vkey = _vkey;
        guardian = _guardian;
        vkeyDelay = _vkeyDelay;
        slashPenaltyBps = _slashPenaltyBps;
    }

    /// @notice One-shot wiring of the Commitments registry and the Schnorr adapter,
    ///         breaking the deploy cycle around the registry's immutable `requiredArbiter`.
    function wireService(address _operatorRegistry, address _adapter) external onlyGuardian {
        if (address(operatorRegistry) != address(0)) revert AlreadyWired();
        if (_operatorRegistry == address(0) || _adapter == address(0)) revert ZeroAddress();
        operatorRegistry = IOperatorRegistryMinimal(_operatorRegistry);
        adapter = SchnorrCommitmentsAdapter(_adapter);
        emit ServiceWired(_operatorRegistry, _adapter);
    }

    // ---------------------------------------------------------------------------------------
    // Slashing
    // ---------------------------------------------------------------------------------------

    /// @notice Slash on a verified SP1 fraud proof. Permissionless: the proof is the
    ///         authority. Opens a forfeit on every supplied commitment bound to the accused
    ///         operator (self-stake and delegations — the caller enumerates ids off-chain
    ///         from registry events; `operatorForCommitment` makes the list trustless) and
    ///         ejects the operator's Schnorr key immediately.
    /// @dev Public-values layout (v1, must match the challenger guest):
    ///      `abi.encode(address operator, bytes32 faultDigest)` where `faultDigest`
    ///      uniquely identifies the offense (e.g. keccak of the equivocating task digest
    ///      and the faithful output hash). Kept in one decode site for guest evolution.
    /// @param publicValues   SP1 public values (see layout above).
    /// @param proofBytes     SP1 proof for the active `vkey`.
    /// @param commitmentIds  commitments to open forfeits on; each must be bound to the
    ///                       accused operator. Individual failures (e.g. an already-pending
    ///                       forfeit) are skipped and surfaced as events, but at least one
    ///                       forfeit must open.
    function slash(bytes calldata publicValues, bytes calldata proofBytes, uint256[] calldata commitmentIds)
        external
    {
        if (address(operatorRegistry) == address(0)) revert NotWired();
        sp1Verifier.verifyProof(vkey, publicValues, proofBytes);

        (address operator, bytes32 faultDigest) = abi.decode(publicValues, (address, bytes32));
        bytes32 offenseKey = keccak256(abi.encodePacked(operator, faultDigest));
        if (offenses[offenseKey].recorded) revert OffenseAlreadyRecorded(offenseKey);
        offenses[offenseKey] =
            Offense({operator: operator, recordedAt: uint64(block.timestamp), recorded: true});
        emit OffenseRecorded(offenseKey, operator, faultDigest);

        uint256 opened = _openForfeits(offenseKey, operator, commitmentIds);
        if (commitmentIds.length > 0 && opened == 0) revert NoForfeitsInitiated();

        // Ejection is idempotent and must not be blockable by forfeit-side failures.
        adapter.eject(operator);
    }

    /// @notice Open forfeits for additional commitments under an already-recorded offense
    ///         (delegations discovered after the original slash). Permissionless.
    function slashMore(bytes32 offenseKey, uint256[] calldata commitmentIds) external {
        Offense storage offense = offenses[offenseKey];
        if (!offense.recorded) revert OffenseNotRecorded(offenseKey);
        uint256 opened = _openForfeits(offenseKey, offense.operator, commitmentIds);
        if (opened == 0) revert NoForfeitsInitiated();
    }

    function _openForfeits(bytes32 offenseKey, address operator, uint256[] calldata commitmentIds)
        internal
        returns (uint256 opened)
    {
        uint256 idsLength = commitmentIds.length;
        for (uint256 i = 0; i < idsLength; ++i) {
            uint256 id = commitmentIds[i];
            if (operatorRegistry.operatorForCommitment(id) != operator) {
                revert CommitmentNotOperators(id, operator);
            }
            try ICommitmentManagerMinimal(commitmentManager).initiateForfeit(id, slashPenaltyBps) {
                ++opened;
                emit ForfeitOpened(offenseKey, id, slashPenaltyBps);
            } catch (bytes memory reason) {
                emit ForfeitAttemptFailed(offenseKey, id, reason);
            }
        }
    }

    /// @notice Crank `executeForfeit` for elapsed challenge windows. Permissionless
    ///         convenience over the manager's own permissionless entry point.
    /// @dev Reverts when the batch is non-empty and NOTHING executed. Without that,
    ///      gas estimation converges on an amount where every inner call gas-starves
    ///      inside the try/catch while the outer transaction "succeeds" — the revert
    ///      forces estimators to find a gas limit under which at least one forfeit
    ///      actually lands (found live in the anvil integration run).
    function crankExecute(uint256[] calldata commitmentIds) external {
        uint256 executed = 0;
        uint256 idsLength = commitmentIds.length;
        for (uint256 i = 0; i < idsLength; ++i) {
            uint256 id = commitmentIds[i];
            try ICommitmentManagerMinimal(commitmentManager).executeForfeit(id) {
                ++executed;
                emit ForfeitExecuted(id);
            } catch (bytes memory reason) {
                emit ForfeitExecutionFailed(id, reason);
            }
        }
        if (idsLength > 0 && executed == 0) revert NoForfeitsExecuted();
    }

    /// @notice Guardian veto for a pending forfeit — proof-bug insurance; proofs are
    ///         objective so this should never fire in normal operation.
    function cancelForfeit(uint256 commitmentId) external onlyGuardian {
        ICommitmentManagerMinimal(commitmentManager).cancelForfeit(commitmentId);
        emit ForfeitCancelled(commitmentId);
    }

    // ---------------------------------------------------------------------------------------
    // Vkey rotation (timelocked)
    // ---------------------------------------------------------------------------------------

    function proposeVkey(bytes32 newVkey) external onlyGuardian {
        pendingVkey = newVkey;
        pendingVkeyActiveAt = block.timestamp + vkeyDelay;
        emit VkeyProposed(newVkey, pendingVkeyActiveAt);
    }

    function cancelVkeyProposal() external onlyGuardian {
        if (pendingVkeyActiveAt == 0) revert NoPendingVkey();
        emit VkeyProposalCancelled(pendingVkey);
        pendingVkey = bytes32(0);
        pendingVkeyActiveAt = 0;
    }

    /// @notice Activate a proposed vkey after its timelock. Permissionless: activation is
    ///         mechanical once the delay every operator could exit within has elapsed.
    function activateVkey() external {
        if (pendingVkeyActiveAt == 0) revert NoPendingVkey();
        if (block.timestamp < pendingVkeyActiveAt) revert VkeyTimelockActive(pendingVkeyActiveAt);
        vkey = pendingVkey;
        emit VkeyActivated(pendingVkey);
        pendingVkey = bytes32(0);
        pendingVkeyActiveAt = 0;
    }

    // ---------------------------------------------------------------------------------------
    // IArbiter
    // ---------------------------------------------------------------------------------------

    function arbiterCapabilities() external pure override returns (uint256) {
        return ArbiterCapabilities.INITIATE_FORFEIT | ArbiterCapabilities.CANCEL_FORFEIT;
    }

    function arbiterMetadataURI() external view override returns (string memory) {
        return metadataURI;
    }

    function setMetadataURI(string calldata uri) external onlyGuardian {
        metadataURI = uri;
        emit MetadataURIUpdated(uri);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        // IArbiter id per upstream convention: xor of its three selectors.
        bytes4 arbiterId = IArbiter.commitmentManager.selector ^ IArbiter.arbiterCapabilities.selector
            ^ IArbiter.arbiterMetadataURI.selector;
        return interfaceId == arbiterId || interfaceId == 0x01ffc9a7; // ERC-165
    }
}
