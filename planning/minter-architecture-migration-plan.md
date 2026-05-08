# Router To Custom Minter Migration Plan

This document plans the move from `TortoiseMintRouter` to a custom Tortoise minter that mints In Process/Zora-compatible ERC-1155 tokens directly.

This plan also changes the payment currency from USDC to native ETH.

## Decision

Use the In Process contracts directly instead of the hosted In Process API for the core creation and collect flow.

The custom minter is the preferred architecture because it owns the full collect path:

1. Receive ETH from the payer.
2. Mint the In Process ERC-1155 token to `mintTo` via `adminMint`.
3. Credit TortoiseShell for the recipient if eligible.
4. Distribute platform fees, staking fees, and artist splits, with staking fees deposited only after successful shell credit.
5. Emit Tortoise-native events for indexing.

The router architecture should be treated as superseded. Its useful pieces are the fee logic, splits logic, shell-credit behavior, batch collect behavior, and security checks.

## Why We're Not Building The Router Architecture

The prototype `TortoiseMintRouter` in this repo was an early design that wrapped the standard In Process ERC-20 minter. That shape made sense only if Tortoise needed to stay compatible with the In Process hosted API/app/indexer/collect flow. Nothing in this repo has been deployed; the router is a design artifact, not a production system.

For a Tortoise-owned direct-contract flow, the router shape is a dead end:

- The standard In Process ERC-20 minter would remain the real minter.
- The router would have to be configured as sale `fundsRecipient`, with all the misconfiguration risk that implies.
- Direct collects through the standard minter could send USDC to the router without executing Tortoise distribution logic.
- Pricing and sale state would live in a third-party minter instead of the Tortoise economic contract.
- The router would have to approve another external minter during the hot collect path.
- The router design is USDC-first, but the target product direction is ETH-first.

The custom minter removes the middle layer. Tortoise becomes the sale contract and minting path. The prototype router will be deleted once the new minter and ETH-native shell pass tests; it is referenced in this document only as a source of patterns to adapt.

## Contract Facts This Plan Relies On

- In Process uses a Zora-compatible ERC-1155 creator implementation.
- The creator contract exposes `adminMint(address recipient, uint256 tokenId, uint256 quantity, bytes data)`.
- `adminMint` is callable by collection admins or addresses with `PERMISSION_BIT_MINTER`.
- `PERMISSION_BIT_MINTER` is `4`.
- Setup actions can grant minter permission with `addPermission(tokenId, minter, 4)`.
- The factory accepts setup actions when creating a collection.
- Direct contract integration does not require the In Process API.

Confirmed Base mainnet addresses:

| Contract | Address | Notes |
| --- | --- | --- |
| In Process `Creator1155FactoryImpl` | `0x540C18B7f99b3b599c6FeB99964498931c211858` | Mainnet factory used for direct collection creation; RPC reports `ZORA 1155 Contract Factory` v2.13.2 |
| In Process Creator1155 implementation | `0x06fb7d2650c308320f6791d0543767735305fec7` | Returned by `zora1155Impl()` on the confirmed mainnet factory |
| In Process ERC-20 minter, reference only | `0xE27d9Dc88dAB82ACa3ebC49895c663C6a0CfA014` | Router-era reference only; not used by `TortoiseInProcessMinter` |

Base Sepolia is intentionally unpinned until In Process confirms the correct testnet
factory. `planning/setup-actions-reference.md` lists observed Zora-compatible
candidates, but those are not operational In Process addresses until confirmed.

## Target Architecture

| Component | Owner | Responsibility |
| --- | --- | --- |
| In Process ERC-1155 collection | In Process contracts | Token storage, metadata URI, supply cap, ERC-1155 transfers |
| `TortoiseInProcessMinter` | Tortoise | ETH collect flow, sale config, minting, fees, splits, shell crediting |
| `TortoiseShell` | Tortoise | TORT staking, ETH rewards, collector credit |
| Tortoise backend | Tortoise | Uploads, setup actions, DB records, event indexing, reconciliation |
| Tortoise frontend | Tortoise | Artist upload flow, album pages, collect UI, collector views |

## Resolved Product Decisions And Recommendations

- Use one ERC-1155 collection per album.
- Ship batch collect with the first custom minter release.
- Use native ETH for collects, platform fees, staking rewards, and artist payouts.
- Use native ETH, not WETH, unless a future wallet or marketplace requirement forces a wrapper.
- Do not expose an In Process/ERC20Minter-compatible `mint(...)` ABI in v1. Use Tortoise-native payable `collect(...)` and `batchCollect(...)` functions.
- Use the In Process-style comment pattern in v1: `collect(...)` accepts `string calldata comment`, emits `MintComment` when the comment is non-empty, and never stores comments in contract state.
- Enforce `bytes(comment).length <= 500` onchain and mirror the same 500-byte limit in the frontend. Tortoise indexes `MintComment` events into the database for fast UI reads.
- Use artist-signed/operator-submitted sale updates in v1. The artist signs the sale config with EIP-712, then the Tortoise backend/operator submits the transaction. Keep owner powers for registration, pausing, and emergency operations.
- Include `maxTokensPerAddress` in v1 with `0` meaning unlimited. It is simple to enforce and useful for editions, presales, and abuse control.
- Treat onchain sale config as settlement truth and the database as a cache. The UI can quote from the DB, but transactions must be protected by onchain price checks.
- Use Tortoise-native events for indexing. Reuse familiar event names like `SaleSet` and `MintComment`, but do not contort the contract into ERC20Minter compatibility.
- Delete router-era code that is not needed once Phase 1 custom minter tests pass. Keep it only long enough to port fee, split, shell-credit, and pending-claim logic safely.

## New Collection And Token Flow

### New Album Collection

1. Artist uploads album artwork, track audio, and metadata through Tortoise.
2. Backend uploads media and metadata to Arweave.
3. Backend builds factory setup actions:
   - `setupNewToken` or `setupNewTokenWithCreateReferral`
   - token URI
   - max supply
   - royalties
   - `addPermission(tokenId, TortoiseInProcessMinter, 4)`
4. Backend calls the In Process creator factory directly.
5. Backend records collection address, token IDs, album rows, track rows, metadata URIs, and sale settings.
6. Backend configures the Tortoise minter sale and splits for each token.

### Add Track To Existing Tortoise Collection

1. Backend verifies the artist is allowed in Tortoise's product/admin model to add a track to the target album.
2. Backend verifies the Tortoise operator, not necessarily the artist, holds collection admin permission onchain.
3. Backend calls the collection directly to create/setup the new token.
4. Backend grants `PERMISSION_BIT_MINTER` to `TortoiseInProcessMinter` for the token.
5. Backend registers sale config and splits in the Tortoise minter from the minter owner/operator signer.

### Important Change

Do not configure the standard In Process ERC-20 minter for Tortoise moments. The Tortoise minter should be the only public paid collect path.

## TortoiseInProcessMinter Responsibilities

The custom minter should own the behavior currently split between the router and the In Process ERC-20 minter.

Core responsibilities:

- Store sale config per `(collection, tokenId)`.
- Require registered songs before collect.
- Enforce sale start and sale end.
- Enforce nonzero quantity.
- Enforce `maxTotalCost` and `maxAggregateCost`.
- Enforce `msg.value` equals the current ETH price times quantity.
- Enforce `maxTokensPerAddress`, with `0` meaning unlimited.
- Call `adminMint` on the In Process ERC-1155 collection with `mintTo` as recipient.
- Credit TortoiseShell once per eligible wallet/song.
- Distribute platform fee, conditional staking fee, and artist revenue.
- Support artist-approved splits and split locking.
- Support pending claims when artist split transfer fails.
- Support single collect and batch collect.
- Emit events designed for the Tortoise indexer.

## Proposed Contract Surface

```solidity
error CommentTooLong();
error InvalidSaleSignature();
error SaleSignatureExpired();
error SaleNonceMismatch(uint256 expected, uint256 provided);
error ZeroAddress();

struct SaleConfig {
    uint64 saleStart;
    uint64 saleEnd;
    uint64 maxTokensPerAddress;
    uint256 pricePerToken;
    bool exists;
}

struct SaleUpdate {
    uint64 saleStart;
    uint64 saleEnd;
    uint64 maxTokensPerAddress;
    uint256 pricePerToken;
}

struct CollectItem {
    address collection;
    uint256 tokenId;
    uint256 quantity;
    address mintTo;
    uint256 maxTotalCost;
}

function collect(
    address collection,
    uint256 tokenId,
    uint256 quantity,
    uint256 maxTotalCost,
    address mintTo,
    string calldata comment
) external payable nonReentrant whenNotPaused;

function batchCollect(
    CollectItem[] calldata items,
    uint256 maxAggregateCost
) external payable nonReentrant whenNotPaused;

function setSale(
    address collection,
    uint256 tokenId,
    SaleUpdate calldata config
) external;

function setSaleWithArtistSignature(
    address collection,
    uint256 tokenId,
    SaleUpdate calldata config,
    uint256 nonce,
    uint256 deadline,
    bytes calldata artistSignature
) external;

function sale(
    address collection,
    uint256 tokenId
) external view returns (SaleConfig memory);

function registerSong(
    address collection,
    uint256 tokenId,
    address artist
) external onlyOwner;

function registerSongWithSplits(
    address collection,
    uint256 tokenId,
    address artist,
    SplitRecipient[] calldata splits,
    bool lockSongSplits,
    uint256 deadline,
    bytes calldata artistSignature
) external onlyOwner;

function configureSplits(
    address collection,
    uint256 tokenId,
    SplitRecipient[] calldata splits
) external;

function lockSplits(address collection, uint256 tokenId) external;
```

The exact names can change during implementation. The important point is that the minter, not the In Process ERC-20 minter, owns sale config and distribution.

## Events For Tortoise Indexing

The minter should emit enough events for the Tortoise backend to build product views without relying on the In Process indexer.

Recommended events:

Use `collector` to mean the token recipient (`mintTo`) and `payer` to mean `msg.sender`.

```solidity
event SaleSet(
    address indexed collection,
    uint256 indexed tokenId,
    uint256 pricePerToken,
    uint64 saleStart,
    uint64 saleEnd,
    uint64 maxTokensPerAddress
);

event SongCollected(
    address indexed collection,
    uint256 indexed tokenId,
    address indexed collector,
    address payer,
    uint256 quantity,
    uint256 totalPaid
);

event MintComment(
    address indexed collection,
    uint256 indexed tokenId,
    address indexed collector,
    address payer,
    uint256 quantity,
    string comment
);

event RevenueDistributed(
    address indexed collection,
    uint256 indexed tokenId,
    uint256 platformFee,
    uint256 stakingFee,
    uint256 artistRevenue
);

event StakeCredited(
    address indexed collection,
    uint256 indexed tokenId,
    address indexed collector,
    uint256 rewardUnits
);

event ShellCreditFailed(
    address indexed collection,
    uint256 indexed tokenId,
    address indexed collector,
    uint256 rewardUnits,
    uint256 expectedCredit,
    uint256 actualCredit
);

event ShellDepositFailed(
    address indexed collection,
    uint256 indexed tokenId,
    uint256 amount
);

event SplitsConfigured(address indexed collection, uint256 indexed tokenId);

event SplitsLocked(address indexed collection, uint256 indexed tokenId);

event SplitPaymentDeferred(
    address indexed collection,
    uint256 indexed tokenId,
    address indexed recipient,
    uint256 amount
);

event PaymentDistributed(
    address indexed collection,
    uint256 indexed tokenId,
    address indexed recipient,
    uint256 amount
);
```

Keep ERC-1155 `TransferSingle` and `TransferBatch` indexing separate from Tortoise minter event indexing. The ERC-1155 collection remains the source of ownership truth.

## Router Patterns To Adapt

Use the prototype `TortoiseMintRouter` as a design reference for the new minter. The router itself will be deleted; these patterns are ported (not literally copied) into `TortoiseInProcessMinter`:

- Platform fee and staking fee math.
- Fee caps.
- Fee-rounds-to-zero protection.
- Split validation.
- Artist-controlled split configuration.
- EIP-712 `registerSongWithSplits`.
- Split locking.
- Pending claims for failed artist payouts.
- Batch collect shape and batch size cap.
- Per-song distribution in batch collects.
- `maxTotalCost` and `maxAggregateCost` front-run protection.
- Shell credit try/catch behavior.
- `updateTortoiseShell(address(0))` auto-zeroing staking fee.
- Reentrancy guard and pause controls.
- Admin token recovery rules.

Remove or replace:

- USDC payment assumptions.
- `inProcessMinter` allowlist.
- Standard ERC-20 minter sale reads.
- Requirement that sale `fundsRecipient == router`.
- Approving USDC to the In Process ERC-20 minter.
- Full-proceeds balance check after the external ERC-20 minter call.

Add:

- `adminMint` interface for In Process ERC-1155 collections.
- Sale config storage in the Tortoise minter.
- Per-wallet mint count storage if `maxTokensPerAddress` is supported.
- Permission/setup validation in deployment scripts.
- Tortoise-native indexing events.
- Native ETH accounting and transfers.
- Native ETH reward support in `TortoiseShell`.

## Collect Flow

```text
Payer sends ETH to TortoiseInProcessMinter.

Payer calls collect(collection, tokenId, quantity, maxTotalCost, mintTo, comment).

Minter:
  1. validates song registration
  2. validates sale exists and is active
  3. validates quantity and max cost
  4. updates per-wallet mint count for `mintTo` if enabled
  5. validates msg.value equals total ETH cost
  6. calls collection.adminMint(mintTo, tokenId, quantity, "")
  7. credits TortoiseShell for `mintTo` if eligible, passing one reward unit for the first eligible wallet/song collect
  8. distributes platform fee, conditional staking fee, and artist revenue
  9. emits collect, revenue, comment, and shell events
```

Batch collect should require `msg.value` to equal the aggregate ETH cost, then process each item with the same per-item accounting. The result of one `batchCollect` should match repeated single `collect` calls, except the payer pays transaction overhead once.

## TortoiseShell ETH Migration

The existing Shell design is ERC-20 reward-token based. Moving to ETH means Shell should become a native ETH rewards contract while still staking TORT.

Required Shell changes:

- Remove `rewardToken`.
- Make `depositRewards()` payable.
- Account reward deposits from `msg.value`.
- Pay claims in native ETH.
- Replace ERC-20 reward-token recovery logic with ETH-aware recovery rules.
- Preserve reward drip math, queued rewards, reserved balance, and credit stake behavior.
- Use guarded ETH transfer helpers and keep reentrancy protection around claim paths.

Recommended Shell interface:

```solidity
function depositRewards() external payable;

function creditStake(
    address user,
    uint256 rewardUnits
) external returns (uint256 credited);
```

The minter should call `creditStake(mintTo, 1)` only for the first eligible wallet/song collect, regardless of how many copies are minted in that transaction. Treat the second argument as reward units, not mint quantity. If `mintTo` receives the expected TORT credit and the staking fee is nonzero, the minter should call `depositRewards{value: stakingFee}()`. If crediting fails or returns less than expected, the staking fee should remain artist revenue so collection is not blocked.

For delegated shell reward claims, `_claimRewards(user, payoutTo, amount)` must debit and send exactly `amount`, not the full unpaid balance. The public claim surface should still allow a reward owner to claim any amount up to `userUnpaidRewards[user]`. Delegated claims must bind `user`, `payoutTo`, `amount`, `nonce`, and `deadline`; `rewardClaimNonces[user]` increments on every successful delegated claim so old signatures cannot withdraw later rewards.

## Backend Indexing Plan

Tortoise should run a small indexer or event listener for:

- `SaleSet`
- `SongCollected`
- `MintComment`
- `RevenueDistributed`
- `StakeCredited`
- `ShellCreditFailed`
- `ShellDepositFailed`
- `SplitsConfigured`
- `SplitsLocked`
- `SplitPaymentDeferred`
- `PaymentDistributed`
- ERC-1155 `TransferSingle`
- ERC-1155 `TransferBatch`

The database should treat backend-created records as the primary catalog and contract events as the settlement truth.

Add-track safety depends on `lastKnownTokenId` being current. Indexer health monitoring is therefore a precondition for the artist add-track path, and the backend should fail closed when collection token indexing is behind. When possible, run `assumeLastTokenIdMatches(lastKnownTokenId)` as a read-only preflight before submitting the write transaction so stale state fails before gas is spent.

Minimum indexed product views:

- Album page with tracks.
- Track page with price, supply, sale status, and metadata.
- Collector list per track.
- Comments per track.
- Wallet ownership.
- Artist earnings and pending claims.
- Album collect eligibility and quoted total.

## Backend Data Model Adjustments

Keep the album-oriented data model from the router plan, but change the integration fields:

- Store `minterAddress`.
- Store `saleConfigSource = tortoise_minter`.
- Store `currency = native_eth`.
- Store collection factory transaction hash.
- Store setup action transaction hash.
- Store token permission status.
- Store minter sale config transaction hash.
- Store indexing status for minter events and ERC-1155 transfers.

Remove reliance on:

- In Process API moment IDs.
- In Process sale update endpoint.
- In Process hosted collect endpoint.
- In Process split configuration.
- USDC approval state.

## Deployment Plan

### Base Sepolia

1. Confirm and pin the Base Sepolia In Process `Creator1155FactoryImpl` in `planning/setup-actions-reference.md`. Do not use the candidate or canonical Zora factories unless In Process explicitly confirms that address, or Tortoise intentionally chooses a non-In-Process testnet stack.
2. Deploy or reuse `TortoiseShell`.
3. Deploy `TortoiseInProcessMinter`.
4. Register the minter as an authorized caller on `TortoiseShell`.
5. Create a test collection through the confirmed In Process factory.
6. Create a test token with minter permission setup action.
7. Configure sale and splits in the Tortoise minter.
8. Collect with Base Sepolia ETH.
9. Verify ERC-1155 ownership, ETH distribution, shell credit, and indexer records.

### Base Mainnet

1. Deploy `TortoiseInProcessMinter`.
2. Register it on `TortoiseShell`.
3. Run a dry-run script against a fork for collection creation setup actions.
4. Create a small production test collection/token.
5. Configure sale with a low price.
6. Execute a test collect from a controlled wallet.
7. Verify Tortoise UI/indexer, ERC-1155 wallet visibility, ETH distribution, and shell credit.

## Testing Plan

### New Mocks

- `MockInProcess1155`: supports `adminMint`, max supply, permission checks, and ERC-1155 transfers.
- `MockBadInProcess1155`: reverts or mints incorrectly for failure tests.
- `MockTortoiseShell`: records `depositRewards` and `creditStake`.

### Unit Tests

- Single collect.
- Multi-copy collect.
- Batch collect.
- Batch equals repeated singles.
- Sale not configured.
- Sale not started.
- Sale ended.
- Wrong ETH value.
- Zero quantity.
- Max cost exceeded.
- Aggregate cost exceeded.
- Max tokens per address exceeded.
- Missing minter permission reverts.
- Max supply exceeded.
- Split configuration and locking.
- Artist-signed initial splits.
- Artist-signed/operator-submitted sale updates.
- Invalid sale update signature reverts.
- Empty comment does not emit `MintComment`.
- Non-empty comment emits `MintComment`.
- Comment over 500 bytes reverts with `CommentTooLong`.
- Comments are never stored in contract state.
- Pending claims.
- Shell disabled.
- Shell credit failure.
- Fee caps and fee-rounding protection.
- Pause behavior.
- Reentrancy-sensitive paths.

### Fork Tests

- Read Base factory and creator implementation.
- Confirm `PERMISSION_BIT_MINTER == 4`.
- Create collection/token with setup actions on a fork if practical.
- Grant custom minter permission.
- Confirm custom minter can call `adminMint`.

## Implementation Decisions

These decisions are derived from review of the plan and resolve ambiguities that would otherwise surface during implementation. They are binding for the v1 minter and ETH-native shell.

### D.1 — Sale-update authority and signatures

- `setSale(address collection, uint256 tokenId, SaleUpdate config)` is `onlyOwner`. Used for emergency / initial / operator-as-owner flows. Bumps `saleUpdateNonces[songKey]`.
- `setSaleWithArtistSignature(...)` is callable by anyone (operator relay). Signature must verify against `songArtist[songKey]` at consume time. Deadline enforced. Bumps `saleUpdateNonces[songKey]`.
- Owner can override an in-flight artist signature at any time; the nonce bump invalidates the artist's pending submission.
- See "EIP-712 Schemas" below for the typed-data definition.

### D.2 — ETH transfer semantics on the distribution path

- All distribution-path sends use a `_safeSendETH(to, amount)` helper that forwards a fixed gas stipend (30,000) and returns a boolean. Failure does not revert the collect.
- On failure, the amount is recorded in `pendingClaims[songKey][recipient]` and `SplitPaymentDeferred` is emitted. Applies to platform fee, every artist split, and the artist-default recipient.
- Pending ETH claims must support an alternate payout recipient. Recommended surface: `claimPendingTo(collection, tokenId, recipient, payoutTo, amount, nonce, deadline, authorization)`, where `recipient` can claim directly with `msg.sender == recipient` or authorize `payoutTo` with EIP-712/EIP-1271. The authorization must bind `collection`, `tokenId`, `recipient`, `payoutTo`, `amount`, `nonce`, and `deadline`; `claimPayoutNonces[songKey][recipient]` increments on every successful authorized claim. This avoids permanently trapping revenue when the recorded recipient is a contract wallet or vault that rejects raw ETH or needs more than the send stipend, while preventing an old authorization from redirecting later deferred revenue.
- The shell's `depositRewards{value: stakingFee}` call is wrapped in `try/catch`. On revert, the staking fee is folded back into artist revenue and re-distributed via the same split path. Emits `ShellDepositFailed`. (No double-payment risk — the shell call happens before split distribution, so artist revenue is recomputed.)
- Strict checks-effects-interactions inside `_distribute`: per-wallet cap write → `adminMint` → `creditStake` → `depositRewards` → platform send → split sends. Each external call is preceded by a state write.
- `nonReentrant` (transient guard) on `collect`, `batchCollect`, `claimPending`, and `claimPendingTo`.

### D.3 — `mintTo` recipient and per-wallet cap

- `collect(address collection, uint256 tokenId, uint256 quantity, uint256 maxTotalCost, address mintTo, string calldata comment)` and the equivalent `CollectItem` entry in `batchCollect` both carry an explicit `mintTo`. `msg.sender` is unreliable on Base under smart-wallet relayers (Coinbase Smart Wallet, paymasters, Safes); attribution must be on the recipient, not the relayer.
- `mintTo == address(0)` reverts `ZeroAddress`. Otherwise unrestricted (gift mints, sponsored relays, smart-wallet routes all work).
- Per-wallet cap storage: `mapping(bytes32 songKey => mapping(address => uint64)) public mintedByAddress;` keyed on `mintTo`.
- `tortRewardClaimed[songKey][mintTo]` — shell credit is attributed to the recipient.
- `MintComment` event's collector field is `mintTo`; its payer field is `msg.sender` and should be treated as the comment author.
- `SongCollected` includes both `mintTo` (collector) and `payer` (`msg.sender`) so the indexer can distinguish self vs. relayed collects.

### D.4 — Refund policy

- Strict equality: `msg.value == totalCost` for `collect`, `msg.value == aggregateCost` for `batchCollect`. Mismatch reverts `IncorrectEthValue(uint256 expected, uint256 actual)`.
- No refund logic. Frontend re-quotes against `sale(collection, tokenId)` immediately before submission. `maxTotalCost` / `maxAggregateCost` absorb mid-block sale changes.

### D.5 — Batch behavior

- `batchCollect` is all-or-nothing. Any item revert tears down the whole tx.
- Each item mints with one `adminMint(mintTo, tokenId, quantity, "")` call. Do not assume the In Process/Zora creator exposes a public `adminMintBatch`; fork tests should fail if implementation accidentally reintroduces that dependency.
- Per-item distribution runs immediately after that item's `adminMint` succeeds. Any later item revert still reverts the whole transaction because `batchCollect` is all-or-nothing.
- `MAX_BATCH_ITEMS = 20`. Phase-2 gas test asserts a worst-case 20-item × 10-split-each batch fits under 20M gas on Base.

### D.6 — `MintComment` constraints

- Contract enforces `bytes(comment).length <= 500` and reverts `CommentTooLong` otherwise.
- Empty comment → no `MintComment` emit.
- Non-empty comment → emit `MintComment(collection, tokenId, mintTo, msg.sender, quantity, comment)`. Never stored in contract state.
- UI should attribute the comment to `payer`, not blindly to `mintTo`, because unrestricted gift mints can attach comments to another recipient's token.
- Frontend hard-truncates to 500 UTF-8 bytes with a visible counter.

### D.7 — Pending-claim ETH accounting

- Storage: `uint256 public totalPendingClaims;` Increment in `_recordPendingClaim`, decrement in `claimPending`.
- Invariant (Phase-2 invariant test): `address(this).balance >= totalPendingClaims` at every external-call boundary.
- No `recoverETH` function on the minter. ERC-20 `recoverTokens(token, amount)` remains for stray tokens.

### D.8 — Shell-credit divergence

`_creditShell` returns `(bool fullCredit, uint256 actualCredit)`. The minter never reverts on shell-related failures. Collect always succeeds when `adminMint` succeeds.

| Condition | `tortRewardClaimed` | Staking fee routed to | Event |
| --- | --- | --- | --- |
| Already claimed | unchanged (true) | Artist revenue (no diversion) | none |
| `creditStake` reverts | unchanged (false) | Artist revenue | `ShellCreditFailed` |
| `creditStake` returns 0 | unchanged (false) | Artist revenue | `ShellCreditFailed` |
| Returns `0 < n < expected` | set to true | Artist revenue | `ShellCreditFailed(expectedCredit, actualCredit)` |
| Returns full | set to true | Shell via `depositRewards{value:}` | `StakeCredited` |
| Full credit but `depositRewards` reverts | set to true (user got TORT) | Artist revenue | `ShellDepositFailed` |

### D.9 — Royalty defaults

- EIP-2981 default at token setup: `royaltyBPS = 500` (5%), `royaltyRecipient = artist primary wallet`, `royaltyMintSchedule = 0`.
- Per-token override allowed via the setup-action helper (see `planning/setup-actions-reference.md`).
- Future per-token royalty updates are admin-gated on the collection — out of scope for the v1 minter; handled by ops scripts.

### D.10 — Album scope per collection

- One ERC-1155 collection per album. New tracks added to existing collections via the "Add Track" flow — backend operator wallet must hold per-collection admin permission. See `planning/setup-actions-reference.md` §C.4.

### D.11 — `TortoiseShell` ETH-native rewrite

The existing prototype `src/TortoiseShell.sol` is USDC-based and will be replaced wholesale. No migration logic; the prototype is a design reference only.

- Drop `IERC20 rewardToken`, `REWARD_SCALAR`, all scaled math.
- Storage shape stays the same (`rewardRate`, `rewardDuration`, `periodFinish`, `lastUpdateTime`, `rewardPerTokenStored`, `reservedBalance`, `_queuedReward`, `_queuedRewardUpdatedAt`, `userRewardPerTokenPaid`, `userUnpaidRewards`, `tortPool`, `tortRewardPerCollection`, `totalTortCredited`, `authorizedCallers`) but all amounts are wei.
- `MIN_REWARD_DEPOSIT = 1e15` wei (0.001 ETH). Document threat model in the contract: prevents cap-and-extend `rewardRate` dilution via dust deposits.
- `depositRewards()` is `external payable onlyAuthorizedCaller updateReward(address(0))`. No `amount` arg. Reconciles via `actual = address(this).balance - totalRewardsDeposited`. (TORT is ERC-20, separate balance, doesn't offset.)
- `_addReward(reward)` accepts wei directly (no `*= REWARD_SCALAR`).
- `_claimRewards(user, payoutTo, amount)` requires `amount <= userUnpaidRewards[user]`, debits exactly `amount`, and uses `_safeSendETH` with revert-on-failure. The public claim surface must let the reward owner choose a payable recipient, and should support EIP-712/EIP-1271 authorization for contract wallets or vaults that cannot receive raw ETH directly. Any delegated claim must bind `user`, `payoutTo`, `amount`, `nonce`, and `deadline`; `rewardClaimNonces[user]` increments on every successful delegated claim so old signatures cannot withdraw later rewards.
- `receive() external payable` reverts unless `authorizedCallers[msg.sender]`. Plain sends rejected; `selfdestruct` ETH still lands and is automatically swept on the next `depositRewards` reconciliation (documented behavior).
- No `recoverETH`. `recoverTokens(token, amount)` exists for stray ERC-20s with `token != address(stakingToken)`.
- All `require("...")` strings replaced with custom errors (`CallerMustBeContract`, `RenouncingOwnershipDisabled`, `CannotRecoverStakingToken`).
- `creditStake(user, rewardUnits)` returns reduced credit when `tortPool` is short; the minter passes `1` for the first eligible wallet/song collect and consumes the result per D.8. Any positive credit consumes the wallet/song reward entitlement unless implementation explicitly tracks a remaining entitlement.

### D.12 — Cleanup

- `SplitsConfigured`, `SplitsLocked`, `ShellDepositFailed`, `SplitPaymentDeferred`, `PaymentDistributed` are all listed in the Recommended Events section above.
- Per-wallet cap is in Phase 1 (storage cost is trivial; deferring it adds churn).
- The prototype `UnexpectedProceeds` invariant is not carried forward. New invariant is `msg.value == totalCost`, enforced before `adminMint`.
- `_validateFeeMinimum(totalCost, platformFeeBps)` and `_validateFeeMinimum(pricePerToken, stakingFeeBps)` are kept. With 18-decimal ETH at sane prices the rounding-to-zero check is effectively unreachable, but it is cheap and defends against future zero-priced configurations.

## Implementation Phases

### Phase 1: Contract Skeleton

- Add `ITortoiseInProcess1155` interface with `adminMint` only.
- Add `ICreator1155Factory` interface used by deployment scripts.
- Rewrite `TortoiseShell` as ETH-native (no migration logic; existing prototype is replaced wholesale).
- Add `TortoiseInProcessMinter`.
- Port fee, splits, EIP-712, pending-claim, and shell-credit patterns from the prototype router.
- Add sale config storage and events.
- Implement collect flow with native ETH, strict-equality `msg.value`, `mintTo` recipient argument, and per-wallet cap.
- Implement single `collect`.

### Phase 2: Batch And Hardening

- Add `batchCollect` that loops `adminMint` per item (`MAX_BATCH_ITEMS = 20`).
- Add full test suite (unit + fuzz + invariant).
- Add gas checks for realistic album collects (target: 20-item × 10-split-each batch fits under 20M gas).
- Add fork checks for factory address, creator implementation, and `PERMISSION_BIT_MINTER == 4`.
- Delete prototype router/shell/USDC-minter mocks once new contracts are green.

### Phase 3: Direct Creation Scripts

- Add setup action helpers.
- Add direct collection creation script.
- Add token creation/setup script for existing collections.
- Add sale registration script.
- Add deployment validation script.
- Require an explicit per-network factory allowlist. For Base Sepolia, scripts must
  fail closed until the In Process factory is confirmed and pinned in
  `planning/setup-actions-reference.md`; do not silently fall back to canonical Zora
  deployments.

### Phase 4: Backend And Indexer

- Add backend paths for direct factory calls.
- Add event indexer.
- Add reconciliation jobs.
- Update DB schema.
- Replace router-based collect calls with minter collect calls.

### Phase 5: Frontend

- Update upload flow to use Tortoise direct contract creation status.
- Update collect UI to call `TortoiseInProcessMinter` with native ETH value.
- Add album collect quote from backend/minter sale configs.
- Add owner/collector/comment views from Tortoise indexer.

## EIP-712 Schemas

The new minter signs and verifies typed data under a fresh EIP-712 domain. There are no legacy signatures to honor — the prototype router is undeployed and its domain is not preserved.

Domain:

```
EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
name    = "TortoiseInProcessMinter"
version = "1"
```

### S.1 — `SetSale` (artist-signed sale updates)

Typehash:

```
SetSale(address collection,uint256 tokenId,bytes32 saleHash,uint256 nonce,uint256 deadline)
```

`saleHash` covers the four fields of `SaleUpdate`:

```solidity
bytes32 saleHash = keccak256(abi.encode(
    config.saleStart,
    config.saleEnd,
    config.maxTokensPerAddress,
    config.pricePerToken
));
```

The internal `SaleConfig.exists` flag is contract-state, not part of the signed payload. `setSale` and `setSaleWithArtistSignature` must set `exists = true` internally instead of copying an unsigned calldata field.
The artist address is not included in the signed payload because the verifier always checks the signature against `songArtist[songKey]`. This avoids a redundant artist field drifting from the registered signer.

Nonce policy:

```solidity
mapping(bytes32 songKey => uint256) public saleUpdateNonces;
```

- Per-`(collection, tokenId)`, not per-artist. An artist who owns multiple tokens has independent counters per token.
- Read at consume time and incremented on consume in **both** `setSale` (owner) and `setSaleWithArtistSignature` (relayed). This way an owner override invalidates an in-flight artist signature.

Verification path:

```solidity
bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
    SET_SALE_TYPEHASH, collection, tokenId, saleHash, nonce, deadline
)));
if (block.timestamp > deadline) revert SaleSignatureExpired();
if (nonce != saleUpdateNonces[songKey]) revert SaleNonceMismatch(saleUpdateNonces[songKey], nonce);
if (!SignatureChecker.isValidSignatureNowCalldata(songArtist[songKey], digest, sig)) {
    revert InvalidSaleSignature();
}
saleUpdateNonces[songKey] = nonce + 1;
```

Errors required: `InvalidSaleSignature`, `SaleSignatureExpired`, `SaleNonceMismatch(uint256 expected, uint256 provided)`.

### S.2 — `RegisterSongWithSplits` (initial registration)

Carry forward from the prototype router with the new domain. Typehash:

```
RegisterSongWithSplits(address collection,uint256 tokenId,address artist,bytes32 splitsHash,bool lockSplits,uint256 nonce,uint256 deadline)
```

`splitsHash = keccak256(abi.encode(splits))` where `splits` is the `SplitRecipient[]` calldata.

Nonce: `mapping(address artist => uint256) public splitAuthorizationNonces;` (per-artist, same shape as the prototype).

Reuse the hashing pattern from the prototype router (`_hashRegisterSongWithSplits`, `_hashSplits`). Only the EIP-712 domain differs because the contract is new; the typehash string is unchanged.

### S.3 — Test vectors

Before audit, ship `test/fixtures/eip712-vectors.json` containing:

- 3 valid `SetSale` signatures across different `(collection, tokenId, nonce, deadline)` tuples.
- 1 expired `SetSale` signature.
- 1 wrong-nonce `SetSale` signature.
- 1 `SetSale` signature signed by a non-artist EOA.
- 3 valid `RegisterSongWithSplits` signatures.
- 1 `RegisterSongWithSplits` signature with mutated `splitsHash`.
- 2 valid `ClaimPendingTo` signatures with distinct nonces and amounts.
- 1 replayed `ClaimPendingTo` signature.
- 2 valid `ClaimShellRewardsTo` signatures with distinct nonces and amounts.
- 1 replayed `ClaimShellRewardsTo` signature.

Vectors are generated off-chain (viem or `cast wallet sign-typed-data`) and asserted onchain in a Foundry test that calls public hashing helpers and `SignatureChecker`. This catches drift between off-chain signing infrastructure and onchain verification before mainnet deployment.

### S.4 — `ClaimPendingTo` (deferred minter payouts)

Typehash:

```
ClaimPendingTo(address collection,uint256 tokenId,address recipient,address payoutTo,uint256 amount,uint256 nonce,uint256 deadline)
```

Nonce: `mapping(bytes32 songKey => mapping(address recipient => uint256)) public claimPayoutNonces;`.

The amount is signed so an authorization for one deferred payout cannot be replayed against later revenue for the same song and recipient. The implementation should require `amount <= pendingClaims[songKey][recipient]`, increment the nonce before the ETH send, and debit exactly `amount`.

### S.5 — `ClaimShellRewardsTo` (ETH shell rewards)

Typehash:

```
ClaimShellRewardsTo(address user,address payoutTo,uint256 amount,uint256 nonce,uint256 deadline)
```

Nonce: `mapping(address user => uint256) public rewardClaimNonces;`.

The amount is signed so an authorization for current accrued rewards cannot be replayed against future rewards. The implementation should require `amount <= claimableRewards(user)`, increment the nonce before the ETH send, and debit exactly `amount`.

## In Process Team Dependency

No In Process team work is required for the core implementation if Tortoise uses direct contracts and owns display/indexing.

Useful confirmations only:

1. Confirm current factory and creator implementation addresses on Base mainnet and Base Sepolia. Mainnet is currently pinned from existing In Process docs/local plan plus RPC reads; Base Sepolia remains unconfirmed.
2. Confirm `PERMISSION_BIT_MINTER = 4`.
3. Confirm direct `adminMint` from a permissioned custom minter is an acceptable contract path.

These confirmations are helpful, but the implementation should not block on them — fork tests will assert ABI behavior independently.

Exception: Base Sepolia deployment scripts must fail closed until the In Process-owned factory address is pinned. Fork tests can validate ABI behavior for a candidate, but they do not prove the candidate is the approved deployment.
