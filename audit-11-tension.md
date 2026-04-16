# Audit #11 — Design Tension (NOT a straight remediation)

Source: Independent security review — TortoiseV1 + TortoiseShell (Pass 6)
Date: 2026-04-16
Confidence threshold applied: 80

---

## ⚠️ Why this doc is different

This pass surfaced what appears to be a regression introduced by audit-10's
remediation. On closer inspection it is not a regression but a **design
tension**: the single `pendingClaimDeferredAt` timestamp is being asked to
carry two contradictory semantics. Remediating the new finding with the
obvious "set-when-zero" fix would roll back audit-10 exactly and re-expose
the bug audit-10 closed. We must break the cycle before landing any code.

---

## The cycle

| Pass | Fix | Closes | Opens |
|------|-----|--------|-------|
| Audit 8 (initial) | set-when-zero (first-deferral semantics) | — | audit-10 attack |
| Audit 10 (fix) | always-refresh (last-deferral semantics) | audit-10 | audit-11 attack |
| Audit 11 (this) | set-when-zero | audit-11 | audit-10 attack |

The two attacks:

**Attack A — audit-10 (closed by audit-10 remediation):**
Dust $10 deferred to blocklisted R at T=0 under set-when-zero → `deferredAt = T0`.
$10,000 legitimate payment deferred to same R at T=T0+100d → timer not refreshed.
Admin can call `rerouteBlockedClaim` immediately at T=T0+100d because
`T0+100d >= T0 + 90d` and seize the $10,000 that has had zero claim window.

**Attack B — audit-11 (this pass, introduced by audit-10's always-refresh):**
Blocklisted R has accumulated $X of legitimate deferred pending claim.
Any minter calls `mintSong` with R as a split recipient, deferring dust.
`deferredAt` resets on every mint. Since `mintSong` is permissionless and songs
can have unlimited supply, an attacker paying ~$0.15 per mint every ~89 days
(≈ $0.61/year) perpetually prevents `rerouteBlockedClaim` from firing —
permanently trapping arbitrary $X in the contract. Admin's only workaround is
a 90-day full-protocol `pause()`, halting every artist's revenue.

Both attacks are real. One timer cannot protect against both directions.

---

## Threat model matrix

The single-timer scheme was trying to protect two things:

| Property | Invariant needed | Timer semantics |
|----------|------------------|-----------------|
| **P1.** Recipient always gets ≥90d to self-claim | Timer anchored to oldest unclaimed dollar | first-deferral (set-when-zero) |
| **P2.** Admin can eventually recover from permanent blocklist | Timer must eventually mature in bounded time | last-deferral (always-refresh) |

These are contradictory under permissionless mint activity. P1 wants the
timer to stay put; P2 wants the timer to reset.

Audit-8 picked P1. Audit-10 picked P2. Neither pick satisfies the other.

---

## Options considered

### Option 1 — Accept pass-6 Finding #1 (roll back to set-when-zero) and add a `claimPending` timer-zeroing step

Land set-when-zero in `_transferOrDefer`; add `pendingClaimDeferredAt[...][r] = 0`
in `claimPending`'s success branch so fresh post-claim deferrals correctly
stamp `block.timestamp`.

**Closes:** Audit-11 DoS (griefers can't reset the timer).
**Re-opens:** Audit-10 attack on the subset of recipients who have a stale
timer that has already elapsed AND have never drained via `claimPending`. This
subset is smaller than full audit-10 exposure but non-zero — e.g. a recipient
who was blocklisted before their first claim, whose dust timer elapses, then
receives a large fresh deferral.

**Residual exposure:** Admin can seize the fresh deferral immediately.
Requires admin malice or compromise. Analogous to the original audit-10 bug.

**Verdict:** Straight roll-back. **Do not pick.** This is the circular fix
flagged at the top of this doc.

---

### Option 2 — Two-timestamp scheme: track both first and last

```solidity
mapping(uint256 => mapping(address => uint256)) public pendingClaimFirstDeferredAt;
mapping(uint256 => mapping(address => uint256)) public pendingClaimLastDeferredAt;
```

- `_transferOrDefer`: stamp `first` only when pendingClaims was 0; always stamp `last`.
- `claimPending` success: zero both.
- `rerouteBlockedClaim` gate: `require(block.timestamp >= last + REROUTE_DELAY)`
  (bounded from most recent deferral) **AND** optionally `>= first + REROUTE_DELAY`
  (recipient had full window from oldest dollar).

**Closes:** Audit-10 (always-refresh `last` timer means fresh deferrals can't
inherit an elapsed clock). Audit-11 partial — griefer still resets `last` on
every dust mint, so admin must wait 90d from the most recent dust. This is
the same DoS as audit-11 but reframed.

**Verdict:** Two timestamps but same fundamental tension. **Do not pick.**

---

### Option 3 — Per-deferral FIFO queue with per-entry timestamps

```solidity
struct DeferredEntry { uint128 amount; uint128 deferredAt; }
mapping(uint256 => mapping(address => DeferredEntry[])) public pendingQueue;
```

- Every deferral pushes a new entry.
- `claimPending` drains all entries atomically.
- `rerouteBlockedClaim` moves only entries whose individual `deferredAt >= REROUTE_DELAY` ago.

**Closes:** Both attacks simultaneously. Recipient always gets 90d per
payment; admin can reroute aged entries even while fresh dust keeps landing.

**Cost:**
- Unbounded gas for `claimPending` on a recipient with many entries.
  Mitigation: `maxEntriesPerClaim` parameter + paginated claims.
- Unbounded storage growth. Griefer can cheap-spam deferrals to balloon
  the queue and brick `claimPending` via gas limit.
- Significant implementation complexity; deferral path is currently ~8 lines,
  this turns it into stateful queue management across three functions.
- Changes the `pendingClaims` storage layout — not drop-in.

**Verdict:** Correct in theory. **Heavy** — warrants its own design review,
fuzz tests, and a tests-first refactor. Good candidate if the trapped-funds
threat model is high-value enough to justify the engineering cost.

---

### Option 4 — Timelock-proposed admin recovery (RECOMMENDED)

Decouple the timer from deferral events entirely. The admin explicitly
**proposes** a reroute; the proposal starts its own 90-day clock; any new
deferral to that recipient invalidates the proposal.

```solidity
struct RerouteProposal { address newRecipient; uint256 proposedAt; }
mapping(uint256 => mapping(address => RerouteProposal)) public pendingReroutes;

function proposeReroute(uint256 songId, address oldRecipient, address newRecipient)
    external onlyOwner
{
    require(pendingClaims[songId][oldRecipient] > 0, "Nothing to reroute");
    require(newRecipient != address(0) && newRecipient != oldRecipient, "Bad target");
    pendingReroutes[songId][oldRecipient] = RerouteProposal({
        newRecipient: newRecipient,
        proposedAt: block.timestamp
    });
    emit RerouteProposed(songId, oldRecipient, newRecipient);
}

function executeReroute(uint256 songId, address oldRecipient) external onlyOwner {
    RerouteProposal memory p = pendingReroutes[songId][oldRecipient];
    require(p.proposedAt != 0, "No proposal");
    require(block.timestamp >= p.proposedAt + REROUTE_DELAY, "Too soon");
    // Any new deferral since proposal invalidates it — enforced by
    // _transferOrDefer wiping the proposal whenever it defers more funds
    // to oldRecipient.
    uint256 amount = pendingClaims[songId][oldRecipient];
    require(amount > 0, "Nothing to reroute");
    pendingClaims[songId][oldRecipient] = 0;
    pendingClaims[songId][p.newRecipient] += amount;
    delete pendingReroutes[songId][oldRecipient];
    emit PendingClaimRerouted(songId, oldRecipient, p.newRecipient, amount);
}
```

And in `_transferOrDefer`, after updating `pendingClaims`, invalidate any
live proposal on that recipient:

```solidity
if (pendingReroutes[songId][recipient].proposedAt != 0) {
    delete pendingReroutes[songId][recipient];
    emit RerouteProposalInvalidated(songId, recipient);
}
```

**How it breaks the cycle:**

- **Audit-10 attack** (fresh deferral inheriting aged timer): The timer is on
  the *proposal*, not the deferral. A fresh deferral wipes the proposal, so
  admin has to re-propose and wait another 90 days. Closed.
- **Audit-11 attack** (griefer resetting timer with dust mints): Same
  mechanism — the griefer invalidates the proposal, forcing admin to re-wait,
  but the **griefer** now pays for the re-wait, not the **recipient**. The
  recipient is not harmed; they can still `claimPending` at any time.
  Crucially, the cost structure inverts: griefer must pay ~$0.15 per
  proposal-invalidation, and the admin can continuously re-propose.
  Each round costs griefer $0.15 and wastes admin one gas-fee of
  `proposeReroute`. Admin can outspend any realistic griefer on a
  large enough trapped balance.

**Remaining griefer leverage:** Can only *delay* admin recovery, not prevent
it. For a trapped balance of $X and griefer round-cost $0.15, griefer's
maximum profit from griefing is $X delay-cost — but the griefer has no way
to extract the $X. So there is no economic motive for a non-recipient
griefer. The recipient themselves as griefer can only delay funds they
can't access anyway. Pure spite has no extraction path.

**Additional properties:**
- `claimPending` continues to work at any time regardless of proposals.
- Proposals are a public state variable; recipient sees their reroute coming
  and has 90d to either self-claim (if unblocked) or negotiate off-chain.
- Each proposal emits an event; indexers/alerting trivially observable.

**Cost:**
- ~40 lines of new code across V1.
- One new struct, one new mapping, two new events.
- Two new functions, one internal invalidation hook in `_transferOrDefer`.
- `rerouteBlockedClaim` is replaced by the two-function version.
- Storage layout is additive — existing `pendingClaims` / `pendingClaimDeferredAt`
  stay (or `pendingClaimDeferredAt` can be removed since the timer now lives
  on the proposal).

**Verdict:** **Recommended.** Matches the real threat model (admin escape
from permanent blocklist), eliminates both attack directions, and the
griefer has no economic incentive because they can't extract the trapped
funds — only delay admin from recovering them.

---

## Decision

| Option | Closes audit-10 | Closes audit-11 | Complexity | Pick? |
|--------|----------------|-----------------|------------|-------|
| 1 — Set-when-zero + claimPending clear | ❌ partial | ✅ | Low | No (circular) |
| 2 — Two timestamps | ❌ | ❌ | Low | No (same tension) |
| 3 — Per-deferral queue | ✅ | ✅ | High | Maybe — if threat justifies |
| **4 — Propose/execute timelock** | ✅ | ✅ | Medium | **Yes** |

Recommendation: **Option 4.**

---

## Pass-6 findings — separable items (land regardless of the tension)

These items are orthogonal to the design tension and should be landed
whether Option 4 (or any other) is chosen:

### A. `claimPending` should clear `pendingClaimDeferredAt` on successful drain

Pass-6 Finding #2. Latent hazard today (benign under always-refresh) but
becomes live the moment any "set-when-zero" semantics is re-introduced in
any form. Free hygiene under any future design. Land it.

```diff
  function claimPending(uint256 songId, address recipient) external nonReentrant {
      uint256 amount = pendingClaims[songId][recipient];
      require(amount > 0, "Nothing to claim");
      pendingClaims[songId][recipient] = 0;
      (bool ok, bytes memory ret) = ...
      bool transferred = ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
      if (transferred) {
+         pendingClaimDeferredAt[songId][recipient] = 0;
          emit PaymentDistributed(songId, recipient, amount, false);
      } else {
          pendingClaims[songId][recipient] = amount;
          revert("Transfer failed; still claimable");
      }
  }
```

Clear only on transfer success. On failure, state (including timer) is
preserved via the explicit restore + revert.

### B. `rerouteBlockedClaim` should reject `oldRecipient == newRecipient`

Pass-6 LEAD. Calling with equal addresses clears `pendingClaims[old]`,
resets the timer, then re-adds the same amount — net effect is timer reset
with no fund movement. Admin-only footgun with no extraction path, but
trivially closable.

```diff
  function rerouteBlockedClaim(
      uint256 songId,
      address oldRecipient,
      address newRecipient
  ) external onlyOwner {
      require(newRecipient != address(0), "Zero recipient");
+     require(newRecipient != oldRecipient, "Self reroute");
      uint256 deferredAt = pendingClaimDeferredAt[songId][oldRecipient];
      require(block.timestamp >= deferredAt + REROUTE_DELAY, "Too soon");
      ...
  }
```

These two items are **safe to ship now** regardless of the design decision
on the main tension.

---

## Implementation order

1. **Land items A and B** above as audit-11 remediation commit (small,
   uncontroversial).
2. **Design review on Option 4** with at least one additional reviewer.
   Points to settle before implementing:
   - Should `executeReroute` be a single call or two-step (propose/confirm)?
   - Should the proposal-invalidation event surface enough data for
     off-chain alerting? (yes)
   - Interaction with `lockSplits` — does locking splits prevent the artist
     from ever changing the recipient set that feeds `_transferOrDefer`?
     (yes; this is already part of the `splitsLocked` guarantee)
   - Timelock parameter — keep 90 days or shorten? 90 days is current;
     Option 4's semantics are different enough that a shorter window may be
     acceptable since the recipient's pull path is still open the whole time.
3. **Implement Option 4** in a separate PR with:
   - Add new storage + events.
   - Replace `rerouteBlockedClaim` with `proposeReroute` / `executeReroute`.
   - Add invalidation hook in `_transferOrDefer`.
   - Remove or deprecate `pendingClaimDeferredAt` (the timer now lives on the proposal).
   - Migration consideration: any in-flight pending claims at deploy time will
     need either a fresh proposal or a one-time admin sweep. Decide policy.
4. **Tests** covering the full attack matrix:
   - Audit-10 replay (dust then large deferral) → admin proposal still needs
     90d from proposal time; seize attempt reverts.
   - Audit-11 replay (griefer resets timer via dust mints) → griefer's dust
     mint invalidates the proposal; admin must re-propose but no funds lost.
   - Griefer cost analysis → verify admin can outspend any finite griefer
     for a given trapped balance (economic invariant).
   - Recipient self-claim always works regardless of proposal state.

---

## Tests to Add (for items A and B, this commit)

| Change | Test |
|--------|------|
| claimPending clears timer | `test_claimPending_zerosDeferredAtOnSuccess` — defer, successfully claim, observe `pendingClaimDeferredAt == 0` |
| claimPending preserves timer on failure | `test_claimPending_preservesDeferredAtOnFailure` — defer, attempt claim while blocklisted (reverts), observe `pendingClaimDeferredAt` unchanged |
| rerouteBlockedClaim rejects self | `test_rerouteBlockedClaim_revertsOnSelfReroute` — oldRecipient == newRecipient → reverts "Self reroute" |

---

## Verification

```bash
forge build
forge test --match-contract AuditRemediationTest -v
forge test -v
```

---

## Status

- **Pass-6 Finding #1 (_transferOrDefer set-when-zero):** BLOCKED pending
  design review (Option 4). Do not land as a straight fix.
- **Pass-6 Finding #2 (claimPending clear timer):** LAND NOW (item A).
- **Pass-6 LEAD (self-reroute guard):** LAND NOW (item B).
- **Follow-up:** Draft Option 4 implementation plan as `audit-11-followup.md`
  after design review concludes.
