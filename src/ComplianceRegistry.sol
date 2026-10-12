// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title Compliance registry — plank (d) of the bridge
/// @notice The underlying here is a regulated security, so the token is permissioned: only
///         addresses that have cleared KYC may hold it or receive it. This contract is the
///         on-chain half of that rule; the off-chain half is the KYC provider that decides
///         who goes on the list. A plain ERC-20 has no such list — that is the difference
///         between a token and a *security* token.
contract ComplianceRegistry is AccessControl {
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    error ZeroAddress();

    /// @dev Who may hold the token. Mint and burn are not exempt: even a fresh mint has to
    ///      land on a whitelisted address.
    mapping(address => bool) public isWhitelisted;

    event WhitelistUpdated(address indexed account, bool status);

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, admin);
    }

    function setWhitelisted(address account, bool status) external onlyRole(COMPLIANCE_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        isWhitelisted[account] = status;
        emit WhitelistUpdated(account, status);
    }
}
