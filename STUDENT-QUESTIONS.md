# STUDENT-QUESTIONS.md — Discussion questions (goes inside your submission zip)

Answer directly under each question. Following the formal assignment, write
**150–300 words per group (A–D), combining both subquestions**, not per subquestion.
Keep the answers separate under their respective prompts — **reasoning over length**.

The sections follow the four planks of the bridge. There are no standard answers; these are the
real point of the lab.

---

## A. Custody — where the asset actually is (plank a)

**A1.** In Lab 1, `totalCollateral()` read the vault's own ERC-20 balance, and the chain could
prove the invariant. Here, `MockTBillCustodian.realHoldings()` is just a number that a permissioned
address can move. Write the equivalent of `totalCollateral() == totalSupply()` for *this* system.
What does it actually assert, and what does it no longer prove?

> Your answer:

Without queued redemptions, the accounting target is
`vault.reserveBalance() + custodian.realHoldings() == vault.totalClaimValue()`,
with claims valued as `totalSupply() * navPerShare() / 1e20` in USDC units.
With the implemented queue, define R as vault reserves, H as reported holdings,
Q as queue cash, S as supply, P as pending shares, and N as NAV. The fuller
target is `R + H + Q == (S - P) * N / 1e20 + pendingAssets() + totalClaimable()`,
allowing rounding. Subtracting P avoids counting escrowed shares twice:
pendingAssets is unsettled fixed debt; totalClaimable is settled allocated cash.
Equality reconciles reports, not reality. `recordPurchase()` needs no cash
movement, so holdings prove neither ownership nor unencumbered backing.
Consistent valuations and complete liabilities are assumed. Custodian mock
cash must not duplicate reported purchases; zero holdings can coexist with
vault cash.

**A2.** The T-Bills are held by an SPV, a legal entity set up so the fund's assets are bankruptcy-
remote from the issuer. Explain in your own words why a *legal* structure is part of a *technical*
design. If the SPV's custodian goes bankrupt, what does the on-chain token entitle its holder to?

> Your answer:

An SPV's legal separation determines who can recover assets when technology
cannot enforce delivery. Bankruptcy remoteness from the issuer depends on
valid structure and operations; it does not eliminate custodian failure.
Properly segregated securities may be recoverable by the SPV outside the
custodian's general estate, but missing assets, liens, or commingling can
cause losses and delays. Token holders receive only the rights established
by fund documents, subscription and custody agreements, and applicable law:
potentially fund-share or contractual redemption rights, not necessarily
direct Treasury ownership or immediate USDC. `realHoldings()` proves none
of these protections. Production needs independent custody reconciliation,
investor records, and clear insolvency representation and procedures.

---

## B. Attestation — how the chain learns the truth (plank b)

**B1.** `attest()` is the only function that moves the NAV, and it is gated by `REPORTER_ROLE`.
Everything downstream — subscription pricing, redemption payouts, both invariants — believes that
number. Name the failure modes of a single trusted reporter, and one mechanism (technical,
financial, or legal) that mitigates each.

> Your answer:

A single reporter can suffer key theft, fraud, mistakes, or downtime.
Hardware-backed keys and independent threshold approval mitigate theft;
independent valuations, custody reconciliation, and enforceable liability
deter fraud. Decimal validation and deviation limits catch input errors;
authentic timestamps, freshness gates, and replacement procedures address
unavailable or withholding reporters. Shared data sources still create
correlated failures. Predictable updates invite preferential trading, so
common dealing cutoffs matter. The current mock has an additional bypass:
although `attest()` requires `REPORTER_ROLE`, anyone can call
`MockPriceFeed.setPrice()`. Production must restrict that writer. False NAV
distorts subscriptions and locked redemptions even when escrow conservation
and settled cash coverage hold: those invariants verify bookkeeping, not
off-chain value.

**B2.** A production feed would check whether `updatedAt` is stale; this lab's mock does not. A
**frozen** NAV is a different attack from a **wrong** NAV. Describe how a stale-but-honest NAV can
be exploited by someone who knows the true value has moved.

> Your answer:

A frozen NAV may have been honest when observed. If true value rises from
1.00 to 1.05 while the feed stays unchanged, 1,000 USDC buys 1,000 shares
rather than approximately 952.38, diluting existing holders. If true value
falls to 0.95, an informed holder can enqueue 1,000 shares at the stale 1.00
price. `assetsLocked` remains 1,000 USDC after correction, shifting losses
to remaining investors if settled. Eligibility, FIFO, cash availability,
and settler authorization still constrain payment. `navPerShare()` ignores
timestamps; worse, the mock reports `block.timestamp` on every read,
disguising an unchanged observation as fresh. Real observation timestamps,
maximum ages, and forward-priced batches are needed; an age check against
this mock alone is ineffective.

---

## C. Redemption — T+1 does not settle on-chain (plank c)

**C1.** The queue locks the payout at the NAV of **enqueue** time, not **settle** time. If the NAV
rises between the two, who gains and who loses — the redeemer, or the holders who stayed? Is that
the right allocation of risk, and how would you change it?

> Your answer:

Enqueueing 1,000 shares at 1.00 locks 1,000 USDC. A subsequent rise to 1.05
leaves the redeemer foregoing 50 of appreciation; genuine residual gains
economically benefit continuing holders under the fund's terms. A decline
reverses that allocation, encouraging early exits. The mock neither creates
cash nor automatically redistributes gains when NAV changes. I prefer
prospective forward pricing at a disclosed cutoff, with redemption costs
charged to that cohort. `vault.reserveBalance() >= queue.pendingAssets()`
is not universal: unsettled obligations may be backed by invested T-Bills,
requiring actual cash repatriation. By contrast,
`usdc.balanceOf(queue) >= queue.totalClaimable()` covers settled allocations.
The implemented settlement pulls reserves, burns escrowed shares, and
converts pending liabilities into claimable balances atomically.

**C2.** In a 2008 money-market fund breaking the buck, and in USDC's 2023 depeg, redemptions were
handled very differently. Compare the two. For a tokenized T-Bill fund, what does it mean to "close
the redemption channel", and what should happen to the queue when it does? Then look at the lever
this lab actually ships: `pause()` (`PAUSER_ROLE`) freezes transfers, minting **and** redemption
together — one switch, no partial setting. Why is that the wrong tool for a liquidity squeeze, and
what would you rather have?

> Your answer:

In 2008, Reserve Primary Fund losses led to breaking the buck, suspended
redemptions, and liquidation distributions. USDC's 2023 depeg combined
reserve uncertainty with weekend banking constraints; secondary trading
continued below par, while primary conversion recovered after deposit
protection and banking reopening. Closing a fund's channel should specify
whether requests or settlement stop, preserving ticket ownership, locked
amounts, and FIFO priority. Unfunded obligations must not become settled
allocations. `pause()` blocks tBILL transfers, minting, and burns through
`_update`, thereby blocking enqueue and ticket settlement. It does not block
already allocated USDC `claim()`: that function updates cash liabilities
and transfers USDC without touching tBILL. A liquidity squeeze need not
stop compliant transfers. Separate subscription, request, and settlement
gates, protected funded claims, and disclosed reopening criteria are
preferable; changing existing rights requires contractual authority.

---

## D. Admission — the guest list and the backdoor (plank d)

**D1.** Every balance change in `TBillToken._update` checks **both** endpoints against the
whitelist. That is what stops a sanctioned address from receiving shares — and also what stops a
completely ordinary user who has not finished KYC. Where is the right line for a regulated fund,
and who should be able to move it?

> Your answer:

Admission should follow published KYC, sanctions, jurisdiction, and
investor-eligibility rules. Incomplete KYC justifies denying new shares,
not treating an ordinary applicant as a criminal. Existing holders need
proportionate freezes, documented reasons, and correction or appeal
procedures. `_update()` checks both nonzero endpoints, including mint
recipients and burn sources; a rejected subscription rolls back its USDC
transfer. The queue must also be whitelisted, while USDC claims have no
equivalent token-level screening. A compliance team should hold
`COMPLIANCE_ROLE`, with dual approval for sensitive changes and private
evidence off-chain. Legal and fund governance should approve policy
changes. An independent multisig should administer roles, since
`DEFAULT_ADMIN_ROLE` can undermine separation by granting new powers.

**D2.** A regulated fund asks for two levers: freeze an address (`setWhitelisted(addr, false)`) and
burn a balance (`MINTER_ROLE`) — both censorship tools, both justified by the product. But Ex4.3
shows the two **collide**: once an address is off the list, `burn()` reverts as well, because
`_update` guards both endpoints. So a freeze also blocks a seizure. Argue **both** sides of handing
an issuer these powers, then say what safeguards you would add and who should hold each key.

> Your answer:

Freezes and seizure powers can implement sanctions, court orders, and
fraud recovery. Conversely, mistakes, compromised keys, or coercion can
immobilize savings or erase balances. `MINTER_ROLE` combines minting with
burning another holder's shares without allowance; burning does not itself
extinguish legal rights. Ex4.3 exposes the collision: removing a holder
from the whitelist makes `_update()` reject even an authorized burn.
Temporary whitelisting could reopen transfers. I would assign freezes
to a compliance multisig, routine minting to the vault, and redemption
burns to the queue. A separate, narrowly scoped seizure role should require
legal and independent trustee approval while preserving the freeze.
Security officers should control emergency pausing; separate governance
should administer roles with delayed changes. Auditable case references,
notice, appeals, and reconciliation should accompany these proposed safeguards.

---

## E. Tests (Tier 1 required — this is Ex2, Ex3 and Ex4)

Turn the red tests green in `test/exercises/01_BridgeTasks.t.sol` to cover the scenarios below, and
write your test function names here:

| Plank | Scenario | Your test function name |
|---|---|---|
| a | Shares exist while the custodian holds nothing | `test_Ex2_SharesExistWhileTheCustodianHoldsNothing` |
| a | `realHoldings()` moves with no cash moving | `test_Ex2_RealHoldingsIsJustANumber` |
| b | The claim value floats while the share count stays | `test_Ex3_TheClaimFloats_TheShareCountDoesNot` |
| b | One `attest` re-prices every holder at once | `test_Ex3_OneCallMovesTheWholeBook` |
| d | A non-whitelisted address cannot receive shares, even by paying | `test_Ex4_NoKyc_NoShares_EvenIfYouPay` |
| d | A whitelisted holder cannot send shares to a non-whitelisted address | `test_Ex4_TransferChecksBothEndpoints` |
| d | Removing an address freezes that holder — and blocks a burn | `test_Ex4_FreezeBeatsConfiscation` |

These are the original seven function names, verified against the local and
reference exercise files. Their root-project bodies now contain scenario
assertions rather than placeholders. This update is based on source inspection;
no test execution or passing result is claimed here.

Then write one more scenario you consider **most likely to be exploited** on a tokenized fund, and
say which plank it breaks:

> Your answer:

My leading practical scenario is stale-NAV arbitrage, breaking plank (b),
attestation, and transmitting losses through plank (c), redemption. This is
a reasoned threat choice, not an empirical frequency claim. A whitelisted
holder learns that the portfolio has lost value while the published NAV is
unchanged, then queues a redemption at the older, higher price. In the
implemented queue, `assetsLocked` preserves that price even after an
honest update. If sufficient cash arrives and an authorized settler honors
the ticket, the holder exits at remaining investors' expense. The attacker
needs timely information and eligibility, not a stolen reporter key.

The distinguishing assertions for a future test would be that the old
observation remains unchanged as time advances, the request captures that
old NAV, and a subsequent lower NAV does not reduce the locked payout.
Settlement should still require actual reserves, and any credited
`totalClaimable()` must remain cash-covered; accounting invariants alone
would not detect the unfair valuation.

For this particular mock, unrestricted `setPrice()` is an even more direct
price-manipulation route and must be closed before production. Authentic
observation timestamps, freshness gates, and forward-priced dealing windows
address the stale-price scenario. This document update adds no test and
claims no test execution, deployment, or demonstrated exploitation.
