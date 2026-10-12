# Assignment Three validation

Local checks on 2026-10-11, using Foundry 1.8.4 and Solidity 0.8.24.

Run from the project root:

```bash
export PATH="/Users/zhengzihao/.foundry/bin:$PATH"
FOUNDRY_OFFLINE=true make doctor test exercise
```

On another machine, use its Foundry installation directory. Offline mode requires
Solidity 0.8.24 to be installed already.

| Check | Observed result |
|---|---|
| `make doctor` | 6 passed, 0 failed |
| `make test` | 7 passed, 0 failed, 0 skipped |
| `make exercise` | 25 passed, 0 failed, 0 skipped |
| Escrow and settlement invariants | Both passed, 256 runs, 128,000 handler calls, 0 reverts |
| `Deploy.s.sol:Deploy` offline simulation | Successful, seven contracts created and wired; 5,369,650 simulated gas |

The exercise total comprises seven bridge tests, eleven original queue tests,
six additional boundary/handler tests, and a combined invariant run. The
invariants are checked from the initial state as well as after randomized calls.

The extra tests cover zero enqueue, floor rounding and dust tickets, FIFO
head blocking and unused cash, atomic rollback when reserves are insufficient,
settler authorization, and an actual handler subscribe/enqueue/settle/claim cycle.

## Submission archive check

`assignment3-local-draft.zip` was independently extracted into
`/tmp/assign3-check.xTWqcJ`. From that extracted project, with the packaged
dependencies and the locally installed compiler, `make doctor test exercise`
exited successfully: 6 environment checks, 7 core tests and 25 exercise tests
passed. No dependency download was needed.

The packager audited 300 project/dependency files and checked ZIP CRCs, manifest
membership, SHA-256 hashes and secret patterns. Dependency test fixtures containing
public example signing keys were excluded; required library source and licenses
were retained. The hardcoded local signing key in the original exercise instructions
was also replaced by an environment-variable reference.

The README architecture diagram is present at
`docs/rwa-bridge-architecture.svg` and passed the diagram self-check. Seven
contracts were deployed on Sepolia using individually gas-limited creation
transactions. Post-deployment reads confirmed the vault queue, minting roles,
custodian role, and admin/queue whitelist entries.

Etherscan browser pages show **Source Code Verified** for all seven contracts.
The final RedemptionQueue submission returned `OK`, GUID
`cmpfsx9r7sttewq4pbgfpnyjnen8nve6r3lpmvucipphdk1yqh`, and
`Pass - Verified`. Earlier API connection resets were transient; no address is
documented as verified until the final verification response passed.

The deployment simulation used no network and is not a Sepolia deployment.
Sepolia broadcasting and Etherscan verification remain pending; consult the
README deployment table. Optional Ex7 remains the original unsolved challenge
and is excluded by the required `make test` and `make exercise` targets.

These checks establish the specified on-chain behavior. They do not establish
real Treasury ownership, trustworthy NAV reporting, or production suitability.
