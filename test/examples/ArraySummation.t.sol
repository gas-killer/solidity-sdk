// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {ArraySummation} from "../../src/examples/array-summation/ArraySummation.sol";

contract ArraySummationTest is Test {
    ArraySummation public arraySummation;
    address public avsAddress = address(0x1234);
    address public blsSignatureChecker = address(0x5678);
    uint256 public arraySize = 1000;
    uint256 public maxValue = 10000;
    uint256 public seed = 0;

    event SumCalculated(uint256 newSum, uint256 timestamp);
    event ArrayInitialized(uint256 size);

    function setUp() public {
        arraySummation = new ArraySummation(avsAddress, blsSignatureChecker, arraySize, maxValue, seed);
    }

    function testInitialization() public view {
        assertEq(arraySummation.getArrayLength(), arraySize);
        assertEq(arraySummation.arraySize(), arraySize);
        assertEq(arraySummation.maxValue(), maxValue);
        assertEq(arraySummation.currentSum(), 0);
    }

    function testArrayElementsInRange() public view {
        uint256[] memory array = arraySummation.getFullArray();
        for (uint256 i = 0; i < array.length; i++) {
            assertTrue(array[i] < maxValue, "Element should be less than 'maxValue'");
        }
    }

    function testGetArrayElement() public view {
        uint256 firstElement = arraySummation.getArrayElement(0);
        assertTrue(firstElement < maxValue);

        uint256 lastElement = arraySummation.getArrayElement(arraySize - 1);
        assertTrue(lastElement < maxValue);
    }

    function testGetArrayElementOutOfBounds() public {
        vm.expectRevert("Index out of bounds");
        arraySummation.getArrayElement(arraySize);
    }

    function testSumAll() public {
        uint256 stateCountBefore = arraySummation.stateTransitionCount();

        uint256[] memory emptyIndexes = new uint256[](0);
        arraySummation.sum(emptyIndexes);

        uint256 stateCountAfter = arraySummation.stateTransitionCount();
        assertEq(stateCountAfter, stateCountBefore + 1, "State transition count should increment");

        uint256 sum = arraySummation.currentSum();
        assertTrue(sum > 0, "Sum should be greater than 0");

        uint256[] memory array = arraySummation.getFullArray();
        uint256 expectedSum = 0;
        for (uint256 i = 0; i < array.length; i++) {
            expectedSum += array[i];
        }
        assertEq(sum, expectedSum, "Sum should match expected calculation");
    }

    function testMultipleSumCalls() public {
        uint256[] memory emptyIndexes = new uint256[](0);
        arraySummation.sum(emptyIndexes);
        uint256 firstSum = arraySummation.currentSum();

        arraySummation.sum(emptyIndexes);
        uint256 secondSum = arraySummation.currentSum();

        assertEq(firstSum, secondSum, "Sum should be consistent for same array");
    }

    function testSetArrayElement() public {
        uint256 stateCountBefore = arraySummation.stateTransitionCount();
        uint256 oldValue = arraySummation.getArrayElement(0);
        uint256 newValue = maxValue - 1;

        arraySummation.setArrayElement(0, newValue);

        uint256 stateCountAfter = arraySummation.stateTransitionCount();
        assertEq(stateCountAfter, stateCountBefore + 1, "State transition count should increment");
        assertEq(arraySummation.getArrayElement(0), newValue);
        assertTrue(arraySummation.getArrayElement(0) != oldValue);
    }

    function testSetArrayElementOutOfBounds() public {
        vm.expectRevert("Index out of bounds");
        arraySummation.setArrayElement(arraySize, maxValue - 1);
    }

    function testSumAfterUpdate() public {
        uint256[] memory emptyIndexes = new uint256[](0);
        arraySummation.sum(emptyIndexes);
        uint256 originalSum = arraySummation.currentSum();

        uint256 index = arraySize / 2;
        uint256 oldValue = arraySummation.getArrayElement(index);
        uint256 newValue = oldValue == maxValue ? 0 : oldValue + 1;

        arraySummation.setArrayElement(index, newValue);
        arraySummation.sum(emptyIndexes);
        uint256 newSum = arraySummation.currentSum();

        assertEq(newSum, originalSum + (newValue - oldValue), "Sum should increase by the difference");
    }

    function testResetArray() public {
        uint256 stateCountBefore = arraySummation.stateTransitionCount();

        uint256[] memory emptyIndexes = new uint256[](0);
        arraySummation.sum(emptyIndexes);
        uint256 originalSum = arraySummation.currentSum();

        uint256 newSeed = 67890;
        vm.expectEmit(true, false, false, false);
        emit ArrayInitialized(1000);

        arraySummation.resetArray(newSeed);

        uint256 stateCountAfter = arraySummation.stateTransitionCount();
        assertEq(stateCountAfter, stateCountBefore + 2, "State count should increment by 2 (sum + reset)");

        assertEq(arraySummation.getArrayLength(), 1000, "Array should still have 1000 elements");

        arraySummation.sum(emptyIndexes);
        uint256 newSum = arraySummation.currentSum();
        assertTrue(newSum != originalSum, "Sum should be different after reset with different seed");
    }

    function testStateTransitionTracking() public {
        uint256 initialCount = arraySummation.stateTransitionCount();

        uint256[] memory emptyIndexes = new uint256[](0);
        arraySummation.sum(emptyIndexes);
        assertEq(arraySummation.stateTransitionCount(), initialCount + 1);

        arraySummation.setArrayElement(0, 100);
        assertEq(arraySummation.stateTransitionCount(), initialCount + 2);

        arraySummation.resetArray(999);
        assertEq(arraySummation.stateTransitionCount(), initialCount + 3);
    }

    function testGasKillerInheritance() public view {
        assertEq(arraySummation.QUORUM_THRESHOLD(), 66);
        assertEq(arraySummation.blockStaleMeasure(), 300);
        assertEq(arraySummation.THRESHOLD_DENOMINATOR(), 100);
        assertTrue(address(arraySummation.blsSignatureChecker()) != address(0));
        assertEq(arraySummation.avsAddress(), avsAddress);

        // Test that the verifyAndUpdate function is properly inherited from GasKillerSDK
        bytes4 selector = arraySummation.verifyAndUpdate.selector;
        assertTrue(selector != bytes4(0), "verifyAndUpdate selector should exist");
    }

    function testFuzzUpdateAndSum(uint256 index, uint256 value) public {
        index = bound(index, 0, 999);
        value = bound(value, 0, 9999);

        uint256[] memory emptyIndexes = new uint256[](0);
        arraySummation.sum(emptyIndexes);
        uint256 originalSum = arraySummation.currentSum();
        uint256 oldValue = arraySummation.getArrayElement(index);

        arraySummation.setArrayElement(index, value);
        arraySummation.sum(emptyIndexes);
        uint256 newSum = arraySummation.currentSum();

        if (value > oldValue) {
            assertEq(newSum, originalSum + (value - oldValue));
        } else {
            assertEq(newSum, originalSum - (oldValue - value));
        }
    }

    function testDeterministicInitialization() public {
        ArraySummation array1 = new ArraySummation(avsAddress, blsSignatureChecker, arraySize, maxValue, 42);
        ArraySummation array2 = new ArraySummation(avsAddress, blsSignatureChecker, arraySize, maxValue, 42);

        uint256[] memory arr1 = array1.getFullArray();
        uint256[] memory arr2 = array2.getFullArray();

        for (uint256 i = 0; i < 10; i++) {
            assertEq(arr1[i], arr2[i], "Same seed should produce same array");
        }
    }

    function testInvalidConfigurationArraySize() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidConfiguration()"));
        new ArraySummation(avsAddress, blsSignatureChecker, 0, maxValue, seed);
    }

    function testInvalidConfigurationMaxValue() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidConfiguration()"));
        new ArraySummation(avsAddress, blsSignatureChecker, arraySize, 0, seed);
    }

    function testSumSubset() public {
        // Test summing a specific subset of indexes
        uint256[] memory indexes = new uint256[](3);
        indexes[0] = 0;
        indexes[1] = 10;
        indexes[2] = 100;

        arraySummation.sum(indexes);
        uint256 subsetSum = arraySummation.currentSum();

        // Calculate expected sum manually
        uint256 expectedSum = arraySummation.getArrayElement(0) + arraySummation.getArrayElement(10)
            + arraySummation.getArrayElement(100);

        assertEq(subsetSum, expectedSum, "Subset sum should match expected");
    }

    function testSumSubsetOutOfBounds() public {
        uint256[] memory indexes = new uint256[](2);
        indexes[0] = 0;
        indexes[1] = 1000; // Out of bounds

        vm.expectRevert("Index out of bounds");
        arraySummation.sum(indexes);
    }

    function testSumLargeSubset() public {
        // Test summing first 100 elements
        uint256[] memory indexes = new uint256[](100);
        uint256 expectedSum = 0;

        for (uint256 i = 0; i < 100; i++) {
            indexes[i] = i;
            expectedSum += arraySummation.getArrayElement(i);
        }

        arraySummation.sum(indexes);
        assertEq(arraySummation.currentSum(), expectedSum, "Large subset sum should match");
    }

    function testSumEmptyVsFullArray() public {
        // Sum with empty indexes (should sum all)
        uint256[] memory emptyIndexes = new uint256[](0);
        arraySummation.sum(emptyIndexes);
        uint256 allSum = arraySummation.currentSum();

        // Calculate expected full sum
        uint256[] memory fullArray = arraySummation.getFullArray();
        uint256 expectedFullSum = 0;
        for (uint256 i = 0; i < fullArray.length; i++) {
            expectedFullSum += fullArray[i];
        }

        assertEq(allSum, expectedFullSum, "Empty indexes should sum all elements");
    }
}
