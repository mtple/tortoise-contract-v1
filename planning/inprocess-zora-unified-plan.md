# Tortoise v1 Unified Development Plan: InProcess/Zora Integration

This document is the planning source for the revised Tortoise v1 system. It replaces the earlier architecture where Tortoise owned the ERC-1155 minting contract. The new architecture delegates NFT infrastructure to InProcess/Zora while Tortoise owns the economic layer.

Two Tortoise contracts:

1. **TortoiseMintRouter**: sits between collectors and InProcess/Zora. Routes USDC payments, distributes revenue, and triggers shell rewards.
2. **TortoiseShell**: staking contract. Users stake TORT, earn USDC rewards from collection fees, and receive automatic TORT crediting when they collect.

## Executive Summary

**Architecture shift:** InProcess/Zora handles ERC-1155 token creation, metadata, and minting infrastructure. Tortoise no longer deploys its own NFT contract. Instead, Tortoise controls the payment flow through a mint router that wraps Zora mints, splits revenue, and feeds the staking flywheel.

**Why:** InProcess/Zora provides NFT infrastructure, marketplace visibility, and protocol compatibility. Tortoise's differentiation is the economic layer: TORT, TortoiseShell, USDC rewards, collector incentives, and curation. Owning the NFT contract adds maintenance burden without adding enough value.

**What Tortoise still owns:** TORT token, TortoiseShell staking, USDC revenue routing, collector TORT rewards, platform curation logic, and the relationship between collecting and staking.

## Overview

| Component | Owner | Responsibility |
|-----------|-------|----------------|
| ERC-1155 NFTs | InProcess/Zora | Token creation, metadata, minting infrastructure |
| Song creation | Tortoise backend + InProcess API | Creates moments with `payoutRecipient = TortoiseMintRouter` |
| Collection flow | TortoiseMintRouter | Pulls USDC, mints through Zora, distributes revenue, credits TORT |
| Staking | TortoiseShell | TORT staking, USDC reward distribution, TORT crediting |
| TORT token | Existing deployment | Ecosystem token |

## End-to-End Flow

### Song Creation

When an artist uploads a song through the Tortoise UI:

1. Tortoise backend uploads audio and metadata to IPFS or Arweave.
2. Backend calls the InProcess API `POST /moment/create` with:
   - `token.tokenMetadataURI`: Arweave URI with song metadata
   - `token.salesConfig.type`: `erc20Mint`
   - `token.salesConfig.currency`: USDC address on Base
   - `token.salesConfig.pricePerToken`: song price in USDC units, for example `1000000` for $1.00
   - `token.payoutRecipient`: TortoiseMintRouter address, not the artist
   - `token.maxSupply`: `0` for unlimited, or a configured limit
3. InProcess/Zora deploys the ERC-1155 token with the ERC20Minter sale configured.
4. Tortoise backend stores the `contractAddress` and `tokenId` in Supabase, linked to the song.

Critical detail: `payoutRecipient` is set to TortoiseMintRouter. All sale USDC flows to the router, which then distributes according to the Tortoise economic model. InProcess's own split feature is not used for Tortoise revenue splits; Tortoise handles splits downstream.

### Collection Flow

```text
Collector calls TortoiseMintRouter.collect(collection, tokenId, quantity, minter, minterArgs, maxTotalCost)
  |
  +-- 1. Router queries sale price from Zora ERC20Minter
  |       totalCost = pricePerToken * quantity
  |       require(totalCost <= maxTotalCost)
  |
  +-- 2. Router pulls USDC from collector
  |
  +-- 3. Router approves USDC to Zora ERC20Minter
  |
  +-- 4. Router calls Zora 1155 mint()
  |       ERC20Minter pulls USDC, mints NFT to collector
  |       sale USDC lands at payoutRecipient, the router
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

TortoiseMintRouter is a payment routing contract that wraps InProcess/Zora mints. It has no ERC-1155 logic, no token storage, and no metadata logic. It:

- Accepts USDC from collectors
- Triggers the Zora mint, with the NFT going to the collector
- Receives sale proceeds as `fundsRecipient` or equivalent payout recipient
- Splits USDC into platform fee, staking fee, and artist revenue
- Credits TORT to the collector's shell

### State

```solidity
IERC20 public immutable usdc;
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

### Key Functions

```solidity
function collect(
    address collection,
    uint256 tokenId,
    uint256 quantity,
    address minter,
    bytes calldata minterArgs,
    uint256 maxTotalCost
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
```

### Collect Flow

```solidity
function collect(
    address collection,
    uint256 tokenId,
    uint256 quantity,
    address minter,
    bytes calldata minterArgs,
    uint256 maxTotalCost
) external nonReentrant whenNotPaused {
    uint256 pricePerToken = IZoraERC20Minter(minter).sale(collection, tokenId).pricePerToken;
    uint256 totalCost = pricePerToken * quantity;
    require(totalCost <= maxTotalCost, "Price exceeds max");
    require(totalCost > 0, "Zero cost");

    usdc.safeTransferFrom(msg.sender, address(this), totalCost);

    usdc.approve(minter, totalCost);
    uint256 balanceBefore = usdc.balanceOf(address(this)) - totalCost;

    IZora1155(collection).mint(
        IMinter1155(minter),
        tokenId,
        quantity,
        new address[](0),
        minterArgs
    );

    uint256 received = usdc.balanceOf(address(this)) - balanceBefore;

    _distribute(collection, tokenId, quantity, received, msg.sender);

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

Song price is set when the moment is created through the InProcess API using `salesConfig.pricePerToken`. The router reads this price from the Zora ERC20Minter `sale()` view function. The router does not store prices.

Fees are inclusive: they are taken from the sale price, not added on top.

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

The imported draft says min 2 recipients. During implementation, decide whether to preserve the current contract's one-recipient support or enforce a new two-recipient minimum.

### Admin Functions

```solidity
function updatePlatformFeeBps(uint256 newBps) external onlyOwner;
function updateStakingFeeBps(uint256 newBps) external onlyOwner;
function updateTortoiseShell(address newShell) external onlyOwner;
function updatePlatformFeeRecipient(address newRecipient) external onlyOwner;
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

### Events

```solidity
event SongCollected(address indexed collection, uint256 indexed tokenId, address indexed collector, uint256 quantity, uint256 totalPaid);
event RevenueDistributed(address indexed collection, uint256 indexed tokenId, uint256 platformFee, uint256 stakingFee, uint256 artistRevenue);
event StakeCredited(address indexed collection, uint256 indexed tokenId, address indexed collector, uint256 quantity);
event ShellCreditFailed(address indexed collection, uint256 indexed tokenId, address indexed collector, uint256 quantity);
event SongRegistered(address indexed collection, uint256 indexed tokenId, address indexed artist);
event SplitsConfigured(address indexed collection, uint256 indexed tokenId);
event SplitsLocked(address indexed collection, uint256 indexed tokenId);
```

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

- **Balance delta verification:** after the Zora mint, measure actual USDC received by balance delta. Do not trust expected amount alone.
- **Shell disabled plus staking fee:** `updateTortoiseShell(address(0))` auto-zeros `stakingFeeBps`, and non-zero staking fee requires a configured shell.
- **Fee cap:** `platformFeeBps + stakingFeeBps` must be less than `BASIS_POINTS`.
- **Shell credit try/catch:** shell graceful degradation, router try/catch, and shell kill switch all preserve collection flow.
- **Reentrancy:** `collect()` is `nonReentrant`; Zora minting is an external call.
- **Front-run protection:** `maxTotalCost` lets the collector cap total USDC paid.
- **Approval hygiene:** prefer resetting USDC approval to zero after minting, or using a bounded force-approve helper if the chosen USDC interface requires it.

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
- **MockZora1155:** implements `mint()`, accepts USDC, mints tokens.
- **MockERC20Minter:** implements `sale()` view and processes USDC payment.
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
- Balance-delta accounting.
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

- Full flow against real Zora 1155 and USDC on a Base mainnet fork.
- Migration flow from the old staker.

## Deployment Shape

```text
1. Deploy TortoiseShell with TORT, USDC, rewardDuration = 604800.
2. Deploy TortoiseMintRouter with USDC, TortoiseShell, platformFeeRecipient, 500 bps platform fee, and 1000 bps staking fee.
3. Register TortoiseMintRouter as an authorized caller on TortoiseShell.
4. Fund the TortoiseShell TORT pool.
5. Set tortRewardPerCollection.
6. Update backend so new moments use the router address as payoutRecipient.
```

Validation is mainnet-oriented. There is no required Base Sepolia testing path in this plan.

## Migration

### From v0.3

- New songs go through InProcess/Zora via TortoiseMintRouter.
- v0.3 NFTs remain on the old contract.

### From Old Staker/FeePool

- Stop ETH rewards.
- Users migrate to TortoiseShell.
- Frontend exposes a "Migrate Your Shell" flow.

## Open Questions

- **Song price:** $1.00 default, or variable per artist?
- **TORT reward per collection:** amount TBD.
- **Initial TORT pool size:** model launch volume against available TORT budget.
- **Collect UX:** should frontend resolve minter address and encode args, or should router expose a simpler interface?
- **Split authorization:** how should `configureSplits` verify the caller is the song's artist?
- **Existing v0.3 songs:** re-create on InProcess or leave as-is?
- **InProcess API authentication:** backend API key management.
- **Router payout sequencing:** confirm exact Zora flow for ERC20Minter proceeds and payout recipient behavior before implementation.

## Reference Addresses

| Token or Contract | Network | Address |
|-------------------|---------|---------|
| USDC | Base Mainnet | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| TORT | Base Mainnet | `0x601410d1d3093cF469fCA4e1EfB2Fb67B4E225c6` |
| InProcess | Base Mainnet | `0x540C18B7f99b3b599c6FeB99964498931c211858` |
| Staker (old) | Base Mainnet | `0xFb05Da3E5522f95b63AFd4ab77e94540f285a912` |
| FeePool (old) | Base Mainnet | `0x1e2674743Ad7E352657899B7f38Ec7C7d4C2E518` |
