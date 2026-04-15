# Audit #8 Remediation Plan

Source: Independent security review — TortoiseV1 + TortoiseShell (Pass 3)
Date: 2026-04-15
Confidence threshold applied: 80

---

## Finding Assessment

| # | Conf | Title | Verdict |
|---|------|-------|---------|
| 1 | [80] | claimPending lacks defer-on-failure — permanent lockup if recipient is blocklisted post-defer | **IMPLEMENT** |

### Leads acted on

| Lead | Verdict |
|------|---------|
| `_transferOrDefer` panics on `ret.length` in [1,31] | **IMPLEMENT** — closes a DoS vector in the deferral wrapper |
| `_transferOrDefer` succeeds on zero-code USDC address | **IMPLEMENT** — one-line defensive guard |
| `validateSplits` should reject `address(this)` / USDC address as recipient | **IMPLEMENT** — defensive, closes self-harm path |
| `StakingFeeDeferred` event name is misleading | **IMPLEMENT** — rename to `StakingFeeAbsorbed` |
| EIP-7702 bypass of `addAuthorizedCaller` code-length check | **ACCEPT** — EIP-7702 not live on Base mainnet; admin-trust assumption sufficient |
| Self-mint TORT-pool arbitrage under per-copy fees | **ACCEPT** — per-copy fees close the large-quantity exploit; residual is design-inherent |
| Rate-truncation gap inflates `reservedBalance` | **ACCEPT** — sub-cent per period; invariant tests already accommodate with `assertLe` |
| `configureSplits` rug path | **ACCEPT** — `lockSplits` is the intended guard; no lockup-before-mint enforcement is intentional |
| `exit()` reverts for zero-stake users with pending rewards | **ACCEPT** — add NatSpec only; no logic change |
| `_flushQueuedReward` windfall capture | **ACCEPT** — documented as intended behavior |
| Orphaned USDC on shell absorbed by future period | **ACCEPT** — consequence of the try/catch design; `StakingFeeAbsorbed` rename addresses the misleading framing |
| `nonReentrant` missing on `depositRewards`/`creditStake` | **ACCEPT** — sole authorized caller is V1 under its own `nonReentrant`; USDC is standard |

---

## Changes

### 1. claimPending: re-defer on transfer failure (Finding 1)

**Root cause:** `claimPending` calls `safeTransfer(recipient, amount)`, which reverts permanently
if the recipient is later added to the USDC blocklist. Since `recoverTokens` blocks USDC and
there is no admin escape, the funds are unrecoverable forever.

**Fix — part A:** Use the same low-level call pattern as `_transferOrDefer`.
On transfer failure, restore the pending claim and revert with a clear message instead of
silently bricking. The claim remains intact for a future attempt or reroute.

```solidity
function claimPending(uint256 songId, address recipient) external nonReentrant {
    uint256 amount = pendingClaims[songId][recipient];
    require(amount > 0, "Nothing to claim");
    pendingClaims[songId][recipient] = 0;
    (bool ok, bytes memory ret) = address(config.usdcToken).call(
        abi.encodeCall(IERC20.transfer, (recipient, amount))
    );
    bool transferred = ok && (ret.length == 0 || ret.length >= 32 && abi.decode(ret, (bool)));
    if (transferred) {
        emit PaymentDistributed(songId, recipient, amount, false);
    } else {
        pendingClaims[songId][recipient] = amount; // restore
        revert("Transfer failed; still claimable");
    }
}
```

**Fix — part B:** Add `rerouteBlockedClaim` for the permanent-blockist case.
The auditor's version took `deferredAt` as a caller parameter, which is exploitable (owner could
pass `block.timestamp - 366 days`). Track `deferredAt` on-chain in a separate mapping instead.

New state:
```solidity
mapping(uint256 => mapping(address => uint256)) public pendingClaimDeferredAt;
```

Update `_transferOrDefer` to record the timestamp when a claim is first created:
```solidity
if (pendingClaims[songId][recipient] == 0) {
    pendingClaimDeferredAt[songId][recipient] = block.timestamp;
}
pendingClaims[songId][recipient] += amount;
```

New function (90-day timelock — long enough to avoid admin rug, short enough to be practical):
```solidity
uint256 public constant REROUTE_DELAY = 90 days;

event PendingClaimRerouted(
    uint256 indexed songId,
    address indexed oldRecipient,
    address indexed newRecipient,
    uint256 amount
);

function rerouteBlockedClaim(
    uint256 songId,
    address oldRecipient,
    address newRecipient
) external onlyOwner nonReentrant {
    require(newRecipient != address(0), "Zero recipient");
    uint256 amount = pendingClaims[songId][oldRecipient];
    require(amount > 0, "Nothing to reroute");
    uint256 deferredAt = pendingClaimDeferredAt[songId][oldRecipient];
    require(block.timestamp >= deferredAt + REROUTE_DELAY, "Too soon");
    pendingClaims[songId][oldRecipient] = 0;
    pendingClaimDeferredAt[songId][oldRecipient] = 0;
    pendingClaims[songId][newRecipient] += amount;
    if (pendingClaims[songId][newRecipient] == amount) {
        pendingClaimDeferredAt[songId][newRecipient] = block.timestamp;
    }
    emit PendingClaimRerouted(songId, oldRecipient, newRecipient, amount);
}
```

---

### 2. _transferOrDefer: guard against ret.length in [1,31] (Lead)

**Root cause:** `abi.decode(ret, (bool))` panics when `ret.length` is in [1,31] — a nonstandard
but technically conforming ERC20 return. The panic bubbles out as a revert, defeating the
deferral pattern and bricking the mint. OZ SafeERC20 guards against this with `ret.length >= 32`.

In `_transferOrDefer`, change the decode condition:
```solidity
// Before:
bool transferred = ok && (ret.length == 0 || abi.decode(ret, (bool)));

// After:
bool transferred = ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
```

Apply the same fix to `claimPending` (done inline with change 1 above).

---

### 3. _transferOrDefer: guard against zero-code USDC address (Lead)

**Root cause:** `address(usdc).call(...)` to an empty-code address returns `ok=true, ret.length==0`,
which the decode logic treats as a successful transfer. If the USDC proxy has no code (e.g.
during an upgrade), artist payments silently "succeed" while funds stay in V1 unaccounted.

Add a one-time code-length check at the top of `_transferOrDefer`:
```solidity
require(address(usdc).code.length > 0, "USDC has no code");
```

---

### 4. validateSplits: reject address(this) and USDC token address (Lead)

**Root cause:** A split recipient equal to V1 itself (`address(this)`) creates USDC that lands
in the contract with no accounting entry — not `platformFeesAccrued`, not `pendingClaims`,
not recoverable via `recoverTokens`. A split recipient equal to the USDC token address causes
`safeTransfer` (or the low-level call) to revert, permanently bricking that mint path.

In `SplitLib.validateSplits`, the validation already rejects `address(0)`. Add two more checks
in `TortoiseV1.configureSplits` (where the V1 and USDC addresses are in scope), since SplitLib
has no knowledge of them:

```solidity
function configureSplits(uint256 songId, SplitRecipient[] calldata splits) external ... {
    ...
    splits.validateSplits();
    for (uint256 i = 0; i < splits.length; i++) {
        require(splits[i].recipient != address(this), "Split to self");
        require(splits[i].recipient != config.usdcToken, "Split to USDC token");
    }
    ...
}
```

---

### 5. Rename StakingFeeDeferred to StakingFeeAbsorbed (Lead)

**Root cause:** `StakingFeeDeferred` implies the funds are pending/recoverable. In reality, the
USDC has already been transferred to Shell and will be absorbed into the next reward period via
the `balanceOf - totalRewardsDeposited` reconciliation. The name should reflect what actually
happens.

- Rename `StakingFeeDeferred` event to `StakingFeeAbsorbed` everywhere (declaration + emit).
- Update NatSpec comment on the catch block to explain the reconciliation behavior.

---

## Implementation Order

1. **Change 2** — `_transferOrDefer` decode guard (`ret.length >= 32`) — touches one line, lowest risk
2. **Change 3** — `_transferOrDefer` zero-code guard — one-line add
3. **Change 5** — Rename `StakingFeeDeferred` → `StakingFeeAbsorbed`
4. **Change 4** — `configureSplits` self/USDC recipient check
5. **Change 1** — `claimPending` re-defer + `rerouteBlockedClaim` + `pendingClaimDeferredAt`

---

## Tests to Add

| Change | Test |
|--------|------|
| 1 | `test_claimPending_redeferOnBlocklistFailure` — mock transfer returning false; verify claim restored, revert message |
| 1 | `test_rerouteBlockedClaim_revertsBeforeDelay` |
| 1 | `test_rerouteBlockedClaim_succeedsAfterDelay` |
| 1 | `test_rerouteBlockedClaim_revertsZeroRecipient` |
| 2 | `test_transferOrDefer_malformedReturnData` — mock returning 1-byte return; verify deferred not minted-bricked |
| 3 | Not easily unit-testable (requires etch to zero-code); covered by code review |
| 4 | `test_configureSplits_rejectsSelfRecipient` |
| 4 | `test_configureSplits_rejectsUsdcRecipient` |
| 5 | Update event name in existing tests |

---

## Verification

```bash
forge build
forge test --match-contract AuditRemediationTest -v
forge test -v
```
