// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {ArraySummation} from "../src/examples/array-summation/ArraySummation.sol";
import {BLSSignatureChecker} from "@eigenlayer-middleware/BLSSignatureChecker.sol";
import {ISlashingRegistryCoordinator} from "@eigenlayer-middleware/interfaces/ISlashingRegistryCoordinator.sol";

/// @title ArraySummationScript
/// @notice Deploys an ArraySummation demo target wired to a REAL BLSSignatureChecker.
/// @dev `verifyAndUpdate` calls `checkSignatures` on the target's configured signature checker.
///      That checker must NOT be the `BLSSigCheckOperatorStateRetriever` (the router's off-chain
///      helper, recorded as `blsSigCheck` in avs_deploy.json) — that contract has no
///      `checkSignatures`, so a target wired to it reverts with empty `0x` during verifyAndUpdate.
///      To make the demo target correct-by-construction:
///        - if `SIG_CHECKER_ADDRESS` is unset, a fresh `BLSSignatureChecker` is deployed against
///          `REGISTRY_COORDINATOR_ADDRESS`;
///        - any provided checker is validated to expose `registryCoordinator()` (which the
///          retriever does not) and, when `REGISTRY_COORDINATOR_ADDRESS` is set, to match it.
contract ArraySummationScript is Script {
    ArraySummation public arraySummation;

    function setUp() public {}

    function run() public {
        address avsAddress = vm.envOr("AVS_ADDRESS", address(0x1234));
        address sigChecker = vm.envOr("SIG_CHECKER_ADDRESS", address(0));
        address registryCoordinator = vm.envOr("REGISTRY_COORDINATOR_ADDRESS", address(0));
        uint256 arraySize = vm.envOr("ARRAY_SIZE", uint256(1000));
        uint256 maxValue = vm.envOr("MAX_VALUE", uint256(10000));
        uint256 seed = vm.envOr("ARRAY_SEED", uint256(block.timestamp));

        vm.startBroadcast();

        // When no checker is provided, deploy one bound to the registry coordinator so the
        // target is correct-by-construction rather than relying on a passed-in address.
        if (sigChecker == address(0)) {
            require(registryCoordinator != address(0), "Set SIG_CHECKER_ADDRESS or REGISTRY_COORDINATOR_ADDRESS");
            sigChecker = address(new BLSSignatureChecker(ISlashingRegistryCoordinator(registryCoordinator)));
            console.log("Deployed BLSSignatureChecker at:", sigChecker);
        }

        // Reject a checker that cannot actually verify signatures (e.g. the
        // BLSSigCheckOperatorStateRetriever, which has no registryCoordinator()/checkSignatures).
        _validateChecker(sigChecker, registryCoordinator);

        arraySummation = new ArraySummation(avsAddress, sigChecker, arraySize, maxValue, seed);

        vm.stopBroadcast();

        console.log("ArraySummation deployed at:", address(arraySummation));
        console.log("BLS signature checker:", sigChecker);
        console.log("AVS Address:", avsAddress);
        console.log("Array size:", arraySize);
        console.log("Max value:", maxValue);
        console.log("Array initialized with seed:", seed);
        console.log("Actual array length:", arraySummation.getArrayLength());
        // Parseable marker for deploy automation (Helm job -> ConfigMap).
        console.log(string.concat("DEPLOYED_TARGET=", vm.toString(address(arraySummation))));
    }

    /// @notice Ensure `sigChecker` is a real BLSSignatureChecker, not the operator-state retriever.
    /// @dev Uses a low-level staticcall so the check is independent of the getter's return type.
    /// @param sigChecker The address the target will call `checkSignatures` on
    /// @param registryCoordinator Expected registry coordinator; skipped when address(0)
    function _validateChecker(address sigChecker, address registryCoordinator) internal view {
        require(sigChecker.code.length > 0, "SIG_CHECKER_ADDRESS has no code");
        (bool ok, bytes memory ret) = sigChecker.staticcall(abi.encodeWithSignature("registryCoordinator()"));
        require(
            ok && ret.length >= 32,
            "SIG_CHECKER_ADDRESS is not a BLSSignatureChecker (no registryCoordinator) - did you pass the blsSigCheck retriever?"
        );
        if (registryCoordinator != address(0)) {
            require(
                abi.decode(ret, (address)) == registryCoordinator, "checker not wired to REGISTRY_COORDINATOR_ADDRESS"
            );
        }
    }
}
