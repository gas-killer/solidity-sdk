// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {SchnorrStakeRegistry} from "../src/schnorr/SchnorrStakeRegistry.sol";
import {SchnorrCommitmentsAdapter} from "../src/commitments/SchnorrCommitmentsAdapter.sol";
import {GasKillerSP1Arbiter} from "../src/commitments/GasKillerSP1Arbiter.sol";

/// Gas Killer x Commitments deploy legs. The full stack interleaves two repos — the
/// Commitments protocol contracts deploy from the commitments repo's own scripts (with
/// their library linking), these legs deploy the Gas Killer side. Orchestrated by the
/// service repo's e2e (scripts/run_e2e_test.sh, STAKE_SOURCE=commitments):
///
///   1. [commitments] DeployCommitmentManager.s.sol            -> manager
///   2. [commitments] DeployAdaptersAndStrategies.s.sol        -> ERC20StaticAdapter
///   3. [solidity-sdk] GasKillerCommitmentsPhase1              -> stake token (dev), arbiter
///   4. [commitments] DeployOperatorRegistry.s.sol             -> operator registry
///      (REQUIRED_ARBITER_ADDRESS = the phase-1 arbiter; then
///       manager.setOperatorRegistry(registry) via cast as admin)
///   5. [solidity-sdk] GasKillerCommitmentsPhase2              -> Schnorr adapter + registry,
///      full wiring (adapter.setRegistry / adapter.setArbiter / arbiter.wireService)
///
/// Both legs log `GK_<NAME>=<address>` lines for the orchestrator to grep.

/// @notice Dev-chain stake token. Open mint keeps operator funding one call — never
///         deploy to a value-bearing chain (pass STAKE_TOKEN_ADDRESS there instead).
contract MintableERC20 {
    string public name = "GasKiller Staked Token";
    string public symbol = "gkSTK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @notice Dev-chain SP1 "verifier" that accepts every proof. The real deployments pass
///         the canonical Succinct gateway via SP1_VERIFIER_ADDRESS; proof strictness for
///         the slash path is covered by forge tests against a strict mock.
contract PermissiveSP1Verifier {
    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure {}
}

/// @notice Phase 1: stake token (unless provided) + the slashing arbiter. Runs after the
///         CommitmentManager exists and BEFORE the OperatorRegistry, whose immutable
///         `requiredArbiter` bakes this arbiter's address in.
///
/// Env: COMMITMENT_MANAGER_ADDRESS (required), ADMIN_ADDRESS (required — guardian),
///      SP1_VERIFIER_ADDRESS (optional; permissive mock when unset),
///      SP1_PROGRAM_VKEY (optional bytes32), VKEY_TIMELOCK_SECONDS (default 2 days),
///      SLASH_PENALTY_BPS (default 10000), STAKE_TOKEN_ADDRESS (optional; dev mint when unset)
contract GasKillerCommitmentsPhase1 is Script {
    function run() external {
        address manager = vm.envAddress("COMMITMENT_MANAGER_ADDRESS");
        address guardian = vm.envAddress("ADMIN_ADDRESS");
        address verifier = vm.envOr("SP1_VERIFIER_ADDRESS", address(0));
        bytes32 vkey = vm.envOr("SP1_PROGRAM_VKEY", bytes32(0));
        uint256 vkeyDelay = vm.envOr("VKEY_TIMELOCK_SECONDS", uint256(2 days));
        uint16 penaltyBps = uint16(vm.envOr("SLASH_PENALTY_BPS", uint256(10_000)));
        address token = vm.envOr("STAKE_TOKEN_ADDRESS", address(0));

        vm.startBroadcast();

        if (token == address(0)) {
            token = address(new MintableERC20());
            console.log("Deployed dev stake token");
        }
        if (verifier == address(0)) {
            verifier = address(new PermissiveSP1Verifier());
            console.log("Deployed permissive dev SP1 verifier");
        }

        GasKillerSP1Arbiter arbiter =
            new GasKillerSP1Arbiter(manager, verifier, vkey, guardian, vkeyDelay, penaltyBps);

        vm.stopBroadcast();

        console.log("GK_STAKE_TOKEN=%s", token);
        console.log("GK_SP1_VERIFIER=%s", verifier);
        console.log("GK_ARBITER=%s", address(arbiter));
    }
}

/// @notice Phase 2: the Schnorr side + full wiring. Runs after the OperatorRegistry
///         exists. Broadcaster must be ADMIN_ADDRESS (it is both the adapter admin and
///         the arbiter guardian in the e2e topology).
///
/// Env: OPERATOR_REGISTRY_ADDRESS, ARBITER_ADDRESS, ADMIN_ADDRESS (required);
///      WEIGHT_SCALE (required — set to MIN_OPERATOR_STAKE for uniform weight 1 at the
///      minimum stake); QUORUM_THRESHOLD/THRESHOLD_DENOMINATOR (default 2/3);
///      SCHNORR_NOTICE_WINDOW (default 0 blocks)
contract GasKillerCommitmentsPhase2 is Script {
    function run() external {
        address operatorRegistry = vm.envAddress("OPERATOR_REGISTRY_ADDRESS");
        address payable arbiterAddr = payable(vm.envAddress("ARBITER_ADDRESS"));
        address admin = vm.envAddress("ADMIN_ADDRESS");
        uint256 weightScale = vm.envUint("WEIGHT_SCALE");
        uint256 thresholdNum = vm.envOr("QUORUM_THRESHOLD", uint256(2));
        uint256 thresholdDen = vm.envOr("THRESHOLD_DENOMINATOR", uint256(3));
        uint256 noticeWindow = vm.envOr("SCHNORR_NOTICE_WINDOW", uint256(0));

        vm.startBroadcast();

        SchnorrCommitmentsAdapter adapter =
            new SchnorrCommitmentsAdapter(operatorRegistry, weightScale, admin);
        SchnorrStakeRegistry registry =
            new SchnorrStakeRegistry(thresholdNum, thresholdDen, address(adapter), noticeWindow);

        adapter.setRegistry(address(registry));
        adapter.setArbiter(arbiterAddr);
        GasKillerSP1Arbiter(arbiterAddr).wireService(operatorRegistry, address(adapter));

        vm.stopBroadcast();

        console.log("GK_SCHNORR_ADAPTER=%s", address(adapter));
        console.log("GK_SCHNORR_STAKE_REGISTRY=%s", address(registry));
    }
}
