# Router To Custom Minter Migration Plan

This document plans the move from `TortoiseMintRouter` to a custom Tortoise minter that mints In Process/Zora-compatible ERC-1155 tokens directly.

This plan also changes the payment currency from USDC to native ETH.

## Decision

Use the In Process contracts directly instead of the hosted In Process API for the core creation and collect flow.

Tortoise does not need moments to appear in the In Process app. Tortoise will own display, indexing, album data, sale data, comments, collector views, and UI. In Process is used as the deployed ERC-1155 creator contract system.

The custom minter is the preferred architecture because it owns the full collect path:

1. Receive ETH from the payer.
2. Mint the In Process ERC-1155 token to `mintTo` via `adminMint`.
3. Credit TortoiseShell for the recipient if eligible.
4. Distribute platform fees, staking fees, and artist splits, with staking fees deposited only after successful shell credit.
5. Emit Tortoise-native events for indexing.

The router architecture should be treated as superseded. Its useful pieces are the fee logic, splits logic, shell-credit behavior, batch collect behavior, and security checks.

## Why Move Away From The Router

The router was designed to wrap the standard In Process ERC-20 minter. That made sense only if Tortoise needed to stay compatible with the In Process hosted API/app/indexer/collect flow.

For a Tortoise-owned direct-contract flow, the router adds an unnecessary dependency:

- The standard In Process ERC-20 minter remains the real minter.
- The router must be configured as sale `fundsRecipient`.
- Direct collects through the standard minter can send USDC to the router without executing Tortoise distribution logic.
- Pricing and sale state live in a third-party minter instead of the Tortoise economic contract.
- The router must approve another external minter during the hot collect path.
- The existing router design is USDC-first, but the target product direction is ETH-first.

The custom minter removes that middle layer. Tortoise becomes the sale contract and minting path.

## Contract Facts This Plan Relies On

- In Process uses a Zora-compatible ERC-1155 creator implementation.
- The creator contract exposes `adminMint(address recipient, uint256 tokenId, uint256 quantity, bytes data)`.
- `adminMint` is callable by collection admins or addresses with `PERMISSION_BIT_MINTER`.
- `PERMISSION_BIT_MINTER` is `4`.
- Setup actions can grant minter permission with `addPermission(tokenId, minter, 4)`.
- The factory accepts setup actions when creating a collection.
- Direct contract integration does not require the In Process API.

Confirmed Base addresses:

| Contract | Base Address |
| --- | --- |
| Creator1155FactoryImpl | `0x540C18B7f99b3b599c6FeB99964498931c211858` |
| In Process ERC-20 minter, reference only | `0xE27d9Dc88dAB82ACa3ebC49895c663C6a0CfA014` |

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

1. Backend verifies the artist can administer the target collection.
2. Backend calls the collection directly to create/setup the new token.
3. Backend grants `PERMISSION_BIT_MINTER` to `TortoiseInProcessMinter` for the token.
4. Backend registers sale config and splits in the Tortoise minter.

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
error InvalidArtistSaleSignature();

struct SaleConfig {
    uint64 saleStart;
    uint64 saleEnd;
    uint64 maxTokensPerAddress;
    uint256 pricePerToken;
    bool exists;
}

struct CollectItem {
    address collection;
    uint256 tokenId;
    address mintTo;
    uint256 quantity;
    uint256 maxTotalCost;
}

function collect(
    address collection,
    uint256 tokenId,
    address mintTo,
    uint256 quantity,
    uint256 maxTotalCost,
    string calldata comment
) external payable nonReentrant whenNotPaused;

function batchCollect(
    CollectItem[] calldata items,
    uint256 maxAggregateCost
) external payable nonReentrant whenNotPaused;

function setSale(
    address collection,
    uint256 tokenId,
    SaleConfig calldata config
) external;

function setSaleWithArtistSignature(
    address collection,
    uint256 tokenId,
    SaleConfig calldata config,
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
    address indexed collector,
    address indexed collection,
    uint256 indexed tokenId,
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
    uint256 rewardUnits
);
```

Keep ERC-1155 `TransferSingle` and `TransferBatch` indexing separate from Tortoise minter event indexing. The ERC-1155 collection remains the source of ownership truth.

## Router Logic To Reuse

Carry forward from `TortoiseMintRouter`:

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

Payer calls collect(collection, tokenId, mintTo, quantity, maxTotalCost, comment).

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
- `SplitsConfigured`
- `SplitsLocked`
- ERC-1155 `TransferSingle`
- ERC-1155 `TransferBatch`

The database should treat backend-created records as the primary catalog and contract events as the settlement truth.

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

1. Deploy or reuse `TortoiseShell`.
2. Deploy `TortoiseInProcessMinter`.
3. Register the minter as an authorized caller on `TortoiseShell`.
4. Create a test collection through the In Process factory.
5. Create a test token with minter permission setup action.
6. Configure sale and splits in the Tortoise minter.
7. Collect with Base Sepolia ETH.
8. Verify ERC-1155 ownership, ETH distribution, shell credit, and indexer records.

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

## Implementation Phases

### Phase 1: Contract Skeleton

- Add `ITortoiseInProcess1155` interface with `adminMint`.
- Add `TortoiseInProcessMinter`.
- Port fee, splits, EIP-712, pending-claim, and shell-credit logic from router.
- Add sale config storage and events.
- Convert collect flow to native ETH.
- Update Shell for native ETH rewards.
- Add single collect.

### Phase 2: Batch And Hardening

- Add `batchCollect`.
- Add max per wallet.
- Add full test suite.
- Add gas checks for realistic album collects.
- Add fork checks for factory and permission constants.

### Phase 3: Direct Creation Scripts

- Add setup action helpers.
- Add direct collection creation script.
- Add token creation/setup script for existing collections.
- Add sale registration script.
- Add deployment validation script.

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

## In Process Team Dependency

No In Process team work is required for the core implementation if Tortoise uses direct contracts and owns display/indexing.

Useful confirmations only:

1. Confirm current factory and creator implementation addresses.
2. Confirm `PERMISSION_BIT_MINTER = 4`.
3. Confirm direct `adminMint` from a permissioned custom minter is an acceptable contract path.
4. Confirm whether the docs typo for the Base ERC-20 minter address should be corrected.

These confirmations are helpful, but the implementation should not block on them.

Exception: Base Sepolia deployment scripts must fail closed until the In Process-owned factory address is pinned. Fork tests can validate ABI behavior for a candidate, but they do not prove the candidate is the approved deployment.
