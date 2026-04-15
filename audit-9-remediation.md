# Audit #9 Remediation Plan

Source: Independent security review — TortoiseV1 + TortoiseShell (Pass 4)
Date: 2026-04-15
Confidence threshold applied: 80

---

## Finding Assessment

| # | Conf | Title | Verdict |
|---|------|-------|---------|
| 1 | [85] | `_creditShell` fires unconditionally when staking fee was orphaned to `platformFeesAccrued` | **IMPLEMENT** |
| 2 | [82] | `_creditShell` has no `stakingFee > 0` guard — zero-fee config drains `tortPool` for free | **IMPLEMENT** (merged with #1) |

### Leads acted on

| Lead | Verdict |
|------|---------|
| `_transferOrDefer` never refreshes `pendingClaimDeferredAt` on additional deferrals | **ACCEPT** — clock is per-address, not per-payment; 90-day window is intended as "time for blocklist detection", not a per-payment claim window. No extraction path exists without admin trust. |
| `rerouteBlockedClaim` chained second-hop bypasses `REROUTE_DELAY` for subsequent hops | **ACCEPT** — first hop still enforces the full 90 days protecting the original recipient. Subsequent admin shuffles are explicitly within admin trust scope. Not a bug. |
| ERC1155 `onERC1155Received` callback re-queues rewards when recipient becomes sole staker | **ACCEPT** — not a profit path; `_creditShell` already runs before `_mint` (CEI order). Requeued rewards go to the next depositor, not the triggering minter. Documented behavior. |
| `recoverTokens` on Shell blocks staking token — mis-sent TORT unrecoverable | **ACCEPT** — orthogonal to current scope; direct-sent TORT is a self-harm case. Noted for future lifecycle tooling. |
| `setTortRewardPerCollection` has no upper bound or cross-contract consistency check | **ACCEPT** — sub-market under-pricing is a parameter-management concern, not a security bug. Findings #1–#2 close the extreme zero-fee case. |

---

## Root Cause

`_distributePayments` (added in audit-7) evaluates a pool-sufficiency gate before forwarding the
staking fee. When the gate fails, the staking fee is orphaned to `platformFeesAccrued` instead of
being sent to Shell. However, `_creditShell` — called unconditionally in `_processMint` after
`_distributePayments` — was never updated to respect the same gate. This creates two exploitable
mismatches:

**Finding 1 (pool-insufficient path):** When `tortPool < quantity × rate`, the staking fee stays
in V1 as platform revenue, but `_creditShell` still calls `Shell.creditStake`. Shell's
`creditStake` clamps `credited = min(quantity × rate, tortPool)` and debits whatever is left in
the pool. Stakers receive nothing (no USDC was deposited), platform collects the fee, and the
buyer still drains the TORT pool. The pre-check comment explicitly says this case should prevent
partial credit — the invariant is broken.

**Finding 2 (zero-fee path):** When `stakingFee == 0` (constructor allows it with a non-zero
shell; `updateStakingFee(0)` preserves the shell address), `_distributePayments` skips the
staking branch entirely (guarded by `stakingFeeAmount > 0`). But `_creditShell` only checks
`shell == address(0)`, so with `tortRewardPerCollection > 0` every mint debits
`quantity × tortRewardPerCollection` from the TORT pool and credits the buyer — with zero USDC
flowing to stakers. An owner deploying with `stakingFee == 0` or calling `updateStakingFee(0)`
inadvertently enables free TORT extraction until the pool is drained.

---

## Fix

The cleanest implementation is to have `_distributePayments` return a `bool stakingFeeForwarded`
and gate `_creditShell` on that value in `_processMint`. This avoids re-querying Shell state and
keeps the decision co-located with the fee routing logic.

### Change `_distributePayments` to return `bool`

```solidity
function _distributePayments(
    uint256 songId,
    uint256 quantity,
    uint256 totalCost,
    uint256 platformFeeAmount,
    uint256 stakingFeeAmount,
    ContractConfig memory cfg
) internal returns (bool stakingFeeForwarded) {
    IERC20 usdc = IERC20(cfg.usdcToken);

    if (platformFeeAmount > 0) {
        platformFeesAccrued += platformFeeAmount;
        emit PaymentDistributed(songId, address(this), platformFeeAmount, true);
    }

    if (stakingFeeAmount > 0 && cfg.tortoiseShell != address(0)) {
        ITortoiseShell shell = ITortoiseShell(cfg.tortoiseShell);
        uint256 rate = shell.tortRewardPerCollection();
        uint256 required = quantity * rate;
        if (rate > 0 && shell.getTortPoolBalance() >= required) {
            usdc.safeTransfer(cfg.tortoiseShell, stakingFeeAmount);
            try shell.depositRewards(stakingFeeAmount) {
                emit StakingFeeDistributed(songId, stakingFeeAmount);
            } catch (bytes memory reason) {
                emit StakingFeeAbsorbed(songId, stakingFeeAmount, reason);
            }
            stakingFeeForwarded = true;   // ← new
        } else {
            platformFeesAccrued += stakingFeeAmount;
            // stakingFeeForwarded remains false
        }
    }
    // stakingFeeAmount == 0 also leaves stakingFeeForwarded == false
    // (no fee paid, no credit owed)

    // ... artist revenue distribution unchanged ...
}
```

### Gate `_creditShell` in `_processMint`

```solidity
function _processMint(...) internal {
    ...
    uint256 scaledPlatformFee = uint256(cfg.platformFee) * quantity;
    uint256 scaledStakingFee  = uint256(cfg.stakingFee)  * quantity;
    bool feeForwarded = _distributePayments(
        songId, quantity, totalCost, scaledPlatformFee, scaledStakingFee, cfg
    );
    if (feeForwarded) {
        _creditShell(songId, actualRecipient, quantity, cfg.tortoiseShell);
    }
    _mint(actualRecipient, songId, quantity, "");
    ...
}
```

This handles both findings with one change:
- Finding 1: gate is `false` when pool insufficient → no credit, pool not drained
- Finding 2: gate is `false` when `stakingFee == 0` → no credit, pool not drained

No `_creditShell` internal change is required. The existing `try/catch` inside it handles auth
failures independently and is unaffected.

---

## Implementation Order

1. Change `_distributePayments` return type from `void` to `bool stakingFeeForwarded`
2. Add `stakingFeeForwarded = true` in the branch where fee is actually forwarded
3. Capture the return value in `_processMint` and gate `_creditShell` on it

---

## Tests to Add

| Finding | Test |
|---------|------|
| 1 | `test_creditShell_skippedWhenPoolInsufficient` — pool < quantity × rate; assert no StakeCredited event and tortPool unchanged |
| 1 | `test_creditShell_skippedWhenRateIsZero` — rate == 0; assert no StakeCredited event |
| 2 | `test_creditShell_skippedWhenStakingFeeIsZero` — stakingFee == 0 with funded pool; assert no StakeCredited event and tortPool unchanged |
| 1+2 | `test_creditShell_firedWhenFeeForwarded` — normal path; confirm StakeCredited still fires (regression guard) |

---

## Verification

```bash
forge build
forge test --match-contract AuditRemediationTest -v
forge test -v
```
