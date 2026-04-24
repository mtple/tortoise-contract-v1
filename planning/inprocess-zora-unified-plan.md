# Tortoise v1 Unified Development Plan: In Process Integration

This document is the planning source for the revised Tortoise v1 system. It replaces the earlier architecture where Tortoise owned the ERC-1155 minting contract. The new architecture delegates NFT infrastructure to In Process while Tortoise owns the economic layer.

In Process should be treated as a Zora-compatible fork or derivative, not canonical Zora itself. The implementation should use the verified In Process mainnet contract ABI and behavior, not assume canonical Zora ERC20Minter reward or referral mechanics.

Current assumption: In Process takes no protocol or platform mint fee. The router should therefore expect to receive the full USDC sale price as the payout recipient. If the router receives less than the expected sale price, collection should revert.

Two Tortoise contracts:

1. **TortoiseMintRouter**: sits between collectors and In Process. Routes USDC payments, distributes revenue, and triggers shell rewards.
2. **TortoiseShell**: staking contract. Users stake TORT, earn USDC rewards from collection fees, and receive automatic TORT crediting when they collect.

## Executive Summary

**Architecture shift:** In Process handles ERC-1155 token creation, metadata, and minting infrastructure. Tortoise no longer deploys its own NFT contract. Instead, Tortoise controls the payment flow through a mint router that wraps In Process collects, splits revenue, and feeds the staking flywheel.

**Why:** In Process provides NFT infrastructure, marketplace visibility, and Zora-compatible protocol structure. Tortoise's differentiation is the economic layer: TORT, TortoiseShell, USDC rewards, collector incentives, and curation. Owning the NFT contract adds maintenance burden without adding enough value.

**What Tortoise still owns:** TORT token, TortoiseShell staking, USDC revenue routing, collector TORT rewards, platform curation logic, and the relationship between collecting and staking.

## Overview

| Component | Owner | Responsibility |
|-----------|-------|----------------|
| ERC-1155 NFTs | In Process | Token creation, metadata, minting infrastructure |
| Song creation | Tortoise backend + In Process API | Creates moments with `payoutRecipient = TortoiseMintRouter` |
| Collection flow | TortoiseMintRouter | Pulls USDC, collects through In Process, distributes revenue, credits TORT |
| Staking | TortoiseShell | TORT staking, USDC reward distribution, TORT crediting |
| TORT token | Existing deployment | Ecosystem token |

## End-to-End Flow

### Song Creation

When an artist uploads a song through the Tortoise UI:

1. Tortoise backend uploads audio and metadata to IPFS or Arweave.
2. Backend calls the In Process API `POST /moment/create` with:
   - `token.tokenMetadataURI`: Arweave URI with song metadata
   - `token.salesConfig.type`: `erc20Mint`
   - `token.salesConfig.currency`: USDC address on Base
   - `token.salesConfig.pricePerToken`: song price in USDC units, for example `1000000` for $1.00
   - `token.payoutRecipient`: TortoiseMintRouter address, not the artist
   - `token.maxSupply`: `0` for unlimited, or a configured limit
3. In Process deploys or configures the ERC-1155 token with the ERC-20 sale configured.
4. Tortoise backend stores the `contractAddress` and `tokenId` in Supabase, linked to the song.

Critical detail: `payoutRecipient` is set to TortoiseMintRouter. All sale USDC should flow to the router, which then distributes according to the Tortoise economic model. In Process's own split feature is not used for Tortoise revenue splits; Tortoise handles splits downstream.

Because In Process is expected to take no fee, the router should require the USDC it receives to equal `pricePerToken * quantity`. This makes fee or payout behavior changes fail loudly instead of silently underpaying artists or the shell.

### Collection Flow

```text
Collector calls TortoiseMintRouter.collect(collection, tokenId, quantity, maxTotalCost, mintData)
  |
  +-- 1. Router queries sale config from the allowlisted In Process minter or sale contract
  |       totalCost = pricePerToken * quantity
  |       require(currency == USDC)
  |       require(payoutRecipient/fundsRecipient == TortoiseMintRouter)
  |       require(totalCost <= maxTotalCost)
  |
  +-- 2. Router pulls USDC from collector
  |
  +-- 3. Router approves exact USDC amount to the allowlisted In Process minter
  |
  +-- 4. Router calls the verified In Process collect or mint function
  |       In Process mints NFT to collector
  |       Full sale value must remain with the router after the external call
  |       require(routerBalanceAfter == routerBalanceBefore + totalCost)
  |
  +-- 5. Router distributes USDC
  |       5% platform fee -> platform fee recipient
  |       10% staking fee -> TortoiseShell.depositRewards()
  |       85% artist revenue -> artist wallet or split recipients
  |
  +-- 6. Router credits TORT to collector's shell
          try TortoiseShell.creditStake(collector, quantity)
          catch -> emit ShellCreditFailed, mint still succeeds
```

### Why the Router Mediates

The collector approves USDC to TortoiseMintRouter only. The router handles all downstream approvals and calls. This keeps the collector experience to one approval and one `collect()` call while giving Tortoise full control of the payment flow.

## TortoiseMintRouter

### Responsibility

TortoiseMintRouter is a payment routing contract that wraps In Process collects. It has no ERC-1155 logic, no token storage, and no metadata logic. It:

- Accepts USDC from collectors
- Triggers the In Process collect or mint call, with the NFT going to the collector
- Receives full sale proceeds as `payoutRecipient`, `fundsRecipient`, or the equivalent In Process payout field
- Splits USDC into platform fee, staking fee, and artist revenue
- Credits TORT to the collector's shell

### State

```solidity
IERC20 public immutable usdc;
address public inProcessMinter;
address public tortoiseShell;
address public platformFeeRecipient;

uint256 public platformFeeBps; // Default: 500, or 5%
uint256 public stakingFeeBps;  // Default: 1000, or 10%
uint256 public constant BASIS_POINTS = 10_000;
uint256 public constant MAX_FEE_BPS = 2_000;

mapping(bytes32 => SplitRecipient[]) internal songSplits;
mapping(bytes32 => address) public songArtist;
mapping(bytes32 => bool) public splitsLocked;

address public owner;
```

`inProcessMinter` is an allowlisted In Process contract address. The collector should not supply an arbitrary minter address, because the router approves USDC and makes an external call during collection.

### Key Functions

```solidity
function collect(
    address collection,
    uint256 tokenId,
    uint256 quantity,
    uint256 maxTotalCost,
    bytes calldata mintData
) external nonReentrant whenNotPaused;

function registerSong(
    address collection,
    uint256 tokenId,
    address artist
) external onlyOwner;

function configureSplits(
    address collection,
    uint256 tokenId,
    SplitRecipient[] calldata splits
) external;

function lockSplits(address collection, uint256 tokenId) external;

function updateInProcessMinter(address newMinter) external onlyOwner;
```

The final `mintData` shape should be narrowed once the production In Process ABI is verified. Prefer explicit typed arguments over arbitrary bytes if the ABI supports it.

### Collect Flow

```solidity
function collect(
    address collection,
    uint256 tokenId,
    uint256 quantity,
    uint256 maxTotalCost,
    bytes calldata mintData
) external nonReentrant whenNotPaused {
    bytes32 songKey = keccak256(abi.encodePacked(collection, tokenId));
    require(songArtist[songKey] != address(0), "Song not registered");
    require(quantity > 0, "Zero quantity");

    InProcessSale memory sale = IInProcessMinter(inProcessMinter).sale(collection, tokenId);
    require(sale.currency == address(usdc), "Invalid currency");
    require(sale.payoutRecipient == address(this), "Invalid payout recipient");

    uint256 pricePerToken = sale.pricePerToken;
    uint256 totalCost = pricePerToken * quantity;
    require(totalCost <= maxTotalCost, "Price exceeds max");
    require(totalCost > 0, "Zero cost");

    uint256 balanceBefore = usdc.balanceOf(address(this));
    usdc.safeTransferFrom(msg.sender, address(this), totalCost);

    usdc.forceApprove(inProcessMinter, totalCost);

    IInProcessMinter(inProcessMinter).collect(collection, tokenId, quantity, msg.sender, mintData);

    usdc.forceApprove(inProcessMinter, 0);

    uint256 expectedBalance = balanceBefore + totalCost;
    uint256 balanceAfter = usdc.balanceOf(address(this));
    require(balanceAfter == expectedBalance, "Unexpected proceeds");

    _distribute(collection, tokenId, quantity, totalCost, msg.sender);

    emit SongCollected(collection, tokenId, msg.sender, quantity, totalCost);
}
```

### Revenue Distribution

```solidity
function _distribute(
    address collection,
    uint256 tokenId,
    uint256 quantity,
    uint256 totalReceived,
    address collector
) internal {
    uint256 platformFee = (totalReceived * platformFeeBps) / BASIS_POINTS;
    if (platformFee > 0) {
        usdc.safeTransfer(platformFeeRecipient, platformFee);
    }

    uint256 stakingFee = (totalReceived * stakingFeeBps) / BASIS_POINTS;
    if (stakingFee > 0 && tortoiseShell != address(0)) {
        usdc.safeTransfer(tortoiseShell, stakingFee);
        ITortoiseShell(tortoiseShell).depositRewards(stakingFee);
    }

    uint256 artistRevenue = totalReceived - platformFee - stakingFee;
    bytes32 songKey = keccak256(abi.encodePacked(collection, tokenId));
    _distributeArtistRevenue(songKey, artistRevenue);

    _creditShell(collection, tokenId, collector, quantity);

    emit RevenueDistributed(collection, tokenId, platformFee, stakingFee, artistRevenue);
}

function _creditShell(
    address collection,
    uint256 tokenId,
    address collector,
    uint256 quantity
) internal {
    if (tortoiseShell == address(0)) return;

    try ITortoiseShell(tortoiseShell).creditStake(collector, quantity) {
        emit StakeCredited(collection, tokenId, collector, quantity);
    } catch {
        emit ShellCreditFailed(collection, tokenId, collector, quantity);
    }
}
```

### Song Pricing

Song price is set when the moment is created through the In Process API using `salesConfig.pricePerToken`. The router reads this price from the verified In Process sale config view. The router does not store prices.

Fees are inclusive: they are taken from the sale price, not added on top.

No In Process protocol fee is expected. If the router receives less than the full sale price, the collect reverts.

Example for a $1.00 sale:

| Component | Amount |
|-----------|--------|
| Collector pays | $1.00 |
| Platform fee | $0.05 |
| Staking fee | $0.10 |
| Artist revenue | $0.85 |

Example for five $1.00 copies:

| Component | Amount |
|-----------|--------|
| Collector pays | $5.00 |
| Platform fee | $0.25 |
| Staking fee | $0.50 |
| Artist revenue | $4.25 |

### Artist Revenue Splits

The router uses on-chain per-song splits, reusing the split validation rules from the current Tortoise implementation.

Split rules:

- Splits are optional.
- If no splits are configured, 100% of artist revenue goes to `songArtist`.
- Percentages are basis points and must sum to `10_000`.
- Minimum allocation is 1% per recipient.
- Maximum recipient count is 10.
- Duplicate recipients are rejected.
- Splits are permanently lockable.

Decision: preserve the current contract's one-recipient support. Requiring two recipients would add friction without improving safety; a single recipient at `10_000` bps is a valid split.

### Admin Functions

```solidity
function updatePlatformFeeBps(uint256 newBps) external onlyOwner;
function updateStakingFeeBps(uint256 newBps) external onlyOwner;
function updateTortoiseShell(address newShell) external onlyOwner;
function updatePlatformFeeRecipient(address newRecipient) external onlyOwner;
function updateInProcessMinter(address newMinter) external onlyOwner;
function pause() external onlyOwner;
function unpause() external onlyOwner;
function recoverTokens(address token, uint256 amount) external onlyOwner;
```

Expected admin behavior:

- `updateTortoiseShell(address(0))` auto-zeros `stakingFeeBps`.
- `updateStakingFeeBps` requires `tortoiseShell != address(0)` for non-zero values.
- `recoverTokens` blocks USDC recovery.
- Fee updates enforce `platformFeeBps + stakingFeeBps < BASIS_POINTS`.
- Individual fee caps are enforced through `MAX_FEE_BPS`.
- `updateInProcessMinter` rejects zero address and emits the old and new minter. Use sparingly; the preferred production shape is a stable, verified In Process contract address.

### Events

```solidity
event SongCollected(address indexed collection, uint256 indexed tokenId, address indexed collector, uint256 quantity, uint256 totalPaid);
event RevenueDistributed(address indexed collection, uint256 indexed tokenId, uint256 platformFee, uint256 stakingFee, uint256 artistRevenue);
event StakeCredited(address indexed collection, uint256 indexed tokenId, address indexed collector, uint256 quantity);
event ShellCreditFailed(address indexed collection, uint256 indexed tokenId, address indexed collector, uint256 quantity);
event SongRegistered(address indexed collection, uint256 indexed tokenId, address indexed artist);
event SplitsConfigured(address indexed collection, uint256 indexed tokenId);
event SplitsLocked(address indexed collection, uint256 indexed tokenId);
event InProcessMinterUpdated(address indexed oldMinter, address indexed newMinter);
```

Custom errors should be preferred over revert strings in implementation, including an `UnexpectedProceeds(expectedBalance, actualBalance)` error for balance mismatch.

## TortoiseShell

TortoiseShell carries forward from the current implementation. The authorized caller changes from `TortoiseV1` to `TortoiseMintRouter`.

### Summary

- Users stake TORT and earn USDC rewards through a 7-day Synthetix-style drip.
- Every collection deposits the staking fee into TortoiseShell for distribution to all stakers.
- Every collection credits fixed TORT per copy into the collector's staked balance.
- TORT pool depletion degrades gracefully and never reverts the mint.
- `depositRewards` reconciles actual USDC received from token balance, rather than trusting caller-provided amount.
- Reward duration is bounded and cannot be zero.

### Interface

```solidity
interface ITortoiseShell {
    function depositRewards(uint256 amount) external;
    function creditStake(address user, uint256 quantity) external returns (uint256 credited);
}
```

The current TortoiseShell reward math, TORT credit mechanics, pause behavior, and accounting invariants still apply.

## Security Notes

### Router Requirements

- **In Process only:** integrate with verified In Process contracts. Do not assume canonical Zora ERC20Minter reward or referral behavior.
- **No arbitrary minter:** the router uses an allowlisted In Process minter or sale contract. Do not accept a user-provided minter address.
- **Full proceeds verification:** after the In Process collect, require router USDC balance to equal pre-collect balance plus `pricePerToken * quantity`. Any protocol fee, transfer slippage, or unexpected payout behavior should revert.
- **Sale config validation:** require registered song, nonzero quantity, USDC currency, router payout recipient, nonzero price, and `totalCost <= maxTotalCost`.
- **Shell disabled plus staking fee:** `updateTortoiseShell(address(0))` auto-zeros `stakingFeeBps`, and non-zero staking fee requires a configured shell.
- **Fee cap:** `platformFeeBps + stakingFeeBps` must be less than `BASIS_POINTS`.
- **Shell credit try/catch:** shell graceful degradation, router try/catch, and shell kill switch all preserve collection flow.
- **Reentrancy:** `collect()` is `nonReentrant`; In Process minting is an external call.
- **Front-run protection:** `maxTotalCost` lets the collector cap total USDC paid.
- **Approval hygiene:** prefer resetting USDC approval to zero after minting, or using a bounded force-approve helper if the chosen USDC interface requires it.
- **Artist payout safety:** preserve the pending-claim/deferred-transfer pattern for artist and split payments so a bad recipient cannot block future collects.

### Shell Requirements

- Balance-delta verification on `depositRewards`.
- `rewardDuration` cannot be zero.
- `creditStake` never blocks collection flow.
- `reservedBalance` protects pending claims.
- State-changing functions are protected with reentrancy guards where appropriate.

## Testing Strategy

### Mock Contracts

- **MockUSDC:** ERC-20, 6 decimals, public `mint()`.
- **MockTORT:** ERC-20, 18 decimals, public `mint()`.
- **MockInProcessMinter:** implements the verified In Process `sale()` and collect/mint behavior.
- **MockInProcessMinterWithFee:** intentionally pays the router less than `pricePerToken * quantity` to prove the router reverts.
- **MockTortoiseShell:** records `depositRewards` and `creditStake` calls.

### Unit Tests

TortoiseMintRouter:

- Single-copy and multi-copy `collect()`.
- Revenue split math for 5% platform, 10% staking, 85% artist.
- Artist split configuration, lock behavior, and edge cases.
- Shell disabled behavior.
- Shell credit failure behavior.
- Fee validation.
- `maxTotalCost` front-run protection.
- Strict full-proceeds balance-delta accounting.
- Revert when In Process sale currency is not USDC.
- Revert when In Process payout recipient is not the router.
- Revert when In Process sends less than expected.
- Admin functions.
- Revert cases.

TortoiseShell:

- Stake, withdraw, claim, exit, and emergency withdraw.
- USDC drip math.
- `creditStake` normal, partial-pool, and empty-pool behavior.
- Reward snapshots.
- TORT pool management.
- Access control.
- Pause behavior.

### Fuzz And Invariant Tests

- Fuzz random fees, quantities, and prices to ensure distribution sums correctly.
- Invariant: router should not retain unexpected USDC after `collect()`.
- Invariant: shell accounting remains solvent across stake, withdraw, reward, claim, emergency withdraw, and credit paths.

### Fork Tests

- Full flow against real In Process contracts and USDC on a Base mainnet fork.
- Migration flow from the old staker.

## Deployment Shape

```text
1. Deploy TortoiseShell with TORT, USDC, rewardDuration = 604800.
2. Deploy TortoiseMintRouter with USDC, TortoiseShell, platformFeeRecipient, 500 bps platform fee, and 1000 bps staking fee.
3. Register TortoiseMintRouter as an authorized caller on TortoiseShell.
4. Fund the TortoiseShell TORT pool.
5. Set tortRewardPerCollection.
6. Update backend so new moments use the router address as `payoutRecipient`.
```

Validation is mainnet-oriented. There is no required Base Sepolia testing path in this plan.

## Migration

### From v0.3

- New songs go through In Process via TortoiseMintRouter.
- v0.3 NFTs remain on the old contract.

### From Old Staker/FeePool

- Stop ETH rewards.
- Users migrate to TortoiseShell.
- Frontend exposes a "Migrate Your Shell" flow.

## Open Questions

- **Song price:** $1.00 default, or variable per artist?
- **TORT reward per collection:** amount TBD.
- **Initial TORT pool size:** model launch volume against available TORT budget.
- **In Process ABI:** exact production ABI for sale reads and collect/mint calls on Base mainnet.
- **In Process mainnet address:** confirm the production minter or sale contract address to allowlist in the router.
- **Payout field mapping:** confirm whether API `token.payoutRecipient` maps on-chain to `payoutRecipient`, `fundsRecipient`, or another field.
- **No-fee invariant:** confirm with mainnet fork that router receives exactly `pricePerToken * quantity` for ERC-20 collects.
- **Max supply semantics:** confirm whether `maxSupply: 0` means unlimited, or whether In Process expects another unlimited sentinel.
- **Collect UX:** decide whether frontend supplies only user-facing collection inputs, or also ABI-specific `mintData`.
- **Split authorization:** owner-only for launch, artist-only, or backend-signed artist authorization.
- **Existing v0.3 songs:** re-create on In Process or leave as-is?
- **In Process API authentication:** backend API key management.

## Reference Addresses

| Token or Contract | Network | Address |
|-------------------|---------|---------|
| USDC | Base Mainnet | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| TORT | Base Mainnet | `0x601410d1d3093cF469fCA4e1EfB2Fb67B4E225c6` |
| In Process | Base Mainnet | `0x540C18B7f99b3b599c6FeB99964498931c211858` |
| Staker (old) | Base Mainnet | `0xFb05Da3E5522f95b63AFd4ab77e94540f285a912` |
| FeePool (old) | Base Mainnet | `0x1e2674743Ad7E352657899B7f38Ec7C7d4C2E518` |
