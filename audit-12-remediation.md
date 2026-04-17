# Audit #12 Remediation Plan

Source: Independent security review — TortoiseV1 + TortoiseShell (Pass 7)
Date: 2026-04-17
Confidence threshold applied: 80

---

## Cross-check against prior passes

This pass surfaced seven candidate findings. Cross-checking against audits 6–11
eliminates five as circular with previously-settled decisions:

| Candidate | Prior pass | Verdict |
|-----------|-----------|---------|
| creditStake mid-period dilution | audit-6 Finding 2 | **CIRCULAR** — accepted; per-quantity fees (audit-6 F1) + pool gate (audit-7 F2+7) + feeForwarded gate (audit-9) close the extraction path |
| claimPending permissionless deferredAt reset | audit-11 item A | **CIRCULAR** — always-refresh + claim-clears-timer is the accepted endpoint |
| No-max `mintSong` overload front-runnable | audit-7 Finding 3 | **CIRCULAR** — overload (not replacement) was explicit backward-compat decision |
| Shell `creditStake` silent partial credit cap | audit-6 Finding 3 | **CIRCULAR** — graceful-degradation at Shell + strict gate at V1 is the layered design |
| USDC proxy broken implementation | audit-8 change 3 | **RESIDUAL** — zero-code guard is in place; remaining risk is Circle's upgrade process |

Two findings remain:

| # | Conf | Title | Verdict |
|---|------|-------|---------|
| 1 | [88] | `emergencyWithdraw` decrements `totalRewardsDeposited` against an amount that was never credited to it, breaking the `reservedBalance ≤ totalRewardsDeposited × REWARD_SCALAR` invariant | **IMPLEMENT** |
| 2 | [75] | `_flushQueuedReward` bypasses `MIN_REWARD_DEPOSIT` floor when rewards are queued via `emergencyWithdraw`-to-zero-stake path | **IMPLEMENT (redesigned)** |

---

## Finding 1 — emergencyWithdraw forfeit accounting breaks reserve invariant

### Root cause

`TortoiseShell.emergencyWithdraw` (lines 165-170):

```solidity
uint256 forfeited = userUnpaidRewards[msg.sender];
if (forfeited > 0) {
    reservedBalance -= forfeited;
    totalRewardsDeposited -= forfeited / REWARD_SCALAR;
    userUnpaidRewards[msg.sender] = 0;
}
```

`totalRewardsDeposited` is the 6-decimal counter of USDC the contract still owes.
It is only decreased on successful `_claimRewards` (line 371: `totalRewardsDeposited -= payout`),
where `payout` has already been transferred out via `safeTransfer`. It is increased in
`depositRewards` (line 201) by `actual`, which is `balance - totalRewardsDeposited` — the
USDC that newly arrived in the contract.

In `emergencyWithdraw` no USDC moves out for the forfeited portion. The user gets their stake
back; the forfeited rewards stay in the contract. Decrementing `totalRewardsDeposited` by
`forfeited / REWARD_SCALAR` therefore understates the real liability, which has two effects:

1. **Integer-division dust double-counted as reserved.** Forfeits where
   `forfeited % REWARD_SCALAR != 0` round the decrement down. The 18-dec side loses the full
   `forfeited` from `reservedBalance`, but the 6-dec side loses less (or zero, when
   `forfeited < REWARD_SCALAR`). The gap is a permanent over-reservation: up to
   `REWARD_SCALAR - 1` scaled-wei per forfeit event.
2. **`depositRewards` recycle double-count.** The contract's USDC balance still includes the
   forfeited 6-dec portion (it never left). Next `depositRewards` computes
   `actual = balance - totalRewardsDeposited`. Since we already subtracted from
   `totalRewardsDeposited`, the same USDC is booked twice — once when forfeited, once when
   recycled — pushing `reservedBalance` above the USDC that actually backs it.

The intended recycling mechanism (comment at lines 162-164) works correctly *without* the
`totalRewardsDeposited` decrement: `reservedBalance -= forfeited` releases the accrual
slot, and the next `depositRewards` picks up the freed USDC via the balance diff.

### Invariant to enforce

```
reservedBalance <= totalRewardsDeposited * REWARD_SCALAR
```

This must hold after every external entry on TortoiseShell. It's a tighter version of
"the contract can pay out everything it claims to reserve."

### Fix

Remove the `totalRewardsDeposited` decrement from `emergencyWithdraw`. The forfeited USDC
stays in the contract, still tracked by `totalRewardsDeposited`, and gets picked up on the
next `depositRewards` via the existing `balance - totalRewardsDeposited` reconciliation.

```solidity
// Before (lines 165-170):
uint256 forfeited = userUnpaidRewards[msg.sender];
if (forfeited > 0) {
    reservedBalance -= forfeited;
    totalRewardsDeposited -= forfeited / REWARD_SCALAR;
    userUnpaidRewards[msg.sender] = 0;
}

// After:
uint256 forfeited = userUnpaidRewards[msg.sender];
if (forfeited > 0) {
    reservedBalance -= forfeited;
    userUnpaidRewards[msg.sender] = 0;
    // totalRewardsDeposited is NOT decremented: no USDC left the contract.
    // The forfeited USDC will be recycled into the next reward period via
    // depositRewards (balanceOf - totalRewardsDeposited sees it as excess).
}
```

Update the NatSpec block above (lines 162-164) to match the corrected flow.

### Why this is safe

- `reservedBalance` correctly releases the forfeited user's accrual slot; other stakers are
  unaffected (their `userRewardPerTokenPaid` snapshots are unchanged).
- `totalRewardsDeposited` continues to represent "6-dec USDC owed by the contract." The
  forfeited amount *is* still owed — to the reward pool as a whole, to be redistributed.
- Next `depositRewards` sees `balance - totalRewardsDeposited == 0 + forfeitedUsdcPortion`,
  which flows into `_addReward(actual)` and either extends the period (if above the floor
  pooled with `_queuedReward`) or pools into `_queuedReward`.

---

## Finding 2 — _flushQueuedReward bypasses MIN_REWARD_DEPOSIT on emergency-triggered requeues

### Root cause

`MIN_REWARD_DEPOSIT` (`TortoiseShell.sol:39`) was installed to raise the cost of
cap-and-extend griefing on `rewardRate`. In `_addReward` (lines 389-394) the floor correctly
gates a fresh deposit:

```solidity
uint256 pooled = reward + _queuedReward;
if (pooled < MIN_REWARD_DEPOSIT) {
    _queuedReward = pooled;
    return;
}
```

But `_flushQueuedReward` (lines 408-424), called from `stake` and `creditStake`, flushes
**any** positive `_queuedReward` unconditionally. The rationale is reasonable for the
"rewards queued while totalStaked was zero" case — stakers arriving should activate
pending rewards. The problem is that **`emergencyWithdraw` and `_withdraw` both push
remaining mid-period rewards into `_queuedReward` when the last staker exits** (lines
177-185 and 346-354):

```solidity
if (totalStaked == 0 && block.timestamp < periodFinish) {
    uint256 remaining = (periodFinish - block.timestamp) * rewardRate;
    if (remaining > 0) {
        _queuedReward += remaining;
        reservedBalance -= remaining;
        rewardRate = 0;
        periodFinish = block.timestamp;
    }
}
```

This can queue an arbitrarily small `remaining` — e.g. 1 second before `periodFinish`, or a
period that had already decayed through most of its drip. The next single-wei `stake(1)`
flushes this sub-floor amount into a full fresh `rewardDuration` period, exactly the dilution
shape `MIN_REWARD_DEPOSIT` was meant to prevent.

Independently, this creates a griefer race: an observer who sees the last emergency exit
can front-run the intended next staker with `stake(1)` and capture the entire queued pool
as a disproportionate share-of-pool.

### Why the naive fix (gate flush on floor) is wrong

Naively adding `if (queued < MIN_REWARD_DEPOSIT) return;` to `_flushQueuedReward` creates a
different failure: sub-floor queued rewards become permanently unflushable unless someone
tops up `_queuedReward` via a new `depositRewards` that crosses the floor when pooled. In
low-activity periods this can trap user rewards indefinitely.

### Fix — two-part

**Part A: gate `_flushQueuedReward` on the floor, but retain an aged-queue escape.**

Track when the queue was last topped up and allow a flush regardless of the floor once the
queue has aged past `rewardDuration`. Any queued amount that has sat for a full period is
expected to drip; starving it further is strictly worse than the dilution concern.

```solidity
uint256 internal _queuedRewardUpdatedAt; // timestamp of last _queuedReward mutation

// In _addReward, on the sub-floor branch:
if (pooled < MIN_REWARD_DEPOSIT) {
    _queuedReward = pooled;
    _queuedRewardUpdatedAt = block.timestamp;
    return;
}

// In emergencyWithdraw / _withdraw when queuing remaining:
_queuedReward += remaining;
_queuedRewardUpdatedAt = block.timestamp;

// In _flushQueuedReward:
function _flushQueuedReward() internal {
    uint256 queued = _queuedReward;
    if (queued == 0) return;
    bool aged = block.timestamp >= _queuedRewardUpdatedAt + rewardDuration;
    if (queued < MIN_REWARD_DEPOSIT && !aged) {
        return; // leave queued; next qualifying deposit flushes it
    }
    _queuedReward = 0;
    _queuedRewardUpdatedAt = 0;
    // ... rest of existing flush logic unchanged ...
}
```

**Part B: don't requeue when the remaining amount is dust.**

In `emergencyWithdraw` and `_withdraw`, skip the requeue for sub-second-drip dust. If
`remaining < REWARD_SCALAR` (i.e. less than 1 native USDC unit after descale), leaving it in
`reservedBalance` and letting the next `depositRewards` reconcile is cleaner than requeueing
amounts that will never meaningfully drip. The choice here is a value judgement — Part A
already fixes the exploitability. Part B is optional tightening.

### Recommended: implement Part A only

Part A is the minimum change that closes the dilution-via-emergency-exit shape without
opening a permanent-trap failure mode. Part B is nice-to-have but adds branching and a new
implicit threshold. Defer Part B unless operational data shows meaningful dust accumulation.

### Why this is not circular with audit-8's acceptance

Audit-8 accepted `_flushQueuedReward` windfall capture as "documented intended behavior."
That acceptance was in the context of rewards queued because `totalStaked == 0` during a
normal deposit — the "nobody was staking when funds arrived" case. The emergency-exit
requeue path was not evaluated against MIN_REWARD_DEPOSIT at that time (audit-8 predates
the MIN_REWARD_DEPOSIT floor, added in commit `8e45ebf` — TortoiseShell: MIN_REWARD_DEPOSIT
floor guards rewardRate dilution).

The finding is: **MIN_REWARD_DEPOSIT's protection is porous at the queue-flush boundary
whenever queuing was triggered by an exit rather than by a small deposit.** Part A closes
that without re-litigating audit-8's accepted semantics.

---

## Implementation order

1. **Finding 1** — remove `totalRewardsDeposited` decrement in `emergencyWithdraw`; update
   NatSpec. One-line delete + comment rewrite; lowest-risk change.
2. **Finding 2 Part A** — add `_queuedRewardUpdatedAt`; gate `_flushQueuedReward` on floor
   with age-escape; update `_addReward` and both exit paths to stamp the timestamp.

---

## Tests to add

### Finding 1

- `test_emergencyWithdraw_preservesTotalRewardsDeposited` — verify `totalRewardsDeposited`
  is unchanged before/after an `emergencyWithdraw` with `forfeited > 0`.
- `test_emergencyWithdraw_forfeitRecyclesViaDepositRewards` — emergency exit with forfeit,
  then `depositRewards(0)` with no new USDC; verify the forfeited 6-dec portion flows
  into `_queuedReward` or `reservedBalance` via the balance-diff path.
- **Invariant test (Foundry invariant harness):**
  `invariant_reservedBalanceDoesNotExceedTotalDeposited` — across a fuzz run of
  stake/withdraw/deposit/claim/emergencyWithdraw sequences, assert
  `reservedBalance <= totalRewardsDeposited * REWARD_SCALAR` after every call.

### Finding 2 Part A

- `test_flushQueuedReward_skipsSubFloorWhenNotAged` — emergency-exit requeue of
  `remaining < MIN_REWARD_DEPOSIT`, re-stake within `rewardDuration`; assert `rewardRate`
  and `periodFinish` unchanged, `_queuedReward` still holds the amount.
- `test_flushQueuedReward_flushesSubFloorAfterAging` — same setup, warp past
  `rewardDuration`, re-stake; assert flush happened.
- `test_addReward_stampsQueuedRewardUpdatedAt` — sub-floor deposit, verify timestamp is
  set; subsequent top-up to above-floor clears the timestamp.
- Regression: `test_flushQueuedReward_flushesImmediatelyWhenAboveFloor` — existing audit-8
  windfall-capture path should still work for above-floor queued rewards.

---

## Verification

```bash
forge build
forge test --match-contract AuditRemediationTest -v
forge test --match-test invariant_reservedBalance -v
forge test -v  # full suite
```

---

## Status

- **Finding 1:** LAND. One-line fix; write the invariant test first, then fix.
- **Finding 2:** LAND Part A. Part B deferred pending operational data.
- **Findings rejected as circular:** see cross-check table at top. No action.
