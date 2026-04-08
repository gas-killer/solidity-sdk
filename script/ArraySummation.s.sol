// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {ArraySummation} from "../src/examples/array-summation/ArraySummation.sol";
import {IGasKillerServiceManager} from "../src/interface/IGasKillerServiceManager.sol";

contract ArraySummationScript is Script {
    ArraySummation public arraySummation;

    function setUp() public {}

    function run() public {
        address avsAddress = vm.envOr("AVS_ADDRESS", address(0x1234));
        address blsSignatureChecker = vm.envOr("SIG_CHECKER_ADDRESS", address(0x5678));
        uint256 arraySize = vm.envOr("ARRAY_SIZE", uint256(1000));
        uint256 maxValue = vm.envOr("MAX_VALUE", uint256(10000));
        uint256 seed = vm.envOr("ARRAY_SEED", uint256(block.timestamp));

        vm.startBroadcast();

        arraySummation = new ArraySummation(avsAddress, blsSignatureChecker, arraySize, maxValue, seed);

        vm.stopBroadcast();

        console.log("ArraySummation deployed at:", address(arraySummation));
        console.log("AVS Address:", avsAddress);
        console.log("Array size:", arraySize);
        console.log("Max value:", maxValue);
        console.log("Array initialized with seed:", seed);
        console.log("Actual array length:", arraySummation.getArrayLength());
    }
}
