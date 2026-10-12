// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {TBillToken} from "../../src/TBillToken.sol";
import {TBillVault} from "../../src/TBillVault.sol";
import {MockPriceFeed} from "../../src/exercises/MockPriceFeed.sol";
import {MockTBillCustodian} from "../../src/exercises/MockTBillCustodian.sol";
import {RedemptionQueue} from "../../src/exercises/RedemptionQueue.sol";

/// @title Ex6 — the two bridge invariants
/// @notice Invariant testing flips the usual test around: let the machine call operations
///         randomly and repeatedly, then ask "no matter how it thrashes, does this property
///         still hold?" That is how a bridge should be tested — you will never guess the order
///         an attacker does things in.
///
///         Acceptance: make exercise (it should be red until you are finished)
///
/// @dev Ex6 depends on Ex5: the handler below calls enqueue / settle / claim, which are the
///      four functions you implement in RedemptionQueue.sol. Finish Ex5 first, or the fuzzer
///      will only ever see reverts.
///
///      How it works: Foundry picks a function from the handler at random, picks random
///      arguments, calls it, and repeats N times; after each round it runs every invariant_*
///      function. The first failed assertion is a counterexample.
contract BridgeHandler is Test {
    MockUSDC internal usdc;
    TBillToken internal tBill;
    TBillVault internal vault;
    RedemptionQueue internal queue;

    address[3] public users;

    /// @dev Bookkeeping: proves the fuzzer really reached the handler instead of idling
    uint256 public ghost_enqueues;
    uint256 public ghost_settles;
    uint256 public ghost_claims;

    constructor(MockUSDC usdc_, TBillToken tBill_, TBillVault vault_, RedemptionQueue queue_) {
        usdc = usdc_;
        tBill = tBill_;
        vault = vault_;
        queue = queue_;

        users[0] = makeAddr("user0");
        users[1] = makeAddr("user1");
        users[2] = makeAddr("user2");
        for (uint256 i; i < users.length; ++i) {
            usdc.faucet(users[i], 100_000e6);
        }
    }

    /// @dev Given — pay USDC, receive shares at today's NAV
    function subscribe(uint256 userSeed, uint256 amount) external {
        address user = users[bound(userSeed, 0, users.length - 1)];

        uint256 balance = usdc.balanceOf(user);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.subscribe(amount);
        vm.stopPrank();
    }

    /// @dev Given — the reporter moves the NAV. Kept inside a sane band so the fuzzer spends
    ///      its budget on the queue rather than on absurd prices.
    function attest(uint256 navSeed) external {
        vault.attest(int256(bound(navSeed, 0.5e8, 2e8)));
    }

    /// @dev Given — the SPV wires cash back into the vault, the way T+1 proceeds would arrive
    function fundVault(uint256 amount) external {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        usdc.approve(address(vault), amount);
        vault.depositReserves(amount);
    }

    /// Ex6.1 — enqueue within a user's available balance
    /// @dev Steps:
    ///       1) pick one user at random (a user may hold 0 tBILL — if so, return early)
    ///       2) bound the shares to [1, that user's tBILL balance]
    ///       3) call queue.enqueue(shares) as that user
    ///       4) do not forget the approval — enqueue pulls the shares in with transferFrom
    function enqueue(uint256 userSeed, uint256 shares) external {
        address user = users[bound(userSeed, 0, users.length - 1)];
        uint256 balance = tBill.balanceOf(user);
        if (balance == 0) return;
        shares = bound(shares, 1, balance);

        vm.startPrank(user);
        tBill.approve(address(queue), shares);
        queue.enqueue(shares);
        vm.stopPrank();
        ++ghost_enqueues;
    }

    /// Ex6.2 — settle within available cash
    /// @dev Steps:
    ///       1) bound `assets` to [1, vault.reserveBalance()] (return early if the vault is empty)
    ///       2) call queue.settle(assets)
    ///      Settling with less cash than the head ticket needs is legal — it simply pays nothing.
    function settle(uint256 assets) external {
        uint256 reserves = vault.reserveBalance();
        if (reserves == 0) return;
        assets = bound(assets, 1, reserves);
        uint256 previousHead = queue.head();
        queue.settle(assets);
        // Count actual progress, including tickets whose payout rounds down to zero.
        if (queue.head() > previousHead) ++ghost_settles;
    }

    /// Ex6.3 — collect an existing credit
    /// @dev Steps:
    ///       1) pick one user at random
    ///       2) if that user has nothing claimable, return early
    ///       3) call queue.claim() as that user
    function claim(uint256 userSeed) external {
        address user = users[bound(userSeed, 0, users.length - 1)];
        if (queue.claimable(user) == 0) return;
        vm.prank(user);
        queue.claim();
        ++ghost_claims;
    }
}

contract InvariantTasksTest is Test {
    MockUSDC internal usdc;
    ComplianceRegistry internal compliance;
    TBillToken internal tBill;
    MockTBillCustodian internal custodian;
    TBillVault internal vault;
    RedemptionQueue internal queue;
    BridgeHandler internal handler;

    address internal admin = address(this);

    function setUp() public {
        usdc = new MockUSDC();
        compliance = new ComplianceRegistry(admin);
        MockPriceFeed feed = new MockPriceFeed(1e8);
        tBill = new TBillToken(admin, compliance);
        custodian = new MockTBillCustodian(admin);
        vault = new TBillVault(usdc, tBill, feed, custodian, admin);
        queue = new RedemptionQueue(vault, tBill, usdc, admin);

        tBill.grantRole(tBill.MINTER_ROLE(), address(vault));
        tBill.grantRole(tBill.MINTER_ROLE(), address(queue));
        custodian.grantRole(custodian.CUSTODIAN_ROLE(), address(vault));
        vault.setQueue(address(queue));

        compliance.setWhitelisted(address(queue), true);

        handler = new BridgeHandler(usdc, tBill, vault, queue);
        // Give the SPV action real funds so fundVault does not always return early.
        usdc.faucet(address(handler), 1_000_000e6);

        for (uint256 i; i < 3; ++i) {
            compliance.setWhitelisted(handler.users(i), true);
        }
        compliance.setWhitelisted(address(handler), true);

        vault.grantRole(vault.REPORTER_ROLE(), address(handler));
        vault.grantRole(vault.OPERATOR_ROLE(), address(handler));
        queue.grantRole(queue.SETTLER_ROLE(), address(handler));

        // Let the fuzzer call only the handler's own actions, not its inherited helpers
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = BridgeHandler.subscribe.selector;
        selectors[1] = BridgeHandler.attest.selector;
        selectors[2] = BridgeHandler.fundVault.selector;
        selectors[3] = BridgeHandler.enqueue.selector;
        selectors[4] = BridgeHandler.settle.selector;
        selectors[5] = BridgeHandler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// Ex6.4 — escrow conservation (plank c)
    /// @dev The queue holds exactly the shares it still owes a payout for. It never loses one
    ///      and never invents one within the handler's modeled operations.
    function invariant_EscrowConservation() public view {
        assertEq(tBill.balanceOf(address(queue)), queue.pendingShares(), "escrow conservation");
    }

    /// Ex6.5 — settlement solvency (plank c)
    /// @dev The queue never owes settled cash it does not hold: it pays at least what the
    ///      claimable balances add up to.
    ///
    ///      Then ask yourself why nobody can write the more tempting invariant:
    ///        vault.reserveBalance() >= queue.pendingAssets()
    ///      Hint: when the NAV rises, where does the extra value physically sit? Is it in the
    ///      vault's USDC buffer, or in the T-Bills at the custodian? That gap is the whole
    ///      lesson of this lab — write your answer up as question C1.
    function invariant_SettlementSolvency() public view {
        assertGe(usdc.balanceOf(address(queue)), queue.totalClaimable(), "settlement solvency");
    }

    function test_Ex6_HandlerCompletesRedemption() public {
        handler.subscribe(0, 1_000e6);
        handler.enqueue(0, 1_000e18);
        handler.attest(1.25e8);
        uint256 reserves = vault.reserveBalance();
        handler.fundVault(250e6);
        assertEq(vault.reserveBalance(), reserves + 250e6);
        handler.settle(1_000e6);
        assertEq(queue.claimable(handler.users(0)), 1_000e6);
        uint256 balance = usdc.balanceOf(handler.users(0));
        handler.claim(0);
        assertEq(usdc.balanceOf(handler.users(0)), balance + 1_000e6);
        assertEq(handler.ghost_enqueues(), 1);
        assertEq(handler.ghost_settles(), 1);
        assertEq(handler.ghost_claims(), 1);
        assertEq(queue.pendingShares(), 0);
        assertEq(queue.totalClaimable(), 0);
        invariant_EscrowConservation();
        invariant_SettlementSolvency();
    }

    function test_Ex5_ZeroEnqueueDoesNotCreateTicket() public {
        address user = handler.users(0);
        vm.expectRevert(RedemptionQueue.ZeroAmount.selector);
        vm.prank(user);
        queue.enqueue(0);
        assertEq(queue.queueLength(), 0);
        assertEq(queue.pendingShares(), 0);
        assertEq(queue.pendingAssets(), 0);
    }

    function test_Ex5_RoundingAndDustTicketDoNotBlockQueue() public {
        assertEq(queue.assetsAtNav(1e12 - 1, 1e8), 0);
        assertEq(queue.assetsAtNav(1e12, 1e8), 1);
        assertEq(queue.assetsAtNav(1e12 + 1, 1e8), 1);
        handler.subscribe(0, 1e6);
        handler.enqueue(0, 1);
        handler.enqueue(0, 1e18 - 1);

        assertEq(queue.settle(0), 0);
        assertEq(queue.head(), 1, "zero-value ticket can settle without cash");
        assertTrue(queue.requestAt(0).settled);
        assertEq(queue.settle(1e6), 1e6 - 1, "round down to USDC smallest units");
        assertEq(queue.head(), 2);
        assertEq(tBill.totalSupply(), 0);
        assertEq(vault.reserveBalance(), 1);
        invariant_EscrowConservation();
        invariant_SettlementSolvency();
    }

    function test_Ex5_FifoDoesNotSkipLargeHeadAndKeepsUnusedCash() public {
        handler.subscribe(0, 1_000e6);
        handler.subscribe(1, 100e6);
        handler.enqueue(0, 1_000e18);
        handler.enqueue(1, 100e18);
        assertEq(queue.settle(100e6), 0);
        assertEq(queue.head(), 0);
        assertEq(vault.reserveBalance(), 1_100e6);
        assertEq(queue.totalClaimable(), 0);
        assertEq(queue.settle(1_050e6), 1_000e6);
        assertEq(queue.head(), 1);
        assertTrue(queue.requestAt(0).settled);
        assertFalse(queue.requestAt(1).settled);
        assertEq(vault.reserveBalance(), 100e6, "unused budget stays in vault");
        assertEq(usdc.balanceOf(address(queue)), 1_000e6);
        assertEq(queue.settle(100e6), 100e6);
        assertEq(queue.settle(type(uint256).max), 0, "settled tickets cannot pay twice");
        assertEq(queue.totalClaimable(), 1_100e6);
        invariant_EscrowConservation();
        invariant_SettlementSolvency();
    }

    function test_Ex5_InsufficientReservesRollBackEntireBatch() public {
        handler.subscribe(0, 1_000e6);
        handler.enqueue(0, 500e18);
        handler.enqueue(0, 500e18);
        vault.invest(500e6);

        vm.expectRevert(TBillVault.InsufficientReserves.selector);
        queue.settle(1_000e6);

        assertEq(queue.head(), 0);
        assertFalse(queue.requestAt(0).settled);
        assertFalse(queue.requestAt(1).settled);
        assertEq(queue.pendingShares(), 1_000e18);
        assertEq(queue.pendingAssets(), 1_000e6);
        assertEq(queue.totalClaimable(), 0);
        assertEq(queue.claimable(handler.users(0)), 0);
        assertEq(vault.reserveBalance(), 500e6);
        assertEq(usdc.balanceOf(address(queue)), 0);
        assertEq(tBill.totalSupply(), 1_000e18);
        invariant_EscrowConservation();

        handler.fundVault(500e6);
        assertEq(queue.settle(1_000e6), 1_000e6);
        assertEq(queue.claimable(handler.users(0)), 1_000e6, "same owner's tickets accumulate");
        handler.claim(0);
        assertEq(queue.totalClaimable(), 0);
        invariant_SettlementSolvency();
    }

    function test_Ex5_SettlementRequiresRole() public {
        address user = handler.users(0);
        bytes32 role = queue.SETTLER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, role
            )
        );
        vm.prank(user);
        queue.settle(1);
    }
}
