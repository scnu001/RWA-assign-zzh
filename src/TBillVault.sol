// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {TBillToken} from "./TBillToken.sol";
import {MockPriceFeed} from "./exercises/MockPriceFeed.sol";
import {MockTBillCustodian} from "./exercises/MockTBillCustodian.sol";

/// @title The subscription vault
/// @notice Users pay USDC and receive tBILL shares priced at the last attested NAV. The vault
///         holds the USDC buffer, the NAV oracle, and the door to the custodian.
///
///         Where Lab 1's vault had a self-evident invariant — collateral sat in the vault, so
///         the chain could count it — this one cannot. The T-Bills are at the custodian. All
///         the vault has is `navFeed`, a number a reporter writes. That is plank (b): the
///         bridge is only as honest as the last attestation.
///
///         Three decimal scales must be told apart (the sequel to Lab 1 Ex5):
///           shares    18 decimals  (tBILL)
///           NAV        8 decimals  (per share)
///           assets     6 decimals  (USDC)
contract TBillVault is AccessControl {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    TBillToken public immutable tBill;
    /// @dev Concrete type on purpose: the reporter pushes into this feed through `attest`.
    ///      Swapping in a production oracle means changing this one line and the `attest` body.
    MockPriceFeed public immutable navFeed;
    MockTBillCustodian public immutable custodian;

    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 public constant NAV_PRECISION = 1e8; // NAV per share, 8 decimals
    uint256 public constant SHARE_PRECISION = 1e18; // shares, 18 decimals
    uint256 public constant ASSET_PRECISION = 1e6; // USDC, 6 decimals
    /// @dev 18 + 8 - 6 — the one number every conversion in this lab divides by
    uint256 public constant DECIMALS_SCALE = 1e20;

    /// @dev The redemption queue, set once after it is deployed
    address public queue;

    event Subscribed(address indexed user, uint256 assets, uint256 shares);
    event Invested(uint256 assets);
    event ReservesDeposited(uint256 assets);
    event NavAttested(int256 nav, uint256 timestamp);
    event QueueSet(address indexed queue);

    error ZeroAddress();
    error ZeroAmount();
    error NotQueue();
    error InsufficientReserves();

    constructor(
        IERC20 usdc_,
        TBillToken tBill_,
        MockPriceFeed navFeed_,
        MockTBillCustodian custodian_,
        address admin
    ) {
        if (
            address(usdc_) == address(0) || address(tBill_) == address(0)
                || address(navFeed_) == address(0) || address(custodian_) == address(0)
                || admin == address(0)
        ) revert ZeroAddress();
        usdc = usdc_;
        tBill = tBill_;
        navFeed = navFeed_;
        custodian = custodian_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REPORTER_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
    }

    // ==================================================================
    // Given to you — the NAV math, do not touch
    // ==================================================================

    /// @notice The last attested NAV per share, 8 decimals
    /// @dev A production feed would also check whether updatedAt is stale — a frozen NAV is
    ///      an attack surface of its own
    function navPerShare() public view returns (uint256) {
        (, int256 answer,,,) = navFeed.latestRoundData();
        if (answer <= 0) revert ZeroAmount();
        return uint256(answer);
    }

    /// @notice Value `shares` (18 decimals) in USDC smallest units (6 decimals)
    function assetsForShares(uint256 shares) public view returns (uint256) {
        return shares * navPerShare() / DECIMALS_SCALE;
    }

    /// @notice How many shares (18 decimals) `assets` (6 decimals) buys at today's NAV
    function sharesForAssets(uint256 assets) public view returns (uint256) {
        return assets * DECIMALS_SCALE / navPerShare();
    }

    function reserveBalance() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice What every share in existence is worth on paper, in USDC smallest units
    function totalClaimValue() public view returns (uint256) {
        return tBill.totalSupply() * navPerShare() / DECIMALS_SCALE;
    }

    // ==================================================================
    // Given to you — the bridge's on-ramp, do not touch
    // ==================================================================

    /// @notice Pay `assets` of USDC, receive shares at today's NAV
    function subscribe(uint256 assets) external {
        if (assets == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), assets);
        uint256 shares = sharesForAssets(assets);
        tBill.mint(msg.sender, shares);
        emit Subscribed(msg.sender, assets, shares);
    }

    /// @notice The SPV buys T-Bills with `assets` of the buffer: cash out, holdings up
    function invest(uint256 assets) external onlyRole(OPERATOR_ROLE) {
        if (assets == 0) revert ZeroAmount();
        if (assets > reserveBalance()) revert InsufficientReserves();
        usdc.safeTransfer(address(custodian), assets);
        custodian.recordPurchase(assets);
        emit Invested(assets);
    }

    /// @notice The SPV wires back the proceeds of selling T-Bills, refilling the buffer
    function depositReserves(uint256 assets) external onlyRole(OPERATOR_ROLE) {
        if (assets == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), assets);
        emit ReservesDeposited(assets);
    }

    /// @notice The reporter posts the NAV per share
    /// @dev This is the chain's only window onto the off-chain asset. Everything downstream
    ///      — subscription pricing, redemption payouts, every invariant — believes this
    ///      number. Plank (b) of the bridge is exactly this one function.
    function attest(int256 nav) external onlyRole(REPORTER_ROLE) {
        navFeed.setPrice(nav);
        emit NavAttested(nav, block.timestamp);
    }

    /// @notice Point the vault at the redemption queue, once, after it is deployed
    function setQueue(address queue_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (queue_ == address(0)) revert ZeroAddress();
        queue = queue_;
        emit QueueSet(queue_);
    }

    /// @notice Hand reserve cash to the redemption queue
    /// @dev Only the queue may draw the buffer, so a compromised reporter or operator cannot
    ///      simply drain it through this door
    function releaseReserves(address to, uint256 assets) external {
        if (msg.sender != queue) revert NotQueue();
        if (assets > reserveBalance()) revert InsufficientReserves();
        usdc.safeTransfer(to, assets);
    }
}
