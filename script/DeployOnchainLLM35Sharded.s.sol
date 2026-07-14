// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {BLSSignatureChecker} from "@eigenlayer-middleware/BLSSignatureChecker.sol";
import {ISlashingRegistryCoordinator} from "@eigenlayer-middleware/interfaces/ISlashingRegistryCoordinator.sol";

import {GasKillerChat35Sharded} from "../src/examples/onchain-llm/GasKillerChat35Sharded.sol";
import {Qwen35SegEngine, Qwen35SegForward} from "../src/examples/onchain-llm/Qwen35SegEngine.sol";

/// @title DeployOnchainLLM35ShardedScript
/// @notice Deploys the SHARDED engine-v3 (Qwen3.5-35B-A3B) stack in OVERLAY mode.
///         Unlike the monolithic `GasKillerChat35`, the sharded settlement consumer
///         (`GasKillerChat35Sharded`) references NO engine, weights, or manifest: its
///         tracked `fulfil()` is a pure commit over `(promptIds, maxNewTokens,
///         answerIds, pipelineRoot)`. Operators split one inference into
///         (positions x layers) segments executed off-chain via
///         `Qwen35SegEngine.forwardRange`/`argmaxRange`, verify the keccak commit chain,
///         then sign the cheap settlement.
/// @dev The seg engine + forward are still deployed here so they exist in the operators'
///      Sepolia fork (their sim mounts the overlay weights on top and STATICCALLs the
///      deployed `Qwen35SegEngine` address), exactly as the monolithic engine/forward
///      are real Sepolia deploys present in the fork. The consumer needs no artifact
///      check at deploy time (nothing to validate — the phantom chunks only exist once
///      an operator mounts them). Prints every value the service shard coordinator needs.
///
///      Required env:
///        AVS_ADDRESS              the AVS service manager (0xdCec8ce0…)
///        SIG_CHECKER_ADDRESS      a real BLSSignatureChecker (0x7568336e…), or set
///        REGISTRY_COORDINATOR_ADDRESS to deploy a fresh checker against it
contract DeployOnchainLLM35ShardedScript is Script {
    GasKillerChat35Sharded public chat;

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

        Qwen35SegForward forward = new Qwen35SegForward();
        Qwen35SegEngine segEngine = new Qwen35SegEngine(forward);
        chat = new GasKillerChat35Sharded(avsAddress, sigChecker);

        vm.stopBroadcast();

        console.log("Qwen35SegForward deployed at:", address(forward));
        console.log("Qwen35SegEngine deployed at:", address(segEngine));
        console.log("BLS signature checker:", sigChecker);
        console.log("AVS Address:", avsAddress);
        console.log("GasKillerChat35Sharded deployed at:", address(chat));
        // Grep-friendly wiring facts for the service shard coordinator.
        console.log("DEPLOYED_TARGET=%s", address(chat));
        console.log("SEG_ENGINE=%s", address(segEngine));
        console.log("SEG_FORWARD=%s", address(forward));
    }
}
