// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Test reserve currency
/// @notice A mock USDC: 6 decimals, plus an unrestricted faucet. Real USDC is minted by a
///         privileged operator; this one is deliberately open so the lab works locally.
///         In this lab USDC is the cash that flows across the bridge — it is what the SPV
///         buys T-Bills with, and what a redeemed shareholder is paid in.
contract MockUSDC is ERC20 {
    error ZeroAmount();

    constructor() ERC20("Mock USDC", "mUSDC") {}

    /// @dev Stablecoins almost always use 6 decimals, not the ERC-20 default of 18
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Test faucet; anyone can call it
    function faucet(address to, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount);
    }
}
