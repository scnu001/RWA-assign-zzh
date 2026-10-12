// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {TBillToken} from "../../src/TBillToken.sol";
import {TBillVault} from "../../src/TBillVault.sol";
import {MockPriceFeed} from "../../src/exercises/MockPriceFeed.sol";
import {MockTBillCustodian} from "../../src/exercises/MockTBillCustodian.sol";

/// @title Ex2 + Ex3 + Ex4 — three planks of the bridge: custody (a), attestation (b), admission (d)
/// @notice The bridge is how an off-chain asset becomes an on-chain token. Each exercise below
///         pulls on one plank and shows you what is holding the span up — and what is not.
///         The fourth plank, redemption (c), is the queue you write in Ex5.
///
///         Assertions distinguish reported asset values from cash and token balances.
///         Admission failures assert their exact custom error and affected address.
///
///         Acceptance: make exercise.
contract BridgeTasksTest is Test {
    MockUSDC internal usdc;
    ComplianceRegistry internal compliance;
    MockPriceFeed internal feed;
    TBillToken internal tBill;
    MockTBillCustodian internal custodian;
    TBillVault internal vault;

    address internal admin = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant PAR = 1e8;
    uint256 internal constant NAV_1_25 = 1.25e8;

    function setUp() public {
        usdc = new MockUSDC();
        compliance = new ComplianceRegistry(admin);
        feed = new MockPriceFeed(int256(PAR));
        tBill = new TBillToken(admin, compliance);
        custodian = new MockTBillCustodian(admin);
        vault = new TBillVault(usdc, tBill, feed, custodian, admin);

        tBill.grantRole(tBill.MINTER_ROLE(), address(vault));
        custodian.grantRole(custodian.CUSTODIAN_ROLE(), address(vault));

        compliance.setWhitelisted(admin, true);
        compliance.setWhitelisted(alice, true);
        compliance.setWhitelisted(bob, true);
    }

    /// @dev Given: pay `assets` of USDC and receive shares at today's NAV
    function _subscribe(address user, uint256 assets) internal {
        usdc.faucet(user, assets);
        vm.startPrank(user);
        usdc.approve(address(vault), assets);
        vault.subscribe(assets);
        vm.stopPrank();
    }

    // ==================================================================
    // Ex2 · plank (a) custody — the shares exist, the box may not
    // ==================================================================

    /// @dev Subscribe 1000 USDC at par, then look at both sides of the bridge at once: the
    ///      shares alice now holds, and what the custodian actually holds.
    ///      Hint: _subscribe(alice, 1_000e6), then compare tBill.balanceOf(alice) with
    ///      custodian.realHoldings(). One of them is 1000e18; the other is zero. Assert both,
    ///      then ask yourself which contract ever talked to the custodian.
    function test_Ex2_SharesExistWhileTheCustodianHoldsNothing() public {
        _subscribe(alice, 1_000e6);
        assertEq(tBill.balanceOf(alice), 1_000e18);
        assertEq(custodian.realHoldings(), 0);
        assertEq(usdc.balanceOf(address(custodian)), 0);
        assertEq(vault.reserveBalance(), 1_000e6);
    }

    /// @dev The custodian's `treasury` is a number a permissioned address can move. Prove that
    ///      the "backing" is a typed-in integer, not cash that arrived.
    ///      Hint: recordPurchase is onlyRole(CUSTODIAN_ROLE) and `admin` holds it. Call
    ///      custodian.recordPurchase(1_000_000e6), then assert realHoldings() jumped while
    ///      usdc.balanceOf(address(custodian)) is still zero.
    function test_Ex2_RealHoldingsIsJustANumber() public {
        assertEq(custodian.realHoldings(), 0);
        assertEq(usdc.balanceOf(address(custodian)), 0);
        custodian.recordPurchase(1_000_000e6);
        assertEq(custodian.realHoldings(), 1_000_000e6);
        assertEq(usdc.balanceOf(address(custodian)), 0);
    }

    // ==================================================================
    // Ex3 · plank (b) attestation — the chain's only window is one number
    // ==================================================================

    /// @dev Subscribe at par, then have the reporter move the NAV up. Assert the two things
    ///      that make this an RWA and not a stablecoin: the share COUNT is unchanged, and the
    ///      VALUE of the position moved. A stablecoin would have kept things 1:1.
    ///      Hint: _subscribe(alice, 1_000e6); read tBill.balanceOf(alice) and
    ///      vault.totalClaimValue(); then vault.attest(int256(NAV_1_25)); read both again.
    ///      Shares stay 1000e18; the claim goes 1000e6 -> 1250e6.
    function test_Ex3_TheClaimFloats_TheShareCountDoesNot() public {
        _subscribe(alice, 1_000e6);
        assertEq(tBill.balanceOf(alice), 1_000e18);
        assertEq(vault.assetsForShares(tBill.balanceOf(alice)), 1_000e6);
        assertEq(vault.totalClaimValue(), 1_000e6);

        vault.attest(int256(NAV_1_25));

        assertEq(tBill.balanceOf(alice), 1_000e18);
        assertEq(vault.assetsForShares(tBill.balanceOf(alice)), 1_250e6);
        assertEq(vault.totalClaimValue(), 1_250e6);
        assertEq(vault.reserveBalance(), 1_000e6);
    }

    /// @dev One number re-prices the entire book. Two holders, one call, and both claim values
    ///      move together. attest is gated by REPORTER_ROLE — `admin` holds it — but nothing
    ///      downstream can question the number it writes.
    ///      Hint: _subscribe alice and bob, then vault.attest. A single holder's claim value is
    ///      vault.assetsForShares(tBill.balanceOf(who)). Pick a moderate NAV (e.g. 50e8) so the
    ///      totals stay small and readable.
    function test_Ex3_OneCallMovesTheWholeBook() public {
        _subscribe(alice, 1_000e6);
        _subscribe(bob, 400e6);
        assertEq(vault.assetsForShares(tBill.balanceOf(alice)), 1_000e6);
        assertEq(vault.assetsForShares(tBill.balanceOf(bob)), 400e6);
        assertEq(vault.totalClaimValue(), 1_400e6);

        vault.attest(50e8);

        assertEq(tBill.balanceOf(alice), 1_000e18);
        assertEq(tBill.balanceOf(bob), 400e18);
        assertEq(tBill.totalSupply(), 1_400e18);
        assertEq(vault.assetsForShares(tBill.balanceOf(alice)), 50_000e6);
        assertEq(vault.assetsForShares(tBill.balanceOf(bob)), 20_000e6);
        assertEq(vault.totalClaimValue(), 70_000e6);
    }

    // ==================================================================
    // Ex4 · plank (d) admission — where the guard is, and who holds the key
    // ==================================================================

    /// @dev An address that never passed KYC cannot receive shares, even by paying for them.
    ///      Hint: faucet the attacker and approve the vault FIRST, or you revert for the wrong
    ///      reason. Then vm.expectRevert + abi.encodeWithSelector to pin down
    ///      TBillToken.NotWhitelisted(attacker). A vague "it reverted" stays green even after
    ///      the guard is removed, so assert the exact selector.
    function test_Ex4_NoKyc_NoShares_EvenIfYouPay() public {
        usdc.faucet(attacker, 1_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, attacker));
        vault.subscribe(1_000e6);
        vm.stopPrank();
        assertEq(tBill.balanceOf(attacker), 0);
        assertEq(tBill.totalSupply(), 0);
        assertEq(usdc.balanceOf(attacker), 1_000e6);
        assertEq(vault.reserveBalance(), 0);
    }

    /// @dev A whitelisted holder still cannot SEND shares to a non-whitelisted address —
    ///      _update checks both endpoints, not just the sender.
    ///      Hint: alice subscribes, then alice calls tBill.transfer(attacker, 1e18). Pin the
    ///      revert on NotWhitelisted(attacker) — note WHICH address appears in the error.
    function test_Ex4_TransferChecksBothEndpoints() public {
        _subscribe(alice, 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, attacker));
        vm.prank(alice);
        tBill.transfer(attacker, 1e18);
        assertEq(tBill.balanceOf(alice), 1_000e18);
        assertEq(tBill.balanceOf(attacker), 0);
    }

    /// @dev Removing an address from the list freezes that individual holder — and it is
    ///      stronger than it looks. The same _update guard sits in front of burn(), so once
    ///      alice is off the list the issuer cannot confiscate her shares either.
    ///      Hint: alice subscribes; compliance.setWhitelisted(alice, false); assert alice's
    ///      transfer reverts; then assert tBill.burn(alice, 1_000e18) called by admin ALSO
    ///      reverts NotWhitelisted(alice). Do not reach for pause() — that is a global switch,
    ///      a different question (STUDENT-QUESTIONS.md C2).
    function test_Ex4_FreezeBeatsConfiscation() public {
        _subscribe(alice, 1_000e6);
        compliance.setWhitelisted(alice, false);
        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, alice));
        vm.prank(alice);
        tBill.transfer(bob, 1e18);
        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, alice));
        tBill.burn(alice, 1_000e18);
        assertEq(tBill.balanceOf(alice), 1_000e18);
        assertEq(tBill.balanceOf(bob), 0);
        assertEq(tBill.totalSupply(), 1_000e18);
    }
}
