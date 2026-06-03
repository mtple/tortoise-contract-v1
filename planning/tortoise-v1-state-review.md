# Tortoise Contracts v1 — Comprehensive State Review

## Context

This is a **review/assessment task**, not an implementation. The goal was to
understand the *current state* of the Tortoise Music smart-contract project
across **all branches**, reading every plan, security-review, and design
document. The repo (`mtple/tortoise-contract-v1`) turns out to contain three
distinct bodies of work: a **frozen, audited v1**, and **two independent,
divergent "v2 / InProcess" rewrites** that have not converged. This document
captures the findings and recommended next steps.

---

## 1. The big picture: branch & PR map

`main` == tag `v1.0.0-rc1` == this review branch (`claude/...review-CzB1p`).
Everything below branches off `main`; the two v2 tracks share **only `main`**
as a merge-base (verified) — they do not share any v2 work.

| Branch | Author | Last activity | Direction | State |
|---|---|---|---|---|
| `main` / `v1.0.0-rc1` | Matt | 2026-04-17 | **v1 (frozen, audited)** | Release candidate |
| `claude/...review-CzB1p` | — | = main | this review | identical to main |
| **codex track (Track A)** | Matt (codex) | 2026-05-08 | router → planned **ETH-native** custom minter | mostly **planning + prototype** |
| ↳ `codex/inprocess-plan` | | 04-24 | plan + `solidity-auditor` skill | docs |
| ↳ `codex/inprocess-implementation` | | 04-28 | `TortoiseMintRouter` (USDC) | prototype, PR #1 open |
| ↳ `codex/album-support-full-plan` | | 05-08 | + album/batchCollect | PR #2 open (draft) |
| ↳ `codex/minter-architecture-plan` | | 05-08 | **pivot**: ETH-native custom minter spec | PR #3 open (draft); PR #4 merged in |
| **techengme/ziad track (Track B)** | Ziad/techeng | 2026-05-14 | **Zora ERC20Minter fork** (USDC, 25/75) | **implemented + deployed to Sepolia** |
| ↳ `techengme/fork-erc20-minter` | | 05-14 | fork groundwork | PR #5 merged → in_process |
| ↳ `techengme/myc-4805-...fee-logic...airdrop` | | 05-14 | fee logic + TORS airdrop | PR #7 merged → in_process |
| ↳ `in_process` | | 05-14 | integration base for Track B | 32 ahead of main |
| ↳ `ziad-testing` | | 05-14 | + Base Sepolia deploy + TORS faucet | **live testnet addresses** |
| `claude/add-album-upload-ZfGkC` | Claude | 2026-02-05 | stale | 3 ahead / 32 behind |

**Open PRs:** #1 (router impl→main), #2 (album support→main, draft),
#3 (minter plan→album-support, draft). **Merged:** #4,#5,#7. None target a
unified v2 line.

---

## 2. v1 — `main` / `v1.0.0-rc1` (the production line)

**Status: mature, audit-hardened, release-candidate. This is the only
deployable, fully-tested code.** Solidity 0.8.34 / Foundry / Base / Cancun.

Contracts (~1,050 LoC src):
- `src/TortoiseV1.sol` (509) — ERC-1155 music NFTs (USDC). Song creation,
  configurable splits (≤10 recipients via `SplitLib`), per-mint fee waterfall:
  platform $0.05 + staking $0.10 + artist $0.85 (defaults). Slippage-guarded
  `mintSong` overload, pull-payment deferral for blocklisted recipients,
  90-day reroute timelock, `Ownable2Step`, `Pausable`, `ReentrancyGuardTransient`.
- `src/TortoiseShell.sol` (451) — TORT staking → USDC rewards, Synthetix-style
  7-day drip; `MIN_REWARD_DEPOSIT` floor; queued-reward logic for zero-stake
  periods; `creditStake` graceful degradation (never blocks mints).
- `src/libraries/SplitLib.sol` (42) — split validation (sum=10000bps, ≤10, ≥1%,
  no dupes).

**Testing: excellent.** 244 test fns / ~5,155 LoC (≈5.4× src): unit, integration,
fuzz, invariant (+handlers), fork (real Base USDC/TORT). CI (`.github/workflows/
test.yml`) runs `forge fmt --check` + `build --sizes` + `test -vvv` on the `ci`
profile (10k fuzz / 512 invariant); a `deep` profile (10k/10k) exists for
pre-freeze. Slither configured (output gitignored). No TODO/FIXME in src.

**Security review history (audits 6→12, iterative; docs now in gitignored `md/`,
reconstructable from git history; mirrored as living tests in
`test/unit/AuditRemediation.t.sol`, ~73 tests):**
- a6: per-qty fee scaling, pull-payment, `Ownable2Step`, pool guard.
- a7: `platformFeesAccrued` tracker, pool-sufficiency gate, slippage overload,
  `depositRewards` try/catch.
- a8: claim re-deferral, reroute timelock (90d), zero-code USDC guard,
  `StakingFeeDeferred`→`StakingFeeAbsorbed`.
- a9: gate `_creditShell` on `stakingFeeForwarded` (stops free tortPool drain).
- a10: always-refresh `pendingClaimDeferredAt` (stale-timer seizure fix).
- a11 (design tension, **accepted tradeoff, not fully fixed**): one timestamp
  cannot satisfy both "recipient always gets ≥90d" and "admin can recover in
  bounded time"; permissionless dust-deferral can perpetually reset the reroute
  timer. Mitigations A/B landed; recommended "Option 4 (timelock-proposed admin
  recovery)" was **not implemented** — flagged for follow-up if threat model
  changes.
- a12: `emergencyWithdraw` accounting fix; `_flushQueuedReward` floor gate with
  aged-queue escape (part B deferred).

**Known open items on v1:** (1) audit-11 Option-4 still open by design;
(2) deployment requires manual post-deploy steps (fund tortPool, set
`tortRewardPerCollection`); (3) `md/` audit docs + `DEPLOYMENT.md` are
gitignored — not preserved in the repo for auditors/future devs.

---

## 3. Track A — codex (router → planned ETH-native custom minter)

Heavily **documented**, lightly **built**. v1 contracts moved to `legacy/v0.3/`.

- **Prototype:** `src/TortoiseMintRouter.sol` (USDC) wraps the InProcess
  ERC-20 minter; 5% platform / 10% staking / 85% artist; full-proceeds
  invariant; pending claims; album `batchCollect`. **Undeployed; explicitly
  marked for deletion** once the custom minter lands.
- **Pivot (the current codex direction):** `planning/minter-architecture-
  migration-plan.md` (+`setup-actions-reference.md`) supersede the router with
  a **`TortoiseInProcessMinter`** that owns sale config and calls `adminMint`
  directly, pays in **native ETH**, with 12 locked decisions (D.1–D.12):
  EIP-712 artist-signed `setSale`, `_safeSendETH`+pending claims, explicit
  `mintTo`, strict `msg.value==totalCost`, `batchCollect` (MAX 20), 500-byte
  comments, shell-credit divergence matrix, EIP-2981 5% default, one collection
  per album, **ETH-native `TortoiseShell` rewrite** (D.11). **The custom minter
  itself is not implemented on any branch — specification only.**
- Adds `.agents/skills/solidity-auditor/` (8-agent parallel audit skill).
- Open questions in plan: default price, TORT-per-collection, initial pool size,
  whether to migrate existing v0.3 songs.

---

## 4. Track B — techengme/ziad (Zora ERC20Minter fork) — **furthest along & deployed**

Independent of Track A. **Actually implemented and deployed to Base Sepolia.**

- `src/in_process/minters/TortoiseMinter.sol` ("Tortoise Minter" v2.0.0) — a
  fork of Zora's ERC20Minter for InProcess 1155s. **ERC20 (USDC) payment**, not
  ETH. Additive platform fee split **25% → TortoiseShell / 75% → artist**
  (`TortoiseMinterRewards.sol`), plus TORS airdrop via `creditStake`. CEI
  enforced, `nonReentrant`, fee-on-transfer slippage check, per-wallet caps
  (`LimitedMintPerAddress`), premint support, upgradeable `Ownable2Step`
  (`src/in_process/utils/ownable/`, Initializable pattern).
- Tests: `test/in_process/TortoiseMinter.t.sol` — **21 unit tests** (init,
  validation, mint flow, 25/75 split, events, config). **No fuzz/invariant/fork
  tests** (vs v1's deep coverage).
- `ziad-testing` extras: `src/TORSTest.sol` (faucet token), `script/
  DeployBaseSepolia.s.sol`, and **live Sepolia addresses** in
  `addresses/84532.json` (Minter `0x2a805A4…`, Shell `0x5220C76…`,
  V1 `0x0713940…`, TORS `0x1c3879b…`).
- Maturity: beta. Gaps: no pause on the minter, hardcoded 25/75 (not
  per-token), no fuzz/invariant tests, sparse revert reasons.

---

## 5. The central finding: two divergent, unreconciled v2 directions

Track A and Track B **disagree on nearly every core decision** and were built
in parallel without converging:

| Decision | Track A (codex, current plan) | Track B (techengme/ziad, deployed) |
|---|---|---|
| Payment currency | **Native ETH** | **ERC20 / USDC** |
| Minter shape | Custom `adminMint` minter | Zora ERC20Minter fork |
| Fee model | 5% / 10% / 85% (platform/stake/artist) | 25% / 75% (shell/artist), additive |
| Shell rewards | planned ETH rewrite (D.11) | USDC (v1 shell) |
| Maturity | spec only (+ undeployed router) | implemented, **deployed to Sepolia** |
| Tests | router has unit/fuzz/fork | 21 unit only |

This is the most important thing for a stakeholder to resolve: **which v2
architecture is the real one?** The most-recent *planning* (Track A, May 8)
points one way; the most-recent *code + deployment* (Track B, May 14) goes the
other. They cannot both be v2.

---

## 6. Risks & observations

1. **No converged v2 line / no v2 PR to `main`.** Open PRs are prototypes and
   drafts; the deployed code (Track B) has no PR at all.
2. **Plan vs. reality mismatch.** The documented direction (ETH-native custom
   minter) is unbuilt; the built thing (ERC20 fork) is undocumented in the
   planning set and untested beyond units.
3. **Audit coverage does not extend to v2.** All 6→12 audits target v1.
   Neither v2 minter has been through the audit loop; Track B lacks fuzz/
   invariant tests entirely.
4. **Deployed testnet contracts are unaudited** and live under a personal
   branch (`ziad-testing`), not main.
5. **Internal docs are gitignored** (`md/`, `docs/`) — audit history and
   deployment runbook aren't preserved in-repo.
6. **audit-11 Option-4** remains an accepted-but-open design risk on v1.

---

## 7. Recommended next steps (for discussion — nothing executed yet)

This review is the deliverable. If you want follow-up work, likely candidates:

- **Decide the v2 architecture** (ETH custom minter vs ERC20 fork) and close/
  consolidate the losing track's branches & PRs.
- **Preserve audit history**: un-ignore or copy `md/` audit docs + `DEPLOYMENT.md`
  into the repo (or a `docs/` that *is* tracked) before they're lost.
- **Bring the chosen v2 to v1's bar**: fuzz + invariant + fork tests, run the
  `solidity-auditor` skill, then a fresh external review.
- **Tidy branches/PRs**: stale `claude/add-album-upload` (32 behind), draft PRs.
- Optionally, **write this review up as a tracked `docs/STATE.md`** in the repo.

---

## 8. Direction decided: continue Track A (ETH), harvest from Track B

**Chosen direction:** continue with the **Track A ETH plan** (`codex/minter-architecture-plan`):
native ETH, 5/10/85 fee model, `SplitLib` multi-recipient splits, non-blocking
shell crediting, ETH `pendingClaims`/`_safeSendETH` deferral.

**Locked architecture decisions (from review of Track B / Ziad's deployed fork):**
- **Upgradeability:** **immutable** `Ownable2Step` (keep plan; do *not* adopt Track B's
  `Initializable` + `Ownable2StepUpgradeable` proxy pattern).
- **Premint:** **none.** Keep the plan's artist-signed `RegisterSongWithSplits` +
  operator-submitted `setSale` (operator pays trivial Base gas to create tokens;
  artist signs gaslessly). Do **not** adopt Zora/InProcess premint
  (`setPremintSale`/`buildSalesConfigForPremint`).
- **InProcess interop stance:** maximal integration **without** ceding the payment
  path. `collect()` stays the sole paid entrypoint (minter custodies ETH → `adminMint`
  → custom distribution). The standard 1155 `mint()`→`requestMint`→ProtocolRewards
  path is NOT used — it routes ETH through the 1155 to a single `fundsRecipient` and
  cannot express splits/shell/deferral. (Confirmed this is a control-flow limit, not a
  fee-size one; InProcess's `totalRewardPct==0` removes only the economic objection.)

### Bring IN from Track B
- **Verified InProcess integration facts** (`in_process:src/in_process/interfaces/IInProcess1155.sol`):
  exact `adminMint(address,uint256,uint256,bytes)` signature; `createReferrals`,
  `firstMinters`, `getCreatorRewardRecipient` hooks; `PERMISSION_BIT_MINTER = 4`;
  deploy order (deploy shell → minter → `initialize` → `addAuthorizedCaller`). Match the
  Track A interface stubs to these verbatim.
- **Discovery/recognition shim (no payment sacrifice):** implement `IMinter1155` +
  `supportsInterface` + a reverting `requestMint` (Track B `TortoiseMinter.sol:262-280`)
  so InProcess's permission system/indexers recognize the contract as a minter.
- **`callSale`-driven `setSale`** (`msg.sender` = collection) *in addition to* the EIP-712
  `setSaleWithArtistSignature`, so artists can configure sales from InProcess's app
  (sale config never touches money → no conflict).
- **Standard `SaleSet`-style events** for indexer/marketplace discovery.
- **`LimitedMintPerAddress`** Zora-canonical per-wallet limiter pattern
  (`utils/LimitedMintPerAddress.sol`, keyed `(tokenContract,tokenId,wallet)`,
  increment-then-check) — reuse instead of rolling a bespoke `mintedByAddress`.
- **Operational scaffolding** (`ziad-testing`): env-driven `DeployBaseSepolia.s.sol`,
  `TORSTest` faucet token for testnet staking, and the `addresses/<chainId>.json`
  registry convention + chain routing in `Config.s.sol`.
- **Open-edition sentinel** convention `saleEnd = type(uint64).max`.

### Do NOT bring in (Track A/v1 already better, or now decided against)
- Blocking shell calls (Track B has no try/catch → reverting shell bricks mint).
- No deferred-payment safety net; no pause on the minter.
- Hardcoded 25/75 single-`fundsRecipient` split; the two-token ERC-20 model.
- Upgradeable/proxy pattern; premint interfaces.
- Track B's 21-unit-test bar — hold the chosen v2 to v1's fuzz/invariant/fork bar.
- Note: Track B's `TortoiseShell` is byte-for-byte v1's (diff is pure `forge fmt`) and
  still USDC — nothing to harvest there; it's superseded by the planned ETH Shell rewrite.

### Confirm with the InProcess team before building
- Whether mints performed via `adminMint` (not the standard path) are picked up by
  InProcess's indexer/app — this determines how much the discovery shim actually buys.
- The Base Sepolia factory address (plan leaves it intentionally unpinned).
- That `totalRewardPct`/`ethRewardAmount`/protocol mint-fee remain zero for ETH mints.

## 9. How to resume this work (start here next time)

- **Chosen base branch to build on:** `codex/minter-architecture-plan` (Track A, ETH).
  Read its two design docs first:
  `planning/minter-architecture-migration-plan.md` (808 lines, the D.1–D.12 decisions,
  collect flow, EIP-712 schemas, ETH Shell rewrite) and
  `planning/setup-actions-reference.md` (factory/permission/setup-action specifics).
- **Decisions already locked** (see §8): native ETH + 5/10/85; immutable (no proxy);
  **no premint**; `collect()` is the only paid path; add a non-payment InProcess
  discovery/recognition shim + `callSale` sale-config + standard events.
- **Track B reference (read-only, for harvest):**
  `origin/in_process:src/in_process/minters/TortoiseMinter.sol` and siblings; deployed
  Sepolia addresses in `origin/ziad-testing:addresses/84532.json`.
- **Next deliverable (not yet written):** a phase-by-phase implementation plan for
  `TortoiseInProcessMinter` (ETH) + the ETH-native `TortoiseShell` rewrite, plus the
  harvested shim/limiter/scaffolding from §8. The codex plan's Phases 1–5 (plan lines
  ~634–681) are the starting skeleton.
- **Blocking external dependency:** the InProcess-team confirmations listed in §8
  (indexer behavior for `adminMint`, Sepolia factory address, zero protocol fee).
- **Where this doc lives in-repo:** committed on branch
  `claude/tortoise-contracts-v1-review-CzB1p` (see commit for path).

## Verification / how this was produced (read-only)
- Branch/PR map: `git for-each-ref`, `git merge-base`, GitHub `list_pull_requests`.
- Per-branch content read cross-branch via `git show <ref>:<path>` (no checkout).
- v1 audit history reconstructed from `git log` (docs gitignored in `md/`).
- Track independence confirmed: merge-base of `origin/in_process` and
  `origin/codex/minter-architecture-plan` == `main`.
