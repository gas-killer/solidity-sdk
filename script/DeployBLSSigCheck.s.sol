// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {BLSSignatureChecker} from "@eigenlayer-middleware/BLSSignatureChecker.sol";
import {ISlashingRegistryCoordinator} from "@eigenlayer-middleware/interfaces/ISlashingRegistryCoordinator.sol";

contract DeployBLSSigCheck is Script {
    BLSSignatureChecker public blsSigCheck;

    function setUp() public {}

    function run() public {
        address registryCoordinator = vm.envAddress("REGISTRY_COORDINATOR_ADDRESS");

        vm.startBroadcast();

        /// Deploy the BLSSignatureChecker
        blsSigCheck = new BLSSignatureChecker(ISlashingRegistryCoordinator(registryCoordinator));
        console.log("BLSSignatureChecker deployed at:", address(blsSigCheck));

        vm.stopBroadcast();
    }
}
