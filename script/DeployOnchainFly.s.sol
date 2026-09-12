// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {BLSSignatureChecker} from "@eigenlayer-middleware/BLSSignatureChecker.sol";
import {ISlashingRegistryCoordinator} from "@eigenlayer-middleware/interfaces/ISlashingRegistryCoordinator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FlyAMM, IFlyPolicyParams} from "../src/examples/onchain-fly/FlyAMM.sol";
import {FlyEngine} from "../src/examples/onchain-fly/FlyEngine.sol";
import {FlyPolicy} from "../src/examples/onchain-fly/FlyPolicy.sol";
import {FlySwapPool, IFlySwapPolicyFills} from "../src/examples/onchain-fly/FlySwapPool.sol";
import {FlySwapPolicy, FlySwapPolicyUnchecked} from "../src/examples/onchain-fly/FlySwapPolicy.sol";
import {FlySwapRasterizer} from "../src/examples/onchain-fly/FlySwapRasterizer.sol";
import {FlyTestToken} from "../src/examples/onchain-fly/FlyTestToken.sol";

/// @title DeployOnchainFlyScript
/// @notice Deploys the fly-connectome AMM stack on top of an ALREADY uploaded graph + warm directory:
///         FlyEngine (unless FLY_ENGINE is set), the pool (test tokens unless BASE_TOKEN/QUOTE_TOKEN are
///         set), and the FlyPolicy consumer, then wires the pool to the policy.
/// @dev The directories come from tools/llm/deploy_sepolia.py --blobs ptr.bin,edges.bin,meta.bin (graph)
///      and --blobs warm.bin (warm); the three config words from artifacts/fly_config.json. Required env:
///        AVS_ADDRESS, SIG_CHECKER_ADDRESS (or REGISTRY_COORDINATOR_ADDRESS to deploy a fresh checker)
///        FLY_GRAPH_ROOT, FLY_WARM_ROOT, FLY_CFG0, FLY_CFG1, FLY_CFG2
///      Optional: FLY_ENGINE, BASE_TOKEN, QUOTE_TOKEN, INITIAL_BASE, INITIAL_QUOTE (seed liquidity),
///      FLY_VARIANT=swap (v2 per-swap intents: FlySwapRasterizer + FlySwapPool + FlySwapPolicy; FLY_RASTERIZER reuses one).
///      The policy constructor runs engine.checkArtifacts over every chunk (~4.4k cold reads on the
///      real graph); on a 30M-gas chain deploy it with FLY_SKIP_CHECK=true and run the check off-chain
///      (tools/fly_anvil.py check) or through verify_onchain_directory.py --engine-kind fly.
contract DeployOnchainFlyScript is Script {
    FlyPolicy public policy;
    FlyAMM public pool;
    FlySwapPolicy public swapPolicy;
    FlySwapPool public swapPool;

    function run() public {
        address avsAddress = vm.envOr("AVS_ADDRESS", address(0));
        address sigChecker = vm.envOr("SIG_CHECKER_ADDRESS", address(0));
        address registryCoordinator = vm.envOr("REGISTRY_COORDINATOR_ADDRESS", address(0));
        address graphRoot = vm.envAddress("FLY_GRAPH_ROOT");
        address warmRoot = vm.envAddress("FLY_WARM_ROOT");
        bytes32[3] memory cfg =
            [bytes32(vm.envUint("FLY_CFG0")), bytes32(vm.envUint("FLY_CFG1")), bytes32(vm.envUint("FLY_CFG2"))];
        require(avsAddress != address(0), "AVS_ADDRESS must be set");

        vm.startBroadcast();

        if (sigChecker == address(0)) {
            require(registryCoordinator != address(0), "Set SIG_CHECKER_ADDRESS or REGISTRY_COORDINATOR_ADDRESS");
            sigChecker = address(new BLSSignatureChecker(ISlashingRegistryCoordinator(registryCoordinator)));
            console.log("Deployed BLSSignatureChecker at:", sigChecker);
        }

        address engineAddr = vm.envOr("FLY_ENGINE", address(0));
        FlyEngine engine = engineAddr == address(0) ? new FlyEngine() : FlyEngine(engineAddr);

        address baseTok = vm.envOr("BASE_TOKEN", address(0));
        address quoteTok = vm.envOr("QUOTE_TOKEN", address(0));
        if (baseTok == address(0)) baseTok = address(new FlyTestToken("Fly Base", "FBASE", 1e27, msg.sender));
        if (quoteTok == address(0)) quoteTok = address(new FlyTestToken("Fly Quote", "FQUOTE", 1e27, msg.sender));

        uint256 seedBase = vm.envOr("INITIAL_BASE", uint256(0));
        uint256 seedQuote = vm.envOr("INITIAL_QUOTE", uint256(0));
        bool swapVariant = keccak256(bytes(vm.envOr("FLY_VARIANT", string("window")))) == keccak256("swap");
        if (swapVariant) {
            address rastAddr = vm.envOr("FLY_RASTERIZER", address(0));
            FlySwapRasterizer rasterizer =
                rastAddr == address(0) ? new FlySwapRasterizer() : FlySwapRasterizer(rastAddr);
            swapPool = new FlySwapPool(IERC20(baseTok), IERC20(quoteTok));
            if (vm.envOr("FLY_SKIP_CHECK", false)) {
                swapPolicy = new FlySwapPolicyUnchecked(
                    avsAddress, sigChecker, engine, rasterizer, graphRoot, warmRoot, cfg, swapPool
                );
            } else {
                swapPolicy =
                    new FlySwapPolicy(avsAddress, sigChecker, engine, rasterizer, graphRoot, warmRoot, cfg, swapPool);
            }
            swapPool.setPolicy(IFlySwapPolicyFills(address(swapPolicy)));
            if (seedBase != 0 && seedQuote != 0) {
                IERC20(baseTok).approve(address(swapPool), seedBase);
                IERC20(quoteTok).approve(address(swapPool), seedQuote);
                swapPool.addLiquidity(seedBase, seedQuote, msg.sender);
            }
            vm.stopBroadcast();
            console.log("FlySwapRasterizer:", address(rasterizer));
            console.log("FlySwapPool:", address(swapPool));
            console.log("FlySwapPolicy:", address(swapPolicy));
            console.log("DEPLOYED_TARGET=%s", address(swapPolicy));
            return;
        }
        pool = new FlyAMM(IERC20(baseTok), IERC20(quoteTok));
        if (vm.envOr("FLY_SKIP_CHECK", false)) {
            policy = new FlyPolicyUnchecked(avsAddress, sigChecker, engine, graphRoot, warmRoot, cfg, pool);
        } else {
            policy = new FlyPolicy(avsAddress, sigChecker, engine, graphRoot, warmRoot, cfg, pool);
        }
        pool.setPolicy(IFlyPolicyParams(address(policy)));
        if (seedBase != 0 && seedQuote != 0) {
            IERC20(baseTok).approve(address(pool), seedBase);
            IERC20(quoteTok).approve(address(pool), seedQuote);
            pool.addLiquidity(seedBase, seedQuote, msg.sender);
        }

        vm.stopBroadcast();

        console.log("FlyEngine:", address(engine));
        console.log("Graph root:", graphRoot);
        console.log("Warm root:", warmRoot);
        console.log("Base token:", baseTok);
        console.log("Quote token:", quoteTok);
        console.log("FlyAMM:", address(pool));
        console.log("FlyPolicy:", address(policy));
        console.log("DEPLOYED_TARGET=%s", address(policy));
    }
}

/// @notice FlyPolicy without the constructor-time artifact check (chains whose block limit cannot hold it)
contract FlyPolicyUnchecked is FlyPolicy {
    constructor(
        address _avsAddress,
        address _blsSigChecker,
        FlyEngine _engine,
        address _graphRoot,
        address _warmRoot,
        bytes32[3] memory _packedConfig,
        FlyAMM _pool
    ) FlyPolicy(_avsAddress, _blsSigChecker, _engine, _graphRoot, _warmRoot, _packedConfig, _pool) {}

    function _validateArtifacts() internal view override {}
}
