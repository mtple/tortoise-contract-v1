# Audit #7 Remediation Plan

Source: Independent security review — TortoiseV1 + TortoiseShell (Pass 2)
Date: 2026-04-15
Confidence threshold applied: 80

---

## Finding Assessment

| # | Conf | Title | Verdict |
|---|------|-------|---------|
| 1 | [92] | withdrawPlatformFees sweeps pendingClaims | **IMPLEMENT** |
| 2 | [90] | poolHasFunds > 0 charges full fee for partial/0 TORT credit | **IMPLEMENT** (merged with #7) |
| 3 | [88] | mintSong missing maxTotalCost slippage guard | **IMPLEMENT** (overload, not breaking change) |
| 4 | [70↓] | _processMint ordering forward-tax | **DEFER** — Synthetix drip is working as designed |
| 5 | [82] | Unwrapped depositRewards bricks mints after missed auth | **IMPLEMENT** |
| 6 | [82] | Missing EIP-2981 | **DEFER** — feature addition, separate workstream |
| 7 | [80] | tortRewardPerCollection == 0 charges fees with no credit | **IMPLEMENT** (merged with #2) |
| 8 | [80] | mintSong recipient strands TORT at dead addresses | **DEFER** — gift mints are valid; Option A too restrictive |

---

## Changes

### 1. Track platformFeesAccrued separately (Finding 1)

**Root cause:** `withdrawPlatformFees` sweeps `balanceOf(address(this))`, which now includes
`pendingClaims` USDC and orphaned stakingFees (pool-empty case). If the owner withdraws while
pending claims exist, `claimPending` reverts with insufficient balance.

**TortoiseV1.sol — add state:**
```solidity
uint256 public platformFeesAccrued;
```

**In `_distributePayments`**, increment when the platform fee is recorded:
```solidity
if (platformFeeAmount > 0) {
    platformFeesAccrued += platformFeeAmount;
    emit PaymentDistributed(songId, address(this), platformFeeAmount, true);
}
```

Also increment when the stakingFee is orphaned (pool insufficient):
```solidity
// pool-insufficient branch: stakingFee stays in contract as platform revenue
platformFeesAccrued += stakingFeeAmount;
```

**`withdrawPlatformFees`** — withdraw from accrued tracker, not balanceOf:
```solidity
function withdrawPlatformFees() external onlyOwner nonReentrant {
    uint256 amount = platformFeesAccrued;
    require(amount > 0, "No fees to withdraw");
    platformFeesAccrued = 0;
    IERC20(config.usdcToken).safeTransfer(owner(), amount);
    emit PlatformFeesWithdrawn(owner(), amount);
}
```

Note: the existing `AuditRemediation.test_withdrawPlatformFees_sweepsStrayUsdc` test explicitly
locks in "owner sweeps everything including donations." That behavior is now intentionally changed:
stray USDC sent to the contract is no longer swept. The test needs updating.

---

### 2+7. Tighten pool-sufficiency gate to quantity × rate (Findings 2 + 7)

**Root cause:** `getTortPoolBalance() > 0` is a boolean check that passes even when the pool has
1 wei of TORT but `quantity × tortRewardPerCollection` requires 10,000 TORT. `creditStake`
silently clamps the shortfall; collector pays full stakingFee for partial or zero TORT credit.
Also catches the `tortRewardPerCollection == 0` mis-configuration case.

**`ITortoiseShell.sol`** — add view to interface:
```solidity
function tortRewardPerCollection() external view returns (uint256);
```

**`TortoiseV1._distributePayments`** — replace boolean gate:
```solidity
// Replace:
bool poolHasFunds = ITortoiseShell(cfg.tortoiseShell).getTortPoolBalance() > 0;
if (poolHasFunds) {

// With:
uint256 rate = ITortoiseShell(cfg.tortoiseShell).tortRewardPerCollection();
uint256 required = quantity * rate;
if (rate > 0 && ITortoiseShell(cfg.tortoiseShell).getTortPoolBalance() >= required) {
```

`_distributePayments` doesn't currently receive `quantity` — it receives pre-scaled fee amounts.
Add `quantity` as a parameter, or compute `required` from `stakingFeeAmount / cfg.stakingFee`
(integer division gives back quantity). Cleanest: pass `quantity` explicitly.

Update `_distributePayments` signature:
```solidity
function _distributePayments(
    uint256 songId,
    uint256 quantity,           // NEW — needed for pool sufficiency check
    uint256 totalCost,
    uint256 platformFeeAmount,
    uint256 stakingFeeAmount,
    ContractConfig memory cfg
) internal
```

Update the call in `_processMint` to pass `quantity`.

---

### 3. Add slippage-protected mintSong overload (Finding 3)

**Root cause:** `totalCost = (price + platformFee + stakingFee) * quantity` is read from mutable
config at execution time. An owner can front-run a pending mint with a fee increase up to
`MAX_PLATFORM_FEE` ($1.00) + `MAX_STAKING_FEE` ($1.00), draining up to `$2 × quantity` extra
from an unlimited approval.

**Approach:** Add an overload rather than change the existing signature, to avoid breaking
current integrators.

```solidity
/// @notice Slippage-protected mint. Reverts if cost has risen above maxTotalCost.
function mintSong(
    uint256 songId,
    uint256 quantity,
    address recipient,
    uint256 maxTotalCost
) external nonReentrant whenNotPaused {
    _validateMint(songId, quantity);
    ContractConfig memory cfg = config;
    uint256 totalCost = (uint256(songs[songId].price) + cfg.platformFee + cfg.stakingFee) * quantity;
    require(totalCost <= maxTotalCost, "Slippage: cost exceeds max");
    IERC20(cfg.usdcToken).safeTransferFrom(msg.sender, address(this), totalCost);
    _processMint(songId, quantity, recipient, totalCost, cfg);
}
```

The existing `mintSong(songId, quantity, recipient)` is unchanged for backward compatibility.

---

### 5. Wrap depositRewards in try/catch (Finding 5)

**Root cause:** `depositRewards` is called without try/catch in `_distributePayments` (line 349),
but `creditStake` (same authorization surface) is already wrapped. A shell rotation where
`addAuthorizedCaller` is missed causes `UnauthorizedCaller()` to revert the entire mint.

Shell's `depositRewards` already reconciles via `balanceOf - totalRewardsDeposited`, so if the
call is skipped the USDC sits in Shell until the next authorized `depositRewards` call picks it
up. Wrapping in try/catch is safe.

Add new event to TortoiseV1:
```solidity
event StakingFeeDeferred(uint256 indexed songId, uint256 amount, bytes reason);
```

Replace the unwrapped call in `_distributePayments`:
```solidity
// Replace:
usdc.safeTransfer(cfg.tortoiseShell, stakingFeeAmount);
ITortoiseShell(cfg.tortoiseShell).depositRewards(stakingFeeAmount);
emit StakingFeeDistributed(songId, stakingFeeAmount);

// With:
usdc.safeTransfer(cfg.tortoiseShell, stakingFeeAmount);
try ITortoiseShell(cfg.tortoiseShell).depositRewards(stakingFeeAmount) {
    emit StakingFeeDistributed(songId, stakingFeeAmount);
} catch (bytes memory reason) {
    emit StakingFeeDeferred(songId, stakingFeeAmount, reason);
}
```

Note: the USDC is already transferred to Shell before the try. On catch, the USDC sits in Shell
and will be reconciled on the next successful `depositRewards` call (the balanceOf-diff mechanism
in Shell handles this). Do NOT move the transfer inside the try block — that would require
reverting the transfer on failure, which reintroduces the DoS.

---

## Implementation Order

1. **Finding 1** — `platformFeesAccrued` tracker + update `withdrawPlatformFees`
2. **Findings 2+7** — pool-sufficiency gate, pass `quantity` into `_distributePayments`, update interface
3. **Finding 5** — wrap `depositRewards` in try/catch
4. **Finding 3** — add `mintSong(songId, quantity, recipient, maxTotalCost)` overload

---

## Tests to Add / Update

| Finding | Test |
|---------|------|
| 1 | `test_withdrawPlatformFees_doesNotSweepPendingClaims` — defer a payment, then withdraw; pending claim still intact |
| 1 | `test_withdrawPlatformFees_includesOrphanedStakingFee` — drain pool, mint; orphaned fee appears in accrued and is withdrawable |
| 1 | Update `test_withdrawPlatformFees_sweepsStrayUsdc` — stray USDC no longer swept by withdrawPlatformFees |
| 2+7 | `test_stakingFee_notForwardedWhenPoolInsufficientForQuantity` — pool has some TORT but < quantity × rate |
| 2+7 | `test_stakingFee_notForwardedWhenRateIsZero` — tortRewardPerCollection == 0 |
| 3 | `test_mintSong_slippage_revertsWhenCostExceedsMax` |
| 3 | `test_mintSong_slippage_succeedsAtExactMax` |
| 5 | `test_depositRewards_mintSucceedsWhenShellUnauthorized` — verify StakingFeeDeferred emitted, mint doesn't revert |

---

## Verification

```bash
forge build
forge test --match-contract AuditRemediationTest -v
forge test -v  # full suite
```
