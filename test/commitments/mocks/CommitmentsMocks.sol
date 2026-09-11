// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {
    ICommitmentManagerMinimal,
    IOperatorRegistryMinimal,
    ISP1Verifier
} from "../../../src/commitments/interfaces/ICommitmentsMinimal.sol";

// Test doubles for the Commitments-protocol surfaces the adapter and arbiter consume
// (`ICommitmentsMinimal`). Everything is settable so a test can drive the exact
// registry/manager/verifier behavior each branch needs; the contracts under test are
// always the REAL `SchnorrCommitmentsAdapter`, `GasKillerSP1Arbiter` and
// `SchnorrStakeRegistry`.

/// @notice Settable stand-in for the Commitments `OperatorRegistry` read surface:
///         per-address registration flag and stake, per-id commitment→operator binding.
contract MockOperatorRegistry is IOperatorRegistryMinimal {
    mapping(address => bool) internal registered;
    mapping(address => uint256) internal stake;
    mapping(uint256 => address) internal commitmentOperator;
    uint256 internal minStake;

    function setOperator(address operator, bool isRegistered, uint256 stakeAmount) external {
        registered[operator] = isRegistered;
        stake[operator] = stakeAmount;
    }

    function setIsOperator(address operator, bool isRegistered) external {
        registered[operator] = isRegistered;
    }

    function setStake(address operator, uint256 stakeAmount) external {
        stake[operator] = stakeAmount;
    }

    function setMinOperatorStake(uint256 value) external {
        minStake = value;
    }

    function setOperatorForCommitment(uint256 commitmentId, address operator) external {
        commitmentOperator[commitmentId] = operator;
    }

    function isOperator(address operator) external view override returns (bool) {
        return registered[operator];
    }

    function getOperatorStake(address operator) external view override returns (uint256) {
        return stake[operator];
    }

    function minOperatorStake() external view override returns (uint256) {
        return minStake;
    }

    function operatorForCommitment(uint256 commitmentId) external view override returns (address) {
        return commitmentOperator[commitmentId];
    }
}

/// @notice Recording stand-in for the `CommitmentManager` forfeit surface. Per-id revert
///         flags simulate manager-side failures (e.g. a forfeit already pending), which
///         the arbiter is expected to try/catch. A reverting call rolls its own recording
///         back with it, so the call logs below only ever hold the calls that SUCCEEDED —
///         exactly the observability the try/catch tests need.
contract MockCommitmentManager is ICommitmentManagerMinimal {
    error ForfeitPending(uint256 commitmentId);
    error ExecuteFailed(uint256 commitmentId);

    struct InitiateCall {
        uint256 commitmentId;
        uint16 penaltyBps;
    }

    InitiateCall[] public initiateCalls;
    uint256[] public cancelCalls;
    uint256[] public executeCalls;

    mapping(uint256 => bool) public revertOnInitiate;
    mapping(uint256 => bool) public revertOnExecute;

    function setRevertOnInitiate(uint256 commitmentId, bool flag) external {
        revertOnInitiate[commitmentId] = flag;
    }

    function setRevertOnExecute(uint256 commitmentId, bool flag) external {
        revertOnExecute[commitmentId] = flag;
    }

    function initiateForfeit(uint256 commitmentId, uint16 penaltyBps) external override {
        if (revertOnInitiate[commitmentId]) revert ForfeitPending(commitmentId);
        initiateCalls.push(InitiateCall({commitmentId: commitmentId, penaltyBps: penaltyBps}));
    }

    function cancelForfeit(uint256 commitmentId) external override {
        cancelCalls.push(commitmentId);
    }

    function executeForfeit(uint256 commitmentId) external override {
        if (revertOnExecute[commitmentId]) revert ExecuteFailed(commitmentId);
        executeCalls.push(commitmentId);
    }

    function initiateCallCount() external view returns (uint256) {
        return initiateCalls.length;
    }

    function cancelCallCount() external view returns (uint256) {
        return cancelCalls.length;
    }

    function executeCallCount() external view returns (uint256) {
        return executeCalls.length;
    }
}

/// @notice Stand-in for the Succinct SP1 verifier gateway. `verifyProof` is `view` on the
///         real interface, so the arbiter reaches it via STATICCALL — a mock cannot write
///         storage (or emit logs) inside it. "Recording" is therefore inverted: a test
///         pre-sets the vkey / public values it expects the arbiter to forward, and the
///         mock reverts on mismatch, which the test observes as a failed slash.
contract MockSP1Verifier is ISP1Verifier {
    error InvalidProof();
    error UnexpectedVkey(bytes32 got, bytes32 want);
    error UnexpectedPublicValues(bytes32 gotHash, bytes32 wantHash);

    bool public ok = true;
    bytes32 public expectedVkey; // zero = accept any vkey
    bytes32 public expectedPublicValuesHash; // zero = accept any public values

    function setOk(bool value) external {
        ok = value;
    }

    function setExpectedVkey(bytes32 value) external {
        expectedVkey = value;
    }

    function setExpectedPublicValues(bytes calldata publicValues) external {
        expectedPublicValuesHash = keccak256(publicValues);
    }

    function verifyProof(bytes32 programVKey, bytes calldata publicValues, bytes calldata)
        external
        view
        override
    {
        if (!ok) revert InvalidProof();
        if (expectedVkey != bytes32(0) && programVKey != expectedVkey) {
            revert UnexpectedVkey(programVKey, expectedVkey);
        }
        bytes32 gotHash = keccak256(publicValues);
        if (expectedPublicValuesHash != bytes32(0) && gotHash != expectedPublicValuesHash) {
            revert UnexpectedPublicValues(gotHash, expectedPublicValuesHash);
        }
    }
}
