// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {BLSSignatureChecker} from "@eigenlayer-middleware/BLSSignatureChecker.sol";
import {ISlashingRegistryCoordinator} from "@eigenlayer-middleware/interfaces/ISlashingRegistryCoordinator.sol";

import {DataContractLib} from "../src/examples/onchain-llm/DataContractLib.sol";
import {GasKillerLLM} from "../src/examples/onchain-llm/GasKillerLLM.sol";
import {LlamaEngine} from "../src/examples/onchain-llm/LlamaEngine.sol";
import {Stories260K} from "../src/examples/onchain-llm/Stories260K.sol";

/// @title DeployOnchainLLMScript
/// @notice Deploys the on-chain LLM: the stories260K weight chunks and tokenizer as data
///         contracts, the directory pointing at them, and the GasKillerLLM consumer.
/// @dev Weights are read from test/fixtures/onchain-llm/ (regenerate with
///      src/examples/onchain-llm/tools/convert.py). Deployment is ~25 transactions;
///      each weight chunk is just under the EIP-170 limit. Required env:
///        AVS_ADDRESS            the AVS service manager
///        SIG_CHECKER_ADDRESS    a real BLSSignatureChecker (or set
///        REGISTRY_COORDINATOR_ADDRESS to deploy a fresh checker against it)
contract DeployOnchainLLMScript is Script {
    /// @dev Wrapper so the script (not the library) is the CREATE caller during broadcast
    GasKillerLLM public llm;

    function run() public {
        address avsAddress = vm.envOr("AVS_ADDRESS", address(0));
        address sigChecker = vm.envOr("SIG_CHECKER_ADDRESS", address(0));
        address registryCoordinator = vm.envOr("REGISTRY_COORDINATOR_ADDRESS", address(0));
        require(avsAddress != address(0), "AVS_ADDRESS must be set");

        string memory root = vm.projectRoot();
        bytes memory weightsBlob = vm.parseBytes(
            string.concat("0x", vm.readFile(string.concat(root, "/test/fixtures/onchain-llm/weights.hex")))
        );
        bytes memory tokBlob = vm.parseBytes(
            string.concat("0x", vm.readFile(string.concat(root, "/test/fixtures/onchain-llm/tokenizer.hex")))
        );

        vm.startBroadcast();

        if (sigChecker == address(0)) {
            require(registryCoordinator != address(0), "Set SIG_CHECKER_ADDRESS or REGISTRY_COORDINATOR_ADDRESS");
            sigChecker = address(new BLSSignatureChecker(ISlashingRegistryCoordinator(registryCoordinator)));
            console.log("Deployed BLSSignatureChecker at:", sigChecker);
        }

        // tokenizer + weight chunks + directory
        address tokPtr = DataContractLib.write(tokBlob);
        uint256 nChunks = (weightsBlob.length + DataContractLib.MAX_PAYLOAD - 1) / DataContractLib.MAX_PAYLOAD;
        bytes memory dir = abi.encodePacked(tokPtr);
        for (uint256 i = 0; i < nChunks; ++i) {
            uint256 start = i * DataContractLib.MAX_PAYLOAD;
            uint256 len = weightsBlob.length - start;
            if (len > DataContractLib.MAX_PAYLOAD) len = DataContractLib.MAX_PAYLOAD;
            address chunk = DataContractLib.write(_slice(weightsBlob, start, len));
            dir = abi.encodePacked(dir, chunk);
        }
        address dirPtr = DataContractLib.write(dir);

        LlamaEngine llamaEngine = new LlamaEngine();
        llm = new GasKillerLLM(avsAddress, sigChecker, llamaEngine, dirPtr, Stories260K.packedConfig());

        vm.stopBroadcast();

        console.log("LlamaEngine deployed at:", address(llamaEngine));
        console.log("Tokenizer data contract:", tokPtr);
        console.log("Weight chunks deployed:", nChunks);
        console.log("Weights directory:", dirPtr);
        console.log("BLS signature checker:", sigChecker);
        console.log("AVS Address:", avsAddress);
        console.log("GasKillerLLM deployed at:", address(llm));
        console.log("DEPLOYED_TARGET=%s", address(llm));
    }

    /// @notice Copy `len` bytes of `data` starting at `start` into a fresh array
    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        assembly ("memory-safe") {
            let src := add(add(data, 0x20), start)
            let dst := add(out, 0x20)
            for { let i := 0 } lt(i, len) { i := add(i, 0x20) } { mstore(add(dst, i), mload(add(src, i))) }
        }
    }
}
