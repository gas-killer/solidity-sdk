// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {BLSSignatureChecker} from "@eigenlayer-middleware/BLSSignatureChecker.sol";
import {ISlashingRegistryCoordinator} from "@eigenlayer-middleware/interfaces/ISlashingRegistryCoordinator.sol";

import {DataContractLib} from "../src/examples/onchain-llm/DataContractLib.sol";
import {GasKillerChatSharded} from "../src/examples/onchain-llm/GasKillerChatSharded.sol";
import {Qwen3} from "../src/examples/onchain-llm/Qwen3.sol";
import {Qwen3Engine} from "../src/examples/onchain-llm/Qwen3Engine.sol";
import {Qwen3SegEngine} from "../src/examples/onchain-llm/Qwen3SegEngine.sol";
import {SyntheticQwen} from "../src/examples/onchain-llm/SyntheticQwen.sol";

/// @title DeployOnchainLLMShardedScript
/// @notice Deploys the SHARDED-inference e2e stack for the synthetic engine-v2
///         fixture model: weight/tokenizer chunks + two-level directory (the exact
///         layout OnchainChat.t.sol builds), Qwen3Engine, Qwen3SegEngine, and the
///         GasKillerChatSharded settlement consumer. Prints every value the service
///         shard coordinator needs (addresses + unpacked model config) as
///         grep-friendly KEY=value lines.
/// @dev Required env: AVS_ADDRESS, and SIG_CHECKER_ADDRESS (or
///      REGISTRY_COORDINATOR_ADDRESS to deploy a fresh checker).
contract DeployOnchainLLMShardedScript is Script {
    function run() public {
        address avsAddress = vm.envOr("AVS_ADDRESS", address(0));
        address sigChecker = vm.envOr("SIG_CHECKER_ADDRESS", address(0));
        address registryCoordinator = vm.envOr("REGISTRY_COORDINATOR_ADDRESS", address(0));
        require(avsAddress != address(0), "AVS_ADDRESS must be set");

        string memory root = vm.projectRoot();
        bytes memory weightsBlob = vm.readFileBinary(string.concat(root, "/test/fixtures/onchain-llm-v2/weights.bin"));
        bytes memory tokBlob = vm.readFileBinary(string.concat(root, "/test/fixtures/onchain-llm-v2/tokenizer.bin"));

        vm.startBroadcast();

        if (sigChecker == address(0)) {
            require(registryCoordinator != address(0), "Set SIG_CHECKER_ADDRESS or REGISTRY_COORDINATOR_ADDRESS");
            sigChecker = address(new BLSSignatureChecker(ISlashingRegistryCoordinator(registryCoordinator)));
            console.log("Deployed BLSSignatureChecker at:", sigChecker);
        }

        // Chunk both blobs and build the two-level directory: root -> page -> chunks
        // (identical layout to the OnchainChat.t.sol fixture setup).
        bytes memory pageBytes;
        for (uint256 at = 0; at < weightsBlob.length; at += Qwen3.CHUNK) {
            uint256 len = weightsBlob.length - at;
            if (len > Qwen3.CHUNK) len = Qwen3.CHUNK;
            pageBytes = abi.encodePacked(pageBytes, DataContractLib.write(_slice(weightsBlob, at, len)));
        }
        for (uint256 at = 0; at < tokBlob.length; at += Qwen3.CHUNK) {
            uint256 len = tokBlob.length - at;
            if (len > Qwen3.CHUNK) len = Qwen3.CHUNK;
            pageBytes = abi.encodePacked(pageBytes, DataContractLib.write(_slice(tokBlob, at, len)));
        }
        address page = DataContractLib.write(pageBytes);
        address dirRoot = DataContractLib.write(abi.encodePacked(page));

        Qwen3Engine engine = new Qwen3Engine();
        Qwen3SegEngine segEngine = new Qwen3SegEngine();
        GasKillerChatSharded chat = new GasKillerChatSharded(avsAddress, sigChecker);

        vm.stopBroadcast();

        bytes32[3] memory cfgWords = SyntheticQwen.packedConfig();
        Qwen3.Config memory c = Qwen3.unpack(cfgWords);

        // Grep-friendly wiring facts for the service harness / shard coordinator.
        console.log("DEPLOYED_TARGET=%s", address(chat));
        console.log("SEG_ENGINE=%s", address(segEngine));
        console.log("ENGINE=%s", address(engine));
        console.log("WEIGHTS_ROOT=%s", dirRoot);
        console.log(string.concat("PACKED_CFG_0=", vm.toString(cfgWords[0])));
        console.log(string.concat("PACKED_CFG_1=", vm.toString(cfgWords[1])));
        console.log(string.concat("PACKED_CFG_2=", vm.toString(cfgWords[2])));
        console.log("N_LAYERS=%s", c.nLayers);
        console.log("KVD=%s", c.nKv * c.headDim);
        console.log("DIM=%s", c.dim);
        console.log("VOCAB=%s", c.vocab);
        console.log("STOP0=%s", c.stop0);
        console.log("STOP1=%s", c.stop1);
        console.log("SEQ_CAP=%s", c.seqCap);
    }

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            out[i] = data[start + i];
        }
    }
}
