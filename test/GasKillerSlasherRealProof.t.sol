// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {GasKillerBLSSlasher} from "../src/GasKillerBLSSlasher.sol";
import {IGasKillerSlasher} from "../src/interface/IGasKillerSlasher.sol";
import {IHeliosLightClient} from "../src/interface/IHeliosLightClient.sol";
import {SP1Verifier} from "../src/vendor/sp1/SP1VerifierGroth16.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";
import {IAllocationManagerTypes} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {OperatorSet} from "eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";

// ============ Mocks ============
// Only proof verification uses the REAL vendored SP1 Groth16 verifier; everything the
// slasher touches besides the SP1 verifier is mocked in-file.

/// @notice Helios mock that validates explicitly whitelisted block hashes
contract MockHeliosLightClient is IHeliosLightClient {
    mapping(bytes32 => bool) public validBlockHashes;

    function setBlockHashValid(bytes32 blockHash, bool isValid) external {
        validBlockHashes[blockHash] = isValid;
    }

    function isBlockHashValid(bytes32 blockHash) external view returns (bool) {
        return validBlockHashes[blockHash];
    }

    function getBlockHash(uint256) external pure returns (bytes32) {
        return bytes32(0);
    }
}

/// @notice BLS signature checker mock that reports full stake signed for every quorum
contract MockBLSSignatureChecker {
    function checkSignatures(
        bytes32,
        bytes calldata quorumNumbers,
        uint32,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature calldata
    ) external pure returns (IBLSSignatureCheckerTypes.QuorumStakeTotals memory stakeTotals, bytes32) {
        stakeTotals.signedStakeForQuorum = new uint96[](quorumNumbers.length);
        stakeTotals.totalStakeForQuorum = new uint96[](quorumNumbers.length);
        for (uint256 i = 0; i < quorumNumbers.length; i++) {
            stakeTotals.signedStakeForQuorum[i] = 100;
            stakeTotals.totalStakeForQuorum[i] = 100;
        }
        return (stakeTotals, bytes32(0));
    }
}

/// @notice Index registry mock returning a fixed operator id list for every quorum
contract MockIndexRegistry {
    bytes32[] internal _operatorIds;

    function setOperatorIds(bytes32[] memory operatorIds) external {
        _operatorIds = operatorIds;
    }

    function getOperatorListAtBlockNumber(uint8, uint32) external view returns (bytes32[] memory) {
        return _operatorIds;
    }
}

/// @notice Registry coordinator mock mapping operator ids to addresses
contract MockRegistryCoordinator {
    mapping(bytes32 => address) public operatorById;

    function setOperator(bytes32 operatorId, address operator) external {
        operatorById[operatorId] = operator;
    }

    function getOperatorFromId(bytes32 operatorId) external view returns (address) {
        return operatorById[operatorId];
    }
}

/// @notice Instant slasher mock that records every fulfilled slashing request
contract MockInstantSlasher {
    address[] public slashedOperators;
    string public lastDescription;

    function fulfillSlashingRequest(IAllocationManagerTypes.SlashingParams memory slashingParams) external {
        slashedOperators.push(slashingParams.operator);
        lastDescription = slashingParams.description;
    }

    function slashCount() external view returns (uint256) {
        return slashedOperators.length;
    }
}

/// @notice Allocation manager mock with a single strategy where every operator is slashable
contract MockAllocationManager {
    IStrategy[] internal _strategies;

    constructor(IStrategy strategy) {
        _strategies.push(strategy);
    }

    function getStrategiesInOperatorSet(OperatorSet memory) external view returns (IStrategy[] memory) {
        return _strategies;
    }

    function isOperatorSlashable(address, OperatorSet memory) external pure returns (bool) {
        return true;
    }
}

/// @notice Placeholder strategy; the slasher only passes its address around
contract MockStrategy {}

/// @title GasKillerSlasherRealProofTest
/// @notice End-to-end integration test that runs a REAL SP1 Groth16 fraud proof through
///         `GasKillerBLSSlasher.slash` using the vendored Succinct verifier (v5.0.0)
/// @dev Requires a proof fixture at `test/fixtures/gas-killer-fixture.json` produced by the
///      Gas Killer challenger host. When the fixture is absent (or `fs_permissions` denies
///      reading it) every test is skipped so the suite stays green before a proof exists.
contract GasKillerSlasherRealProofTest is Test {
    using stdJson for string;

    // ============ Fixture ============

    /// @notice Deserialized contents of `test/fixtures/gas-killer-fixture.json`
    struct Fixture {
        uint256 chainId;
        uint256 blockNumber;
        bytes32 anchorHash;
        bytes32 chainConfigHash;
        address callerAddress;
        address contractAddress;
        bytes contractCalldata;
        bytes contractOutput;
        bytes storageUpdates;
        bytes32 opcodeHash;
        bytes32 vkey;
        bytes publicValues;
        bytes proof;
    }

    string internal constant FIXTURE_PATH = "test/fixtures/gas-killer-fixture.json";

    Fixture internal fixture;

    // ============ Test State ============

    GasKillerBLSSlasher internal slasher;
    SP1Verifier internal sp1Verifier;
    MockHeliosLightClient internal helios;
    MockBLSSignatureChecker internal blsSignatureChecker;
    MockIndexRegistry internal indexRegistry;
    MockRegistryCoordinator internal registryCoordinator;
    MockInstantSlasher internal instantSlasher;
    MockAllocationManager internal allocationManager;

    uint256 internal constant CHALLENGE_WINDOW = 7 days;
    uint32 internal constant OPERATOR_SET_ID = 0;
    uint32 internal constant REFERENCE_BLOCK_NUMBER = 1;
    bytes internal constant QUORUM_NUMBERS = hex"00";

    address internal avs = makeAddr("avs");
    address internal challenger = makeAddr("challenger");
    address internal operator1 = makeAddr("operator1");
    address internal operator2 = makeAddr("operator2");
    address internal operator3 = makeAddr("operator3");

    function setUp() public {
        // Skip the whole suite when no proof fixture has been generated yet.
        string memory json;
        try vm.readFile(FIXTURE_PATH) returns (string memory contents) {
            json = contents;
        } catch {
            vm.skip(true, "missing test/fixtures/gas-killer-fixture.json (or fs_permissions denies reading it)");
            return;
        }

        fixture.chainId = json.readUint(".chainId");
        fixture.blockNumber = json.readUint(".blockNumber");
        fixture.anchorHash = json.readBytes32(".anchorHash");
        fixture.chainConfigHash = json.readBytes32(".chainConfigHash");
        fixture.callerAddress = json.readAddress(".callerAddress");
        fixture.contractAddress = json.readAddress(".contractAddress");
        fixture.contractCalldata = json.readBytes(".contractCalldata");
        fixture.contractOutput = json.readBytes(".contractOutput");
        fixture.storageUpdates = json.readBytes(".storageUpdates");
        fixture.opcodeHash = json.readBytes32(".opcodeHash");
        fixture.vkey = json.readBytes32(".vkey");
        fixture.publicValues = json.readBytes(".publicValues");
        fixture.proof = json.readBytes(".proof");

        // Real Groth16 verifier: no mock for proof verification.
        sp1Verifier = new SP1Verifier();

        helios = new MockHeliosLightClient();
        helios.setBlockHashValid(fixture.anchorHash, true);

        blsSignatureChecker = new MockBLSSignatureChecker();

        indexRegistry = new MockIndexRegistry();
        registryCoordinator = new MockRegistryCoordinator();
        bytes32[] memory operatorIds = new bytes32[](3);
        operatorIds[0] = bytes32(uint256(1));
        operatorIds[1] = bytes32(uint256(2));
        operatorIds[2] = bytes32(uint256(3));
        indexRegistry.setOperatorIds(operatorIds);
        registryCoordinator.setOperator(operatorIds[0], operator1);
        registryCoordinator.setOperator(operatorIds[1], operator2);
        registryCoordinator.setOperator(operatorIds[2], operator3);

        instantSlasher = new MockInstantSlasher();
        allocationManager = new MockAllocationManager(IStrategy(address(new MockStrategy())));

        slasher = new GasKillerBLSSlasher(
            address(sp1Verifier),
            address(helios),
            address(blsSignatureChecker),
            address(registryCoordinator),
            address(indexRegistry),
            address(instantSlasher),
            address(allocationManager),
            avs,
            fixture.vkey,
            fixture.chainConfigHash,
            CHALLENGE_WINDOW,
            OPERATOR_SET_ID
        );
    }

    // ============ Tests ============

    /// @notice A commitment whose signed storage updates diverge from the proven ones is fraud:
    ///         the real proof verifies and every signing operator gets slashed
    function test_fraud() public {
        IGasKillerSlasher.SignedCommitment memory commitment = _commitment(_tamper(fixture.storageUpdates));
        bytes32 commitmentHash = slasher.computeCommitmentHash(commitment);

        vm.prank(challenger);
        slasher.slash(
            commitment,
            QUORUM_NUMBERS,
            REFERENCE_BLOCK_NUMBER,
            _emptyNonSignerStakesAndSignature(),
            fixture.proof,
            fixture.publicValues
        );

        assertTrue(slasher.isSlashed(commitmentHash), "commitment not marked slashed");
        assertEq(instantSlasher.slashCount(), 3, "expected all three signers slashed");
        assertEq(instantSlasher.slashedOperators(0), operator1);
        assertEq(instantSlasher.slashedOperators(1), operator2);
        assertEq(instantSlasher.slashedOperators(2), operator3);
    }

    /// @notice A commitment whose signed storage updates equal the proven ones is not fraud
    function test_noFraud() public {
        IGasKillerSlasher.SignedCommitment memory commitment = _commitment(fixture.storageUpdates);

        vm.prank(challenger);
        vm.expectRevert(IGasKillerSlasher.NoFraudDetected.selector);
        slasher.slash(
            commitment,
            QUORUM_NUMBERS,
            REFERENCE_BLOCK_NUMBER,
            _emptyNonSignerStakesAndSignature(),
            fixture.proof,
            fixture.publicValues
        );
    }

    /// @notice A corrupted Groth16 proof is rejected by the real verifier
    function test_invalidProof() public {
        IGasKillerSlasher.SignedCommitment memory commitment = _commitment(_tamper(fixture.storageUpdates));

        // Flip one byte past the 4-byte verifier selector so Groth16 verification itself fails.
        bytes memory badProof = bytes.concat(fixture.proof);
        badProof[badProof.length - 1] ^= 0x01;

        vm.prank(challenger);
        vm.expectRevert(IGasKillerSlasher.InvalidProof.selector);
        slasher.slash(
            commitment,
            QUORUM_NUMBERS,
            REFERENCE_BLOCK_NUMBER,
            _emptyNonSignerStakesAndSignature(),
            badProof,
            fixture.publicValues
        );
    }

    /// @notice A commitment whose calldata differs from the proven execution is not challengeable
    function test_wrongCalldata() public {
        IGasKillerSlasher.SignedCommitment memory commitment = _commitment(_tamper(fixture.storageUpdates));
        commitment.contractCalldata = bytes.concat(fixture.contractCalldata, hex"ff");

        vm.prank(challenger);
        vm.expectRevert(IGasKillerSlasher.InputMismatch.selector);
        slasher.slash(
            commitment,
            QUORUM_NUMBERS,
            REFERENCE_BLOCK_NUMBER,
            _emptyNonSignerStakesAndSignature(),
            fixture.proof,
            fixture.publicValues
        );
    }

    // ============ Helpers ============

    /// @notice Build a signed commitment matching the fixture's proven inputs
    /// @param storageUpdates The storage updates the aggregate network allegedly signed
    function _commitment(bytes memory storageUpdates)
        internal
        view
        returns (IGasKillerSlasher.SignedCommitment memory)
    {
        return IGasKillerSlasher.SignedCommitment({
            transitionIndex: 1,
            contractAddress: fixture.contractAddress,
            anchorHash: fixture.anchorHash,
            callerAddress: fixture.callerAddress,
            contractCalldata: fixture.contractCalldata,
            storageUpdates: storageUpdates
        });
    }

    /// @notice Copy `data` with its last byte flipped (or a non-empty placeholder when empty)
    function _tamper(bytes memory data) internal pure returns (bytes memory tampered) {
        if (data.length == 0) {
            return hex"01";
        }
        tampered = bytes.concat(data);
        tampered[tampered.length - 1] ^= 0xff;
    }

    /// @notice All three operators signed, so the non-signer data is empty
    function _emptyNonSignerStakesAndSignature()
        internal
        pure
        returns (IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nsas)
    {
        // Every array field defaults to empty and every BN254 point to zero; the BLS
        // signature checker is mocked so the aggregate signature material is unused.
        return nsas;
    }
}
