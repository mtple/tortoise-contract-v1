# Audit #10 Remediation Plan

Source: Independent security review — TortoiseV1 + TortoiseShell (Pass 5)
Date: 2026-04-16
Confidence threshold applied: 80

---

## Finding Assessment

| # | Conf | Title | Verdict |
|---|------|-------|---------|
| 1 | [82] | `_transferOrDefer` never refreshes `pendingClaimDeferredAt` — fresh deferrals inherit stale reroute timer | **IMPLEMENT** |

### Leads acted on

| Lead | Verdict |
|------|---------|
| `rerouteBlockedClaim` merge branch preserves `newRecipient`'s older timestamp | **IMPLEMENT** — same root cause as Finding #1; fix both in one change |
| Admin de-authorization of V1 leaves fee-paid / no-TORT-credit state | **ACCEPT** — requires explicit admin misstep; both `StakingFeeAbsorbed` and `ShellCreditFailed` events fire, giving full observability. Document in operator runbook (NatSpec). |

---

## Root Cause

`pendingClaimDeferredAt` is intended as a per-claim-balance freshness timer that guarantees the
recipient a full 90-day window to call `claimPending` before admin can reroute. The current
implementation sets the timestamp only when the balance transitions from zero to non-zero (first
deferral). Two paths violate the invariant:

**Path A — `_transferOrDefer` staleness (Finding #1):**
Day 0: a $10 dust payment fails, setting `deferredAt = T0` and `pendingClaims = $10`.
Day 100 (T0 + 100 days): a $10,000 payment fails to the same `(songId, recipient)`. Because
`pendingClaims != 0`, the `if` guard is skipped and `deferredAt` stays at `T0`. Since
`T0 + 90 days` has already elapsed, the owner can immediately call `rerouteBlockedClaim` and
seize the entire `$10,010` — including the $10,000 that was just deferred 0 seconds ago.

**Path B — `rerouteBlockedClaim` merge staleness (Lead):**
Admin reroutes A → B where B already has an aged `pendingClaimDeferredAt`. The merge condition
`pendingClaims[B] == amount` is `false` (B had prior balance), so `deferredAt[B]` is not
refreshed. Admin can immediately perform B → C with no additional wait, bypassing the spirit
of the second-hop cooldown on the rerouted amount.

---

## Fix

**Simplest correct fix:** always write `block.timestamp` to `pendingClaimDeferredAt` on every
deferral — in both `_transferOrDefer` and in `rerouteBlockedClaim`'s merge path. This ensures
every net addition to a pending balance resets the 90-day window from the moment of that
addition, which is the semantically correct invariant: "the recipient always has at least 90
days from the most recent deferral before admin can reroute."

### `_transferOrDefer`

```solidity
// Before:
if (pendingClaims[songId][recipient] == 0) {
    pendingClaimDeferredAt[songId][recipient] = block.timestamp;
}
pendingClaims[songId][recipient] += amount;

// After:
pendingClaims[songId][recipient] += amount;
// Refresh every time new funds are deferred so fresh amounts cannot
// inherit an already-elapsed timer from an earlier dust deferral (audit-10).
pendingClaimDeferredAt[songId][recipient] = block.timestamp;
```

### `rerouteBlockedClaim`

```solidity
// Before:
pendingClaims[songId][newRecipient] += amount;
if (pendingClaims[songId][newRecipient] == amount) {
    pendingClaimDeferredAt[songId][newRecipient] = block.timestamp;
}

// After:
pendingClaims[songId][newRecipient] += amount;
// Always refresh — merging into an aged destination must not let admin
// immediately reroute the combined balance without another 90-day wait.
pendingClaimDeferredAt[songId][newRecipient] = block.timestamp;
```

Both changes are a net simplification (the conditional is deleted in both cases).

---

## NatSpec addition for admin de-authorization lead

Add a comment to `_distributePayments` near the `StakingFeeAbsorbed` catch block:

```solidity
// Operator note: if V1 is de-authorized from Shell while stakingFee > 0,
// depositRewards will revert here (StakingFeeAbsorbed) and creditStake will
// revert in _creditShell (ShellCreditFailed). Both events are emitted so the
// condition is observable. Re-authorize V1 via shell.addAuthorizedCaller to
// restore normal operation; the stranded USDC will be absorbed by Shell on
// the next successful depositRewards call.
```

---

## Tests to Add

| Change | Test |
|--------|------|
| `_transferOrDefer` refresh | `test_deferredAt_refreshedOnSubsequentDeferral` — defer dust at T0, warp 91 days, defer again; verify `deferredAt` is now T0+91d and reroute reverts |
| `rerouteBlockedClaim` merge refresh | `test_rerouteBlockedClaim_mergeRefreshesDestinationTimer` — reroute A→B where B already has an aged deferral; verify reroute of B→C reverts immediately after |

---

## Verification

```bash
forge build
forge test --match-contract AuditRemediationTest -v
forge test -v
```
