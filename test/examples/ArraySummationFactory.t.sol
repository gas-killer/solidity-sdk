// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {ArraySummationFactory} from "../../src/examples/array-summation/ArraySummationFactory.sol";
import {ArraySummation} from "../../src/examples/array-summation/ArraySummation.sol";

contract ArraySummationFactoryTest is Test {
    ArraySummationFactory public factory;
    address public avsAddress1 = address(0x1234);
    address public avsAddress2 = address(0x5678);
    address public blsSignatureChecker = address(0x1111);
    uint256 public arraySize1 = 1000;
    uint256 public arraySize2 = 500;
    uint256 public maxValue1 = 10000;
    uint256 public maxValue2 = 5000;
    uint256 public seed1 = 12345;
    uint256 public seed2 = 67890;

    event ArraySummationDeployed(
        address indexed contractAddress,
        address indexed avsAddress,
        address indexed blsSigChecker,
        uint256 arraySize,
        uint256 maxValue,
        uint256 seed,
        uint256 deploymentIndex
    );

    function setUp() public {
        factory = new ArraySummationFactory();
    }

    function testFactoryDeployment() public view {
        assertEq(factory.getDeployedContractCount(), 0);
        address[] memory contracts = factory.getAllDeployedContracts();
        assertEq(contracts.length, 0);
    }

    function testDeploySingleContract() public {
        uint256 deploymentIndex = 0;

        address deployedAddress =
            factory.deployArraySummation(avsAddress1, blsSignatureChecker, arraySize1, maxValue1, seed1);

        // Verify deployment tracking
        assertEq(factory.getDeployedContractCount(), 1);
        assertTrue(factory.isContractDeployedByFactory(deployedAddress));
        assertTrue(factory.isDeployedContract(deployedAddress));

        // Verify contract info
        ArraySummationFactory.ContractInfo memory info = factory.getContractInfo(deployedAddress);
        assertEq(info.avsAddress, avsAddress1);
        assertEq(info.arraySize, arraySize1);
        assertEq(info.maxValue, maxValue1);
        assertEq(info.seed, seed1);
        assertEq(info.deploymentIndex, deploymentIndex);
        assertTrue(info.deploymentTimestamp > 0);

        // Verify the deployed contract works
        ArraySummation deployedContract = ArraySummation(deployedAddress);
        assertEq(deployedContract.avsAddress(), avsAddress1);
        assertEq(deployedContract.arraySize(), arraySize1);
        assertEq(deployedContract.maxValue(), maxValue1);
        assertEq(deployedContract.getArrayLength(), arraySize1);
    }

    function testDeployWithInvalidAVSAddress() public {
        vm.expectRevert("Invalid AVS address");
        factory.deployArraySummation(address(0), blsSignatureChecker, arraySize1, maxValue1, seed1);
    }

    function testDeployWithInvalidArraySize() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidConfiguration()"));
        factory.deployArraySummation(avsAddress1, blsSignatureChecker, 0, maxValue1, seed1);
    }

    function testDeployWithInvalidMaxValue() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidConfiguration()"));
        factory.deployArraySummation(avsAddress1, blsSignatureChecker, arraySize1, 0, seed1);
    }

    function testGetContractInfoForNonDeployedContract() public {
        address nonDeployedAddress = address(0x9999);

        vm.expectRevert("Contract not deployed by factory");
        factory.getContractInfo(nonDeployedAddress);
    }

    function testGetContractsByAVS() public {
        // Deploy contracts with different AVS addresses
        factory.deployArraySummation(avsAddress1, blsSignatureChecker, arraySize1, maxValue1, seed1);
        factory.deployArraySummation(avsAddress2, blsSignatureChecker, arraySize2, maxValue2, seed2);
        factory.deployArraySummation(avsAddress1, blsSignatureChecker, arraySize2, maxValue2, seed2); // Another contract for avsAddress1

        address[] memory contractsForAVS1 = factory.getContractsByAVS(avsAddress1);
        address[] memory contractsForAVS2 = factory.getContractsByAVS(avsAddress2);

        assertEq(contractsForAVS1.length, 2);
        assertEq(contractsForAVS2.length, 1);
    }

    function testGetDeployedContractsRange() public {
        // Deploy 5 contracts
        for (uint256 i = 0; i < 5; i++) {
            factory.deployArraySummation(avsAddress1, blsSignatureChecker, arraySize1, maxValue1, seed1 + i);
        }

        // Test range queries
        address[] memory range1 = factory.getDeployedContractsRange(0, 2);
        address[] memory range2 = factory.getDeployedContractsRange(2, 5);
        address[] memory range3 = factory.getDeployedContractsRange(1, 3);

        assertEq(range1.length, 2);
        assertEq(range2.length, 3);
        assertEq(range3.length, 2);
    }

    function testGetDeployedContractsRangeInvalidBounds() public {
        // Deploy 1 contract
        factory.deployArraySummation(avsAddress1, blsSignatureChecker, arraySize1, maxValue1, seed1);

        // Test invalid ranges
        vm.expectRevert("Start index out of bounds");
        factory.getDeployedContractsRange(1, 2);

        vm.expectRevert("End index out of bounds");
        factory.getDeployedContractsRange(0, 2);

        // Test invalid range (start >= end) - need to deploy more contracts first
        factory.deployArraySummation(avsAddress1, blsSignatureChecker, arraySize2, maxValue2, seed2);

        vm.expectRevert("Invalid range");
        factory.getDeployedContractsRange(1, 0);
    }

    function testDeployedContractFunctionality() public {
        address deployedAddress =
            factory.deployArraySummation(avsAddress1, blsSignatureChecker, arraySize1, maxValue1, seed1);
        ArraySummation deployedContract = ArraySummation(deployedAddress);

        // Test that the deployed contract works as expected
        uint256[] memory emptyIndexes = new uint256[](0);
        deployedContract.sum(emptyIndexes);

        uint256 sum = deployedContract.currentSum();
        assertTrue(sum > 0, "Sum should be greater than 0");

        // Test array element access
        uint256 element = deployedContract.getArrayElement(0);
        assertTrue(element < maxValue1, "Element should be in valid range");
    }

    function testMultipleDeploymentsWithSameParameters() public {
        // Deploy multiple contracts with same parameters
        address address1 = factory.deployArraySummation(avsAddress1, blsSignatureChecker, arraySize1, maxValue1, seed1);
        address address2 = factory.deployArraySummation(avsAddress1, blsSignatureChecker, arraySize1, maxValue1, seed1);

        // Verify they are different addresses
        assertTrue(address1 != address2);

        // Verify both are tracked
        assertTrue(factory.isContractDeployedByFactory(address1));
        assertTrue(factory.isContractDeployedByFactory(address2));

        // Verify contract info
        ArraySummationFactory.ContractInfo memory info1 = factory.getContractInfo(address1);
        ArraySummationFactory.ContractInfo memory info2 = factory.getContractInfo(address2);

        assertEq(info1.deploymentIndex, 0);
        assertEq(info2.deploymentIndex, 1);
        assertEq(info1.avsAddress, info2.avsAddress);
        assertEq(info1.blsSigChecker, info2.blsSigChecker);
        assertEq(info1.arraySize, info2.arraySize);
        assertEq(info1.maxValue, info2.maxValue);
        assertEq(info1.seed, info2.seed);
    }

    function testDeployedContractsArray() public {
        address[] memory allContracts = factory.getAllDeployedContracts();
        assertEq(allContracts.length, 0);

        address deployedAddress =
            factory.deployArraySummation(avsAddress1, blsSignatureChecker, arraySize1, maxValue1, seed1);

        allContracts = factory.getAllDeployedContracts();
        assertEq(allContracts.length, 1);
        assertEq(allContracts[0], deployedAddress);

        address deployedAddress2 =
            factory.deployArraySummation(avsAddress2, blsSignatureChecker, arraySize2, maxValue2, seed2);

        allContracts = factory.getAllDeployedContracts();
        assertEq(allContracts.length, 2);
        assertEq(allContracts[0], deployedAddress);
        assertEq(allContracts[1], deployedAddress2);
    }
}
