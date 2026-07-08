// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {GasKillerVertex} from "../src/examples/gaskiller-vertex/GasKillerVertex.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";

/// @dev Minimal ERC20 with unbounded mint — for the local anvil demo only.
contract DemoUSDC is IERC20 {
    string public name = "Demo USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

/// @dev BLS checker that always reports 100% signed stake — lets the demo exercise the operator
///      `verifyAndUpdate` path without a real operator set.
contract DemoBLSChecker {
    function checkSignatures(
        bytes32,
        bytes calldata quorumNumbers,
        uint32,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory
    ) external pure returns (IBLSSignatureCheckerTypes.QuorumStakeTotals memory totals, bytes32) {
        uint256 n = quorumNumbers.length;
        totals.signedStakeForQuorum = new uint96[](n);
        totals.totalStakeForQuorum = new uint96[](n);
        for (uint256 i = 0; i < n; i++) {
            totals.signedStakeForQuorum[i] = uint96(1e18);
            totals.totalStakeForQuorum[i] = uint96(1e18);
        }
    }
}

/// @notice Deploys the GasKillerVertex demo stack to a local node and writes
///         `frontend/src/deployments.json` for the dApp to consume.
///
///  Usage:
///    anvil &
///    forge script script/DeployVertex.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
///      --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///
///  The exchange is left with its EMPTY committed state — the frontend (acting as the operator)
///  lists markets, deposits, trades, settles, and liquidates through the UI, keeping its local
///  ExchangeState mirror in sync with the on-chain commitment.
contract DeployVertex is Script {
    // First 10 anvil default accounts (deterministic) — minted demo USDC so any can trade.
    address[10] internal ANVIL = [
        0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
        0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
        0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
        0x90F79bf6EB2c4f870365E785982E1f101E93b906,
        0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65,
        0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc,
        0x976EA74026E726554dB657fA54763abd0C3a0aa9,
        0x14dC79964da2C08b23698B3D3cc7Ca32193d9955,
        0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f,
        0xa0Ee7A142d267C1f36714E4a8F75612F20a79720
    ];

    function run() external {
        uint256 avs = 0xA75; // arbitrary AVS service-manager address for the demo

        vm.startBroadcast();

        DemoUSDC usdc = new DemoUSDC();
        DemoBLSChecker bls = new DemoBLSChecker();
        GasKillerVertex vertex = new GasKillerVertex(address(uint160(avs)), address(bls), IERC20(address(usdc)));

        for (uint256 i = 0; i < ANVIL.length; i++) {
            usdc.mint(ANVIL[i], 10_000_000 ether);
        }

        vm.stopBroadcast();

        console2.log("USDC   :", address(usdc));
        console2.log("BLS    :", address(bls));
        console2.log("Vertex :", address(vertex));

        string memory json = string.concat(
            "{\n",
            '  "chainId": 31337,\n',
            '  "rpcUrl": "http://127.0.0.1:8545",\n',
            '  "vertex": "',
            vm.toString(address(vertex)),
            '",\n',
            '  "usdc": "',
            vm.toString(address(usdc)),
            '",\n',
            '  "bls": "',
            vm.toString(address(bls)),
            '",\n',
            '  "avs": "',
            vm.toString(address(uint160(avs))),
            '"\n',
            "}\n"
        );
        vm.writeFile("./frontend/src/deployments.json", json);
        console2.log("Wrote frontend/src/deployments.json");
    }
}
