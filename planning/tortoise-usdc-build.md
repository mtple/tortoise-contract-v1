# Tortoise (custom USDC) — as-built reference

**Status:** active v2 implementation. Unit/fuzz/invariant tests are green and a live Base USDC
fork suite is included. The contracts remain pre-audit and no verified v2 deployment is
recorded. This is the authoritative description of what exists in `src/` and `test/`; it
supersedes the In Process / ETH planning docs (see "Lineage" below).

---

## What this is

A single Tortoise-owned ERC-1155 that is **token + minter + provenance registry**, paid in
**USDC**, with the one load-bearing verifiability guarantee — a `sha256(manifest)` commitment —
living on-chain in the same contract that holds the token. No proxy (immutable).

Two contracts:

- **`src/Tortoise.sol`** — the ERC-1155 music NFT + minter + registry.
- **`src/TortoiseShell.sol`** — TORT-staking → USDC-rewards shell (v1's audited USDC shell,
  revived). `Tortoise` credits it non-blockingly on collect.

Plus `src/interfaces/IEIP3009.sol` (USDC `receiveWithAuthorization`) and the shared
`src/libraries/SplitLib.sol`.

---

## Decisions (and why)

| Decision | Choice | Rationale |
|---|---|---|
| Token layer | **Custom** Tortoise 1155 (not In Process) | Single trust anchor: token + manifest + ownership in one immutable contract — the cleanest form of the "prove you hold the real release" claim. |
| Currency | **USDC** | Native dollar pricing, no oracle. Approval friction removed via EIP-3009 (below). |
| Payment UX | **EIP-3009 `receiveWithAuthorization`** sign-to-collect + `approve`/`transferFrom` fallback | One signature, no allowance, and relayable (collector needs no ETH → sponsored collects). EIP-1271 supported for smart wallets. |
| Fees | **Percentage 5 / 10 / 85** (platform / staking / artist), inclusive, BPS-capped | Denomination-agnostic; conserves value exactly (artist takes the remainder). |
| Song creation | **Owner/operator assertion**, plus **artist-signed EIP-712/EIP-1271** (`createSongWithArtistSignature`) | `artistAttested(songId)` makes the authority mode explicit. Only the signed path proves artist authorization; the operator path remains available for administration/migration. |
| Verifiability | **`sha256(manifest)` derived on-chain**, immutable (structural — fresh `songId` per create), emitted with preimage in one `SongCreated` event | A collector can verify manifest integrity. Artist identity is independently evidenced by `artistAttested`. |
| Blocklisted recipients | **Pull-payment deferral** to `pendingClaims` + 90-day admin reroute | One frozen USDC recipient can't brick a collect. |
| Shell credit | **Non-blocking** (try/catch); staking fee forwarded only when the TORT pool can cover it | Shell issues never block mints; no partial credit. |
| Royalties | **EIP-2981** per-song (default 5% to artist) | Marketplace-standard. |
| Ownership | **`Ownable2Step`**, renounce disabled; `Pausable`; `ReentrancyGuardTransient` | v1's hardening. |

Storage/serving (R2 + Opus + cold-backup master) is app/ops work beside the contracts; the
manifest thesis is unchanged from the storage design doc.

## Surface

- **Create:** `createSong(CreateSongParams)` (owner assertion) ·
  `createSongWithArtistSignature(...)` (owner submits artist EIP-712/EIP-1271) ·
  `artistAttested(songId)` · `configureSplits` / `lockSplits` (artist).
- **Collect:** `collect(...)` (approve) · `collectWithAuthorization(...)` (EIP-3009) ·
  `batchCollect(...)` / `batchCollectWithAuthorization(...)` (≤20 items, all-or-nothing,
  aggregate auth bound to the whole batch via `batchCollectNonce`).
- **Claims:** `claimPending` (permissionless) · `rerouteBlockedClaim` (owner, 90-day timelock).
- **Admin:** fee bps (capped, staking requires a shell), shell, default price, withdraw platform
  fees, pause, `recoverTokens` (not USDC).
- **Views:** `quote`, `collectNonce`, `batchCollectNonce`, `releaseManifest`, `getSong`,
  `getSongSplits`, `getArtistSongs`, `royaltyInfo`, `supportsInterface`.

## Testing

`test/unit/Tortoise.t.sol` (+ fuzz), `test/unit/TortoiseShell.t.sol`,
`test/invariant/TortoiseInvariant.t.sol` (+ handler), `test/fork/TortoiseBaseFork.t.sol`,
and mocks (`MockUSDC` with EIP-3009 + blocklist, `MockRevertingShell`).

- Unit: createSong (operator + signed, with wrong-signer/tamper/expiry rejection), both collect
  paths, EIP-3009 nonce/relay/replay/comment binding, fee split, shell credit (funded +
  non-blocking), pull-payment + reroute timelock, admin guards, batch (happy + security).
- Regression: duplicate-song batch entries enforce the cumulative maximum supply; emergency
  withdrawal recycles forfeited shell rewards to remaining/future stakers.
- Shell: staking/withdrawal, authorization, real-balance deposits, completed claims, no-staker
  queue, emergency recycling, pause and pool-cap behavior.
- Base fork: real Circle USDC EIP-3009 collect, complete shell reward lifecycle, and blocklist
  deferral/unblock/claim.
- Fuzz: fee waterfall conserves value for any price/quantity.
- Invariant: balance ≥ platformFeesAccrued; nextSongId monotonic; manifest immutable.
- **Mutation-verified**: deliberately breaking the fee split and the EIP-3009 `mintTo` binding
  turned the relevant tests red (incl. the relayer-redirect guard) — the assertions bite.

## Deploy

`script/Deploy.s.sol` resolves `USDC` and `TORT` from env overrides or
`addresses/<chainId>.json`; `REWARD_DURATION` and `TORT_REWARD_PER_COLLECTION` remain
env-configurable. It deploys shell + Tortoise and wires the NFT as an authorized shell caller.
Post-deploy: fund the TORT pool, verify the deployment, then record the confirmed addresses.

## Not done yet

- A verified Base Sepolia deployment rehearsal and recorded v2 addresses.
- A fresh external **v2 security audit** — the v1 audit history (6→12) does not cover this
  contract.
- App integration (Supabase indexer/verify-then-record + Next.js collect UI), including use of
  `artistAttested` when presenting release authority. This lands in the Tortoise app repo.

## Lineage

The project explored two directions before this build:

1. **In Process (Zora-1155) + ETH** — see `eth-minter-implementation-plan.md`,
   `setup-actions-reference.md`, and the ETH-oriented parts of
   `architecture-decisions-inprocess-eth-storage.md`. Set aside (the partnership decision was
   walked back); the token layer went custom and the currency went USDC.
2. The **storage/verifiability thesis** (manifest hash, R2/Opus, no permanence promise) from that
   same decision doc **still holds** and is realized here.
