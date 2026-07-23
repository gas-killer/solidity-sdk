// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {ReentrantCheckpoint} from "./ReentrantCheckpoint.sol";
import {ReentrantObserver} from "./ReentrantObserver.sol";

/// @title ReentrantCheckpointFactory
/// @notice Deploys a paired {ReentrantObserver, ReentrantCheckpoint} for the re-entrancy
///         e2e. The observer is deployed first and wired into the checkpoint so the
///         checkpoint's task re-enters through it; both addresses are emitted so the
///         deploy/e2e harness can submit the task to the checkpoint and assert on both.
contract ReentrantCheckpointFactory {
    /// @notice Emitted when a checkpoint + observer pair is deployed.
    /// @param checkpoint The ReentrantCheckpoint (the Gas Killer target / task recipient).
    /// @param observer The ReentrantObserver it re-enters through.
    /// @param avsAddress The AVS service manager address configured on the checkpoint.
    /// @param schnorrStakeRegistry The Schnorr stake registry configured on the checkpoint.
    /// @param deploymentIndex Zero-based position of this pair in `deployedCheckpoints`.
    event ReentrantCheckpointDeployed(
        address indexed checkpoint,
        address indexed observer,
        address indexed avsAddress,
        address schnorrStakeRegistry,
        uint256 deploymentIndex
    );

    /// @notice Ordered list of every checkpoint deployed through this factory.
    address[] public deployedCheckpoints;
    /// @notice checkpoint => its paired observer.
    mapping(address => address) public observerOf;
    /// @notice Membership check — true if the address was deployed here.
    mapping(address => bool) public isDeployedContract;

    /// @notice Deploy a wired {observer, checkpoint} pair.
    /// @param _avsAddress The AVS service manager address for the checkpoint.
    /// @param _schnorrStakeRegistry The Schnorr stake registry verifying quorums.
    /// @return checkpoint The deployed ReentrantCheckpoint (submit the task here).
    /// @return observer The deployed ReentrantObserver it re-enters.
    function deployReentrantCheckpoint(address _avsAddress, address _schnorrStakeRegistry)
        external
        returns (address checkpoint, address observer)
    {
        require(_avsAddress != address(0), "Invalid AVS address");

        observer = address(new ReentrantObserver());
        checkpoint = address(new ReentrantCheckpoint(_avsAddress, _schnorrStakeRegistry, observer));

        uint256 deploymentIndex = deployedCheckpoints.length;
        deployedCheckpoints.push(checkpoint);
        observerOf[checkpoint] = observer;
        isDeployedContract[checkpoint] = true;

        emit ReentrantCheckpointDeployed(checkpoint, observer, _avsAddress, _schnorrStakeRegistry, deploymentIndex);
    }

    /// @notice Total number of checkpoints deployed by this factory.
    function getDeployedContractCount() external view returns (uint256) {
        return deployedCheckpoints.length;
    }

    /// @notice Whether a contract was deployed by this factory.
    function isContractDeployedByFactory(address _contractAddress) external view returns (bool) {
        return isDeployedContract[_contractAddress];
    }
}
