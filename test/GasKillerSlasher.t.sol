// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {GasKillerSlasher} from "../src/GasKillerSlasher.sol";
import {IGasKillerSlasher} from "../src/interface/IGasKillerSlasher.sol";
import {GasKillerSDKExposed} from "./exposed/GasKillerSDKExposed.sol";

import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";
import {BN254} from "@eigenlayer-middleware/libraries/BN254.sol";
import {IAllocationManagerTypes} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {OperatorSet} from "eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";

// ============ Mocks ============

/// @notice SP1 verifier mock with a pass/fail switch; optionally pins the expected program vkey
contract MockSP1Verifier {
    bool public shouldFail;
    bytes32 public expectedVKey;

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    function setExpectedVKey(bytes32 _expectedVKey) external {
        expectedVKey = _expectedVKey;
    }

    function verifyProof(bytes32 programVKey, bytes calldata, bytes calldata) external view {
        require(!shouldFail, "MockSP1Verifier: invalid proof");
        require(expectedVKey == bytes32(0) || programVKey == expectedVKey, "MockSP1Verifier: wrong vkey");
    }
}

/// @notice Helios light client mock backed by a mapping of valid block hashes
contract MockHeliosLightClient {
    mapping(bytes32 => bool) public validBlockHashes;

    function setBlockHashValid(bytes32 blockHash, bool isValid) external {
        validBlockHashes[blockHash] = isValid;
    }

    function isBlockHashValid(bytes32 blockHash) external view returns (bool) {
        return validBlockHashes[blockHash];
    }
}

/// @notice BLS signature checker mock returning configurable per-quorum stake totals
/// @dev Optionally pins the message hash it expects (verifies the slasher passes the commitment hash)
contract MockBLSSignatureChecker {
    uint96[] internal _signedStake;
    uint96[] internal _totalStake;
    bytes32 public expectedMsgHash;

    function setStakes(uint96[] memory signedStake, uint96[] memory totalStake) external {
        _signedStake = signedStake;
        _totalStake = totalStake;
    }

    function setExpectedMsgHash(bytes32 _expectedMsgHash) external {
        expectedMsgHash = _expectedMsgHash;
    }

    function checkSignatures(
        bytes32 msgHash,
        bytes calldata,
        uint32,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory
    ) external view returns (IBLSSignatureCheckerTypes.QuorumStakeTotals memory, bytes32) {
        require(expectedMsgHash == bytes32(0) || msgHash == expectedMsgHash, "MockBLSSignatureChecker: wrong msgHash");
        return (
            IBLSSignatureCheckerTypes.QuorumStakeTotals({
                signedStakeForQuorum: _signedStake,
                totalStakeForQuorum: _totalStake
            }),
            bytes32(0)
        );
    }
}

/// @notice Index registry mock with configurable operator id lists per quorum
contract MockIndexRegistry {
    mapping(uint8 => bytes32[]) internal _operatorLists;

    function setOperatorList(uint8 quorumNumber, bytes32[] memory operatorIds) external {
        _operatorLists[quorumNumber] = operatorIds;
    }

    function getOperatorListAtBlockNumber(uint8 quorumNumber, uint32) external view returns (bytes32[] memory) {
        return _operatorLists[quorumNumber];
    }
}

/// @notice Registry coordinator mock resolving operator ids to addresses
contract MockRegistryCoordinator {
    mapping(bytes32 => address) internal _operators;

    function setOperator(bytes32 operatorId, address operator) external {
        _operators[operatorId] = operator;
    }

    function getOperatorFromId(bytes32 operatorId) external view returns (address) {
        return _operators[operatorId];
    }
}

/// @notice InstantSlasher mock recording every fulfillSlashingRequest call
contract MockInstantSlasher {
    address[] internal _slashedOperators;
    uint32 public lastOperatorSetId;
    IStrategy[] internal _lastStrategies;
    uint256[] internal _lastWadsToSlash;
    string public lastDescription;

    function fulfillSlashingRequest(IAllocationManagerTypes.SlashingParams calldata params) external {
        _slashedOperators.push(params.operator);
        lastOperatorSetId = params.operatorSetId;
        _lastStrategies = params.strategies;
        _lastWadsToSlash = params.wadsToSlash;
        lastDescription = params.description;
    }

    function slashedOperators() external view returns (address[] memory) {
        return _slashedOperators;
    }

    function lastStrategies() external view returns (IStrategy[] memory) {
        return _lastStrategies;
    }

    function lastWadsToSlash() external view returns (uint256[] memory) {
        return _lastWadsToSlash;
    }
}

/// @notice AllocationManager mock with configurable strategies and slashability
/// @dev Requires every query to target the expected (avs, operatorSetId) pair so the tests
///      also verify the slasher plumbs the operator set through correctly
contract MockAllocationManager {
    address public immutable EXPECTED_AVS;
    uint32 public immutable EXPECTED_OPERATOR_SET_ID;

    IStrategy[] internal _strategies;
    mapping(address => bool) public slashable;

    constructor(address expectedAvs, uint32 expectedOperatorSetId) {
        EXPECTED_AVS = expectedAvs;
        EXPECTED_OPERATOR_SET_ID = expectedOperatorSetId;
    }

    function setStrategies(IStrategy[] memory strategies) external {
        _strategies = strategies;
    }

    function setOperatorSlashable(address operator, bool isSlashable) external {
        slashable[operator] = isSlashable;
    }

    function getStrategiesInOperatorSet(OperatorSet memory operatorSet) external view returns (IStrategy[] memory) {
        _requireExpectedOperatorSet(operatorSet);
        return _strategies;
    }

    function isOperatorSlashable(address operator, OperatorSet memory operatorSet) external view returns (bool) {
        _requireExpectedOperatorSet(operatorSet);
        return slashable[operator];
    }

    function _requireExpectedOperatorSet(OperatorSet memory operatorSet) internal view {
        require(
            operatorSet.avs == EXPECTED_AVS && operatorSet.id == EXPECTED_OPERATOR_SET_ID,
            "MockAllocationManager: wrong operator set"
        );
    }
}

/// @notice Placeholder contract whose address is cast to IStrategy
contract MockStrategy {}

// ============ Tests ============

contract GasKillerSlasherTest is Test {
    using BN254 for BN254.G1Point;

    GasKillerSlasher public slasher;
    MockSP1Verifier public sp1Verifier;
    MockHeliosLightClient public helios;
    MockBLSSignatureChecker public blsSignatureChecker;
    MockIndexRegistry public indexRegistry;
    MockRegistryCoordinator public registryCoordinator;
    MockInstantSlasher public instantSlasher;
    MockAllocationManager public allocationManager;

    bytes32 public constant PROGRAM_VKEY = bytes32(uint256(0x1234));
    bytes32 public constant CHAIN_CONFIG_HASH = keccak256("chain-config");
    uint256 public constant CHALLENGE_WINDOW = 7 days;
    uint32 public constant OPERATOR_SET_ID = 1;
    uint32 public constant REFERENCE_BLOCK = 100;
    uint256 public constant TRANSITION_INDEX = 7;

    address public avs = makeAddr("avs");
    address public challenger = makeAddr("challenger");
    address public targetContract = makeAddr("target");
    address public caller = makeAddr("caller");

    address public operator1 = makeAddr("operator1");
    address public operator2 = makeAddr("operator2");
    address public operator3 = makeAddr("operator3");

    BN254.G1Point internal pubkey1;
    BN254.G1Point internal pubkey2;
    BN254.G1Point internal pubkey3;
    bytes32 internal operatorId1;
    bytes32 internal operatorId2;
    bytes32 internal operatorId3;

    bytes32 public anchorHash = keccak256("anchor");
    bytes public defaultCalldata = abi.encodeWithSignature("foo(uint256)", 42);
    bytes public signedStorageUpdates = abi.encode("signed storage updates");
    bytes public provenStorageUpdates = abi.encode("proven storage updates");
    bytes public sp1Proof = bytes("proof");

    function setUp() public {
        sp1Verifier = new MockSP1Verifier();
        helios = new MockHeliosLightClient();
        blsSignatureChecker = new MockBLSSignatureChecker();
        indexRegistry = new MockIndexRegistry();
        registryCoordinator = new MockRegistryCoordinator();
        instantSlasher = new MockInstantSlasher();
        allocationManager = new MockAllocationManager(avs, OPERATOR_SET_ID);

        // The slasher must pass exactly the configured program vkey to the verifier
        sp1Verifier.setExpectedVKey(PROGRAM_VKEY);

        // The anchor block hash is valid by default
        helios.setBlockHashValid(anchorHash, true);

        // 100% of the stake signed by default
        uint96[] memory signedStake = new uint96[](1);
        signedStake[0] = 100;
        uint96[] memory totalStake = new uint96[](1);
        totalStake[0] = 100;
        blsSignatureChecker.setStakes(signedStake, totalStake);

        // Three operators registered for quorum 0
        pubkey1 = BN254.G1Point(1, 2);
        pubkey2 = BN254.G1Point(3, 4);
        pubkey3 = BN254.G1Point(5, 6);
        operatorId1 = pubkey1.hashG1Point();
        operatorId2 = pubkey2.hashG1Point();
        operatorId3 = pubkey3.hashG1Point();

        bytes32[] memory quorum0Operators = new bytes32[](3);
        quorum0Operators[0] = operatorId1;
        quorum0Operators[1] = operatorId2;
        quorum0Operators[2] = operatorId3;
        indexRegistry.setOperatorList(0, quorum0Operators);

        registryCoordinator.setOperator(operatorId1, operator1);
        registryCoordinator.setOperator(operatorId2, operator2);
        registryCoordinator.setOperator(operatorId3, operator3);

        // Two strategies in the operator set; every operator slashable
        IStrategy[] memory strategies = new IStrategy[](2);
        strategies[0] = IStrategy(address(new MockStrategy()));
        strategies[1] = IStrategy(address(new MockStrategy()));
        allocationManager.setStrategies(strategies);
        allocationManager.setOperatorSlashable(operator1, true);
        allocationManager.setOperatorSlashable(operator2, true);
        allocationManager.setOperatorSlashable(operator3, true);

        slasher = new GasKillerSlasher(
            address(sp1Verifier),
            address(helios),
            address(blsSignatureChecker),
            address(registryCoordinator),
            address(indexRegistry),
            address(instantSlasher),
            address(allocationManager),
            avs,
            PROGRAM_VKEY,
            CHAIN_CONFIG_HASH,
            CHALLENGE_WINDOW,
            OPERATOR_SET_ID
        );
    }

    // ============ Helpers ============

    /// @notice Default signed commitment being challenged
    function _commitment() internal view returns (IGasKillerSlasher.SignedCommitment memory) {
        return IGasKillerSlasher.SignedCommitment({
            transitionIndex: TRANSITION_INDEX,
            contractAddress: targetContract,
            anchorHash: anchorHash,
            callerAddress: caller,
            contractCalldata: defaultCalldata,
            storageUpdates: signedStorageUpdates
        });
    }

    /// @notice Default proven public values: mirror the commitment with differing storage updates (fraud)
    function _publicValues() internal view returns (IGasKillerSlasher.GasKillerPublicValues memory) {
        return IGasKillerSlasher.GasKillerPublicValues({
            id: 12345,
            anchorHash: anchorHash,
            anchorType: 0,
            chainConfigHash: CHAIN_CONFIG_HASH,
            callerAddress: caller,
            contractAddress: targetContract,
            contractCalldata: defaultCalldata,
            contractOutput: bytes("output"),
            storageUpdates: provenStorageUpdates,
            opcodeHash: keccak256("opcodes")
        });
    }

    /// @notice NonSignerStakesAndSignature carrying only the given non-signer pubkeys
    function _nsas(BN254.G1Point[] memory nonSignerPubkeys)
        internal
        pure
        returns (IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nsas)
    {
        nsas.nonSignerPubkeys = nonSignerPubkeys;
    }

    function _emptyNsas() internal pure returns (IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory) {
        return _nsas(new BN254.G1Point[](0));
    }

    /// @notice Call slash as the challenger with explicit arguments
    function _slash(
        IGasKillerSlasher.SignedCommitment memory commitment,
        bytes memory quorumNumbers,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nsas,
        bytes memory publicValues
    ) internal {
        vm.prank(challenger);
        slasher.slash(commitment, quorumNumbers, REFERENCE_BLOCK, nsas, sp1Proof, publicValues);
    }

    /// @notice Call slash as the challenger with the default fraud scenario
    function _slashDefault() internal {
        _slash(_commitment(), hex"00", _emptyNsas(), abi.encode(_publicValues()));
    }

    // ============ Constructor Tests ============

    function test_constructor_setsConfig() public view {
        assertEq(address(slasher.SP1_VERIFIER()), address(sp1Verifier));
        assertEq(address(slasher.HELIOS()), address(helios));
        assertEq(address(slasher.BLS_SIGNATURE_CHECKER()), address(blsSignatureChecker));
        assertEq(address(slasher.REGISTRY_COORDINATOR()), address(registryCoordinator));
        assertEq(address(slasher.INDEX_REGISTRY()), address(indexRegistry));
        assertEq(address(slasher.INSTANT_SLASHER()), address(instantSlasher));
        assertEq(address(slasher.ALLOCATION_MANAGER()), address(allocationManager));
        assertEq(slasher.AVS(), avs);
        assertEq(slasher.PROGRAM_V_KEY(), PROGRAM_VKEY);
        assertTrue(slasher.acceptedChainConfigHash(CHAIN_CONFIG_HASH));
        assertEq(slasher.owner(), address(this));
        assertEq(slasher.CHALLENGE_WINDOW(), CHALLENGE_WINDOW);
        assertEq(slasher.OPERATOR_SET_ID(), OPERATOR_SET_ID);
        assertEq(slasher.challengeWindow(), CHALLENGE_WINDOW);
        assertEq(slasher.programVKey(), PROGRAM_VKEY);
    }

    // ============ Happy Path ============

    function test_slash_fraudSlashesAllSigners() public {
        bytes32 commitmentHash = slasher.computeCommitmentHash(_commitment());

        // The slasher must verify the aggregate signature over exactly the commitment hash
        blsSignatureChecker.setExpectedMsgHash(commitmentHash);

        address[] memory expectedSigners = new address[](3);
        expectedSigners[0] = operator1;
        expectedSigners[1] = operator2;
        expectedSigners[2] = operator3;

        vm.expectEmit(true, true, false, true, address(slasher));
        emit IGasKillerSlasher.SlashingExecuted(commitmentHash, challenger, expectedSigners, 1e18);

        _slashDefault();

        assertTrue(slasher.isSlashed(commitmentHash));

        // Every signer slashed through the InstantSlasher
        address[] memory slashed = instantSlasher.slashedOperators();
        assertEq(slashed.length, 3);
        assertEq(slashed[0], operator1);
        assertEq(slashed[1], operator2);
        assertEq(slashed[2], operator3);

        // Slashing params: operator set id, one full-slash wad per strategy, hash in description
        assertEq(instantSlasher.lastOperatorSetId(), OPERATOR_SET_ID);
        assertEq(instantSlasher.lastStrategies().length, 2);
        uint256[] memory wads = instantSlasher.lastWadsToSlash();
        assertEq(wads.length, 2);
        assertEq(wads[0], 1e18);
        assertEq(wads[1], 1e18);
        assertEq(
            instantSlasher.lastDescription(),
            string.concat("Gas Killer fraud detected for commitment: ", vm.toString(commitmentHash))
        );
    }

    function test_slash_revertsAlreadySlashed() public {
        _slashDefault();

        vm.expectRevert(IGasKillerSlasher.AlreadySlashed.selector);
        _slashDefault();
    }

    // ============ Challenge Window ============

    function test_slash_revertsChallengeExpired() public {
        bytes32 commitmentHash = slasher.computeCommitmentHash(_commitment());

        // The target contract records the application of the commitment
        vm.prank(targetContract);
        slasher.recordCommitment(commitmentHash);
        uint256 recordedAt = block.timestamp;

        vm.warp(recordedAt + CHALLENGE_WINDOW + 1);

        vm.expectRevert(IGasKillerSlasher.ChallengeExpired.selector);
        _slashDefault();
    }

    function test_slash_succeedsAtChallengeWindowBoundary() public {
        bytes32 commitmentHash = slasher.computeCommitmentHash(_commitment());

        vm.prank(targetContract);
        slasher.recordCommitment(commitmentHash);
        uint256 recordedAt = block.timestamp;

        // Last valid second of the window
        vm.warp(recordedAt + CHALLENGE_WINDOW);

        _slashDefault();
        assertTrue(slasher.isSlashed(commitmentHash));
    }

    function test_slash_unrecordedCommitmentChallengeableForever() public {
        bytes32 commitmentHash = slasher.computeCommitmentHash(_commitment());

        // Never recorded: challengeable long after any window would have expired
        vm.warp(block.timestamp + 365 days);

        _slashDefault();
        assertTrue(slasher.isSlashed(commitmentHash));
    }

    // ============ recordCommitment ============

    function test_recordCommitment_setsTimestampAndEmits() public {
        bytes32 commitmentHash = keccak256("commitment");

        vm.expectEmit(true, true, false, false, address(slasher));
        emit IGasKillerSlasher.CommitmentRecorded(targetContract, commitmentHash);

        vm.prank(targetContract);
        slasher.recordCommitment(commitmentHash);

        assertEq(slasher.getCommitmentTimestamp(targetContract, commitmentHash), block.timestamp);
    }

    function test_recordCommitment_doesNotOverwrite() public {
        bytes32 commitmentHash = keccak256("commitment");

        vm.prank(targetContract);
        slasher.recordCommitment(commitmentHash);

        // Read back through an external call: via-ir rematerializes `block.timestamp` locals
        // across `vm.warp`, so a cached local would observe the warped value
        uint256 firstTimestamp = slasher.getCommitmentTimestamp(targetContract, commitmentHash);

        vm.warp(firstTimestamp + 1000);
        vm.prank(targetContract);
        slasher.recordCommitment(commitmentHash);

        assertEq(slasher.getCommitmentTimestamp(targetContract, commitmentHash), firstTimestamp);
    }

    function test_recordCommitment_keyedByMsgSender() public {
        bytes32 commitmentHash = slasher.computeCommitmentHash(_commitment());
        address attacker = makeAddr("attacker");

        // A third party recording the hash does not start the window for the target contract
        vm.prank(attacker);
        slasher.recordCommitment(commitmentHash);

        assertEq(slasher.getCommitmentTimestamp(attacker, commitmentHash), block.timestamp);
        assertEq(slasher.getCommitmentTimestamp(targetContract, commitmentHash), 0);

        // The commitment stays challengeable after the attacker-started window elapsed
        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
        _slashDefault();
        assertTrue(slasher.isSlashed(commitmentHash));
    }

    // ============ Quorum Threshold ============

    function test_slash_revertsInsufficientQuorumThreshold() public {
        uint96[] memory signedStake = new uint96[](1);
        signedStake[0] = 65;
        uint96[] memory totalStake = new uint96[](1);
        totalStake[0] = 100;
        blsSignatureChecker.setStakes(signedStake, totalStake);

        vm.expectRevert(IGasKillerSlasher.InsufficientQuorumThreshold.selector);
        _slashDefault();
    }

    function test_slash_succeedsAtQuorumThresholdBoundary() public {
        // Exactly 66% signed passes
        uint96[] memory signedStake = new uint96[](1);
        signedStake[0] = 66;
        uint96[] memory totalStake = new uint96[](1);
        totalStake[0] = 100;
        blsSignatureChecker.setStakes(signedStake, totalStake);

        _slashDefault();
        assertTrue(slasher.isSlashed(slasher.computeCommitmentHash(_commitment())));
    }

    function test_slash_revertsInsufficientQuorumThreshold_secondQuorum() public {
        // First quorum passes, second quorum falls short
        uint96[] memory signedStake = new uint96[](2);
        signedStake[0] = 100;
        signedStake[1] = 50;
        uint96[] memory totalStake = new uint96[](2);
        totalStake[0] = 100;
        totalStake[1] = 100;
        blsSignatureChecker.setStakes(signedStake, totalStake);

        vm.expectRevert(IGasKillerSlasher.InsufficientQuorumThreshold.selector);
        _slash(_commitment(), hex"0001", _emptyNsas(), abi.encode(_publicValues()));
    }

    // ============ Proof / Anchor Verification ============

    function test_slash_revertsInvalidProof() public {
        sp1Verifier.setShouldFail(true);

        vm.expectRevert(IGasKillerSlasher.InvalidProof.selector);
        _slashDefault();
    }

    function test_slash_revertsUnverifiedBlock() public {
        helios.setBlockHashValid(anchorHash, false);

        vm.expectRevert(IGasKillerSlasher.UnverifiedBlock.selector);
        _slashDefault();
    }

    function test_slash_revertsUnverifiedBlock_whenHeliosUnset() public {
        GasKillerSlasher slasherNoHelios = new GasKillerSlasher(
            address(sp1Verifier),
            address(0), // no Helios light client
            address(blsSignatureChecker),
            address(registryCoordinator),
            address(indexRegistry),
            address(instantSlasher),
            address(allocationManager),
            avs,
            PROGRAM_VKEY,
            CHAIN_CONFIG_HASH,
            CHALLENGE_WINDOW,
            OPERATOR_SET_ID
        );

        vm.prank(challenger);
        vm.expectRevert(IGasKillerSlasher.UnverifiedBlock.selector);
        slasherNoHelios.slash(
            _commitment(), hex"00", REFERENCE_BLOCK, _emptyNsas(), sp1Proof, abi.encode(_publicValues())
        );
    }

    // ============ Public Values Checks ============

    function test_slash_revertsInvalidChainConfig() public {
        IGasKillerSlasher.GasKillerPublicValues memory proven = _publicValues();
        proven.chainConfigHash = keccak256("other-chain-config");

        vm.expectRevert(IGasKillerSlasher.InvalidChainConfig.selector);
        _slash(_commitment(), hex"00", _emptyNsas(), abi.encode(proven));
    }

    /// @notice After a hardfork, the owner accepts the new fork's config hash and
    ///         post-fork commitments become challengeable again.
    function test_setChainConfigHashAccepted_enablesNewFork() public {
        bytes32 newForkConfig = keccak256("post-hardfork-config");

        // A proof carrying the new fork's config is rejected until accepted.
        IGasKillerSlasher.GasKillerPublicValues memory proven = _publicValues();
        proven.chainConfigHash = newForkConfig;
        vm.expectRevert(IGasKillerSlasher.InvalidChainConfig.selector);
        _slash(_commitment(), hex"00", _emptyNsas(), abi.encode(proven));

        // Owner accepts the new fork's config.
        vm.expectEmit(true, false, false, true, address(slasher));
        emit IGasKillerSlasher.ChainConfigHashSet(newForkConfig, true);
        slasher.setChainConfigHashAccepted(newForkConfig, true);
        assertTrue(slasher.acceptedChainConfigHash(newForkConfig));

        // Now a fraudulent post-fork commitment can be slashed.
        _slash(_commitment(), hex"00", _emptyNsas(), abi.encode(proven));
        assertTrue(slasher.isSlashed(slasher.computeCommitmentHash(_commitment())));
    }

    /// @notice Only the owner may change accepted chain config hashes.
    function test_setChainConfigHashAccepted_onlyOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert("Ownable: caller is not the owner");
        slasher.setChainConfigHashAccepted(keccak256("x"), true);
    }

    /// @notice The owner can revoke a previously accepted config hash.
    function test_setChainConfigHashAccepted_revoke() public {
        assertTrue(slasher.acceptedChainConfigHash(CHAIN_CONFIG_HASH));
        slasher.setChainConfigHashAccepted(CHAIN_CONFIG_HASH, false);
        assertFalse(slasher.acceptedChainConfigHash(CHAIN_CONFIG_HASH));

        vm.expectRevert(IGasKillerSlasher.InvalidChainConfig.selector);
        _slash(_commitment(), hex"00", _emptyNsas(), abi.encode(_publicValues()));
    }

    function test_slash_revertsInputMismatch_anchorType() public {
        IGasKillerSlasher.GasKillerPublicValues memory proven = _publicValues();
        proven.anchorType = 1; // Timestamp anchor instead of BlockHash

        vm.expectRevert(IGasKillerSlasher.InputMismatch.selector);
        _slash(_commitment(), hex"00", _emptyNsas(), abi.encode(proven));
    }

    function test_slash_revertsInputMismatch_anchorHash() public {
        IGasKillerSlasher.GasKillerPublicValues memory proven = _publicValues();
        proven.anchorHash = keccak256("other-anchor");

        vm.expectRevert(IGasKillerSlasher.InputMismatch.selector);
        _slash(_commitment(), hex"00", _emptyNsas(), abi.encode(proven));
    }

    function test_slash_revertsInputMismatch_caller() public {
        IGasKillerSlasher.GasKillerPublicValues memory proven = _publicValues();
        proven.callerAddress = makeAddr("otherCaller");

        vm.expectRevert(IGasKillerSlasher.InputMismatch.selector);
        _slash(_commitment(), hex"00", _emptyNsas(), abi.encode(proven));
    }

    function test_slash_revertsInputMismatch_contract() public {
        IGasKillerSlasher.GasKillerPublicValues memory proven = _publicValues();
        proven.contractAddress = makeAddr("otherContract");

        vm.expectRevert(IGasKillerSlasher.InputMismatch.selector);
        _slash(_commitment(), hex"00", _emptyNsas(), abi.encode(proven));
    }

    function test_slash_revertsInputMismatch_calldata() public {
        IGasKillerSlasher.GasKillerPublicValues memory proven = _publicValues();
        proven.contractCalldata = abi.encodeWithSignature("bar(uint256)", 42);

        vm.expectRevert(IGasKillerSlasher.InputMismatch.selector);
        _slash(_commitment(), hex"00", _emptyNsas(), abi.encode(proven));
    }

    function test_slash_revertsNoFraudDetected() public {
        // Proven storage updates equal the signed ones: honest commitment
        IGasKillerSlasher.GasKillerPublicValues memory proven = _publicValues();
        proven.storageUpdates = signedStorageUpdates;

        vm.expectRevert(IGasKillerSlasher.NoFraudDetected.selector);
        _slash(_commitment(), hex"00", _emptyNsas(), abi.encode(proven));
    }

    // ============ Signer Derivation ============

    function test_slash_excludesNonSigners() public {
        // operator2 declared as non-signer: must not be slashed
        BN254.G1Point[] memory nonSignerPubkeys = new BN254.G1Point[](1);
        nonSignerPubkeys[0] = pubkey2;

        bytes32 commitmentHash = slasher.computeCommitmentHash(_commitment());
        address[] memory expectedSigners = new address[](2);
        expectedSigners[0] = operator1;
        expectedSigners[1] = operator3;

        vm.expectEmit(true, true, false, true, address(slasher));
        emit IGasKillerSlasher.SlashingExecuted(commitmentHash, challenger, expectedSigners, 1e18);

        _slash(_commitment(), hex"00", _nsas(nonSignerPubkeys), abi.encode(_publicValues()));

        address[] memory slashed = instantSlasher.slashedOperators();
        assertEq(slashed.length, 2);
        assertEq(slashed[0], operator1);
        assertEq(slashed[1], operator3);
    }

    function test_slash_duplicateOperatorAcrossQuorumsSlashedOnce() public {
        // Quorum 0: [op1, op2]; quorum 1: [op2, op3] — op2 must be slashed only once
        bytes32[] memory quorum0Operators = new bytes32[](2);
        quorum0Operators[0] = operatorId1;
        quorum0Operators[1] = operatorId2;
        indexRegistry.setOperatorList(0, quorum0Operators);

        bytes32[] memory quorum1Operators = new bytes32[](2);
        quorum1Operators[0] = operatorId2;
        quorum1Operators[1] = operatorId3;
        indexRegistry.setOperatorList(1, quorum1Operators);

        uint96[] memory signedStake = new uint96[](2);
        signedStake[0] = 100;
        signedStake[1] = 100;
        uint96[] memory totalStake = new uint96[](2);
        totalStake[0] = 100;
        totalStake[1] = 100;
        blsSignatureChecker.setStakes(signedStake, totalStake);

        bytes32 commitmentHash = slasher.computeCommitmentHash(_commitment());
        address[] memory expectedSigners = new address[](3);
        expectedSigners[0] = operator1;
        expectedSigners[1] = operator2;
        expectedSigners[2] = operator3;

        vm.expectEmit(true, true, false, true, address(slasher));
        emit IGasKillerSlasher.SlashingExecuted(commitmentHash, challenger, expectedSigners, 1e18);

        _slash(_commitment(), hex"0001", _emptyNsas(), abi.encode(_publicValues()));

        address[] memory slashed = instantSlasher.slashedOperators();
        assertEq(slashed.length, 3);
        assertEq(slashed[0], operator1);
        assertEq(slashed[1], operator2);
        assertEq(slashed[2], operator3);
    }

    function test_slash_skipsUnslashableOperator() public {
        allocationManager.setOperatorSlashable(operator2, false);

        bytes32 commitmentHash = slasher.computeCommitmentHash(_commitment());
        address[] memory expectedSigners = new address[](3);
        expectedSigners[0] = operator1;
        expectedSigners[1] = operator2;
        expectedSigners[2] = operator3;

        // The event still lists every signer, including the unslashable one
        vm.expectEmit(true, true, false, true, address(slasher));
        emit IGasKillerSlasher.SlashingExecuted(commitmentHash, challenger, expectedSigners, 1e18);

        _slashDefault();

        // Only slashable operators reach the InstantSlasher
        address[] memory slashed = instantSlasher.slashedOperators();
        assertEq(slashed.length, 2);
        assertEq(slashed[0], operator1);
        assertEq(slashed[1], operator3);
        assertTrue(slasher.isSlashed(commitmentHash));
    }

    // ============ Commitment Hash ============

    function test_computeCommitmentHash_deterministicAndMatchesEncoding() public view {
        IGasKillerSlasher.SignedCommitment memory commitment = _commitment();

        bytes32 hash1 = slasher.computeCommitmentHash(commitment);
        bytes32 hash2 = slasher.computeCommitmentHash(commitment);
        assertEq(hash1, hash2);

        // sha256 over the abi-encoded commitment fields, in order
        bytes32 expected = sha256(
            abi.encode(
                commitment.transitionIndex,
                commitment.contractAddress,
                commitment.anchorHash,
                commitment.callerAddress,
                commitment.contractCalldata,
                commitment.storageUpdates
            )
        );
        assertEq(hash1, expected);

        // Any field change produces a different hash
        IGasKillerSlasher.SignedCommitment memory other = _commitment();
        other.storageUpdates = provenStorageUpdates;
        assertTrue(slasher.computeCommitmentHash(other) != hash1);
    }

    function test_computeCommitmentHash_matchesSdkMessageHash() public {
        // The hash the slasher verifies must equal the message hash the SDK signs, where the
        // SDK hashes over address(this) and the slasher over commitment.contractAddress
        GasKillerSDKExposed sdk = new GasKillerSDKExposed(avs, address(blsSignatureChecker));

        IGasKillerSlasher.SignedCommitment memory commitment = _commitment();
        commitment.contractAddress = address(sdk);

        bytes32 sdkHash = sdk.getMessageHash(
            commitment.transitionIndex,
            commitment.anchorHash,
            commitment.callerAddress,
            commitment.contractCalldata,
            commitment.storageUpdates
        );

        assertEq(slasher.computeCommitmentHash(commitment), sdkHash);
    }
}
