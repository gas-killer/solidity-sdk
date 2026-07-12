// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {BLSSignatureChecker} from "@eigenlayer-middleware/BLSSignatureChecker.sol";
import {ISlashingRegistryCoordinator} from "@eigenlayer-middleware/interfaces/ISlashingRegistryCoordinator.sol";

import {GasKillerChat35} from "../src/examples/onchain-llm/GasKillerChat35.sol";
import {Qwen35Engine} from "../src/examples/onchain-llm/Qwen35Engine.sol";
import {Qwen35Forward} from "../src/examples/onchain-llm/Qwen35Forward.sol";

/// @title DeployOnchainLLM35Script
/// @notice Deploys the engine-v3 on-chain LLM consumer in OVERLAY mode: Qwen3.5-35B-A3B
///         (~35GB int8) never touches on-chain storage. The deploy chain is
///         `Qwen35Forward` (the forward-pass contract, too large to inline into the
///         engine — see Qwen35Forward.sol) -> `Qwen35Engine` (wraps it with directory
///         resolution + token decoding) -> `GasKillerChat35` (the Gas Killer consumer,
///         constructed with `weightsRoot = address(0)` and `weightsManifest` set to the
///         converter's manifest hash).
/// @dev Overlay mode has NO on-chain artifacts to validate at deploy time: the phantom
///      weight chunks only exist once an operator mounts them via `anvil_setCode` /
///      `stateOverrides` in their own simulation environment (UNBOUNDED_V2_OVERLAYS.md).
///      `GasKillerChat35`'s constructor already encodes this — it only calls
///      `engine.checkArtifacts` when `_weightsRoot != address(0)` — so this script does
///      not attempt any on-chain artifact check; it just needs to pass `address(0)` as
///      the root, exactly like the v2 script's overlay path (see
///      test/examples/OnchainChat.t.sol's `bytes32(0)`-manifest/`address(0)`-root
///      construction and script/e2e_operator_replay.sh, which runs `checkArtifacts` as
///      a separate operator step AFTER mounting, never at deploy time).
///
///      Required env:
///        AVS_ADDRESS              the AVS service manager
///        SIG_CHECKER_ADDRESS      a real BLSSignatureChecker (or set
///        REGISTRY_COORDINATOR_ADDRESS to deploy a fresh checker against it)
///        QWEN35_MANIFEST          bytes32 manifest hash from tools/convert_qwen35.py's
///                                 manifest.json ("manifest" field)
///      Optional env (packed config words; default to the placeholders below, which
///      MUST be replaced with tools/convert_qwen35.py's vectors.json output for a real
///      deployment):
///        QWEN35_CFG0, QWEN35_CFG1, QWEN35_CFG2, QWEN35_CFG3
contract DeployOnchainLLM35Script is Script {
    /// @dev Wrapper so the script (not the library) is the CREATE caller during broadcast
    GasKillerChat35 public chat;

    /// ================================================================================
    /// FILLED BY CONVERTER: placeholder packed-config words. These are the SyntheticQwen
    /// test-fixture words reshaped to the v3 bytes32[4] layout purely so this script
    /// deploys and decodes cleanly against a config-shaped consumer during dry runs
    /// (`forge build` / anvil rehearsal). They do NOT describe the real 35B-A3B model.
    /// Once tools/convert_qwen35.py has run against the real weights, set QWEN35_CFG0..3
    /// (and QWEN35_MANIFEST) from its vectors.json / manifest.json output — do not ship
    /// a deployment relying on these constants.
    /// ================================================================================
    bytes32 internal constant PLACEHOLDER_CFG0 =
        bytes32(uint256(0x30006002040200100000010000400101000000000000000000000000000000));
    bytes32 internal constant PLACEHOLDER_CFG1 =
        bytes32(uint256(0x10c6f7a10000000040000000000000000000faa90000000000000000));
    bytes32 internal constant PLACEHOLDER_CFG2 =
        bytes32(uint256(0x50d00000000000000000000000000000000000000000000000000000000));
    bytes32 internal constant PLACEHOLDER_CFG3 = bytes32(0);

    function run() public {
        address avsAddress = vm.envOr("AVS_ADDRESS", address(0));
        address sigChecker = vm.envOr("SIG_CHECKER_ADDRESS", address(0));
        address registryCoordinator = vm.envOr("REGISTRY_COORDINATOR_ADDRESS", address(0));
        require(avsAddress != address(0), "AVS_ADDRESS must be set");

        bytes32 manifest = vm.envBytes32("QWEN35_MANIFEST");
        require(manifest != bytes32(0), "QWEN35_MANIFEST must be set");

        bytes32[4] memory packedConfig = [
            vm.envOr("QWEN35_CFG0", PLACEHOLDER_CFG0),
            vm.envOr("QWEN35_CFG1", PLACEHOLDER_CFG1),
            vm.envOr("QWEN35_CFG2", PLACEHOLDER_CFG2),
            vm.envOr("QWEN35_CFG3", PLACEHOLDER_CFG3)
        ];

        vm.startBroadcast();

        if (sigChecker == address(0)) {
            require(registryCoordinator != address(0), "Set SIG_CHECKER_ADDRESS or REGISTRY_COORDINATOR_ADDRESS");
            sigChecker = address(new BLSSignatureChecker(ISlashingRegistryCoordinator(registryCoordinator)));
            console.log("Deployed BLSSignatureChecker at:", sigChecker);
        }

        Qwen35Forward forward = new Qwen35Forward();
        Qwen35Engine engine = new Qwen35Engine(forward);

        // Overlay mode: rootDirectory = address(0). The engine never touches on-chain
        // artifacts here — GasKillerChat35's constructor only calls
        // engine.checkArtifacts(...) when the root directory is non-zero, so no
        // deploy-time call can reach the (not-yet-mounted) phantom chunks.
        chat = new GasKillerChat35(avsAddress, sigChecker, engine, address(0), manifest, packedConfig);

        vm.stopBroadcast();

        console.log("Qwen35Forward deployed at:", address(forward));
        console.log("Qwen35Engine deployed at:", address(engine));
        console.log("BLS signature checker:", sigChecker);
        console.log("AVS Address:", avsAddress);
        console.log("Overlay manifest:", vm.toString(manifest));
        console.log("GasKillerChat35 deployed at:", address(chat));
        console.log("DEPLOYED_TARGET=%s", address(chat));
    }
}
