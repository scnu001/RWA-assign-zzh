# EXERCISES.md — the hands-on list

This file is **what you have to write**. The README tells you what the lab is; this tells you what to do.

Every exercise has one command that answers "am I done?". Red means not done, green means done.
The tests under `test/exercises/` are **deliberately red** — that is not a bug report, that is your task.

New to Foundry? **`FOUNDRY-101.md`** covers the test shape, the cheatcodes, the command band, and
where to look when it breaks. Read it before Ex2.

---

## Overview

| # | What you will do | Acceptance command | Plank | Where to look if stuck |
|---|---|---|---|---|
| Ex0 | Set up the environment, get the core tests passing | `make test` (7 green) | — | `README.md` "1. Setup" |
| Ex1 | Walk the bridge once on the command line — **warm-up, not graded** | `make subscribe` → `make nav` → `make redeem` | all | `README.md` "2. Quick start", the Ex1 commands below |
| Ex2 | Prove the shares exist while the custodian holds nothing | `test_Ex2_*` in `01_BridgeTasks.t.sol` | a | the Ex2 section below |
| Ex3 | Prove one NAV number re-prices the whole book | `test_Ex3_*` in the same file | b | the Ex3 section below |
| Ex4 | Prove who may hold shares, and how strong a freeze is | `test_Ex4_*` in the same file | d | the Ex4 table below, `STUDENT-QUESTIONS.md` D2 |
| Ex5 | Implement the redemption queue (T+1, FIFO) | all of `02_QueueTasks.t.sol` green | c | `src/exercises/RedemptionQueue.sol` |
| Ex6 | Implement the handler and write the two bridge invariants | all of `03_InvariantTasks.t.sol` green | c | `test/exercises/03_InvariantTasks.t.sol` |
| Ex7 | Turn the reporter's key into cash | `make challenge` (**red** until you solve it) | b | `test/challenges/FalseNav.t.sol` |

The four planks — custody (a), attestation (b), redemption (c), admission (d) — are the column
above. The three decimal scales are in Ex5 below.

---

## Ex0 · Environment

```bash
make doctor    # 30 seconds: is this machine ready? anything ✗ comes with its own fix
make test      # acceptance: 7 passed
```

`lib/` (forge-std + OpenZeppelin v5.0.2) **ships inside this repository** — a plain
`git clone` compiles as-is. There is nothing to install, and you do not need `make setup`
unless `lib/` is somehow empty (then `git checkout -- lib` restores it).

Installing Foundry on your own machine is the one step that can fail on a mainland network;
the Setup section of `README.md` covers the `gh-proxy.com` mirror, and Track B (Codespaces)
installs nothing locally.

---

## Ex1 · Walk the bridge once

> **Not graded — a warm-up.** There is nothing to hand in for this one. Walk it once so the
> rest has something to hang on: this is exactly the loop Ex2–Ex6 put under test.

```bash
make anvil                  # terminal A, leave it running
make deploy-anvil           # terminal B — prints the admin + 7 contracts
export ADMIN=... USDC=... TBILL=... VAULT=... QUEUE=... CUSTODIAN=...   # paste from that output

# Fund yourself first — the deploy mints no USDC. Load ANVIL_KEY privately from
# your local Anvil instance; use the same account as the whitelisted deploy admin.
cast send $USDC "faucet(address,uint256)" $ADMIN 1000000000000 \
  --rpc-url http://127.0.0.1:8545 \
  --private-key "$ANVIL_KEY"

make subscribe AMOUNT=1000000000         # 1000 USDC (6 decimals)
make nav                    # the attested NAV, 8 decimals
make holdings               # what the custodian says it holds
make redeem AMOUNT=1000000000000000000   # 1 share (18 decimals)
make queue                  # what the queue still owes
```

Skip the faucet step and `make subscribe` reverts — nothing funded your USDC balance.
Watch one number in particular: after `subscribe`, your `balanceOf` is fixed, but when the NAV
moves the **value** of that balance moves with it. A stablecoin would have kept 1:1.

> `make redeem` will revert until you have finished Ex5. That is the queue you have not written yet.

---

## Ex2 · Custody — the shares exist, the box may not

Open `test/exercises/01_BridgeTasks.t.sol` and write the two `Ex2` tests. This is plank (a).

| Function | What you are proving |
|---|---|
| `test_Ex2_SharesExistWhileTheCustodianHoldsNothing` | you hold `1000e18` shares while the custodian holds **zero** |
| `test_Ex2_RealHoldingsIsJustANumber` | the "backing" is an integer a permissioned address typed in |

`subscribe()` takes your USDC into the vault and mints shares. It never talks to the custodian —
so shares exist the moment you pay, whether or not anything backs them. Read both sides at once:
`tBill.balanceOf(alice)` is `1000e18`, `custodian.realHoldings()` is `0`.

For the second test: `recordPurchase` is `onlyRole(CUSTODIAN_ROLE)`, and `admin` holds that role.
Call it and watch `realHoldings()` jump while `usdc.balanceOf(address(custodian))` stays at zero.
The number the chain trusts is not cash that arrived — it is a number that was typed.

---

## Ex3 · Attestation — one number re-prices the whole book

Same file, the two `Ex3` tests. Plank (b): the chain's only window onto the asset.

| Function | What you are proving |
|---|---|
| `test_Ex3_TheClaimFloats_TheShareCountDoesNot` | NAV up: the share **count** is unchanged, the **value** moved |
| `test_Ex3_OneCallMovesTheWholeBook` | one `attest` re-prices every holder at once |

A single holder's claim value is `vault.assetsForShares(tBill.balanceOf(who))`; the whole book is
`vault.totalClaimValue()`. After `vault.attest(int256(1.25e8))` on a 1000-share position, the claim
goes `1000e6` → `1250e6` while the balance stays `1000e18`. A stablecoin would have kept 1:1 —
that difference is the whole difference between a pegged token and a claim.

`attest` is gated by `REPORTER_ROLE` (the deployer holds it), but look at what it *writes*: a bare
number. Nothing downstream — subscription pricing, redemption payouts, either invariant — can
check it against anything on-chain.

> Want to see the same failure from the command line? `script/BreakIt.s.sol` attests a NAV of `2e8`
> on a live Anvil and prints `totalClaimValue()` beside `custodian.realHoldings()`. It is the demo
> from the session, **not** a deliverable. `FAKE_NAV=<8-decimal int>` overrides the default.

---

## Ex4 · Admission — where the guard is, and how strong it is

Same file, three `Ex4` tests. Plank (d).

| Function | What you are proving |
|---|---|
| `test_Ex4_NoKyc_NoShares_EvenIfYouPay` | no whitelist, no shares — even if you pay |
| `test_Ex4_TransferChecksBothEndpoints` | `_update` checks the **receiver** too, not just the sender |
| `test_Ex4_FreezeBeatsConfiscation` | off the list a holder is frozen — and **cannot be burned either** |

All three pin the exact revert:
`vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, who))`. A vague
"it reverted" stays green even after the guard is removed, so assert the selector.

The third is the surprising one. `_update` runs for **every** balance change, and `burn()` is a
balance change — so the same guard that freezes a holder also stops the issuer seizing their
shares. The compliance power cuts both ways: that tension is question **D2** in
`STUDENT-QUESTIONS.md`.

> `pause()` is the *other* lever (`PAUSER_ROLE`): it freezes transfers, minting and redemption
> together. That is question **C2** — a different and blunter tool.

---

## Ex5 · The redemption queue

Open `src/exercises/RedemptionQueue.sol` and fill in the four TODOs. This is plank (c): the T+1
settlement a tokenized fund cannot avoid. The tests in `02_QueueTasks.t.sol` are given — they are
your acceptance criteria, and they are red only because these four functions revert.

| TODO | What to do | The hard part |
|---|---|---|
| Ex5.1 `assetsAtNav` | turn shares into USDC at a given NAV | 18 + 8 − 6: divide by 10 to what power? |
| Ex5.2 `enqueue` | escrow the shares, lock the payout at today's NAV, hand out a ticket | record first, or transfer first? |
| Ex5.3 `settle` | pay out FIFO as T+1 cash lands | a ticket is all-or-nothing; a partial fill carries the remainder forward |
| Ex5.4 `claim` | collect a settled ticket | CEI: zero the claim before you transfer |

Acceptance:

```bash
make exercise   # the 02_QueueTasks.t.sol group
```

Three decimal scales meet in `assetsAtNav`, and getting the power wrong is the classic silent
bug — no revert, the invariant still holds, and every payout is off by 10^12:

```
shares   tBILL   18 decimals
NAV      feed     8 decimals
assets   USDC     6 decimals     18 + 8 - 6 = 20  ->  divide by 10^20
```

Two things worth noticing once it is green:

- `test_Ex5_3_Settle_NeedsTheVaultToHoldCash` walks the real T+1 story: the cash was invested, so
  the vault is empty and the settlement cannot draw on it until the SPV wires the proceeds back.
- `settle` has to **burn** the shares it holds, and burning is a balance change — which is why
  the queue itself must be whitelisted. Miss that in `Deploy.s.sol` and the whole loop reverts.

---

## Ex6 · The two bridge invariants

Open `test/exercises/03_InvariantTasks.t.sol`.

Invariant testing flips the usual test around: **let the machine call a pile of operations at
random and in sequence**, then ask "no matter how it thrashes, has this property been broken?"

> **Ex6 depends on Ex5.** The handler calls `enqueue` / `settle` / `claim`, so with the queue
> still stubbed the fuzzer only ever sees reverts and finds nothing.

Five TODOs:

| TODO | What to do |
|---|---|
| Ex6.1 | implement the handler's `enqueue` |
| Ex6.2 | implement the handler's `settle` |
| Ex6.3 | implement the handler's `claim` |
| Ex6.4 | `invariant_EscrowConservation` — the queue holds exactly the shares it still owes |
| Ex6.5 | `invariant_SettlementSolvency` — the queue never owes cash it does not hold |

```bash
make exercise   # the 03_* group
```

When an assertion fails, Foundry prints the **counterexample call sequence** — walk it by hand
and you will see exactly which step, with which arguments, broke the invariant. This is the
closest thing in the lab to a real security audit.

Then answer the question the code cannot: there is a third relation that looks true and is not —

```
vault.reserveBalance() >= queue.pendingAssets()
```

> Why can nobody write that one? When the NAV rises, where does the extra value physically sit —
> in the vault's USDC buffer, or in the T-Bills at the custodian? Write this up as question C1.

---

## Ex7 · Turn the reporter's key into cash

```bash
make challenge     # should be red right now -- that is the puzzle, not a bug
```

The material is in `test/challenges/FalseNav.t.sol`. You are a KYC'd customer who also holds the
reporter's key — a leaked signing key, or a bribed operations desk — and Alice is an honest
holder who did nothing wrong. Your goal: **end with more USDC than you started with, at the
fund's expense.**

The only function you need to change is `test_falseNav()`. The hint is already in there:

> The vault trusts `navPerShare()` for **both** pricing (`subscribe`) and paying out (the queue).
> You can move that number. What is the cheapest path from "I can write the NAV" to "I hold more
> USDC than I started with"?

---

## Deliverables

The homework requirements, grading weights and how to submit are in the "4. Homework" and
"6. Submission" sections of `README.md`.
The discussion questions are in `STUDENT-QUESTIONS.md`.
