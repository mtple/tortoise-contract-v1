# Audit #6 Remediation Plan

Source: Independent security review — TortoiseV1 + TortoiseShell  
Date: 2026-04-13  
Confidence threshold applied: 80

---

## Finding Assessment

### [90] Finding 1 — Per-call fees let self-minting artist drain tortPool

**Verdict: IMPLEMENT FIX**

`mintSong` charges a single flat `platformFee + stakingFee` regardless of `quantity`.
An artist minting 100 000 copies to themselves pays ~$0.15 in fees but receives
`100_000 × tortRewardPerCollection` TORT from the owner-funded pool.

Fix: multiply both fees by quantity so cost scales linearly with copies minted.
Also update `calculateTotalCost` view to match, and cap the fee multiplication to
prevent overflow (fees are `uint64`, quantity `uint256` max 100 000 — product fits
in `uint256` easily, no special handling needed).

---

### [85] Finding 2 — creditStake dilutes existing stakers

**Verdict: IMPLEMENT FIX (simplified)**

The audit proposes a `creditedBalance` split that would require rebuilding `_withdraw`,
`earned`, `exit`, and the staker accounting throughout. That redesign is too invasive
and likely to introduce new bugs.

The root economic problem is solved by Finding 1's fix: once fees scale with quantity
the subsidy-to-fee ratio is constant and there is no profitable attack surface.
The dilution effect (credited TORT inflating `totalStaked`) remains but is proportional
to fees paid, which is acceptable because the same is true of normal stakes.

**No code change for Finding 2 beyond what Finding 1 already closes.**

---

### [85] Finding 3 — withdrawTortPool frontrun / silent loss of stakingFee

**Verdict: IMPLEMENT FIX (partial — refund path, no revert)**

Real issue: when `tortPool == 0`, the stakingFee USDC is transferred to Shell and
distributed as USDC yield to existing stakers, but the collector receives no TORT.
The proposed fix (reverting `creditStake`) would break the explicit graceful-degradation
design (try/catch in `_creditShell`).

Better approach: in `TortoiseV1._distributePayments`, skip sending the stakingFee
to Shell when the pool has insufficient TORT to credit any amount. This avoids the
silent loss without breaking the non-blocking mint design.

Concretely: call a new `ITortoiseShell.canCredit(quantity)` view before forwarding
the fee, or (simpler) only forward if `tortPool > 0`. If the pool is empty the
stakingFee stays in the V1 contract (accounted as platform fee), and no attempt is
made to call `creditStake`.

**Implementation: add `tortPoolBalance()` check in V1 before forwarding stakingFee.**

---

### [82] Finding 4 — Every mint resets periodFinish

**Verdict: DEFER / ACCEPT RISK**

The scenario requires a griefer to pay real USDC (~$0.15/tx on Base) per spam mint.
The economic incentive is weak and the fix proposed (two-path emission) is complex enough
to warrant its own audit. The concern is real but low practical severity at current fee
levels.

Accepted risk. Will revisit if `MIN_SONG_PRICE` is reduced or fee structure changes.

---

### [82] Finding 5 — Blocklisted USDC recipient bricks mints for locked split

**Verdict: IMPLEMENT FIX**

A single USDC-blocklisted address in a locked split list permanently DoS-es all future
mints for that song (and by extension the staking fee and platform fee too). The
pull-payment pattern fix is the correct response: attempt the transfer, and on failure
record a pending claim rather than reverting.

Requires:
- `pendingClaims[songId][recipient]` mapping in TortoiseV1
- `claimPending(songId)` external function for deferred recipients
- `SplitPaymentDeferred` event
- Low-level `call` instead of `safeTransfer` for split payments (platform fee and
  staking fee are unaffected — platform fee stays in contract, staking fee goes to Shell
  which is owner-configured and not user-supplied)

---

### [82] Finding 6 — addAuthorizedCaller no contract check

**Verdict: IMPLEMENT FIX**

Trivial: add `require(caller.code.length > 0)` to `addAuthorizedCaller`.
An EOA authorized by mistake could call `creditStake` directly to drain `tortPool`.

---

### [80] Finding 7 — Single-step ownership

**Verdict: IMPLEMENT FIX**

Upgrade both contracts from `Ownable` to `Ownable2Step` and disable `renounceOwnership`.
`withdrawPlatformFees` and `withdrawTortPool` are the critical gates. A transfer-typo
would lock accumulated USDC and TORT permanently.

---

### [80] Finding 8 — Paused Shell blocks claims while forcing new credits

**Verdict: IMPLEMENT FIX**

`claimRewards` and `exit` are `whenNotPaused` but `creditStake` and `depositRewards`
are not. During a pause, mints continue crediting and dripping rewards to users who
cannot claim or exit (only `emergencyWithdraw` which forfeits rewards is available).

Fix: remove `whenNotPaused` from `claimRewards` and `exit`. New stake entry (`stake`)
and new reward injection (`depositRewards`) should remain pause-gated.

---

## Implementation Order

1. **Shell: Ownable2Step** (Finding 7) — touches imports/inheritance only
2. **V1: Ownable2Step** (Finding 7) — same
3. **Shell: addAuthorizedCaller contract check** (Finding 6)
4. **Shell: remove whenNotPaused from claimRewards/exit** (Finding 8)
5. **V1+Shell: per-quantity fees** (Finding 1) — update mintSong, calculateTotalCost, _distributePayments
6. **V1: skip stakingFee when tortPool insufficient** (Finding 3)
7. **V1: pull-payment for blocklisted split recipients** (Finding 5)

---

## Tests to Add / Update

- Finding 1: test that minting N copies costs N × (platformFee + stakingFee)
- Finding 1: test that calculateTotalCost matches mintSong charge
- Finding 3: test that stakingFee is NOT forwarded when tortPool == 0
- Finding 5: test that a blocked recipient defers payment; other splits still pay; claimPending works
- Finding 6: test that addAuthorizedCaller reverts for EOA
- Finding 7: test that renounceOwnership reverts; transferOwnership requires two steps
- Finding 8: test that claimRewards and exit work while paused; stake still blocked
