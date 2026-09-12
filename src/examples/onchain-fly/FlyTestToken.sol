// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FlyTestToken
/// @notice Mintable ERC20 for local / testnet rehearsals of the fly AMM (anyone may mint)
contract FlyTestToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 initialSupply, address to) ERC20(name_, symbol_) {
        _mint(to, initialSupply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
