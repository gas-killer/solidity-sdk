// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";

import {GasKillerServiceManagerWrapper} from "../src/GasKillerServiceManagerWrapper.sol";

// forge script script/DeployGasKillerServiceManagerWrapper.s.sol \
//   --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
//
// Required env vars:
//   PRIVATE_KEY            - deployer private key
//   AVS_SERVICE_MANAGER    - address of the underlying ServiceManager to wrap
//   AVS_DEPLOYMENT_PATH    - path to avs_deploy.json (written with wrapper address)

contract DeployGasKillerServiceManagerWrapper is Script {
    function run() external {
        address serviceManager = vm.envAddress("AVS_SERVICE_MANAGER");
        string memory outputPath = vm.envString("AVS_DEPLOYMENT_PATH");

        console.log("Underlying ServiceManager:         ", serviceManager);

        vm.startBroadcast();

        GasKillerServiceManagerWrapper wrapper = new GasKillerServiceManagerWrapper(serviceManager);

        vm.stopBroadcast();

        console.log("GasKillerServiceManagerWrapper:    ", address(wrapper));

        vm.writeJson(vm.toString(address(wrapper)), outputPath, ".addresses.gasKillerServiceManagerWrapper");

        console.log("Updated avs_deploy.json with gasKillerServiceManagerWrapper");
    }
}
