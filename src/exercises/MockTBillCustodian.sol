// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title The custodian / SPV — plank (a) of the bridge
/// @notice In the real world the T-Bills sit at a custodian bank, held by a legal entity (an
///         SPV) set up for exactly that purpose. None of it is on-chain. This contract is a
///         stand-in whose only job is to answer one question: how much is actually there?
///
///         Note what it is: a number a permissioned address can move. The chain cannot look
///         behind it. That is the whole point of the exercise — the asset is real, but on
///         this side of the bridge it is only ever a claim.
contract MockTBillCustodian is AccessControl {
    bytes32 public constant CUSTODIAN_ROLE = keccak256("CUSTODIAN_ROLE");

    /// @dev The value of the T-Bills on the books, 6 decimals (same scale as the reserves)
    uint256 public treasury;

    event PurchaseRecorded(uint256 amount, uint256 treasury);
    event SaleRecorded(uint256 amount, uint256 treasury);

    error ZeroAddress();
    error InsufficientHoldings();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CUSTODIAN_ROLE, admin);
    }

    /// @notice The custodian reports that `amount` of T-Bills has been bought
    function recordPurchase(uint256 amount) external onlyRole(CUSTODIAN_ROLE) {
        treasury += amount;
        emit PurchaseRecorded(amount, treasury);
    }

    /// @notice The custodian reports that `amount` of T-Bills has been sold
    function recordSale(uint256 amount) external onlyRole(CUSTODIAN_ROLE) {
        if (amount > treasury) revert InsufficientHoldings();
        treasury -= amount;
        emit SaleRecorded(amount, treasury);
    }

    /// @notice What the custodian SAYS it holds
    /// @dev The chain has no way to check this against reality. Everything the vault and the
    ///      queue believe about the backing ultimately rests on numbers like this one.
    function realHoldings() external view returns (uint256) {
        return treasury;
    }
}
