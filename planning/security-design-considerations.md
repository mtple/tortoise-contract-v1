# Security design considerations

This register tracks security-relevant behavior that is not currently classified as a
vulnerability, but must receive an explicit product/security decision before a production
deployment. An item remains open until its decision, rationale, and regression coverage are
recorded here.

## Open items

### SEC-DC-001 — Public collections can roll an active reward period

**Status:** Open — explicit accept-or-change decision required before mainnet.

**Affected code:** `TortoiseShell._addScaledReward`

**Current behavior**

When at least `MIN_REWARD_DEPOSIT` of new rewards arrives during an active reward period, the
Shell combines the new reward with the unpaid remainder and schedules the combined amount over
a fresh `rewardDuration`:

```solidity
uint256 remaining = periodFinish - block.timestamp;
uint256 leftover = remaining * rewardRate;
rewardRate = (pooled + leftover) / rewardDuration;
periodFinish = block.timestamp + rewardDuration;
```

Collections can indirectly trigger this path because a successful collection may forward its
staking fee to the Shell. A collector therefore influences reward-schedule timing through an
ordinary paid collection.

**Why this is not currently classified as a vulnerability**

- The collector pays the normal song price and receives the song.
- The collection adds USDC to the reward pool.
- No principal or scheduled reward is stolen.
- Stakers continue receiving rewards.
- Repeated rollovers delay only the remaining balance, which shrinks as rewards stream.
- No direct way for the collector to profit from the delay has been identified.

The behavior is consistent with a rolling-emissions policy where every qualifying reward inflow
is blended into a new full-duration stream.

**Why it still needs a decision**

If the intended policy is that already-scheduled rewards must finish by their original
`periodFinish`, the current implementation violates that policy. For example, late in a large
reward period, a comparatively small collection-funded deposit can spread the remaining balance
over another full duration. The resulting harm is timing and time value, not loss of nominal
rewards.

**Decision required**

Choose and document exactly one policy:

1. **Accept rolling emissions.** Every qualifying deposit may reset `periodFinish`. Document
   this behavior for stakers and add regression coverage proving the intended rollover math.
2. **Preserve the active deadline.** During an active period, incorporate new rewards without
   changing the existing `periodFinish`; only start a full duration after the old period ends.
3. **Allow bounded extension.** Permit extensions only when the new deposit is sufficiently
   large relative to the unpaid remainder, or cap the maximum extension.

**Required regression coverage**

- A qualifying deposit near the end of an active period.
- Several qualifying deposits during one active period.
- Conservation of all deposited rewards, allowing only documented rounding dust.
- The selected `periodFinish` policy.
- The selected maximum delay or extension bound, if any.
- Normal collection behavior when the Shell accepts or rejects the reward update.

**Closure criteria**

- The chosen policy and rationale are recorded in this section.
- Contract NatSpec and user-facing staking documentation match that policy.
- Regression tests cover the requirements above.
- The implementation is changed if the selected policy differs from current behavior.
- Security review confirms the final behavior does not introduce reward loss or an unbounded,
  economically cheap delay.
