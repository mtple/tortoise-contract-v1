# Tortoise v1 — Unified Development Plan

This document is the single source of truth for the Tortoise v1 system: two contracts deployed together in one Foundry repo.

1. **TortoiseV1** — ERC-1155 music NFT collection contract with USDC payments and revenue splits.
2. **TortoiseShell** — Staking contract where users stake $TORT, earn USDC rewards from collection fees, and receive automatic TORT crediting when they collect music.

---

## Executive Summary

**Build** — Two contracts, one repo. TortoiseV1 handles song creation, minting, USDC payments, and revenue splits. TortoiseShell handles staking, USDC reward distribution (7-day drip), and TORT crediting from a pre-funded pool. Full test suites for both.

**Deploy** — TortoiseShell first, then TortoiseV1 with the shell address. Register V1 as an authorized caller on the shell. Fund the TORT pool. Set fees.

**Migrate** — Users move $TORT from old Staker/FeePool (WETH rewards) to TortoiseShell (USDC rewards). Artists re-create songs on V1. Old contracts stay accessible but dormant.

**Live** — Someone collects a song. USDC splits three ways: platform fee, staking fee (dripped to all stakers), artist revenue (to split recipients). TORT from the shell's pool is credited into the collector's staked balance, growing their share of future rewards. The flywheel runs.

---

## Overview of Changes from v0.3

| Feature | v0.3 | v1 |
|---------|------|------|
| Payment Token | ETH | USDC |
| Song Price | Variable (ETH) | Configurable per-song, default $0.95 artist revenue per copy |
| Platform Fee | Variable (ETH) | $0.05 flat per transaction (configurable) |
| Staking Fee | None | Flat per transaction, USDC → TortoiseShell (configurable, TBD) |
| TORT Credit | None | Fixed TORT per copy collected → collector's staked balance |
| Artist Revenue | 100% of price | Per-copy price, split among up to 10 contributors |
| Revenue Splits | None | Configurable per-song, lockable |
| Staking Rewards | ETH via old Staker/FeePool | USDC via TortoiseShell |
| Network | Base | Base |
| Payment Method | Direct ETH | Direct USDC + Base Pay |

---

## Part 1: TortoiseV1 (Collection Contract)

### 1.1 Project Setup

```bash
mkdir tortoise-contract-v1
cd tortoise-contract-v1
pnpm init
forge init --no-commit
rm src/Counter.sol test/Counter.t.sol script/Counter.s.sol
pnpm install
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install foundry-rs/forge-std --no-commit
```

### 1.2 Project Structure

```
tortoise-contract-v1/
├── src/
│   ├── TortoiseV1.sol              # Collection contract
│   ├── TortoiseShell.sol           # Staking contract
│   ├── interfaces/
│   │   ├── ITortoiseV1.sol
│   │   └── ITortoiseShell.sol
│   └── libraries/
│       └── SplitLib.sol
├── test/
│   ├── unit/
│   │   ├── TortoiseV1.t.sol
│   │   └── TortoiseShell.t.sol
│   ├── fuzz/
│   │   ├── TortoiseV1.fuzz.t.sol
│   │   └── TortoiseShell.fuzz.t.sol
│   ├── invariant/
│   │   ├── TortoiseV1.invariant.t.sol
│   │   ├── TortoiseShell.invariant.t.sol
│   │   └── handlers/
│   │       ├── TortoiseHandler.sol
│   │       └── ShellHandler.sol
│   ├── integration/
│   │   └── MintToShell.t.sol
│   ├── fork/
│   │   └── TortoiseV1.fork.t.sol
│   └── mocks/
│       ├── MockUSDC.sol
│       └── MockTORT.sol
├── script/
│   ├── Deploy.s.sol
│   └── helpers/
│       └── Config.s.sol
├── foundry.toml
├── package.json
├── remappings.txt
├── .env.example
├── .gitignore
├── .solhint.json
├── CLAUDE.md
└── README.md
```

### 1.3 Configuration Files

**foundry.toml:**
```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.30"
optimizer = true
optimizer_runs = 200
via_ir = false
evm_version = "cancun"
dynamic_test_linking = true
gas_reports = ["TortoiseV1", "TortoiseShell"]

[fuzz]
runs = 1000
max_test_rejects = 65536

[invariant]
runs = 256
depth = 50
fail_on_revert = false
show_metrics = true

[profile.ci.fuzz]
runs = 10000

[profile.ci.invariant]
runs = 512
depth = 100

[rpc_endpoints]
localhost = "http://127.0.0.1:8545"
base = "${BASE_RPC_URL}"
base_sepolia = "${BASE_SEPOLIA_RPC_URL}"

[etherscan]
base = { key = "${BASESCAN_API_KEY}", url = "https://api.basescan.org/api" }
base_sepolia = { key = "${BASESCAN_API_KEY}", url = "https://api-sepolia.basescan.org/api" }

[fmt]
line_length = 100
tab_width = 4
bracket_spacing = false
int_types = "long"
multiline_func_header = "params_first"
quote_style = "double"
number_underscore = "thousands"
single_line_statement_blocks = "multi"
```

**remappings.txt:**
```
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
forge-std/=lib/forge-std/src/
```

**.env.example:**
```bash
BASE_RPC_URL=https://mainnet.base.org
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
DEPLOYER_PRIVATE_KEY=
BASESCAN_API_KEY=
INITIAL_SONG_PRICE=950000
INITIAL_PLATFORM_FEE=50000
INITIAL_STAKING_FEE=0
TORTOISE_SHELL_ADDRESS=
TORT_REWARD_PER_COLLECTION=0
```

### 1.4 Pricing Model

```
Total Cost = (Artist Revenue per Copy × Quantity) + Platform Fee + Staking Fee
```

| Component | Type | Default | Recipient |
|-----------|------|---------|-----------|
| Artist Revenue | Per copy | $0.95 (950,000 USDC units) | Split recipients (or artist) |
| Platform Fee | Flat per tx | $0.05 (50,000 USDC units) | Platform fee recipient |
| Staking Fee | Flat per tx | TBD | TortoiseShell (USDC rewards) |

TORT crediting costs the buyer nothing — funded from TortoiseShell's pre-loaded pool.

**Single mint example:** $0.95 + $0.05 + staking fee = ~$1.00 + staking fee
**5-copy mint example:** ($0.95 × 5) + $0.05 + staking fee = $4.80 + staking fee

### 1.5 Mint Flow

```
Buyer calls TortoiseV1.mintSong(songId, quantity, recipient)
  │
  ├─ USDC transferred from buyer to TortoiseV1
  │
  ├─ 1. Platform Fee (flat)     → Platform fee recipient
  ├─ 2. Staking Fee (flat)      → TortoiseShell.depositRewards()
  │                                (USDC distributed to all stakers over 7-day drip)
  ├─ 3. Artist Revenue (×qty)   → Split recipients (or artist if no splits)
  │
  └─ 4. TortoiseV1 calls TortoiseShell.creditStake(recipient, quantity)
        → (quantity × tortRewardPerCollection) TORT
          moved from shell's pool into recipient's staked balance
        → If shell reverts, mint still succeeds (try/catch)
```

### 1.6 Core Data Structures

```solidity
struct SplitRecipient {
    address recipient;
    uint96 percentage;       // Basis points (10000 = 100%)
}

struct Song {
    string title;
    address artist;
    uint128 price;           // USDC (6 decimals) — artist revenue per copy
    uint128 maxSupply;       // 0 = unlimited
    uint128 currentSupply;
    bool exists;
    bool splitsLocked;
}

struct ContractConfig {
    uint128 defaultSongPrice;
    uint128 platformFee;
    uint128 stakingFee;
    address platformFeeRecipient;
    address usdcToken;
    address tortoiseShell;   // Can be address(0) to disable shell integration
}
```

### 1.7 Revenue Split System

- Splits optional — if not configured, 100% to artist
- Basis points (10000 = 100%), must sum exactly to 10000
- Artist does NOT need to be included (can assign 100% to collaborators)
- Min 1% (100 bps) per recipient, max 10 recipients
- No duplicate recipients
- Lockable permanently by artist (one-way, irreversible)
- Last recipient gets remainder to prevent rounding dust

**SplitLib.sol:**
```solidity
library SplitLib {
    uint256 constant BASIS_POINTS = 10_000;
    uint256 constant MAX_SPLITS = 10;
    uint96 constant MIN_PERCENTAGE = 100;

    error InvalidSplitTotal();
    error TooManySplits();
    error ZeroAddressRecipient();
    error PercentageBelowMinimum();
    error DuplicateRecipient();

    function validateSplits(SplitRecipient[] calldata splits) internal pure {
        if (splits.length > MAX_SPLITS) revert TooManySplits();

        uint256 totalPercentage;
        for (uint256 i = 0; i < splits.length; i++) {
            if (splits[i].recipient == address(0)) revert ZeroAddressRecipient();
            if (splits[i].percentage < MIN_PERCENTAGE) revert PercentageBelowMinimum();
            totalPercentage += splits[i].percentage;

            for (uint256 j = i + 1; j < splits.length; j++) {
                if (splits[i].recipient == splits[j].recipient) revert DuplicateRecipient();
            }
        }
        if (totalPercentage != BASIS_POINTS) revert InvalidSplitTotal();
    }

    function calculateSplitAmount(
        uint256 totalAmount,
        uint96 percentage
    ) internal pure returns (uint256) {
        return (totalAmount * percentage) / BASIS_POINTS;
    }
}
```

### 1.8 TortoiseV1 Contract

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SplitLib} from "./libraries/SplitLib.sol";
import {ITortoiseShell} from "./interfaces/ITortoiseShell.sol";

contract TortoiseV1 is ERC1155, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using SplitLib for SplitRecipient[];

    // ============ Constants ============

    uint256 public constant MAX_MINT_QUANTITY = 100_000;
    uint128 public constant MAX_PLATFORM_FEE = 1_000_000;
    uint128 public constant MAX_STAKING_FEE = 1_000_000;
    uint128 public constant DEFAULT_SONG_PRICE = 950_000;
    uint128 public constant DEFAULT_PLATFORM_FEE = 50_000;

    // ============ State ============

    ContractConfig public config;
    mapping(uint256 => Song) public songs;
    mapping(uint256 => SplitRecipient[]) internal songSplits;
    mapping(uint256 => string) internal tokenUris;
    mapping(address => uint256[]) public artistSongs;
    uint256 public nextSongId;

    string private constant _name = "Tortoise";
    string private constant _symbol = "TORT";
    function name() public pure returns (string memory) { return _name; }
    function symbol() public pure returns (string memory) { return _symbol; }

    // ============ Events ============

    event SongCreated(uint256 indexed songId, string title, address indexed artist, uint128 price, uint128 maxSupply);
    event SongMinted(uint256 indexed songId, address indexed buyer, address indexed recipient, uint256 quantity, uint256 totalPaid);
    event SplitsConfigured(uint256 indexed songId, SplitRecipient[] splits);
    event SplitsLocked(uint256 indexed songId);
    event PaymentDistributed(uint256 indexed songId, address indexed recipient, uint256 amount, bool isPlatformFee);
    event StakingFeeDistributed(uint256 indexed songId, uint256 amount);
    event StakeCredited(uint256 indexed songId, address indexed recipient, uint256 quantity);
    event ShellCreditFailed(uint256 indexed songId, address indexed recipient, uint256 quantity);
    event PlatformFeeUpdated(uint128 oldFee, uint128 newFee);
    event StakingFeeUpdated(uint128 oldFee, uint128 newFee);
    event DefaultPriceUpdated(uint128 oldPrice, uint128 newPrice);

    // ============ Constructor ============

    constructor(
        address _usdcToken,
        address _platformFeeRecipient,
        uint128 _platformFee,
        uint128 _defaultSongPrice,
        address _tortoiseShell,
        uint128 _stakingFee
    ) ERC1155("") Ownable(msg.sender) {
        require(_usdcToken != address(0), "Invalid USDC address");
        require(_platformFeeRecipient != address(0), "Invalid fee recipient");
        require(_platformFee <= MAX_PLATFORM_FEE, "Platform fee exceeds maximum");
        require(_stakingFee <= MAX_STAKING_FEE, "Staking fee exceeds maximum");

        config = ContractConfig({
            defaultSongPrice: _defaultSongPrice == 0 ? DEFAULT_SONG_PRICE : _defaultSongPrice,
            platformFee: _platformFee == 0 ? DEFAULT_PLATFORM_FEE : _platformFee,
            stakingFee: _stakingFee,
            platformFeeRecipient: _platformFeeRecipient,
            usdcToken: _usdcToken,
            tortoiseShell: _tortoiseShell  // Can be address(0) — shell integration is optional
        });
    }

    // ============ Song Management ============

    function createSong(
        string calldata title, uint128 price, uint128 maxSupply, string calldata tokenUri
    ) external whenNotPaused returns (uint256 songId) {
        require(bytes(title).length > 0, "Title cannot be empty");
        require(bytes(tokenUri).length > 0, "URI cannot be empty");

        songId = nextSongId++;
        uint128 actualPrice = price == 0 ? config.defaultSongPrice : price;

        songs[songId] = Song({
            title: title, artist: msg.sender, price: actualPrice,
            maxSupply: maxSupply, currentSupply: 0, exists: true, splitsLocked: false
        });
        tokenUris[songId] = tokenUri;
        artistSongs[msg.sender].push(songId);
        emit SongCreated(songId, title, msg.sender, actualPrice, maxSupply);
    }

    function configureSplits(uint256 songId, SplitRecipient[] calldata splits) external whenNotPaused {
        Song storage song = songs[songId];
        require(song.exists, "Song does not exist");
        require(msg.sender == song.artist, "Only artist can configure splits");
        require(!song.splitsLocked, "Splits are locked");

        splits.validateSplits();
        delete songSplits[songId];
        for (uint256 i = 0; i < splits.length; i++) {
            songSplits[songId].push(splits[i]);
        }
        emit SplitsConfigured(songId, splits);
    }

    function lockSplits(uint256 songId) external whenNotPaused {
        Song storage song = songs[songId];
        require(song.exists, "Song does not exist");
        require(msg.sender == song.artist, "Only artist can lock splits");
        require(!song.splitsLocked, "Already locked");
        song.splitsLocked = true;
        emit SplitsLocked(songId);
    }

    // ============ Minting ============

    function mintSong(uint256 songId, uint256 quantity, address recipient) external nonReentrant whenNotPaused {
        _validateMint(songId, quantity);
        uint256 totalCost = calculateTotalCost(songId, quantity);
        IERC20(config.usdcToken).safeTransferFrom(msg.sender, address(this), totalCost);
        _processMint(songId, quantity, recipient, totalCost);
    }

    // ============ Internal Functions ============

    function _validateMint(uint256 songId, uint256 quantity) internal view {
        Song storage song = songs[songId];
        require(song.exists, "Song does not exist");
        require(quantity > 0, "Quantity must be positive");
        require(quantity <= MAX_MINT_QUANTITY, "Exceeds max mint quantity");
        require(song.maxSupply == 0 || song.currentSupply + quantity <= song.maxSupply, "Would exceed max supply");
    }

    function _processMint(uint256 songId, uint256 quantity, address recipient, uint256 totalCost) internal {
        Song storage song = songs[songId];
        address actualRecipient = recipient == address(0) ? msg.sender : recipient;

        require(song.currentSupply + quantity <= type(uint128).max, "Supply overflow");
        song.currentSupply += uint128(quantity);

        _mint(actualRecipient, songId, quantity, "");
        _distributePayments(songId, quantity, totalCost);
        _creditShell(songId, actualRecipient, quantity);

        emit SongMinted(songId, msg.sender, actualRecipient, quantity, totalCost);
    }

    function _distributePayments(uint256 songId, uint256 quantity, uint256 totalCost) internal {
        Song storage song = songs[songId];

        // 1. Platform fee
        uint256 platformFeeAmount = config.platformFee;
        if (platformFeeAmount > 0) {
            IERC20(config.usdcToken).safeTransfer(config.platformFeeRecipient, platformFeeAmount);
            emit PaymentDistributed(songId, config.platformFeeRecipient, platformFeeAmount, true);
        }

        // 2. Staking fee → TortoiseShell
        uint256 stakingFeeAmount = config.stakingFee;
        if (stakingFeeAmount > 0 && config.tortoiseShell != address(0)) {
            IERC20(config.usdcToken).safeTransfer(config.tortoiseShell, stakingFeeAmount);
            ITortoiseShell(config.tortoiseShell).depositRewards(stakingFeeAmount);
            emit StakingFeeDistributed(songId, stakingFeeAmount);
        }

        // 3. Artist revenue = totalCost - platformFee - stakingFee
        uint256 artistRevenue = totalCost - platformFeeAmount - stakingFeeAmount;

        SplitRecipient[] storage splits = songSplits[songId];

        if (splits.length == 0) {
            IERC20(config.usdcToken).safeTransfer(song.artist, artistRevenue);
            emit PaymentDistributed(songId, song.artist, artistRevenue, false);
        } else {
            uint256 distributed = 0;
            for (uint256 i = 0; i < splits.length; i++) {
                uint256 amount;
                if (i == splits.length - 1) {
                    amount = artistRevenue - distributed; // Remainder to last recipient
                } else {
                    amount = SplitLib.calculateSplitAmount(artistRevenue, splits[i].percentage);
                }
                distributed += amount;
                if (amount > 0) {
                    IERC20(config.usdcToken).safeTransfer(splits[i].recipient, amount);
                    emit PaymentDistributed(songId, splits[i].recipient, amount, false);
                }
            }
        }
    }

    /// @dev Credit TORT to collector's shell. Uses try/catch so shell issues never block mints.
    function _creditShell(uint256 songId, address recipient, uint256 quantity) internal {
        if (config.tortoiseShell == address(0)) return;

        try ITortoiseShell(config.tortoiseShell).creditStake(recipient, quantity) {
            emit StakeCredited(songId, recipient, quantity);
        } catch {
            emit ShellCreditFailed(songId, recipient, quantity);
        }
    }

    // ============ View Functions ============

    function getSongDetails(uint256 songId) external view returns (Song memory) { return songs[songId]; }
    function getSongSplits(uint256 songId) external view returns (SplitRecipient[] memory) { return songSplits[songId]; }
    function uri(uint256 songId) public view override returns (string memory) {
        require(songs[songId].exists, "Song does not exist");
        return tokenUris[songId];
    }
    function getArtistSongs(address artist) external view returns (uint256[] memory) { return artistSongs[artist]; }
    function getConfig() external view returns (ContractConfig memory) { return config; }

    /// @notice Total cost: (price × quantity) + platformFee + stakingFee
    function calculateTotalCost(uint256 songId, uint256 quantity) public view returns (uint256) {
        Song storage song = songs[songId];
        require(song.exists, "Song does not exist");
        return (uint256(song.price) * quantity) + config.platformFee + config.stakingFee;
    }

    // ============ Admin Functions ============

    function updatePlatformFee(uint128 newFee) external onlyOwner {
        require(newFee <= MAX_PLATFORM_FEE, "Fee exceeds maximum");
        emit PlatformFeeUpdated(config.platformFee, newFee);
        config.platformFee = newFee;
    }

    function updateStakingFee(uint128 newFee) external onlyOwner {
        require(newFee <= MAX_STAKING_FEE, "Fee exceeds maximum");
        emit StakingFeeUpdated(config.stakingFee, newFee);
        config.stakingFee = newFee;
    }

    function updateTortoiseShell(address newShell) external onlyOwner {
        config.tortoiseShell = newShell;
    }

    function updateDefaultPrice(uint128 newPrice) external onlyOwner {
        require(newPrice > 0, "Price must be positive");
        emit DefaultPriceUpdated(config.defaultSongPrice, newPrice);
        config.defaultSongPrice = newPrice;
    }

    function updatePlatformFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid recipient");
        config.platformFeeRecipient = newRecipient;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function recoverTokens(address token, uint256 amount) external onlyOwner nonReentrant {
        require(token != config.usdcToken, "Cannot recover USDC");
        IERC20(token).safeTransfer(owner(), amount);
    }
}
```

### 1.9 Base Pay Compatibility

No contract-level changes needed. Base Pay handles token swaps at the frontend/wallet level. The standard `mintSong()` function works with Base Pay out of the box.

---

## Part 2: TortoiseShell (Staking Contract)

### 2.1 What It Does

Two functions in one contract:

**USDC Rewards for Stakers:** Every collection deposits a flat USDC staking fee into the shell, distributed to all stakers proportionally over a 7-day drip. More collections = higher yield.

**TORT Crediting for Collectors:** Every collection credits a fixed amount of TORT per copy into the collector's staked balance. The TORT comes from a pre-funded pool. The collector's shell grows automatically, increasing their share of future USDC rewards.

### 2.2 State

```solidity
// ============ Tokens ============
IERC20 public immutable stakingToken;       // $TORT
IERC20 public immutable rewardToken;        // USDC

// ============ Staking ============
mapping(address => uint256) public stakedBalance;
uint256 public totalStaked;

// ============ USDC Rewards (Synthetix pattern, 7-day drip) ============
uint256 public rewardRate;                  // USDC per second (scaled by rewardScalar)
uint256 public rewardDuration;              // 604800 (7 days)
uint256 public periodFinish;
uint256 public lastUpdateTime;
uint256 public rewardPerTokenStored;
uint256 public reservedBalance;             // USDC earned but not yet claimed
uint256 public rewardScalar;                // 1e12 (scales 6-decimal USDC to 18 internally)
mapping(address => uint256) public userRewardPerTokenPaid;
mapping(address => uint256) public userUnpaidRewards;

// ============ TORT Credit Pool ============
uint256 public tortPool;                    // TORT available for crediting
uint256 public tortRewardPerCollection;     // Fixed TORT per copy collected (configurable)
uint256 public totalTortCredited;           // Lifetime tracking

// ============ Access Control ============
mapping(address => bool) public authorizedCallers;  // TortoiseV1, owner
address public owner;
```

### 2.3 Key Functions

**Staking (user-facing):**
```solidity
function stake(uint256 amount) external;
function withdraw(uint256 amount) external;
function claimRewards() external;           // Claim accumulated USDC
function exit() external;                   // Withdraw all TORT + claim USDC
function emergencyWithdraw() external;      // Withdraw TORT, forfeit unclaimed USDC
```

**Called by TortoiseV1 on every mint:**
```solidity
function depositRewards(uint256 amount) external onlyAuthorizedCaller;
function creditStake(address user, uint256 quantity) external onlyAuthorizedCaller;
```

**TORT Pool Management (owner):**
```solidity
function fundTortPool(uint256 amount) external onlyOwner;
function withdrawTortPool(uint256 amount) external onlyOwner;
function setTortRewardPerCollection(uint256 amount) external onlyOwner;
```

**Admin:**
```solidity
function addAuthorizedCaller(address caller) external onlyOwner;
function removeAuthorizedCaller(address caller) external onlyOwner;
function updateRewardDuration(uint256 newDuration) external onlyOwner;
function pause() external onlyOwner;
function unpause() external onlyOwner;
```

**View Functions:**
```solidity
function earned(address user) external view returns (uint256);
function balanceOf(address user) external view returns (uint256);
function getUserStats(address user) external view returns (
    uint256 stakedAmount, uint256 pendingUsdcRewards, uint256 shareOfPool
);
function getTortPoolBalance() external view returns (uint256);
function getRewardRate() external view returns (uint256);
```

**Interface (used by TortoiseV1):**
```solidity
interface ITortoiseShell {
    function depositRewards(uint256 amount) external;
    function creditStake(address user, uint256 quantity) external;
}
```

### 2.4 USDC Reward Math (7-Day Drip)

Standard Synthetix pattern:

```solidity
function _addReward(uint256 reward) internal updateReward(address(0)) {
    reward *= rewardScalar;
    if (block.timestamp >= periodFinish) {
        rewardRate = reward / rewardDuration;
    } else {
        uint256 remaining = periodFinish - block.timestamp;
        uint256 leftover = remaining * rewardRate;
        rewardRate = (reward + leftover) / rewardDuration;
    }
    lastUpdateTime = block.timestamp;
    periodFinish = block.timestamp + rewardDuration;
}
```

Each deposit combines with remaining rewards and resets the 7-day window. Frequent collections create a smooth reward stream. `reservedBalance` tracks USDC owed but unclaimed, preventing double-counting.

### 2.5 TORT Credit Mechanics

```solidity
function creditStake(address user, uint256 quantity) external onlyAuthorizedCaller updateReward(user) {
    uint256 creditAmount = quantity * tortRewardPerCollection;

    // Graceful degradation — never revert, never block mints
    if (creditAmount > tortPool) {
        creditAmount = tortPool;
    }
    if (creditAmount == 0) return;

    tortPool -= creditAmount;
    stakedBalance[user] += creditAmount;
    totalStaked += creditAmount;
    totalTortCredited += creditAmount;

    emit StakeCredited(user, creditAmount, quantity);
}
```

`updateReward(user)` runs first — snapshots USDC earnings before the balance changes. Newly credited TORT starts earning USDC from this moment forward, not retroactively.

**If the TORT pool runs out:** Credits what's available, or no-ops if empty. Never reverts. TortoiseV1 also wraps the call in try/catch as a second layer of protection (see section 4.1).

### 2.6 Pause Behavior

| Function | When Paused |
|----------|-------------|
| `stake()` | Blocked |
| `depositRewards()` | Allowed (mints must never fail due to staking pause) |
| `creditStake()` | Allowed (mints must never fail due to staking pause) |
| `claimRewards()` | Blocked |
| `exit()` | Blocked |
| `withdraw()` | Allowed (users can always get their TORT back) |
| `emergencyWithdraw()` | Allowed (always works, forfeits unclaimed USDC) |

---

## Part 3: How the Two Contracts Interact

### 3.1 Mint Transaction Flow (Detailed)

```
1. Buyer calls TortoiseV1.mintSong(songId, 3, buyerAddress)

2. TortoiseV1._validateMint() — checks song exists, supply, quantity

3. TortoiseV1 pulls USDC from buyer:
   totalCost = ($0.95 × 3) + $0.05 + stakingFee = $2.90 + stakingFee

4. TortoiseV1._distributePayments():
   a. $0.05 USDC → platform fee recipient
   b. stakingFee USDC → TortoiseShell
      - safeTransfer USDC to shell
      - call shell.depositRewards(stakingFee)
      - shell runs _addReward(), updates rewardRate and periodFinish
   c. $2.85 USDC → artist/split recipients

5. TortoiseV1._creditShell():
   try shell.creditStake(buyer, 3):
      - shell calculates: 3 × tortRewardPerCollection = creditAmount
      - shell moves creditAmount TORT from pool → buyer's stakedBalance
      - buyer's USDC reward snapshot updated first (no retroactive rewards)
      - emit StakeCredited
   catch:
      - emit ShellCreditFailed (mint still succeeds)

6. ERC-1155 mint: 3 copies of songId → buyer's wallet

7. emit SongMinted
```

### 3.2 Three Layers of Protection

The system is designed so auxiliary features (staking, TORT crediting) never block core functionality (collecting music):

**Layer 1 — TortoiseShell graceful degradation:** `creditStake` never reverts. If TORT pool is empty, it no-ops. If pool is low, it credits what's available.

**Layer 2 — TortoiseV1 try/catch:** `_creditShell` wraps the external call in try/catch. If the shell reverts for any unexpected reason, the mint still succeeds and emits `ShellCreditFailed`.

**Layer 3 — Kill switch:** Owner can set `tortoiseShell` to `address(0)` to disable all shell integration instantly. Mints continue with no staking fee and no TORT crediting.

---

## Part 4: Security

### 4.1 TortoiseV1 Audit Findings

All findings from the original v1 security review are addressed in the contract code above:

- **C-1 (Split rounding dust):** Last recipient gets remainder via `artistRevenue - distributed`.
- **C-2 (Unsafe uint128 cast):** Explicit overflow check before cast.
- **H-1 (recoverTokens drains USDC):** Blocked with `require(token != config.usdcToken)`.
- **H-2 (Duplicate split recipients):** Checked in `SplitLib.validateSplits`.
- **H-3 (mintBatchSongs):** Removed from interface. Single mint only.
- **M-2 (Default price zero):** `require(newPrice > 0)` in `updateDefaultPrice`.
- **M-3 (Pause on splits):** `whenNotPaused` on `configureSplits` and `lockSplits`.
- **M-4 (Wrong price in event):** `actualPrice` computed before storage and event.
- **M-5 (CEI violation):** `_validateMint` called before USDC transfer.
- **L-1 (name/symbol):** Added.
- **L-3 (recoverTokens reentrancy):** `nonReentrant` added.

### 4.2 Shell Integration Findings

**S-1: `_creditShell` revert blocks mint** — FIXED. `_creditShell` uses try/catch. If shell reverts, mint succeeds and emits `ShellCreditFailed`. Three layers of protection (see 3.2).

**S-2: Fee change between calculateTotalCost and mint** — Non-issue. Both read `config.stakingFee` from same storage slot in same transaction. Fee changes only take effect on next mint.

**S-3: Staking fee sent but depositRewards not called** — Non-issue. If `depositRewards()` reverts, entire transaction reverts atomically. No USDC can be stranded.

### 4.3 TortoiseShell Security

- **Authorized caller pattern:** Only TortoiseV1 and owner can call `depositRewards()` and `creditStake()`. Prevents unauthorized TORT pool drainage.
- **TORT pool isolation:** `tortPool` is separate from staked balances. Withdrawals pull from `stakedBalance`, not `tortPool`.
- **Reward snapshot on credit:** `updateReward(user)` runs before balance changes — no retroactive USDC claims.
- **Graceful degradation:** `creditStake` never reverts on pool depletion.
- **`reservedBalance`:** Tracks USDC owed to stakers, preventing new deposits from double-counting.
- **ReentrancyGuard:** On all state-changing functions.
- **SafeERC20:** On all token transfers.

### 4.4 Audit Checklist

- [ ] All external calls use ReentrancyGuard
- [ ] CEI pattern followed in all functions
- [ ] Input validation on all parameters
- [ ] Access control on admin functions
- [ ] Events emitted for all state changes
- [ ] SafeERC20 used for all token transfers
- [ ] No unchecked arithmetic in critical paths
- [ ] Split percentages validated to sum to 100%
- [ ] Maximum limits on arrays (splits)
- [ ] Shell integration uses try/catch
- [ ] Shell `creditStake` never reverts
- [ ] `reservedBalance` correctly tracks USDC obligations
- [ ] TORT pool cannot go negative
- [ ] `totalStaked` always equals sum of `stakedBalance`

---

## Part 5: Testing Strategy

### 5.1 TortoiseV1 Unit Tests

- Song creation (with/without custom price, default price, empty title revert)
- Split configuration (valid, invalid total, duplicates, too many, zero address, below minimum)
- Split locking (lock, revert on re-lock, revert on reconfigure after lock)
- Minting without splits (single, multi-quantity, verify balances)
- Minting with splits (payment distribution accuracy, remainder to last recipient)
- Staking fee distribution (USDC arrives in shell, depositRewards called)
- TORT crediting (creditStake called with correct quantity)
- Shell not configured (address(0) — mint works without shell)
- Shell credit failure (try/catch — mint succeeds, ShellCreditFailed emitted)
- Staking fee zero (skips shell USDC deposit, still credits TORT)
- Admin functions (update fees, update shell, update price, pause/unpause)
- Revert cases (insufficient allowance, paused, max supply, invalid song)
- recoverTokens (blocks USDC, allows other tokens)

### 5.2 TortoiseShell Unit Tests

- Stake, withdraw, claim USDC lifecycle
- USDC drip math: single deposit, multiple overlapping deposits, expired period + new deposit
- `creditStake` increases user balance and totalStaked
- `creditStake` with insufficient TORT pool — graceful degradation (partial credit)
- `creditStake` with empty pool — no-op
- Reward snapshot correctness: no retroactive USDC on newly credited TORT
- TORT pool funding and withdrawal by owner
- `tortRewardPerCollection` configuration
- Authorized caller access control (deposit, credit, unauthorized revert)
- Pause/unpause behavior (deposit/credit allowed, stake/claim blocked)
- Emergency withdraw (forfeits USDC, returns TORT)
- `reservedBalance` tracking across deposits and claims

### 5.3 Fuzz Tests

**TortoiseV1:**
- Random prices, quantities, split percentages — payments always sum correctly
- No USDC left in contract after any mint

**TortoiseShell:**
- Arbitrary stake/withdraw/deposit/credit sequences
- Proportional USDC accuracy across random staker populations
- TORT pool never goes negative
- `totalStaked` always equals sum of all `stakedBalance`

### 5.4 Invariant Tests

**TortoiseV1:**
- Contract USDC balance == 0 after every mint
- `currentSupply <= maxSupply` for all songs with maxSupply > 0
- `platformFee <= MAX_PLATFORM_FEE`

**TortoiseShell:**
- `reservedBalance <= USDC balance of contract`
- `totalStaked == sum(all stakedBalance)`
- `tortPool + totalTortCredited == total TORT ever funded`

### 5.5 Integration Tests

Full mint → shell flow with both real contracts deployed:
- Mint → USDC in reward pool → TORT in collector's staked balance
- Multiple mints compound reward rate correctly
- Collector stakes TORT, collects song, shell grows, claims USDC
- Full accounting: no USDC or TORT unaccounted for

### 5.6 Fork Tests (Base)

Against real USDC and TORT on Base fork:
- Full mint → reward → credit → claim flow
- Migration: old Staker exit → TortoiseShell stake → collect → verify

---

## Part 6: Deployment

### 6.1 Deployment Order

```
1. Deploy TortoiseShell (TORT address, USDC address, rewardDuration=604800)
2. Deploy TortoiseV1 (USDC, platformFeeRecipient, fees, TortoiseShell address)
3. Register TortoiseV1 as authorized caller on TortoiseShell
4. Fund TortoiseShell TORT pool via fundTortPool()
5. Set tortRewardPerCollection on TortoiseShell
6. Set stakingFee on TortoiseV1 (if not set at deploy)
```

### 6.2 Deployment Script

```solidity
contract DeployTortoise is Script {
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant TORT_BASE = 0x601410d1d3093cf469fca4e1efb2fb67b4e225c6;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address platformFeeRecipient = vm.envAddress("PLATFORM_FEE_RECIPIENT");
        uint128 platformFee = uint128(vm.envUint("INITIAL_PLATFORM_FEE"));
        uint128 defaultPrice = uint128(vm.envUint("INITIAL_SONG_PRICE"));
        uint128 stakingFee = uint128(vm.envUint("INITIAL_STAKING_FEE"));

        address usdcAddress = block.chainid == 8453 ? USDC_BASE : USDC_BASE_SEPOLIA;

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy TortoiseShell
        TortoiseShell shell = new TortoiseShell(TORT_BASE, usdcAddress);

        // 2. Deploy TortoiseV1
        TortoiseV1 tortoise = new TortoiseV1(
            usdcAddress, platformFeeRecipient, platformFee,
            defaultPrice, address(shell), stakingFee
        );

        // 3. Register TortoiseV1 as authorized caller
        shell.addAuthorizedCaller(address(tortoise));

        vm.stopBroadcast();

        // 4. Fund TORT pool separately: shell.fundTortPool(amount)
    }
}
```

---

## Part 7: Migration

### 7.1 From v0.3 (Collection Contract)

- No state migration — fresh deployment
- Existing v0.3 NFTs remain on v0.3 contract
- Artists re-create songs on v1
- Users need USDC instead of ETH

### 7.2 From Old Staker/FeePool (Staking)

**Old system:** Staker (`0xFb05...`) + FeePool (`0x1e26...`) — TORT staked, WETH (ETH) rewards.
**New system:** TortoiseShell — TORT staked, USDC rewards + TORT crediting on collection.

**Migration steps:**
1. Stop depositing ETH rewards to old FeePool.
2. Current `rewardRate` drips remaining WETH until `periodFinish`.
3. Users migrate via guided frontend flow:

```
Step 1: "Claim ETH rewards"     → claimRewards() on old Staker
Step 2: "Unstake from old Shell" → unstake() on old Staker
Step 3: "Stake in new Shell"     → approve() + stake() on TortoiseShell
```

4. Old pool stays accessible indefinitely (users can claim/unstake anytime) but becomes dormant.

**Suggested timeline:** 30-day migration window with frontend prompts.

---

## Part 8: Open Questions

- [ ] **Staking fee amount:** Flat per transaction, TBD.
- [ ] **TORT reward per collection:** Fixed per copy, TBD. Model expected volume against pool budget.
- [ ] **Initial TORT pool size:** Depends on reward rate and expected collection volume.
- [ ] **TORT pool refill strategy:** Manual owner deposits? Periodic tortOS job?
- [ ] **Migration timeline:** 30-day window suggested.

---

## Part 9: Development Timeline

### Phase 1: Setup (Day 1)
- [ ] Initialize repo, Foundry, dependencies, linting

### Phase 2: TortoiseShell (Days 2-4)
- [ ] USDC reward distribution (Synthetix 7-day drip)
- [ ] TORT credit pool and `creditStake` with graceful degradation
- [ ] Access control, pause, emergency withdraw
- [ ] View functions for UI
- [ ] Unit tests

### Phase 3: TortoiseV1 (Days 5-7)
- [ ] SplitLib library
- [ ] TortoiseV1 with shell integration (try/catch on creditShell)
- [ ] Unit tests including shell integration scenarios

### Phase 4: Integration & Fuzz Testing (Days 8-9)
- [ ] Full mint → shell integration tests
- [ ] Fuzz tests for both contracts
- [ ] Invariant tests for both contracts
- [ ] Fork tests against real Base USDC/TORT

### Phase 5: Deployment & Migration (Days 10-12)
- [ ] Deploy to Base Sepolia, test full flow
- [ ] Deploy to Base Mainnet
- [ ] Fund TORT pool, register V1 as authorized caller
- [ ] Frontend migration flow
- [ ] Announce migration, wind down old pool

---

## Appendix: Token Addresses

| Token | Network | Address | Decimals |
|-------|---------|---------|----------|
| USDC | Base Mainnet | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | 6 |
| USDC | Base Sepolia | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` | 6 |
| $TORT | Base Mainnet | `0x601410d1d3093cf469fca4e1efb2fb67b4e225c6` | 18 |
| Staker (old) | Base Mainnet | `0xFb05Da3E5522f95b63AFd4ab77e94540f285a912` | — |
| FeePool (old) | Base Mainnet | `0x1e2674743Ad7E352657899B7f38Ec7C7d4C2E518` | — |

---

*This plan is a living document and should be updated as implementation progresses.*