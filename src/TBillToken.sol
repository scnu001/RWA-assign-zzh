// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {ComplianceRegistry} from "./ComplianceRegistry.sol";

/// @title The tokenized share
/// @notice This is NOT a stablecoin. One token is not worth one dollar — it is a share of a
///         fund, and what it is worth is whatever the last attested NAV says. Compare it
///         with Lab 1's sUSD: that token was pegged; this one floats with the fund.
///
///         Two things are bolted on that a plain ERC-20 does not have:
///           1) permissioning — the underlying is a regulated security, so both ends of every
///              transfer must be whitelisted (plank (d) of the bridge);
///           2) the same pause switch as before, so a crisis can freeze everything at once.
contract TBillToken is ERC20, AccessControl, Pausable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    ComplianceRegistry public immutable compliance;

    error ZeroAddress();
    error ZeroAmount();
    error NotWhitelisted(address account);

    constructor(address admin, ComplianceRegistry compliance_) ERC20("Tokenized T-Bill", "tBILL") {
        if (admin == address(0) || address(compliance_) == address(0)) revert ZeroAddress();
        compliance = compliance_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    /// @dev 18 decimals — a fund share, not a 6-decimal dollar token. The mismatch with USDC
    ///      is deliberate: it is what makes the NAV conversions in the vault non-trivial.
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount);
    }

    /// @dev A holder of MINTER_ROLE can burn any balance — the same backdoor as Lab 1's
    ///      stablecoin. Here it is not a convenience: the issuer of a security really can
    ///      force-transfer a holder's position. See the discussion questions.
    function burn(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _burn(from, amount);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @dev Every balance change routes through here, so both policies live in one place:
    ///      the pause switch, and the whitelist check on every non-zero endpoint.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20)
        whenNotPaused
    {
        if (from != address(0) && !compliance.isWhitelisted(from)) {
            revert NotWhitelisted(from);
        }
        if (to != address(0) && !compliance.isWhitelisted(to)) revert NotWhitelisted(to);
        super._update(from, to, value);
    }
}
