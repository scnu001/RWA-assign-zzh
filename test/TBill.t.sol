// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {MockUSDC} from "../src/MockUSDC.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {TBillToken} from "../src/TBillToken.sol";
import {TBillVault} from "../src/TBillVault.sol";
import {MockPriceFeed} from "../src/exercises/MockPriceFeed.sol";
import {MockTBillCustodian} from "../src/exercises/MockTBillCustodian.sol";

/// @title The green checkpoint — the answers live here
/// @notice Everything below passes out of the box and only touches the GIVEN contracts. The
///         redemption queue is not exercised here on purpose: its four functions are your
///         TODOs in src/exercises/RedemptionQueue.sol, graded by `make exercise`.
///
///         Do not open this file until you are stuck; write your own tests first.
contract TBillTest is Test {
    MockUSDC internal usdc;
    ComplianceRegistry internal compliance;
    MockPriceFeed internal feed;
    TBillToken internal tBill;
    MockTBillCustodian internal custodian;
    TBillVault internal vault;

    address internal admin = address(this);
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant AMOUNT = 1_000e6;
    uint256 internal constant PAR = 1e8; // NAV 1.00 per share
    uint256 internal constant NAV_1_25 = 1.25e8;

    function setUp() public {
        usdc = new MockUSDC();
        compliance = new ComplianceRegistry(admin);
        feed = new MockPriceFeed(int256(PAR));
        tBill = new TBillToken(admin, compliance);
        custodian = new MockTBillCustodian(admin);
        vault = new TBillVault(usdc, tBill, feed, custodian, admin);

        tBill.grantRole(tBill.MINTER_ROLE(), address(vault));
        // The vault is the custodian's authorized client: without this line invest() reverts
        custodian.grantRole(custodian.CUSTODIAN_ROLE(), address(vault));

        // The token is permissioned: without this line every mint reverts
        compliance.setWhitelisted(admin, true);
        compliance.setWhitelisted(alice, true);
    }

    function _subscribe(address user, uint256 assets) internal {
        usdc.faucet(user, assets);
        vm.startPrank(user);
        usdc.approve(address(vault), assets);
        vault.subscribe(assets);
        vm.stopPrank();
    }

    // ---------- the loop ----------

    /// @dev At par, 1000 USDC buys exactly 1000 shares
    function test_Subscribe_MintsSharesAtPar() public {
        _subscribe(alice, AMOUNT);

        assertEq(tBill.balanceOf(alice), 1_000e18, "1000 USDC at NAV 1.00 = 1000 shares");
        assertEq(vault.reserveBalance(), AMOUNT, "the USDC should be in the vault");
        assertEq(vault.totalClaimValue(), AMOUNT, "claim value should equal what was paid");
    }

    /// @dev After the NAV rises, the same 1000 USDC buys fewer shares
    ///      1000e6 * 1e20 / 1.25e8 = 800e18
    function test_Subscribe_AtHigherNav_MintsFewerShares() public {
        vault.attest(int256(NAV_1_25));
        _subscribe(alice, AMOUNT);

        assertEq(tBill.balanceOf(alice), 800e18, "1000 USDC at NAV 1.25 = 800 shares");
    }

    // ---------- the share is not a dollar ----------

    /// @dev The whole point of the lesson: the balance does not move when the NAV rises, but
    ///      what it is worth does. A stablecoin would have kept 1:1.
    function test_NavRise_LiftsClaimValueNotBalance() public {
        _subscribe(alice, AMOUNT);

        vault.attest(int256(NAV_1_25));

        assertEq(tBill.balanceOf(alice), 1_000e18, "the share count is unchanged");
        assertEq(vault.totalClaimValue(), 1_250e6, "the claim is now worth 1250 USDC");
    }

    // ---------- plank (a): cash becomes an off-chain holding ----------

    /// @dev Buying T-Bills moves the cash out of the vault and into the custodian's books
    function test_Invest_MovesCashToTheCustodian() public {
        _subscribe(admin, AMOUNT);

        vault.invest(AMOUNT);

        assertEq(vault.reserveBalance(), 0, "the buffer is spent");
        assertEq(custodian.realHoldings(), AMOUNT, "the custodian now reports the T-Bills");
    }

    // ---------- plank (b): only the reporter may move the NAV ----------

    /// @dev The in-class attack demo: a non-reporter trying to post a NAV must revert
    function test_Attest_RevertsForNonReporter() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                attacker,
                vault.REPORTER_ROLE()
            )
        );
        vm.prank(attacker);
        vault.attest(int256(NAV_1_25));
    }

    // ---------- plank (d): the token is permissioned ----------

    /// @dev An address that never passed KYC cannot receive shares, even by paying for them
    function test_Compliance_BlocksNonWhitelistedHolder() public {
        usdc.faucet(attacker, AMOUNT);

        vm.startPrank(attacker);
        usdc.approve(address(vault), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, attacker));
        vault.subscribe(AMOUNT);
        vm.stopPrank();
    }

    // ---------- invariant ----------

    /// @dev At par, whatever you pay is exactly what your claim is worth
    function testFuzz_Subscribe_ClaimValueMatchesPayment(uint96 raw) public {
        uint256 assets = uint256(raw) % 1_000_000e6;
        vm.assume(assets > 0);

        _subscribe(alice, assets);

        assertEq(vault.totalClaimValue(), assets, "claim value must equal what was paid at par");
    }
}
