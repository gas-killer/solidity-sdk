// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {BLSSignatureChecker} from "@eigenlayer-middleware/BLSSignatureChecker.sol";
import {ISlashingRegistryCoordinator} from "@eigenlayer-middleware/interfaces/ISlashingRegistryCoordinator.sol";

import {GasKillerChatSharded} from "../src/examples/onchain-llm/GasKillerChatSharded.sol";
import {Qwen3SegEngine} from "../src/examples/onchain-llm/Qwen3SegEngine.sol";

/// @title DeployOnchainLLMShardedOverlayScript
/// @notice Deploys the sharded engine-v2 (Qwen3-0.6B) stack in OVERLAY mode — the
///         real 597MB model never touches on-chain storage (contrast with
///         DeployOnchainLLMSharded.s.sol, which uploads the synthetic CI fixture's
///         blobs). The settlement consumer (`GasKillerChatSharded`) is a pure
///         commit: operators execute `Qwen3SegEngine.forwardRange`/`argmaxRange`
///         segments off-chain against their own overlay-mounted simulation, verify
///         the keccak commit chain, and sign the cheap `fulfil()`.
/// @dev Built for the fresh multi-operator env: pass REGISTRY_COORDINATOR_ADDRESS
///      from the fresh AVS deploy (avs_deploy.json) to get a checker wired to the
///      new operator registry, and AVS_ADDRESS = the fresh service manager.
///
///      Required env:
///        AVS_ADDRESS                    the fresh AVS service manager
///        SIG_CHECKER_ADDRESS            existing BLSSignatureChecker, or set
///        REGISTRY_COORDINATOR_ADDRESS   to deploy a fresh checker against it
contract DeployOnchainLLMShardedOverlayScript is Script {
    GasKillerChatSharded public chat;

    function run() public {
        address avsAddress = vm.envOr("AVS_ADDRESS", address(0));
        address sigChecker = vm.envOr("SIG_CHECKER_ADDRESS", address(0));
        address registryCoordinator = vm.envOr("REGISTRY_COORDINATOR_ADDRESS", address(0));
        require(avsAddress != address(0), "AVS_ADDRESS must be set");

        vm.startBroadcast();

        if (sigChecker == address(0)) {
            require(registryCoordinator != address(0), "Set SIG_CHECKER_ADDRESS or REGISTRY_COORDINATOR_ADDRESS");
            sigChecker = address(new BLSSignatureChecker(ISlashingRegistryCoordinator(registryCoordinator)));
            console.log("Deployed BLSSignatureChecker at:", sigChecker);
        }

        Qwen3SegEngine segEngine = new Qwen3SegEngine();
        chat = new GasKillerChatSharded(avsAddress, sigChecker);

        vm.stopBroadcast();

        console.log("Qwen3SegEngine deployed at:", address(segEngine));
        console.log("BLS signature checker:", sigChecker);
        console.log("AVS Address:", avsAddress);
        console.log("GasKillerChatSharded deployed at:", address(chat));
        // Grep-friendly wiring facts for the shard coordinator request.
        console.log("DEPLOYED_TARGET=%s", address(chat));
        console.log("SEG_ENGINE=%s", address(segEngine));
    }
}
