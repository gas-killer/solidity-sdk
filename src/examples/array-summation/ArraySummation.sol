// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {GasKillerSDK} from "../../GasKillerSDK.sol";

contract ArraySummation is GasKillerSDK {
    error InvalidConfiguration();

    event SumCalculated(uint256 newSum, uint256 timestamp);
    event ArrayInitialized(uint256 size);

    uint256 public immutable arraySize;
    uint256 public immutable maxValue;
    uint256 public currentSum;
    uint256[] public values;

    constructor(address _avsAddress, address _blsSigChecker, uint256 _arraySize, uint256 _maxValue, uint256 _seed) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);

        if (_arraySize == 0 || _maxValue == 0) {
            revert InvalidConfiguration();
        }

        arraySize = _arraySize;
        maxValue = _maxValue;

        _initializeArray(_seed);
    }

    function _initializeArray(uint256 _seed) private {
        if (_seed == 0) {
            _seed = block.timestamp;
        }

        uint256 hashedSeed = uint256(keccak256(abi.encode(_seed)));
        for (uint256 i = 0; i < arraySize; i++) {
            values.push(uint256(keccak256(abi.encode(hashedSeed, i))) % maxValue);
        }

        emit ArrayInitialized(arraySize);
    }

    /**
     * @notice Calculate sum of specified array elements
     * @dev Uses trackState modifier to track state transitions
     * @param indexes Array of indexes to sum (if empty, sums all elements)
     */
    function sum(uint256[] calldata indexes) public trackState {
        _calculateSum(indexes);
    }

    /**
     * @notice Internal function to calculate and store the sum
     * @param indexes Array of indexes to sum (if empty, sums all elements)
     */
    function _calculateSum(uint256[] calldata indexes) internal {
        uint256 total = 0;

        if (indexes.length == 0) {
            // If no indexes provided, sum all elements
            for (uint256 i = 0; i < values.length; i++) {
                total += values[i];
            }
        } else {
            // Sum only specified indexes
            for (uint256 i = 0; i < indexes.length; i++) {
                require(indexes[i] < values.length, "Index out of bounds");
                total += values[indexes[i]];
            }
        }

        currentSum = total;
        emit SumCalculated(total, block.timestamp);
    }

    function getArrayElement(uint256 index) public view returns (uint256) {
        require(index < values.length, "Index out of bounds");
        return values[index];
    }

    function getArrayLength() public view returns (uint256) {
        return values.length;
    }

    function getFullArray() public view returns (uint256[] memory) {
        return values;
    }

    function setArrayElement(uint256 index, uint256 newValue) public trackState {
        require(index < values.length, "Index out of bounds");
        values[index] = newValue;
    }

    function resetArray(uint256 _seed) public trackState {
        delete values;
        _initializeArray(_seed);
    }
}
