// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {ArraySummationFactory} from "../src/examples/array-summation/ArraySummationFactory.sol";

contract DeployArraySummationFactory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying ArraySummationFactory...");
        console.log("Deployer address:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        ArraySummationFactory factory = new ArraySummationFactory();

        vm.stopBroadcast();

        console.log("ArraySummationFactory deployed at:", address(factory));
        console.log("Deployment completed successfully!");

        // Verify the deployment
        console.log("Verifying deployment...");
        console.log("Deployed contract count:", factory.getDeployedContractCount());
        console.log("All deployed contracts length:", factory.getAllDeployedContracts().length);
    }
}
