// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {ArraySummation} from "../src/examples/array-summation/ArraySummation.sol";

/// @title ArraySummationScript
/// @notice Deploys an ArraySummation demo target wired to an EigenLayer ECDSA stake registry.
/// @dev `verifyAndUpdate` calls the registry's ERC-1271 `isValidSignature` to verify the operator
///      quorum. The stake registry (and the rest of the ECDSA stack — delegation manager, AVS
///      directory, service manager) is deployed and initialised by the service's own deploy
///      scripts; this demo script only needs the resulting registry address, passed via
///      `ECDSA_STAKE_REGISTRY_ADDRESS`.
contract ArraySummationScript is Script {
    ArraySummation public arraySummation;

    function setUp() public {}

    function run() public {
        address avsAddress = vm.envOr("AVS_ADDRESS", address(0));
        address ecdsaStakeRegistry = vm.envOr("ECDSA_STAKE_REGISTRY_ADDRESS", address(0));
        uint256 arraySize = vm.envOr("ARRAY_SIZE", uint256(1000));
        uint256 maxValue = vm.envOr("MAX_VALUE", uint256(10000));
        uint256 seed = vm.envOr("ARRAY_SEED", uint256(block.timestamp));

        // The AVS address scopes the target's namespace and must be set explicitly.
        require(avsAddress != address(0), "AVS_ADDRESS must be set");
        // The registry verifies operator signatures; a target wired to address(0) can never
        // pass verifyAndUpdate, so require it up front.
        require(ecdsaStakeRegistry != address(0), "ECDSA_STAKE_REGISTRY_ADDRESS must be set");
        require(ecdsaStakeRegistry.code.length > 0, "ECDSA_STAKE_REGISTRY_ADDRESS has no code");

        vm.startBroadcast();

        arraySummation = new ArraySummation(avsAddress, ecdsaStakeRegistry, arraySize, maxValue, seed);

        vm.stopBroadcast();

        console.log("ArraySummation deployed at:", address(arraySummation));
        console.log("ECDSA stake registry:", ecdsaStakeRegistry);
        console.log("AVS Address:", avsAddress);
        console.log("Array size:", arraySize);
        console.log("Max value:", maxValue);
        console.log("Array initialized with seed:", seed);
        console.log("Actual array length:", arraySummation.getArrayLength());
        // Parseable marker for deploy automation (Helm job -> ConfigMap).
        console.log(string.concat("DEPLOYED_TARGET=", vm.toString(address(arraySummation))));
    }
}
