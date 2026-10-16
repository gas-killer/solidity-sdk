// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {GasKillerSDK} from "../../GasKillerSDK.sol";
import {HashChain} from "../HashChain.sol";

/// @title DepositVault
/// @notice The callee of the nested-deposit example: credits the ETH its gateway forwards,
///         chains a receipt over every deposit, and pays deposits back out on withdrawal.
/// @dev The receipt chain makes `deposit` expensive enough natively that applying its frame
///      is cheaper, so the analyzer nests it rather than replaying it as a plain `CALL`.
///      Only the gateway may deposit. A deposit settled as this contract's own root transition
///      would be credited for any `msg.value` (gas-killer/solidity-sdk#104); reached only
///      through the gateway, it is either a nested frame, whose leaf binds the value, or a
///      native call carrying real ETH.
contract DepositVault is GasKillerSDK {
    error InvalidConfiguration();
    error NotGateway();
    error InsufficientBalance(uint256 balance, uint256 amount);
    error TransferFailed();

    event Deposited(address indexed account, uint256 amount, bytes32 receipt);
    event Withdrawn(address indexed account, uint256 amount);

    /// @notice Credited ETH per account (slot 0).
    mapping(address => uint256) public balances;
    /// @notice Head of the hash chain over every deposit (slot 1).
    bytes32 public receipt;

    address public immutable gateway;
    /// @notice Hash rounds per deposit receipt.
    uint256 public immutable receiptRounds;

    constructor(address _avsAddress, address _schnorrStakeRegistry, uint256 _receiptRounds) {
        if (_receiptRounds == 0) revert InvalidConfiguration();
        _setAvsAddress(_avsAddress);
        _setSchnorrRegistry(_schnorrStakeRegistry);
        gateway = msg.sender;
        receiptRounds = _receiptRounds;
    }

    function deposit(address account) external payable trackState {
        if (msg.sender != gateway) revert NotGateway();
        balances[account] += msg.value;
        bytes32 h = HashChain.extend(keccak256(abi.encode(receipt, account, msg.value)), receiptRounds);
        receipt = h;
        emit Deposited(account, msg.value, h);
    }

    /// @dev Tracked like `deposit`: an untracked write to `balances` between a trace and its
    ///      settlement would be overwritten by the signed absolute values.
    function withdraw(uint256 amount) external trackState {
        uint256 balance = balances[msg.sender];
        if (balance < amount) revert InsufficientBalance(balance, amount);
        balances[msg.sender] = balance - amount;
        emit Withdrawn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
