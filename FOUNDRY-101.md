# FOUNDRY-101.md — the tooling crash course

`EXERCISES.md` says *what* to do. This says *how to drive the tool*. Read it once before you
start, and keep the command band at the bottom open in a second window.

---

## 1. How a Foundry test is shaped

```solidity
contract BridgeTasksTest is Test {
    function setUp() public {                 // runs before EVERY test
        vault = new TBillVault(usdc, tBill, feed, custodian, admin);
    }

    function test_Ex2_Something() public {    // test_ is how Foundry finds it
        assertEq(a, b);
    }
}
```

Three things to notice:

- `Test` gives you `assertEq` and the whole set of `vm` cheatcodes.
- `setUp` runs again before every single test, so state never leaks between them.
- `test_` is the **registration mechanism**. Foundry scans for the prefix — not the file, not the
  order the functions appear in.

> **The quiet trap.** Drop the `test_` prefix and Foundry does not complain. It reports zero tests
> run and exits normally. Confirm a test actually executed before you believe it passed.

---

## 2. The cheatcodes you will need

| Cheatcode | What it does | How it fails quietly |
|---|---|---|
| `vm.prank(addr)` | impersonate `addr` for the **next** call only | — |
| `vm.startPrank(addr)` / `vm.stopPrank()` | impersonate for several calls in a row | forget the closing `stopPrank` and every later call runs as somebody else — the test goes green for no reason |
| `vm.expectRevert(...)` | assert the next call must fail — put it on the line **before** the call | pass an error **identifier**, not a string; a message where an error is expected is the usual miss |
| `bound(x, lo, hi)` | clamp a fuzz input into range (the fuzzer will always try zero) | — |
| `vm.assume(cond)` | throw the input away when `cond` is false | a reverting `assume` does **not** fail the test — it just skips that input |

Pin the exact error, never a vague "it reverted":

```solidity
vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, attacker));
vault.subscribe(1_000e6);
```

"If it reverted" stays green even after the guard is removed, so in this lab you always assert the
selector.

---

## 3. Commands

**Make targets**

| Command | What it does |
|---|---|
| `make test` | the checkpoint — the core suite, 7 green |
| `make exercise` | the student exercise suites (red until you finish them) |
| `make challenge` | the Ex7 challenge (red until you solve it) |
| `make doctor` | 30-second pre-flight check of your machine |
| `make deploy-anvil` | deploy the whole system to a local chain |
| `make nav` / `make holdings` / `make queue` | read the attestation, the custodian, the queue |
| `make subscribe AMOUNT=…` / `make redeem AMOUNT=…` | walk the bridge by hand |
| `make install-foundry` | install Foundry through the mainland mirror |

**Foundry and cast**

```bash
forge test --match-path 'test/exercises/01_*' -vv     # one file
forge test --match-test 'test_Ex3_*' -vv              # one group
cast call  $VAULT  "totalClaimValue()(uint256)"
cast call  $TBILL  "balanceOf(address)(uint256)" $TA
cast send  $USDC   "faucet(address,uint256)" $TA 1000000000
```

**Verbosity** — `-v` pass/fail · `-vv` logs on failure · `-vvv` the revert reason · `-vvvv` the full
call trace and prank identity. When a `vm.prank` is not landing where you think it is, `-vvvv` is
how you find out.

> The `$` is the shell prompt, not part of the command. Commands that need addresses expect
> `export USDC=… TBILL=… VAULT=… QUEUE=… CUSTODIAN=…` from `make deploy-anvil` first.

---

## 4. When it breaks

The symptom-to-fix table is **`README.md` §5 "Common problems"** — roles, `NotWhitelisted`,
orders-of-magnitude, a restarted Anvil, an empty `lib/`, and the invariant cache.

The one worth repeating here, because it wastes the most time:

```bash
rm -rf cache/invariant      # Foundry replays a cached counterexample otherwise
```

Not in that table? Then it is probably not your environment — it is the problem itself. Come and ask.
