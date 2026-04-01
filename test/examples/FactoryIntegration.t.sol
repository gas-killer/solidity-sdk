// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {ArraySummationFactory} from "../../src/examples/array-summation/ArraySummationFactory.sol";
import {ArraySummation} from "../../src/examples/array-summation/ArraySummation.sol";

/// @title FactoryIntegrationTest
/// @notice Integration tests demonstrating real-world usage of the factory
/// @dev Shows how different components might interact with the factory
contract FactoryIntegrationTest is Test {
    ArraySummationFactory public factory;

    /// Mock addresses for different services
    address public avsService1 = address(0x1111);
    address public avsService2 = address(0x2222);
    address public avsService3 = address(0x3333);
    address public blsSignatureChecker = address(0x4444);

    /// Different array sizes and max values
    uint256 public arraySize1 = 1000;
    uint256 public arraySize2 = 500;
    uint256 public maxValue1 = 10000;
    uint256 public maxValue2 = 5000;

    /// Different seeds for deterministic initialization
    uint256 public seed1 = 12345;
    uint256 public seed2 = 67890;
    uint256 public seed3 = 11111;

    function setUp() public {
        factory = new ArraySummationFactory();
    }

    /// @notice Test scenario: Multiple services deploying their own summation contracts
    function testMultipleServicesDeployment() public {
        /// Service 1 deploys a contract
        address contract1 = factory.deployArraySummation(avsService1, blsSignatureChecker, arraySize1, maxValue1, seed1);

        /// Service 2 deploys a contract
        address contract2 = factory.deployArraySummation(avsService2, blsSignatureChecker, arraySize2, maxValue2, seed2);

        /// Service 3 deploys a contract
        address contract3 = factory.deployArraySummation(avsService3, blsSignatureChecker, arraySize1, maxValue1, seed3);

        /// Verify all contracts are tracked
        assertEq(factory.getDeployedContractCount(), 3);
        assertTrue(factory.isContractDeployedByFactory(contract1));
        assertTrue(factory.isContractDeployedByFactory(contract2));
        assertTrue(factory.isContractDeployedByFactory(contract3));

        /// Verify each service can find their contracts
        address[] memory service1Contracts = factory.getContractsByAVS(avsService1);
        address[] memory service2Contracts = factory.getContractsByAVS(avsService2);
        address[] memory service3Contracts = factory.getContractsByAVS(avsService3);

        assertEq(service1Contracts.length, 1);
        assertEq(service2Contracts.length, 1);
        assertEq(service3Contracts.length, 1);
        assertEq(service1Contracts[0], contract1);
        assertEq(service2Contracts[0], contract2);
        assertEq(service3Contracts[0], contract3);
    }

    /// @notice Test scenario: Contract discovery and management
    function testContractDiscoveryAndManagement() public {
        /// Deploy some contracts
        factory.deployArraySummation(avsService1, blsSignatureChecker, arraySize1, maxValue1, seed1);
        factory.deployArraySummation(avsService2, blsSignatureChecker, arraySize2, maxValue2, seed2);
        factory.deployArraySummation(avsService1, blsSignatureChecker, arraySize1, maxValue1, seed3); // Another contract for service 1

        /// Get all deployed contracts
        address[] memory allContracts = factory.getAllDeployedContracts();
        assertEq(allContracts.length, 3);

        /// Get contracts by range
        address[] memory firstTwo = factory.getDeployedContractsRange(0, 2);
        address[] memory lastOne = factory.getDeployedContractsRange(2, 3);

        assertEq(firstTwo.length, 2);
        assertEq(lastOne.length, 1);

        /// Get contract information
        ArraySummationFactory.ContractInfo memory info = factory.getContractInfo(allContracts[0]);
        assertEq(info.avsAddress, avsService1);
        assertEq(info.arraySize, arraySize1);
        assertEq(info.maxValue, maxValue1);
        assertEq(info.deploymentIndex, 0);
        assertTrue(info.deploymentTimestamp > 0);
    }

    /// @notice Test scenario: Contract verification and validation
    function testContractVerification() public {
        /// Deploy a contract through the factory
        address factoryDeployed =
            factory.deployArraySummation(avsService1, blsSignatureChecker, arraySize1, maxValue1, seed1);

        /// Deploy a contract directly (not through factory)
        ArraySummation directDeployed =
            new ArraySummation(avsService1, blsSignatureChecker, arraySize1, maxValue1, seed1);

        /// Verify factory deployment
        assertTrue(factory.isContractDeployedByFactory(factoryDeployed));
        assertFalse(factory.isContractDeployedByFactory(address(directDeployed)));

        /// Try to get info for non-factory contract
        vm.expectRevert("Contract not deployed by factory");
        factory.getContractInfo(address(directDeployed));
    }

    /// @notice Test scenario: Real-world usage pattern with contract interaction
    function testRealWorldUsagePattern() public {
        /// Simulate a service that needs to deploy and manage multiple summation contracts

        /// Step 1: Deploy contracts for different data sets
        address productionContract =
            factory.deployArraySummation(avsService1, blsSignatureChecker, arraySize1, maxValue1, seed1);
        address testingContract =
            factory.deployArraySummation(avsService1, blsSignatureChecker, arraySize2, maxValue2, seed2);

        /// Step 2: Interact with the contracts
        ArraySummation production = ArraySummation(productionContract);
        ArraySummation testing = ArraySummation(testingContract);

        /// Step 3: Perform operations
        uint256[] memory emptyIndexes = new uint256[](0);
        production.sum(emptyIndexes);
        testing.sum(emptyIndexes);

        uint256 productionSum = production.currentSum();
        uint256 testingSum = testing.currentSum();

        /// Step 4: Verify different seeds produce different results
        assertTrue(productionSum != testingSum, "Different seeds should produce different sums");

        /// Step 5: Update data and recalculate
        production.setArrayElement(0, 9999);
        production.sum(emptyIndexes);
        uint256 updatedProductionSum = production.currentSum();

        assertTrue(updatedProductionSum != productionSum, "Sum should change after update");

        /// Step 6: Query factory for contract management
        address[] memory myContracts = factory.getContractsByAVS(avsService1);
        assertEq(myContracts.length, 2);

        /// Step 7: Verify contract info
        ArraySummationFactory.ContractInfo memory info = factory.getContractInfo(productionContract);
        assertEq(info.avsAddress, avsService1);
        assertEq(info.arraySize, arraySize1);
        assertEq(info.maxValue, maxValue1);
        assertEq(info.seed, seed1);
    }
}
