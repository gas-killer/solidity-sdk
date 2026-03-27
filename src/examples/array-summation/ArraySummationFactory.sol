// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ArraySummation} from "./ArraySummation.sol";

/**
 * @title ArraySummationFactory
 * @notice Factory contract for deploying ArraySummation contracts
 * @dev Allows permissionless deployment of new array summation contracts
 *      and provides tracking functionality for deployed contracts
 */
contract ArraySummationFactory {
    // Events
    event ArraySummationDeployed(
        address indexed contractAddress,
        address indexed avsAddress,
        address indexed blsSigChecker,
        uint256 arraySize,
        uint256 maxValue,
        uint256 seed,
        uint256 deploymentIndex
    );

    // State variables
    address[] public deployedContracts;
    mapping(address => bool) public isDeployedContract;
    mapping(address => ContractInfo) public contractInfo;

    // Struct to store contract deployment information
    struct ContractInfo {
        address avsAddress;
        address blsSigChecker;
        uint256 arraySize;
        uint256 maxValue;
        uint256 seed;
        uint256 deploymentIndex;
        uint256 deploymentTimestamp;
    }

    /**
     * @notice Deploy a new ArraySummation contract
     * @param _avsAddress The AVS address for the new contract
     * @param _arraySize The size of the array to initialize
     * @param _maxValue The maximum value for array elements
     * @param _seed The seed for array initialization
     * @return contractAddress The address of the deployed contract
     */
    function deployArraySummation(
        address _avsAddress,
        address _blsSigChecker,
        uint256 _arraySize,
        uint256 _maxValue,
        uint256 _seed
    ) external returns (address contractAddress) {
        require(_avsAddress != address(0), "Invalid AVS address");

        // Deploy the new contract
        ArraySummation newContract = new ArraySummation(_avsAddress, _blsSigChecker, _arraySize, _maxValue, _seed);
        contractAddress = address(newContract);

        // Track the deployment
        uint256 deploymentIndex = deployedContracts.length;
        deployedContracts.push(contractAddress);
        isDeployedContract[contractAddress] = true;

        contractInfo[contractAddress] = ContractInfo({
            avsAddress: _avsAddress,
            blsSigChecker: _blsSigChecker,
            arraySize: _arraySize,
            maxValue: _maxValue,
            seed: _seed,
            deploymentIndex: deploymentIndex,
            deploymentTimestamp: block.timestamp
        });

        emit ArraySummationDeployed(
            contractAddress, _avsAddress, _blsSigChecker, _arraySize, _maxValue, _seed, deploymentIndex
        );
    }

    /**
     * @notice Get the total number of deployed contracts
     * @return count The number of deployed contracts
     */
    function getDeployedContractCount() external view returns (uint256 count) {
        return deployedContracts.length;
    }

    /**
     * @notice Get all deployed contract addresses
     * @return addresses Array of all deployed contract addresses
     */
    function getAllDeployedContracts() external view returns (address[] memory addresses) {
        return deployedContracts;
    }

    /**
     * @notice Get deployed contracts within a range
     * @param _startIndex Starting index (inclusive)
     * @param _endIndex Ending index (exclusive)
     * @return addresses Array of contract addresses in the specified range
     */
    function getDeployedContractsRange(uint256 _startIndex, uint256 _endIndex)
        external
        view
        returns (address[] memory addresses)
    {
        require(_startIndex < deployedContracts.length, "Start index out of bounds");
        require(_endIndex <= deployedContracts.length, "End index out of bounds");
        require(_startIndex < _endIndex, "Invalid range");

        uint256 length = _endIndex - _startIndex;
        addresses = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            addresses[i] = deployedContracts[_startIndex + i];
        }
    }

    /**
     * @notice Get contract information for a specific deployed contract
     * @param _contractAddress The address of the deployed contract
     * @return info The contract information
     */
    function getContractInfo(address _contractAddress) external view returns (ContractInfo memory info) {
        require(isDeployedContract[_contractAddress], "Contract not deployed by factory");
        return contractInfo[_contractAddress];
    }

    /**
     * @notice Get contracts deployed by a specific AVS address
     * @param _avsAddress The AVS address to filter by
     * @return addresses Array of contract addresses deployed by the AVS
     */
    function getContractsByAVS(address _avsAddress) external view returns (address[] memory addresses) {
        uint256 count = 0;

        // First pass: count matching contracts
        for (uint256 i = 0; i < deployedContracts.length; i++) {
            if (contractInfo[deployedContracts[i]].avsAddress == _avsAddress) {
                count++;
            }
        }

        // Second pass: collect addresses
        addresses = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < deployedContracts.length; i++) {
            if (contractInfo[deployedContracts[i]].avsAddress == _avsAddress) {
                addresses[index] = deployedContracts[i];
                index++;
            }
        }
    }

    /**
     * @notice Verify if a contract was deployed by this factory
     * @param _contractAddress The address to verify
     * @return deployed True if the contract was deployed by this factory
     */
    function isContractDeployedByFactory(address _contractAddress) external view returns (bool deployed) {
        return isDeployedContract[_contractAddress];
    }
}
