// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {SchnorrArraySummation} from "./SchnorrArraySummation.sol";

/// @title SchnorrArraySummationFactory
/// @notice Factory contract for deploying SchnorrArraySummation contracts
/// @dev Allows permissionless deployment of new array summation contracts
///      and provides tracking functionality for deployed contracts
contract SchnorrArraySummationFactory {
    /// @notice Emitted when a new SchnorrArraySummation contract is deployed via this factory
    /// @param contractAddress Address of the newly deployed SchnorrArraySummation contract
    /// @param avsAddress The AVS service manager address passed to the contract
    /// @param schnorrStakeRegistry The Schnorr stake registry passed to the contract
    /// @param arraySize Number of elements in the initialised array
    /// @param maxValue Upper bound used for element generation
    /// @param seed Entropy seed used for array initialisation
    /// @param deploymentIndex Zero-based position of this deployment in `deployedContracts`
    event SchnorrArraySummationDeployed(
        address indexed contractAddress,
        address indexed avsAddress,
        address indexed schnorrStakeRegistry,
        uint256 arraySize,
        uint256 maxValue,
        uint256 seed,
        uint256 deploymentIndex
    );

    /// @notice Ordered list of all SchnorrArraySummation contracts deployed through this factory
    address[] public deployedContracts;

    /// @notice Quick membership check — true if an address was deployed by this factory
    mapping(address => bool) public isDeployedContract;

    /// @notice Deployment metadata keyed by contract address
    mapping(address => ContractInfo) public contractInfo;

    /// @notice Metadata recorded at deployment time for each SchnorrArraySummation contract
    struct ContractInfo {
        /// @notice The AVS service manager address the contract was configured with
        address avsAddress;
        /// @notice The Schnorr stake registry the contract was configured with
        address schnorrStakeRegistry;
        /// @notice Number of elements in the contract's array
        uint256 arraySize;
        /// @notice Upper bound used for element generation
        uint256 maxValue;
        /// @notice Entropy seed used at deployment
        uint256 seed;
        /// @notice Zero-based index of this contract in `deployedContracts`
        uint256 deploymentIndex;
        /// @notice `block.timestamp` at the time of deployment
        uint256 deploymentTimestamp;
    }

    /// @notice Deploy a new SchnorrArraySummation contract
    /// @param _avsAddress The AVS service manager address for the new contract
    /// @param _schnorrStakeRegistry The Schnorr stake registry verifying aggregate operator quorums
    /// @param _arraySize The size of the array to initialize
    /// @param _maxValue The maximum value for array elements
    /// @param _seed The seed for array initialization
    /// @return contractAddress The address of the deployed contract
    function deploySchnorrArraySummation(
        address _avsAddress,
        address _schnorrStakeRegistry,
        uint256 _arraySize,
        uint256 _maxValue,
        uint256 _seed
    ) external returns (address contractAddress) {
        require(_avsAddress != address(0), "Invalid AVS address");

        // Deploy the new contract
        SchnorrArraySummation newContract =
            new SchnorrArraySummation(_avsAddress, _schnorrStakeRegistry, _arraySize, _maxValue, _seed);
        contractAddress = address(newContract);

        // Track the deployment
        uint256 deploymentIndex = deployedContracts.length;
        deployedContracts.push(contractAddress);
        isDeployedContract[contractAddress] = true;

        contractInfo[contractAddress] = ContractInfo({
            avsAddress: _avsAddress,
            schnorrStakeRegistry: _schnorrStakeRegistry,
            arraySize: _arraySize,
            maxValue: _maxValue,
            seed: _seed,
            deploymentIndex: deploymentIndex,
            deploymentTimestamp: block.timestamp
        });

        emit SchnorrArraySummationDeployed(
            contractAddress, _avsAddress, _schnorrStakeRegistry, _arraySize, _maxValue, _seed, deploymentIndex
        );
    }

    /// @notice Return the total number of contracts deployed by this factory
    /// @return count The number of deployed contracts
    function getDeployedContractCount() external view returns (uint256 count) {
        return deployedContracts.length;
    }

    /// @notice Return all contract addresses deployed by this factory
    /// @return addresses Array of all deployed contract addresses
    function getAllDeployedContracts() external view returns (address[] memory addresses) {
        return deployedContracts;
    }

    /// @notice Return a slice of deployed contract addresses
    /// @param _startIndex Starting index (inclusive)
    /// @param _endIndex Ending index (exclusive)
    /// @return addresses Array of contract addresses in the specified range
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

    /// @notice Return the deployment metadata for a specific contract
    /// @param _contractAddress The address of the deployed contract
    /// @return info The contract information
    function getContractInfo(address _contractAddress) external view returns (ContractInfo memory info) {
        require(isDeployedContract[_contractAddress], "Contract not deployed by factory");
        return contractInfo[_contractAddress];
    }

    /// @notice Return all contracts deployed for a given AVS address
    /// @param _avsAddress The AVS address to filter by
    /// @return addresses Array of contract addresses deployed by the AVS
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

    /// @notice Check whether a contract was deployed by this factory
    /// @param _contractAddress The address to verify
    /// @return deployed True if the contract was deployed by this factory
    function isContractDeployedByFactory(address _contractAddress) external view returns (bool deployed) {
        return isDeployedContract[_contractAddress];
    }
}
