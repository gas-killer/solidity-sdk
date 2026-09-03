// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {SchnorrArraySummation} from "../src/examples/array-summation/SchnorrArraySummation.sol";

/// @title SchnorrArraySummationScript
/// @notice Deploys a SchnorrArraySummation demo target wired to an existing SchnorrStakeRegistry.
/// @dev The aggregate-Schnorr counterpart of `ArraySummationScript`. The two are not
///      interchangeable: a target verifies exactly one scheme's proof, so this one settles only
///      against a fleet running `SIGNATURE_SCHEME=schnorr`, and `ArraySummation` only against a
///      BLS fleet.
///
///      Unlike the BLS script this one never provisions its verifier. A registry is an operator
///      set, not a stateless checker: it is deployed once and every operator registers a
///      secp256k1 key against it with a proof of possession, which is what the service's
///      `setup_schnorr_operators` binary does. Deploying a second registry here would produce a
///      target verifying against an empty operator set.
///
///      Registration order is load-bearing. Every registration advances the registry's
///      `effectiveBlock` watermark and verification fail-closes for reference blocks behind it,
///      so the whole operator set must already be registered when this runs.
contract SchnorrArraySummationScript is Script {
    SchnorrArraySummation public arraySummation;

    function setUp() public {}

    function run() public {
        address avsAddress = vm.envOr("AVS_ADDRESS", address(0));
        address stakeRegistry = vm.envOr("SCHNORR_STAKE_REGISTRY_ADDRESS", address(0));
        uint256 arraySize = vm.envOr("ARRAY_SIZE", uint256(1000));
        uint256 maxValue = vm.envOr("MAX_VALUE", uint256(10000));
        uint256 seed = vm.envOr("ARRAY_SEED", uint256(block.timestamp));

        // The AVS address scopes the target's namespace and must be set explicitly.
        require(avsAddress != address(0), "AVS_ADDRESS must be set");
        require(stakeRegistry != address(0), "SCHNORR_STAKE_REGISTRY_ADDRESS must be set");

        // Reject an address that cannot verify a quorum before it is baked into an immutable
        // target. A target wired to the wrong contract reverts inside verifyAndUpdate, where the
        // cause is far harder to read than it is here.
        _validateRegistry(stakeRegistry);

        vm.startBroadcast();

        arraySummation = new SchnorrArraySummation(avsAddress, stakeRegistry, arraySize, maxValue, seed);

        vm.stopBroadcast();

        console.log("SchnorrArraySummation deployed at:", address(arraySummation));
        console.log("Schnorr stake registry:", stakeRegistry);
        console.log("AVS Address:", avsAddress);
        console.log("Array size:", arraySize);
        console.log("Max value:", maxValue);
        console.log("Array initialized with seed:", seed);
        console.log("Actual array length:", arraySummation.getArrayLength());
        // Parseable marker for deploy automation (Helm job -> ConfigMap).
        console.log(string.concat("DEPLOYED_TARGET=", vm.toString(address(arraySummation))));
    }

    /// @notice Ensure `stakeRegistry` is a real SchnorrStakeRegistry.
    /// @dev Uses a low-level staticcall on `nextPossibleMutationBlock()`, which the registry
    ///      exposes and the BLS-side contracts do not, so passing a BLSSignatureChecker or the
    ///      operator-state retriever by mistake fails here rather than at settlement.
    /// @param stakeRegistry The address the target will verify aggregate signatures against
    function _validateRegistry(address stakeRegistry) internal view {
        require(stakeRegistry.code.length > 0, "SCHNORR_STAKE_REGISTRY_ADDRESS has no code");
        (bool ok, bytes memory ret) = stakeRegistry.staticcall(abi.encodeWithSignature("nextPossibleMutationBlock()"));
        require(
            ok && ret.length >= 32,
            "SCHNORR_STAKE_REGISTRY_ADDRESS is not a SchnorrStakeRegistry (no nextPossibleMutationBlock)"
        );
    }
}
