# Tortoise Contract v1 - Development Plan

This document outlines the comprehensive plan for building Tortoise v1, a major upgrade that introduces USDC payments, revenue splits, and Base Pay integration.

## Overview of Changes

| Feature | v0.3 | v1 |
|---------|------|------|
| Payment Token | ETH | USDC |
| Song Price | Variable (ETH) | $1 total (configurable, includes platform fee) |
| Platform Fee | Variable (ETH) | $0.05 included in price (configurable) |
| Artist Revenue | 100% of price | $0.95 (price minus platform fee), split among contributors |
| Revenue Splits | None | Configurable per-song |
| Network | Base | Base |
| Payment Method | Direct | Direct + Base Pay |

---

## 1. Project Setup

### 1.1 Initialize New Repository

```bash
# Create new project directory
mkdir tortoise-contract-v1
cd tortoise-contract-v1

# Initialize pnpm
pnpm init

# Initialize Foundry
forge init --no-commit

# Remove default Counter files
rm src/Counter.sol test/Counter.t.sol script/Counter.s.sol
```

### 1.2 Package.json Configuration

```json
{
  "name": "tortoise-contract-v1",
  "version": "1.0.0",
  "description": "ERC1155 Music NFT Marketplace with USDC payments and revenue splits",
  "scripts": {
    "build": "forge build",
    "test": "forge test",
    "test:verbose": "forge test -vvv",
    "test:gas": "forge test --gas-report",
    "test:fuzz": "forge test --match-path 'test/fuzz/*.t.sol'",
    "test:invariant": "forge test --match-path 'test/invariant/*.t.sol'",
    "test:fork": "forge test --match-path 'test/fork/*.t.sol' --fork-url $BASE_RPC_URL",
    "coverage": "forge coverage",
    "snapshot": "forge snapshot",
    "fmt": "forge fmt",
    "lint": "pnpm solhint 'src/**/*.sol' 'test/**/*.sol'",
    "deploy:local": "forge script script/Deploy.s.sol --fork-url http://localhost:8545 --broadcast",
    "deploy:base-sepolia": "forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify",
    "deploy:base": "forge script script/Deploy.s.sol --rpc-url base --broadcast --verify",
    "clean": "forge clean && rm -rf cache out"
  },
  "devDependencies": {
    "solhint": "^5.0.0",
    "@openzeppelin/contracts": "^5.4.0"
  },
  "engines": {
    "node": ">=18.0.0",
    "pnpm": ">=8.0.0"
  },
  "license": "Apache-2.0"
}
```

### 1.3 Install Dependencies

```bash
# Install npm dev dependencies
pnpm install

# Install Foundry dependencies
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install foundry-rs/forge-std --no-commit
```

### 1.4 Foundry Configuration (foundry.toml)

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
dynamic_test_linking = true  # Faster test compilation
gas_reports = ["TortoiseV1"]

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

### 1.5 Remappings (remappings.txt)

```
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
forge-std/=lib/forge-std/src/
```

### 1.6 Solhint Configuration (.solhint.json)

```json
{
  "extends": "solhint:recommended",
  "plugins": [],
  "rules": {
    "compiler-version": ["error", "^0.8.30"],
    "func-visibility": ["warn", { "ignoreConstructors": true }],
    "max-line-length": ["warn", 100],
    "not-rely-on-time": "off",
    "reason-string": ["warn", { "maxLength": 64 }],
    "var-name-mixedcase": "off"
  }
}
```

### 1.7 Environment Configuration (.env.example)

```bash
# Network RPC URLs
BASE_RPC_URL=https://mainnet.base.org
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org

# Deployment Account (use keystore for production)
DEPLOYER_PRIVATE_KEY=

# API Keys
BASESCAN_API_KEY=

# Contract Parameters
INITIAL_SONG_PRICE=950000           # $0.95 in USDC (artist revenue per copy)
INITIAL_PLATFORM_FEE=50000          # $0.05 in USDC (flat per-transaction fee)
# Single mint total: $0.95 + $0.05 = $1.00

# Token Addresses
USDC_BASE_MAINNET=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
USDC_BASE_SEPOLIA=0x036CbD53842c5426634e7929541eC2318f3dCF7e
```

### 1.8 Git Configuration (.gitignore)

```gitignore
# Foundry
cache/
out/
broadcast/

# Environment
.env
.env.local

# Dependencies
node_modules/

# IDE
.idea/
.vscode/

# OS
.DS_Store
Thumbs.db

# Coverage
lcov.info
coverage/
```

---

## 2. Contract Architecture

### 2.1 Project Structure

```
tortoise-contract-v1/
├── src/
│   ├── TortoiseV1.sol           # Main contract
│   ├── interfaces/
│   │   └── ITortoiseV1.sol      # Contract interface
│   └── libraries/
│       └── SplitLib.sol           # Split calculation library
├── test/
│   ├── unit/
│   │   └── TortoiseV1.t.sol      # Unit tests
│   ├── fuzz/
│   │   └── TortoiseV1.fuzz.t.sol  # Fuzz tests
│   ├── invariant/
│   │   ├── TortoiseV1.invariant.t.sol # Invariant tests
│   │   └── handlers/
│   │       └── TortoiseHandler.sol    # Invariant handler
│   ├── fork/
│   │   └── TortoiseV1.fork.t.sol  # Fork tests against real Base USDC
│   └── mocks/
│       └── MockUSDC.sol           # Mock USDC for testing
├── script/
│   ├── Deploy.s.sol               # Main deployment script
│   ├── DeployTestnet.s.sol        # Testnet deployment
│   └── helpers/
│       └── Config.s.sol           # Network configuration
├── lib/                           # Foundry dependencies
├── foundry.toml
├── package.json
├── pnpm-lock.yaml
├── remappings.txt
├── .env.example
├── .gitignore
├── .solhint.json
├── CLAUDE.md
└── README.md
```

### 2.2 Core Data Structures

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @notice Represents a single revenue split recipient
struct SplitRecipient {
    address recipient;       // Address to receive payment
    uint96 percentage;       // Percentage in basis points (100 = 1%, 10000 = 100%)
}

/// @notice Represents a song with its metadata and splits
struct Song {
    string title;            // Song title
    address artist;          // Primary artist address
    uint128 price;           // Price in USDC (6 decimals)
    uint128 maxSupply;       // Maximum mintable supply (0 = unlimited)
    uint128 currentSupply;   // Current minted supply
    bool exists;             // Whether song exists
    bool splitsLocked;       // Whether splits can still be modified
}

/// @notice Configuration for the contract
struct ContractConfig {
    uint128 defaultSongPrice;  // Default price for new songs (artist revenue per copy)
    uint128 platformFee;       // Flat platform fee per transaction
    address platformFeeRecipient; // Where platform fees go
    address usdcToken;         // USDC token address
}
```

### 2.3 Main Contract Interface

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

interface ITortoiseV1 {
    // ============ Events ============

    event SongCreated(
        uint256 indexed songId,
        string title,
        address indexed artist,
        uint128 price,
        uint128 maxSupply
    );

    event SongMinted(
        uint256 indexed songId,
        address indexed buyer,
        address indexed recipient,
        uint256 quantity,
        uint256 totalPaid
    );

    event SplitsConfigured(
        uint256 indexed songId,
        SplitRecipient[] splits
    );

    event SplitsLocked(uint256 indexed songId);

    event PaymentDistributed(
        uint256 indexed songId,
        address indexed recipient,
        uint256 amount,
        bool isPlatformFee
    );

    event PlatformFeeUpdated(uint128 oldFee, uint128 newFee);
    event DefaultPriceUpdated(uint128 oldPrice, uint128 newPrice);

    // ============ Song Management ============

    /// @notice Create a new song
    /// @param title Song title (cannot be empty)
    /// @param price Artist revenue per copy in USDC (0 = use default $0.95)
    /// @param maxSupply Maximum supply (0 = unlimited)
    /// @param tokenUri IPFS URI for metadata
    /// @return songId The ID of the created song
    function createSong(
        string calldata title,
        uint128 price,
        uint128 maxSupply,
        string calldata tokenUri
    ) external returns (uint256 songId);

    /// @notice Configure revenue splits for a song
    /// @param songId The song to configure
    /// @param splits Array of split recipients (must total 10000 basis points)
    function configureSplits(
        uint256 songId,
        SplitRecipient[] calldata splits
    ) external;

    /// @notice Lock splits permanently (cannot be undone)
    /// @param songId The song to lock
    function lockSplits(uint256 songId) external;

    // ============ Minting ============

    /// @notice Mint songs using USDC
    /// @param songId The song to mint
    /// @param quantity Number to mint
    /// @param recipient Address to receive the NFTs
    function mintSong(
        uint256 songId,
        uint256 quantity,
        address recipient
    ) external;

    /// @notice Batch mint multiple songs
    /// @param songIds Array of song IDs
    /// @param quantities Array of quantities
    /// @param recipient Address to receive all NFTs
    function mintBatchSongs(
        uint256[] calldata songIds,
        uint256[] calldata quantities,
        address recipient
    ) external;

    // ============ View Functions ============

    function getSongDetails(uint256 songId) external view returns (Song memory);
    function getSongSplits(uint256 songId) external view returns (SplitRecipient[] memory);
    function calculateTotalCost(uint256 songId, uint256 quantity) external view returns (uint256);
    function getArtistSongs(address artist) external view returns (uint256[] memory);
    function getConfig() external view returns (ContractConfig memory);
}
```

---

## 3. Payment System Design

### 3.1 USDC Integration

**USDC Token Addresses:**
- Base Mainnet: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- Base Sepolia: `0x036CbD53842c5426634e7929541eC2318f3dCF7e`

**Payment Flow:**
```
1. Buyer approves USDC spending for Tortoise contract
2. Buyer calls mintSong(songId, quantity, recipient)
3. Contract calculates total: (price * quantity) + platformFee (one flat fee per tx)
4. Contract transfers USDC from buyer
5. Contract distributes:
   - Platform fee (flat, once per tx) → Platform fee recipient
   - Artist revenue (price * quantity) → Split recipients (or artist if no splits)
```

**Pricing Model:**
- The song price is the amount the artist receives per copy (default $0.95)
- The platform fee is a flat per-transaction fee (default $0.05), charged once regardless of quantity
- Total cost to buyer: (song price * quantity) + platform fee
- Example: 5 copies at $0.95 + $0.05 fee = $4.80 total
- The "headline price" shown to users is $1.00 (for single mints: $0.95 + $0.05)

**Implementation Notes:**
- USDC has 6 decimals (not 18 like ETH)
- $1.00 = 1_000_000 (1e6 USDC units)
- $0.95 = 950_000 (default song price / artist revenue per copy)
- $0.05 = 50_000 (flat platform fee per transaction)
- Platform fee is charged once per mint transaction, not per copy
- Use `SafeERC20` for all transfers
- Check allowance before attempting transfer

### 3.2 Revenue Split System

**Split Configuration Rules:**
1. Splits are optional - if not configured, 100% goes to artist
2. Split percentages are in basis points (10000 = 100%)
3. All splits must sum to exactly 10000 (100%)
4. Primary artist does NOT need to be included (can assign 100% to collaborators)
5. Minimum 1% (100 bps) per recipient
6. Maximum 10 split recipients per song
7. Splits can be locked permanently by the artist (one-way, irreversible)
8. Only the song's artist can configure or lock splits

**Split Calculation Library:**
```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

library SplitLib {
    uint256 constant BASIS_POINTS = 10_000;
    uint256 constant MAX_SPLITS = 10;
    uint96 constant MIN_PERCENTAGE = 100; // 1% minimum per recipient

    error InvalidSplitTotal();
    error TooManySplits();
    error ZeroAddressRecipient();
    error PercentageBelowMinimum();
    error DuplicateRecipient();

    /// @notice Validate split configuration
    function validateSplits(SplitRecipient[] calldata splits) internal pure {
        if (splits.length > MAX_SPLITS) revert TooManySplits();

        uint256 totalPercentage;
        for (uint256 i = 0; i < splits.length; i++) {
            if (splits[i].recipient == address(0)) revert ZeroAddressRecipient();
            if (splits[i].percentage < MIN_PERCENTAGE) revert PercentageBelowMinimum();
            totalPercentage += splits[i].percentage;

            // H-2 fix: check for duplicate recipients
            for (uint256 j = i + 1; j < splits.length; j++) {
                if (splits[i].recipient == splits[j].recipient) revert DuplicateRecipient();
            }
        }

        if (totalPercentage != BASIS_POINTS) revert InvalidSplitTotal();
    }

    /// @notice Calculate payment amount for a recipient
    function calculateSplitAmount(
        uint256 totalAmount,
        uint96 percentage
    ) internal pure returns (uint256) {
        return (totalAmount * percentage) / BASIS_POINTS;
    }
}
```

**Example Splits (single mint):**
```
Total Buyer Cost: $1.00 (1_000_000 USDC units)
Platform Fee: $0.05 (50_000 USDC units) - flat per transaction
Artist Revenue: $0.95 (950_000 USDC units)

Split Configuration (applied to artist revenue):
- Artist: 70% (7000 bps) → $0.665 (665_000)
- Producer: 20% (2000 bps) → $0.19 (190_000)
- Songwriter: 10% (1000 bps) → $0.095 (95_000)

Note: Primary artist does NOT need to be in the split.
An artist could assign 100% to collaborators.
```

**Example Splits (5-copy mint):**
```
Total Buyer Cost: $4.80 ($0.95 * 5 + $0.05 flat fee)
Platform Fee: $0.05 (50_000 USDC units) - flat, same regardless of quantity
Artist Revenue: $4.75 (4_750_000 USDC units)

Split Distribution:
- Artist: 70% (7000 bps) → $3.325 (3_325_000)
- Producer: 20% (2000 bps) → $0.95 (950_000)
- Songwriter: 10% (1000 bps) → $0.475 (475_000)
```

### 3.3 Base Pay Compatibility

Base Pay is a payment infrastructure on Base that handles token swaps and payment routing at the **frontend/wallet level**. No special contract-level integration is needed.

**How it works:**
1. The frontend uses the Base Pay SDK to initiate a payment
2. Base Pay handles any token swaps (ETH → USDC, other tokens → USDC, etc.)
3. The resulting USDC is sent to the user's wallet
4. The user's wallet approves and calls `mintSong()` with USDC as normal

**Contract requirements:** None. The standard `mintSong()` function that accepts USDC works with Base Pay out of the box. All Base Pay integration is handled in the frontend code.

**Frontend reference:** See [Base Pay docs](https://docs.base.org/base-account/guides/accept-payments) for integration details.

---

## 4. Implementation Details

### 4.1 Main Contract Skeleton

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

/// @title Tortoise v1 - Music NFT Marketplace with USDC & Splits
/// @notice ERC1155-based NFT marketplace for music with USDC payments and revenue splits
/// @dev Implements configurable pricing, platform fees, and Base Pay integration
contract TortoiseV1 is ERC1155, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using SplitLib for SplitRecipient[];

    // ============ Constants ============

    uint256 public constant MAX_MINT_QUANTITY = 100_000;
    uint256 public constant MAX_BATCH_SIZE = 50;
    uint128 public constant MAX_PLATFORM_FEE = 1_000_000; // $1 max fee
    uint128 public constant DEFAULT_SONG_PRICE = 950_000; // $0.95 (artist revenue per copy)
    uint128 public constant DEFAULT_PLATFORM_FEE = 50_000; // $0.05 (flat per-transaction fee)

    // ============ State ============

    ContractConfig public config;

    mapping(uint256 => Song) public songs;
    mapping(uint256 => SplitRecipient[]) internal songSplits;
    mapping(uint256 => string) internal tokenUris;
    mapping(address => uint256[]) public artistSongs;

    uint256 public nextSongId;

    // L-1 fix: name/symbol for marketplace compatibility
    string private constant _name = "Tortoise";
    string private constant _symbol = "TORT";

    function name() public pure returns (string memory) { return _name; }
    function symbol() public pure returns (string memory) { return _symbol; }

    // ============ Constructor ============

    constructor(
        address _usdcToken,
        address _platformFeeRecipient,
        uint128 _platformFee,
        uint128 _defaultSongPrice
    ) ERC1155("") Ownable(msg.sender) {
        require(_usdcToken != address(0), "Invalid USDC address");
        require(_platformFeeRecipient != address(0), "Invalid fee recipient");
        require(_platformFee <= MAX_PLATFORM_FEE, "Fee exceeds maximum");

        config = ContractConfig({
            defaultSongPrice: _defaultSongPrice == 0 ? DEFAULT_SONG_PRICE : _defaultSongPrice,
            platformFee: _platformFee == 0 ? DEFAULT_PLATFORM_FEE : _platformFee,
            platformFeeRecipient: _platformFeeRecipient,
            usdcToken: _usdcToken
        });
    }

    // ============ Song Management ============

    function createSong(
        string calldata title,
        uint128 price,
        uint128 maxSupply,
        string calldata tokenUri
    ) external whenNotPaused returns (uint256 songId) {
        require(bytes(title).length > 0, "Title cannot be empty");
        require(bytes(tokenUri).length > 0, "URI cannot be empty");

        songId = nextSongId++;

        uint128 actualPrice = price == 0 ? config.defaultSongPrice : price; // M-4 fix

        songs[songId] = Song({
            title: title,
            artist: msg.sender,
            price: actualPrice,
            maxSupply: maxSupply,
            currentSupply: 0,
            exists: true,
            splitsLocked: false
        });

        tokenUris[songId] = tokenUri;
        artistSongs[msg.sender].push(songId);

        emit SongCreated(songId, title, msg.sender, actualPrice, maxSupply); // M-4 fix: emit stored price
    }

    function configureSplits(
        uint256 songId,
        SplitRecipient[] calldata splits
    ) external whenNotPaused { // M-3 fix
        Song storage song = songs[songId];
        require(song.exists, "Song does not exist");
        require(msg.sender == song.artist, "Only artist can configure splits");
        require(!song.splitsLocked, "Splits are locked");

        splits.validateSplits();

        // Clear existing splits
        delete songSplits[songId];

        // Store new splits
        for (uint256 i = 0; i < splits.length; i++) {
            songSplits[songId].push(splits[i]);
        }

        emit SplitsConfigured(songId, splits);
    }

    function lockSplits(uint256 songId) external whenNotPaused { // M-3 fix
        Song storage song = songs[songId];
        require(song.exists, "Song does not exist");
        require(msg.sender == song.artist, "Only artist can lock splits");
        require(!song.splitsLocked, "Already locked");

        song.splitsLocked = true;
        emit SplitsLocked(songId);
    }

    // ============ Minting ============

    function mintSong(
        uint256 songId,
        uint256 quantity,
        address recipient
    ) external nonReentrant whenNotPaused {
        // M-5 fix: validate before pulling USDC
        _validateMint(songId, quantity);

        uint256 totalCost = calculateTotalCost(songId, quantity);

        // Transfer USDC from buyer (Checks done, now Interactions)
        IERC20(config.usdcToken).safeTransferFrom(msg.sender, address(this), totalCost);

        // Process mint and payments (Effects + more Interactions)
        _processMint(songId, quantity, recipient, totalCost);
    }

    // ============ Internal Functions ============

    /// @dev M-5 fix: separate validation so it can be called before USDC transfer
    function _validateMint(uint256 songId, uint256 quantity) internal view {
        Song storage song = songs[songId];
        require(song.exists, "Song does not exist");
        require(quantity > 0, "Quantity must be positive");
        require(quantity <= MAX_MINT_QUANTITY, "Exceeds max mint quantity");
        require(
            song.maxSupply == 0 || song.currentSupply + quantity <= song.maxSupply,
            "Would exceed max supply"
        );
    }

    function _processMint(
        uint256 songId,
        uint256 quantity,
        address recipient,
        uint256 totalCost
    ) internal {
        Song storage song = songs[songId];
        // Validation already done in _validateMint (called before USDC transfer)

        address actualRecipient = recipient == address(0) ? msg.sender : recipient;

        // Update supply (C-2 fix: safe cast check)
        require(song.currentSupply + quantity <= type(uint128).max, "Supply overflow");
        song.currentSupply += uint128(quantity);

        // Mint NFTs
        _mint(actualRecipient, songId, quantity, "");

        // Distribute payments
        _distributePayments(songId, totalCost);

        emit SongMinted(songId, msg.sender, actualRecipient, quantity, totalCost);
    }

    function _distributePayments(uint256 songId, uint256 totalCost) internal {
        Song storage song = songs[songId];

        // Platform fee (flat, once per transaction)
        uint256 platformFeeAmount = config.platformFee;
        IERC20(config.usdcToken).safeTransfer(config.platformFeeRecipient, platformFeeAmount);
        emit PaymentDistributed(songId, config.platformFeeRecipient, platformFeeAmount, true);

        // Artist revenue = total cost - flat platform fee
        uint256 artistRevenue = totalCost - platformFeeAmount;

        SplitRecipient[] storage splits = songSplits[songId];

        if (splits.length == 0) {
            // No splits - all to artist
            IERC20(config.usdcToken).safeTransfer(song.artist, artistRevenue);
            emit PaymentDistributed(songId, song.artist, artistRevenue, false);
        } else {
            // Distribute according to splits
            // Last recipient gets remainder to prevent rounding dust (C-1 fix)
            uint256 distributed = 0;
            for (uint256 i = 0; i < splits.length; i++) {
                uint256 amount;
                if (i == splits.length - 1) {
                    amount = artistRevenue - distributed;
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

    // ============ View Functions ============

    function getSongDetails(uint256 songId) external view returns (Song memory) {
        return songs[songId];
    }

    function getSongSplits(uint256 songId) external view returns (SplitRecipient[] memory) {
        return songSplits[songId];
    }

    function uri(uint256 songId) public view override returns (string memory) {
        require(songs[songId].exists, "Song does not exist");
        return tokenUris[songId];
    }

    function getArtistSongs(address artist) external view returns (uint256[] memory) {
        return artistSongs[artist];
    }

    function getConfig() external view returns (ContractConfig memory) {
        return config;
    }

    // ============ Admin Functions ============

    function updatePlatformFee(uint128 newFee) external onlyOwner {
        require(newFee <= MAX_PLATFORM_FEE, "Fee exceeds maximum");
        uint128 oldFee = config.platformFee;
        config.platformFee = newFee;
        emit PlatformFeeUpdated(oldFee, newFee);
    }

    function updateDefaultPrice(uint128 newPrice) external onlyOwner {
        require(newPrice > 0, "Price must be positive"); // M-2 fix
        uint128 oldPrice = config.defaultSongPrice;
        config.defaultSongPrice = newPrice;
        emit DefaultPriceUpdated(oldPrice, newPrice);
    }

    function updatePlatformFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid recipient");
        config.platformFeeRecipient = newRecipient;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Get total cost for a mint: (price * quantity) + one flat platform fee
    /// @dev Platform fee is charged once per transaction, not per copy
    function calculateTotalCost(uint256 songId, uint256 quantity) public view returns (uint256) {
        Song storage song = songs[songId];
        require(song.exists, "Song does not exist");
        return (uint256(song.price) * quantity) + config.platformFee;
    }

    /// @notice Recover accidentally sent ERC20 tokens (cannot recover USDC)
    /// @dev H-1 fix: block USDC recovery, add nonReentrant (L-3 fix)
    function recoverTokens(address token, uint256 amount) external onlyOwner nonReentrant {
        require(token != config.usdcToken, "Cannot recover USDC");
        IERC20(token).safeTransfer(owner(), amount);
    }
}
```

### 4.2 Gas Optimizations

1. **Storage Packing:**
   - `Song` struct is packed to minimize storage slots
   - Use `uint128` for prices/supplies (sufficient for USDC amounts)
   - Use `uint96` for split percentages (basis points fit easily)

2. **Calldata vs Memory:**
   - Use `calldata` for function parameters where possible
   - Avoid copying arrays to memory unnecessarily

3. **Loop Optimizations:**
   - Cache array length in loops
   - Use unchecked increments in loops where overflow is impossible

4. **Batch Operations:**
   - Support batch minting to reduce per-transaction overhead
   - Limit batch size to prevent gas limit issues

---

## 5. Testing Strategy

### 5.1 Mock Contracts

**MockUSDC.sol:**
```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
```


### 5.2 Test Categories

#### Unit Tests (TortoiseV1.t.sol)

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {TortoiseV1} from "../src/TortoiseV1.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract TortoiseV1Test is Test {
    TortoiseV1 public tortoise;
    MockUSDC public usdc;

    address public owner = makeAddr("owner");
    address public platformFeeRecipient = makeAddr("platformFeeRecipient");
    address public artist1 = makeAddr("artist1");
    address public artist2 = makeAddr("artist2");
    address public producer = makeAddr("producer");
    address public songwriter = makeAddr("songwriter");
    address public buyer1 = makeAddr("buyer1");

    uint128 constant SONG_PRICE = 950_000;   // $0.95 (artist revenue per copy)
    uint128 constant PLATFORM_FEE = 50_000;  // $0.05 (flat per-transaction fee)
    // Single mint total: $0.95 + $0.05 = $1.00
    // Multi mint total: ($0.95 * qty) + $0.05

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy Tortoise
        vm.startPrank(owner);
        tortoise = new TortoiseV1(
            address(usdc),
            platformFeeRecipient,
            PLATFORM_FEE,
            SONG_PRICE
        );
        vm.stopPrank();

        // Fund test accounts with USDC
        usdc.mint(buyer1, 1_000_000_000); // $1000
    }

    // ============ Song Creation Tests ============

    function test_CreateSong_Success() public {
        vm.startPrank(artist1);

        uint256 songId = tortoise.createSong(
            "My First Song",
            SONG_PRICE,
            100,
            "ipfs://QmExample"
        );

        assertEq(songId, 0);

        TortoiseV1.Song memory song = tortoise.getSongDetails(0);
        assertEq(song.title, "My First Song");
        assertEq(song.artist, artist1);
        assertEq(song.price, SONG_PRICE);
        assertEq(song.maxSupply, 100);
        assertEq(song.currentSupply, 0);
        assertTrue(song.exists);
        assertFalse(song.splitsLocked);

        vm.stopPrank();
    }

    function test_CreateSong_UsesDefaultPrice() public {
        vm.startPrank(artist1);

        tortoise.createSong("Free Price Song", 0, 100, "ipfs://test");

        TortoiseV1.Song memory song = tortoise.getSongDetails(0);
        assertEq(song.price, SONG_PRICE); // Default $0.95

        vm.stopPrank();
    }

    // ============ Split Configuration Tests ============

    function test_ConfigureSplits_Success() public {
        // Create song
        vm.startPrank(artist1);
        tortoise.createSong("Split Song", SONG_PRICE, 100, "ipfs://test");

        // Configure splits
        SplitRecipient[] memory splits = new SplitRecipient[](3);
        splits[0] = SplitRecipient(artist1, 7000);   // 70%
        splits[1] = SplitRecipient(producer, 2000);  // 20%
        splits[2] = SplitRecipient(songwriter, 1000); // 10%

        tortoise.configureSplits(0, splits);

        SplitRecipient[] memory storedSplits = tortoise.getSongSplits(0);
        assertEq(storedSplits.length, 3);
        assertEq(storedSplits[0].recipient, artist1);
        assertEq(storedSplits[0].percentage, 7000);

        vm.stopPrank();
    }

    function test_ConfigureSplits_RevertWhen_NotArtist() public {
        vm.prank(artist1);
        tortoise.createSong("Split Song", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(artist1, 10000);

        vm.prank(artist2);
        vm.expectRevert("Only artist can configure splits");
        tortoise.configureSplits(0, splits);
    }

    function test_ConfigureSplits_RevertWhen_InvalidTotal() public {
        vm.startPrank(artist1);
        tortoise.createSong("Split Song", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(artist1, 5000); // 50%
        splits[1] = SplitRecipient(producer, 4000); // 40% - total 90%

        vm.expectRevert(SplitLib.InvalidSplitTotal.selector);
        tortoise.configureSplits(0, splits);

        vm.stopPrank();
    }

    function test_LockSplits_Success() public {
        vm.startPrank(artist1);
        tortoise.createSong("Lock Test", SONG_PRICE, 100, "ipfs://test");

        tortoise.lockSplits(0);

        TortoiseV1.Song memory song = tortoise.getSongDetails(0);
        assertTrue(song.splitsLocked);

        // Should revert on reconfigure
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(artist1, 10000);

        vm.expectRevert("Splits are locked");
        tortoise.configureSplits(0, splits);

        vm.stopPrank();
    }

    // ============ Minting Tests ============

    function test_MintSong_WithoutSplits() public {
        // Create song
        vm.prank(artist1);
        tortoise.createSong("Mint Test", SONG_PRICE, 100, "ipfs://test");

        // Approve and mint: $0.95 + $0.05 = $1.00
        uint256 totalCost = SONG_PRICE + PLATFORM_FEE;

        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, 1, buyer1);
        vm.stopPrank();

        // Verify balances
        assertEq(tortoise.balanceOf(buyer1, 0), 1);
        assertEq(usdc.balanceOf(platformFeeRecipient), PLATFORM_FEE); // $0.05
        assertEq(usdc.balanceOf(artist1), SONG_PRICE);                // $0.95
    }

    function test_MintSong_WithSplits() public {
        // Create song and configure splits
        vm.startPrank(artist1);
        tortoise.createSong("Split Mint", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](3);
        splits[0] = SplitRecipient(artist1, 7000);   // 70%
        splits[1] = SplitRecipient(producer, 2000);  // 20%
        splits[2] = SplitRecipient(songwriter, 1000); // 10%
        tortoise.configureSplits(0, splits);
        vm.stopPrank();

        // Mint: $0.95 + $0.05 flat fee = $1.00
        uint256 totalCost = SONG_PRICE + PLATFORM_FEE;

        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, 1, buyer1);
        vm.stopPrank();

        // Verify split payments (splits applied to artist revenue: $0.95)
        assertEq(usdc.balanceOf(platformFeeRecipient), PLATFORM_FEE); // $0.05
        assertEq(usdc.balanceOf(artist1), 665_000);    // 70% of 950_000
        assertEq(usdc.balanceOf(producer), 190_000);   // 20% of 950_000
        assertEq(usdc.balanceOf(songwriter), 95_000);  // 10% of 950_000
    }

    function test_MintSong_MultipleQuantity() public {
        vm.prank(artist1);
        tortoise.createSong("Multi Mint", SONG_PRICE, 100, "ipfs://test");

        uint256 quantity = 5;
        // Platform fee is flat (once per tx), not per copy
        uint256 totalCost = (SONG_PRICE * quantity) + PLATFORM_FEE;
        // totalCost = ($0.95 * 5) + $0.05 = $4.80

        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, quantity, buyer1);
        vm.stopPrank();

        assertEq(tortoise.balanceOf(buyer1, 0), 5);
        assertEq(usdc.balanceOf(platformFeeRecipient), PLATFORM_FEE); // $0.05 flat
        assertEq(usdc.balanceOf(artist1), SONG_PRICE * quantity);     // $0.95 * 5 = $4.75
    }

    function test_MintSong_RevertWhen_InsufficientAllowance() public {
        vm.prank(artist1);
        tortoise.createSong("Allowance Test", SONG_PRICE, 100, "ipfs://test");

        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), SONG_PRICE); // Missing platform fee

        vm.expectRevert();
        tortoise.mintSong(0, 1, buyer1);
        vm.stopPrank();
    }

    // ============ Admin Tests ============

    function test_UpdatePlatformFee() public {
        vm.startPrank(owner);

        uint128 newFee = 100_000; // $0.10
        tortoise.updatePlatformFee(newFee);

        TortoiseV1.ContractConfig memory cfg = tortoise.getConfig();
        assertEq(cfg.platformFee, newFee);

        vm.stopPrank();
    }

    function test_UpdatePlatformFee_RevertWhen_ExceedsMax() public {
        vm.startPrank(owner);

        vm.expectRevert("Fee exceeds maximum");
        tortoise.updatePlatformFee(2_000_000); // $2, exceeds $1 max

        vm.stopPrank();
    }

    function test_UpdateDefaultPrice_RevertWhen_Zero() public {
        vm.prank(owner);
        vm.expectRevert("Price must be positive");
        tortoise.updateDefaultPrice(0);
    }

    // ============ Security Audit Test Cases ============

    // C-1: Split rounding dust must not stay in contract
    function test_MintSong_SplitRoundingDust_NoLeftover() public {
        vm.startPrank(artist1);
        // Use a price that causes rounding: $1.00001 (1_000_001 units)
        tortoise.createSong("Rounding Test", 1_000_001, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](3);
        splits[0] = SplitRecipient(artist1, 3333);    // 33.33%
        splits[1] = SplitRecipient(producer, 3333);   // 33.33%
        splits[2] = SplitRecipient(songwriter, 3334);  // 33.34%
        tortoise.configureSplits(0, splits);
        vm.stopPrank();

        uint256 totalCost = tortoise.calculateTotalCost(0, 1);
        usdc.mint(buyer1, totalCost);

        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, 1, buyer1);
        vm.stopPrank();

        // Contract must hold zero USDC after distribution
        assertEq(usdc.balanceOf(address(tortoise)), 0);
    }

    // H-1: recoverTokens blocks USDC
    function test_RecoverTokens_RevertWhen_USDC() public {
        vm.prank(owner);
        vm.expectRevert("Cannot recover USDC");
        tortoise.recoverTokens(address(usdc), 1);
    }

    // H-2: Duplicate split recipients rejected
    function test_ConfigureSplits_RevertWhen_DuplicateRecipient() public {
        vm.startPrank(artist1);
        tortoise.createSong("Dup Test", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(producer, 5000);
        splits[1] = SplitRecipient(producer, 5000); // duplicate

        vm.expectRevert(SplitLib.DuplicateRecipient.selector);
        tortoise.configureSplits(0, splits);
        vm.stopPrank();
    }

    // Split with percentage below 1% minimum
    function test_ConfigureSplits_RevertWhen_BelowMinimum() public {
        vm.startPrank(artist1);
        tortoise.createSong("Min Test", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(artist1, 9901);
        splits[1] = SplitRecipient(producer, 99); // 0.99% — below 1% minimum

        vm.expectRevert(SplitLib.PercentageBelowMinimum.selector);
        tortoise.configureSplits(0, splits);
        vm.stopPrank();
    }

    // Splits with exactly 10 recipients (boundary — should succeed)
    function test_ConfigureSplits_MaxRecipients() public {
        vm.startPrank(artist1);
        tortoise.createSong("Max Splits", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](10);
        for (uint256 i = 0; i < 10; i++) {
            splits[i] = SplitRecipient(makeAddr(string.concat("r", vm.toString(i))), 1000);
        }
        tortoise.configureSplits(0, splits); // Should succeed (10 * 1000 = 10000)

        assertEq(tortoise.getSongSplits(0).length, 10);
        vm.stopPrank();
    }

    // Splits with 11 recipients (should revert)
    function test_ConfigureSplits_RevertWhen_TooManySplits() public {
        vm.startPrank(artist1);
        tortoise.createSong("Too Many", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](11);
        for (uint256 i = 0; i < 11; i++) {
            splits[i] = SplitRecipient(makeAddr(string.concat("r", vm.toString(i))), 909);
        }

        vm.expectRevert(SplitLib.TooManySplits.selector);
        tortoise.configureSplits(0, splits);
        vm.stopPrank();
    }

    // Split recipient is zero address
    function test_ConfigureSplits_RevertWhen_ZeroAddress() public {
        vm.startPrank(artist1);
        tortoise.createSong("Zero Addr", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(address(0), 10000);

        vm.expectRevert(SplitLib.ZeroAddressRecipient.selector);
        tortoise.configureSplits(0, splits);
        vm.stopPrank();
    }

    // lockSplits by non-artist reverts
    function test_LockSplits_RevertWhen_NotArtist() public {
        vm.prank(artist1);
        tortoise.createSong("Lock Auth", SONG_PRICE, 100, "ipfs://test");

        vm.prank(artist2);
        vm.expectRevert("Only artist can lock splits");
        tortoise.lockSplits(0);
    }

    // lockSplits on already locked song reverts
    function test_LockSplits_RevertWhen_AlreadyLocked() public {
        vm.startPrank(artist1);
        tortoise.createSong("Double Lock", SONG_PRICE, 100, "ipfs://test");
        tortoise.lockSplits(0);

        vm.expectRevert("Already locked");
        tortoise.lockSplits(0);
        vm.stopPrank();
    }

    // Minting with price = 0 (free song, only platform fee)
    function test_MintSong_FreeSong_PlatformFeeOnly() public {
        vm.prank(artist1);
        tortoise.createSong("Free Song", 1, 100, "ipfs://test"); // 1 unit = $0.000001

        uint256 totalCost = tortoise.calculateTotalCost(0, 1);
        assertEq(totalCost, 1 + PLATFORM_FEE); // price(1) + fee

        usdc.mint(buyer1, totalCost);
        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, 1, buyer1);
        vm.stopPrank();

        assertEq(tortoise.balanceOf(buyer1, 0), 1);
    }

    // Minting with platformFee = 0 (admin set fee to zero)
    function test_MintSong_ZeroPlatformFee() public {
        vm.prank(owner);
        tortoise.updatePlatformFee(0);

        vm.prank(artist1);
        tortoise.createSong("No Fee", SONG_PRICE, 100, "ipfs://test");

        uint256 totalCost = tortoise.calculateTotalCost(0, 1);
        assertEq(totalCost, SONG_PRICE); // No fee

        usdc.mint(buyer1, totalCost);
        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, 1, buyer1);
        vm.stopPrank();

        assertEq(usdc.balanceOf(artist1), SONG_PRICE);
        assertEq(usdc.balanceOf(platformFeeRecipient), 0);
    }

    // Unlimited supply song (maxSupply = 0)
    function test_MintSong_UnlimitedSupply() public {
        vm.prank(artist1);
        tortoise.createSong("Unlimited", SONG_PRICE, 0, "ipfs://test"); // 0 = unlimited

        uint256 qty = 1000;
        uint256 totalCost = tortoise.calculateTotalCost(0, qty);
        usdc.mint(buyer1, totalCost);

        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, qty, buyer1);
        vm.stopPrank();

        assertEq(tortoise.balanceOf(buyer1, 0), qty);
    }

    // M-4: createSong with price=0 emits default price, not zero
    function test_CreateSong_EmitsActualPrice() public {
        vm.startPrank(artist1);

        vm.expectEmit(true, true, true, true);
        emit SongCreated(0, "Default Price", artist1, SONG_PRICE, 100); // Should be SONG_PRICE, not 0

        tortoise.createSong("Default Price", 0, 100, "ipfs://test");
        vm.stopPrank();
    }

    // M-3: configureSplits reverts when paused
    function test_ConfigureSplits_RevertWhen_Paused() public {
        vm.prank(artist1);
        tortoise.createSong("Pause Test", SONG_PRICE, 100, "ipfs://test");

        vm.prank(owner);
        tortoise.pause();

        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(artist1, 10000);

        vm.prank(artist1);
        vm.expectRevert();
        tortoise.configureSplits(0, splits);
    }

    // M-3: lockSplits reverts when paused
    function test_LockSplits_RevertWhen_Paused() public {
        vm.prank(artist1);
        tortoise.createSong("Pause Lock", SONG_PRICE, 100, "ipfs://test");

        vm.prank(owner);
        tortoise.pause();

        vm.prank(artist1);
        vm.expectRevert();
        tortoise.lockSplits(0);
    }

    // Artist can assign 100% to collaborators (not in split at all)
    function test_MintSong_SplitsWithoutArtist() public {
        vm.startPrank(artist1);
        tortoise.createSong("No Artist Split", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(producer, 6000);   // 60%
        splits[1] = SplitRecipient(songwriter, 4000);  // 40%
        tortoise.configureSplits(0, splits);
        vm.stopPrank();

        uint256 totalCost = SONG_PRICE + PLATFORM_FEE;
        usdc.mint(buyer1, totalCost);

        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, 1, buyer1);
        vm.stopPrank();

        assertEq(usdc.balanceOf(artist1), 0);         // Artist gets nothing
        assertEq(usdc.balanceOf(producer), 570_000);   // 60% of 950_000
        assertEq(usdc.balanceOf(songwriter), 380_000); // 40% of 950_000
    }
}
```

#### Fuzz Tests (TortoiseV1.fuzz.t.sol)

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TortoiseV1, SplitRecipient} from "../src/TortoiseV1.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract TortoiseV1FuzzTest is Test {
    TortoiseV1 public tortoise;
    MockUSDC public usdc;

    function setUp() public {
        usdc = new MockUSDC();
        tortoise = new TortoiseV1(
            address(usdc),
            makeAddr("platform"),
            50_000,
            950_000
        );
    }

    function testFuzz_CreateSong_VariousPrices(uint128 price) public {
        vm.assume(price <= 1_000_000_000_000); // Max $1M

        vm.prank(makeAddr("artist"));
        tortoise.createSong("Fuzz Song", price, 100, "ipfs://fuzz");

        TortoiseV1.Song memory song = tortoise.getSongDetails(0);

        if (price == 0) {
            assertEq(song.price, 950_000); // Default ($0.95)
        } else {
            assertEq(song.price, price);
        }
    }

    function testFuzz_MintQuantities(uint256 quantity) public {
        vm.assume(quantity > 0 && quantity <= 1000);

        address artist = makeAddr("artist");
        address buyer = makeAddr("buyer");

        vm.prank(artist);
        tortoise.createSong("Fuzz Mint", 950_000, 0, "ipfs://");

        uint256 totalCost = tortoise.calculateTotalCost(0, quantity);
        usdc.mint(buyer, totalCost);

        vm.startPrank(buyer);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, quantity, buyer);
        vm.stopPrank();

        assertEq(tortoise.balanceOf(buyer, 0), quantity);
    }

    function testFuzz_SplitPercentages(
        uint96 split1,
        uint96 split2,
        uint96 split3
    ) public {
        vm.assume(split1 >= 100 && split2 >= 100 && split3 >= 100); // Min 1% each
        vm.assume(uint256(split1) + split2 + split3 == 10_000);

        address artist = makeAddr("artist");

        vm.startPrank(artist);
        tortoise.createSong("Split Fuzz", 950_000, 100, "ipfs://");

        SplitRecipient[] memory splits = new SplitRecipient[](3);
        splits[0] = SplitRecipient(makeAddr("r1"), split1);
        splits[1] = SplitRecipient(makeAddr("r2"), split2);
        splits[2] = SplitRecipient(makeAddr("r3"), split3);

        tortoise.configureSplits(0, splits);
        vm.stopPrank();

        SplitRecipient[] memory stored = tortoise.getSongSplits(0);
        assertEq(stored[0].percentage, split1);
        assertEq(stored[1].percentage, split2);
        assertEq(stored[2].percentage, split3);
    }
}
```

#### Invariant Tests (TortoiseV1.invariant.t.sol)

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TortoiseV1, SplitRecipient} from "../src/TortoiseV1.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract TortoiseV1InvariantHandler is Test {
    TortoiseV1 public tortoise;
    MockUSDC public usdc;

    uint256 public songCount;
    uint256 public totalMinted;
    uint256 public totalPlatformFees;
    uint256 public totalArtistPayments;

    constructor(TortoiseV1 _tortoise, MockUSDC _usdc) {
        tortoise = _tortoise;
        usdc = _usdc;
    }

    function createSong(uint128 price, uint128 maxSupply) external {
        if (price == 0) price = 950_000;
        if (maxSupply == 0) maxSupply = 1000;

        tortoise.createSong(
            string.concat("Song ", vm.toString(songCount)),
            price,
            maxSupply,
            "ipfs://test"
        );
        songCount++;
    }

    function mintSong(uint256 songId, uint256 quantity, address buyer) external {
        if (songCount == 0) return;
        songId = bound(songId, 0, songCount - 1);
        quantity = bound(quantity, 1, 10);

        TortoiseV1.Song memory song = tortoise.getSongDetails(songId);
        if (!song.exists) return;
        if (song.maxSupply > 0 && song.currentSupply + quantity > song.maxSupply) return;

        uint256 totalCost = tortoise.calculateTotalCost(songId, quantity);
        usdc.mint(buyer, totalCost);

        vm.startPrank(buyer);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(songId, quantity, buyer);
        vm.stopPrank();

        totalMinted += quantity;
        totalPlatformFees += tortoise.getConfig().platformFee;
        totalArtistPayments += (song.price * quantity);
    }
}

contract TortoiseV1InvariantTest is Test {
    TortoiseV1 public tortoise;
    MockUSDC public usdc;
    TortoiseV1InvariantHandler public handler;

    function setUp() public {
        usdc = new MockUSDC();
        tortoise = new TortoiseV1(
            address(usdc),
            makeAddr("platform"),
            50_000,
            950_000
        );

        handler = new TortoiseV1InvariantHandler(tortoise, usdc);
        targetContract(address(handler));
    }

    function invariant_SupplyNeverExceedsMax() public view {
        for (uint256 i = 0; i < handler.songCount(); i++) {
            TortoiseV1.Song memory song = tortoise.getSongDetails(i);
            if (song.exists && song.maxSupply > 0) {
                assertLe(song.currentSupply, song.maxSupply);
            }
        }
    }

    function invariant_PlatformFeeNeverExceedsMax() public view {
        assertLe(
            tortoise.getConfig().platformFee,
            tortoise.MAX_PLATFORM_FEE()
        );
    }

    function invariant_ContractHasNoLeftoverUSDC() public view {
        // Contract should always distribute all USDC
        assertEq(usdc.balanceOf(address(tortoise)), 0);
    }
}
```

#### Integration Tests (TortoiseV1.integration.t.sol)

```solidity
// Tests against forked Base network with real USDC
// Test Base Pay integration with mock/real contract
```

### 5.3 Test Commands

```bash
# Run all tests
pnpm test

# Run with verbosity
pnpm test:verbose

# Run specific test file
forge test --match-path test/unit/TortoiseV1.t.sol

# Run specific test function
forge test --match-test test_MintSong_WithSplits

# Run fuzz tests with more iterations
forge test --match-path 'test/fuzz/*.t.sol' --fuzz-runs 5000

# Run invariant tests
pnpm test:invariant

# Run fork tests (requires BASE_RPC_URL)
pnpm test:fork

# Gas report
pnpm test:gas

# Coverage report
pnpm coverage

# Lint for security and style issues
forge lint
forge lint --severity high
```

---

## 6. Deployment

### 6.1 Deployment Script

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {TortoiseV1} from "../src/TortoiseV1.sol";

contract DeployTortoiseV1 is Script {
    // Base Mainnet USDC
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    // Base Sepolia USDC
    address constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() public returns (TortoiseV1) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address platformFeeRecipient = vm.envAddress("PLATFORM_FEE_RECIPIENT");
        uint128 platformFee = uint128(vm.envUint("INITIAL_PLATFORM_FEE"));
        uint128 defaultPrice = uint128(vm.envUint("INITIAL_SONG_PRICE"));

        // Determine USDC address based on chain
        address usdcAddress;
        if (block.chainid == 8453) {
            usdcAddress = USDC_BASE;
            console.log("Deploying to Base Mainnet");
        } else if (block.chainid == 84532) {
            usdcAddress = USDC_BASE_SEPOLIA;
            console.log("Deploying to Base Sepolia");
        } else {
            revert("Unsupported chain");
        }

        console.log("USDC Address:", usdcAddress);
        console.log("Platform Fee Recipient:", platformFeeRecipient);
        console.log("Platform Fee:", platformFee);
        console.log("Default Price:", defaultPrice);

        vm.startBroadcast(deployerPrivateKey);

        TortoiseV1 tortoise = new TortoiseV1(
            usdcAddress,
            platformFeeRecipient,
            platformFee,
            defaultPrice
        );

        console.log("Tortoise v1 deployed at:", address(tortoise));

        vm.stopBroadcast();

        return tortoise;
    }
}
```

### 6.2 Deployment Commands

```bash
# Deploy to Base Sepolia
pnpm deploy:base-sepolia

# Deploy to Base Mainnet (requires confirmation)
pnpm deploy:base

# Verify contract
forge verify-contract \
  --chain base \
  --constructor-args $(cast abi-encode "constructor(address,address,uint128,uint128)" \
    0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
    $PLATFORM_FEE_RECIPIENT \
    50000 \
    950000) \
  $CONTRACT_ADDRESS \
  src/TortoiseV1.sol:TortoiseV1
```

---

## 7. Security Audit Findings

The following issues were identified during a deep security review of the planned contract code. Each finding includes the required fix.

### 7.1 CRITICAL — Will Lose Funds

#### C-1: Split rounding dust stuck in contract forever

**Location:** `_distributePayments` split loop

**Issue:** `calculateSplitAmount` uses integer division: `(totalAmount * percentage) / BASIS_POINTS`. The divided amounts do not always sum to `artistRevenue`. The remainder (dust) stays in the contract with no way to recover it (accumulates over every mint with splits).

**Example:**
```
artistRevenue = 1_000_001 (custom-priced song)
Splits: 33.33% / 33.33% / 33.34%

Recipient 1: 1_000_001 * 3333 / 10000 = 333_300
Recipient 2: 1_000_001 * 3333 / 10000 = 333_300
Recipient 3: 1_000_001 * 3334 / 10000 = 333_400
Total distributed: 1_000_000
Lost: 1 USDC unit per mint
```

**Note:** The plan's security section claims "last recipient receives remainder" but the code does not implement this. The `invariant_ContractHasNoLeftoverUSDC` test would catch this — meaning the implementation as written would fail its own invariant.

**Fix:** Last recipient must receive the remainder instead of the calculated amount:
```solidity
// In _distributePayments, replace the split loop with:
uint256 distributed = 0;
for (uint256 i = 0; i < splits.length; i++) {
    uint256 amount;
    if (i == splits.length - 1) {
        // Last recipient gets the remainder to avoid rounding dust
        amount = artistRevenue - distributed;
    } else {
        amount = SplitLib.calculateSplitAmount(artistRevenue, splits[i].percentage);
    }
    distributed += amount;
    if (amount > 0) {
        IERC20(config.usdcToken).safeTransfer(splits[i].recipient, amount);
        emit PaymentDistributed(songId, splits[i].recipient, amount, false);
    }
}
```

---

#### C-2: `currentSupply` unsafe downcast truncation

**Location:** `_processMint`: `song.currentSupply += uint128(quantity);`

**Issue:** `quantity` is `uint256`, validated only as `<= MAX_MINT_QUANTITY` (100,000). The explicit cast `uint128(quantity)` bypasses Solidity 0.8's checked arithmetic. While practically impossible to overflow `uint128` at 100k per call, the missing check is a code quality issue and could become exploitable if `MAX_MINT_QUANTITY` is raised.

**Fix:** Add explicit check:
```solidity
require(song.currentSupply + quantity <= type(uint128).max, "Supply overflow");
song.currentSupply += uint128(quantity);
```

---

### 7.2 HIGH — Potential Fund Loss or Broken Invariants

#### H-1: `recoverTokens` can drain USDC

**Location:** `recoverTokens`

**Issue:** No restriction on token address. Owner can call `recoverTokens(config.usdcToken, amount)` to drain any USDC held by the contract (rounding dust, or mid-transaction if future changes introduce intermediate balances). v0.3 had balance checks and validation; v1 has neither.

**Fix:** Either block USDC recovery or gate it behind a timelock:
```solidity
function recoverTokens(address token, uint256 amount) external onlyOwner nonReentrant {
    require(token != config.usdcToken, "Cannot recover USDC");
    IERC20(token).safeTransfer(owner(), amount);
}
```
Add a separate `emergencyWithdrawUSDC()` function with a timelock or multisig requirement if emergency recovery is needed.

Also: add `nonReentrant` modifier (missing from v1 plan, present in v0.3).

---

#### H-2: No duplicate recipient check in splits

**Location:** `SplitLib.validateSplits`

**Issue:** An artist can set the same address multiple times in splits. This wastes gas (multiple USDC transfers to the same address) and confuses off-chain indexers. More importantly, if the rounding remainder fix (C-1) gives the "last" recipient the dust, a malicious split ordering could game who receives remainders.

**Fix:** Add duplicate check in `validateSplits`:
```solidity
// After the percentage checks:
for (uint256 i = 0; i < splits.length; i++) {
    for (uint256 j = i + 1; j < splits.length; j++) {
        if (splits[i].recipient == splits[j].recipient) revert DuplicateRecipient();
    }
}
```

---

#### H-3: `mintBatchSongs` declared in interface but not implemented

**Location:** Interface `ITortoiseV1` line 358-362

**Issue:** The interface declares `mintBatchSongs` but the contract skeleton has no implementation. Any contract claiming to implement this interface would fail. If batch minting is intended, it needs implementation with:
- Single flat platform fee for the entire batch
- ReentrancyGuard
- Proper loop bounds and gas limit handling
- Split distribution per song

**Fix:** Either implement the function or remove it from the interface. If implementing, follow v0.3's batch pattern but adapted for USDC and splits.

---

### 7.3 MEDIUM — Design Concerns

#### M-1: Owner can set platform fee to consume most of song price

**Issue:** `updatePlatformFee` caps at `MAX_PLATFORM_FEE = $1.00`. But a song priced at $0.95 with a $0.95 platform fee means the artist gets $0.00 per single mint. The math doesn't break (`artistRevenue = ($0.95 * 1) + $0.95 - $0.95 = $0.95`... wait, no: `totalCost = (price * qty) + platformFee`, so `artistRevenue = totalCost - platformFee = price * qty`). The artist revenue is actually always `price * quantity` regardless of platform fee.

Correction: On re-examination, this is not actually an issue. `totalCost = (price * qty) + platformFee`, and `artistRevenue = totalCost - platformFee = price * qty`. The platform fee cannot eat into artist revenue — it's additive. However, a high platform fee does make songs more expensive for buyers, which could hurt artists indirectly.

**Action:** Document this as a known trust assumption. No code fix needed.

---

#### M-2: `updateDefaultPrice` has no lower bound

**Location:** `updateDefaultPrice`

**Issue:** Owner can set `defaultSongPrice` to 0. Artists creating songs without a custom price would get $0 per copy (only platform fee collected).

**Fix:**
```solidity
function updateDefaultPrice(uint128 newPrice) external onlyOwner {
    require(newPrice > 0, "Price must be positive");
    uint128 oldPrice = config.defaultSongPrice;
    config.defaultSongPrice = newPrice;
    emit DefaultPriceUpdated(oldPrice, newPrice);
}
```

---

#### M-3: No `whenNotPaused` on `configureSplits` and `lockSplits`

**Issue:** During an emergency pause (e.g., exploit detected), artists can still change or lock splits. If the pause is due to a split-related vulnerability, the owner cannot prevent split modifications.

**Fix:** Add `whenNotPaused` modifier to both `configureSplits` and `lockSplits`. Or document this as intentional (artists always retain split control).

---

#### M-4: `createSong` emits wrong price when using default

**Location:** `createSong` event emission

**Issue:** When `price == 0`, the song is stored with `config.defaultSongPrice` but the event emits the input parameter (0). Off-chain indexers record the wrong price.

**Fix:**
```solidity
// Change the emit to use the stored price:
uint128 actualPrice = price == 0 ? config.defaultSongPrice : price;
songs[songId] = Song({ ..., price: actualPrice, ... });
emit SongCreated(songId, title, msg.sender, actualPrice, maxSupply);
```

---

#### M-5: CEI pattern violated — USDC pulled before validation

**Location:** `mintSong`

**Issue:** `safeTransferFrom` (line 638) executes before `_processMint` validates the song exists and quantity is valid. If validation fails, the tx reverts and no funds are lost, but the buyer wastes gas.

**Fix:** Extract validation from `_processMint` and call it before the USDC transfer:
```solidity
function mintSong(uint256 songId, uint256 quantity, address recipient)
    external nonReentrant whenNotPaused
{
    _validateMint(songId, quantity); // Checks first
    uint256 totalCost = calculateTotalCost(songId, quantity);
    IERC20(config.usdcToken).safeTransferFrom(msg.sender, address(this), totalCost);
    _processMint(songId, quantity, recipient, totalCost); // Effects + Interactions
}
```

---

### 7.4 LOW — Minor Issues

#### L-1: Missing `name()` and `symbol()` functions

v0.3 returned "Tortoise" / "TORT". Some marketplaces and indexers expect these on ERC1155 contracts. Add them.

---

#### L-2: `artistSongs` mapping is append-only, no song transfer

v0.3 had `updateArtistAddress` and `_removeSongFromArtist`. v1 has neither. An artist can never transfer song ownership. If intentional, document it.

---

#### L-3: `recoverTokens` missing `nonReentrant`

v0.3 had `nonReentrant` on `recoverTokens`. v1 doesn't. Since `safeTransfer` could call into a malicious token contract's callback, reentrancy protection should be present.

---

#### L-4: `SplitRecipient[]` in events is hard to index

`event SplitsConfigured(uint256 indexed songId, SplitRecipient[] splits)` — dynamic struct arrays in events are ABI-encoded, making them harder to decode for some off-chain tools. Consider emitting individual events per recipient, or a hash of the splits config.

---

### 7.5 Updated Audit Checklist

- [ ] **C-1**: Split rounding dust — last recipient gets remainder
- [ ] **C-2**: Safe uint128 cast on currentSupply
- [ ] **H-1**: Block USDC in recoverTokens, add nonReentrant
- [ ] **H-2**: Duplicate split recipient check
- [ ] **H-3**: Implement or remove mintBatchSongs
- [ ] **M-2**: Minimum default price validation
- [ ] **M-3**: Decide on whenNotPaused for split functions
- [ ] **M-4**: Emit actual stored price in createSong
- [ ] **M-5**: Validate before USDC transfer
- [ ] **L-1**: Add name() and symbol()
- [ ] **L-2**: Decide on song ownership transfer
- [ ] **L-3**: Add nonReentrant to recoverTokens
- [ ] **L-4**: Consider split event design
- [ ] All external calls use ReentrancyGuard
- [ ] CEI pattern followed in all functions
- [ ] Input validation on all parameters
- [ ] Access control on admin functions
- [ ] Events emitted for all state changes
- [ ] SafeERC20 used for all token transfers
- [ ] No unchecked arithmetic in critical paths
- [ ] Split percentages validated to sum to 100%
- [ ] Maximum limits on arrays (splits, batch size)

---

## 8. Migration from v0.3

### 8.1 Key Differences

| Aspect | v0.3 | v1 |
|--------|------|------|
| Payment | ETH | USDC (ERC20) |
| User Flow | Send ETH with tx | Approve + Mint |
| Pricing | Price + fee on top | $1 total (fee included) |
| Fee Model | Fee per copy | Flat fee per transaction |
| Splits | Not supported | Configurable per-song |
| Price Decimals | 18 (wei) | 6 (USDC) |
| Refunds | Automatic (ETH) | Not needed (exact approve) |

### 8.2 Migration Notes

1. **No State Migration**: v1 is a new deployment with fresh state
2. **NFTs Not Transferable**: Existing v0.3 NFTs remain on v0.3 contract
3. **Artists Must Re-create**: Songs need to be recreated on v1
4. **Users Need USDC**: Users must have USDC instead of ETH

---

## 9. Development Timeline

### Phase 1: Setup (Day 1)
- [ ] Initialize repository with pnpm
- [ ] Configure Foundry
- [ ] Install dependencies
- [ ] Set up linting and formatting

### Phase 2: Core Contract (Days 2-4)
- [ ] Implement SplitLib library
- [ ] Implement main contract structure
- [ ] Add USDC payment logic
- [ ] Add split distribution logic
- [ ] Add admin functions

### Phase 3: Testing (Days 5-7)
- [ ] Write unit tests (target: 100% coverage)
- [ ] Write fuzz tests
- [ ] Write invariant tests
- [ ] Test on local fork

### Phase 4: Deployment & Verification (Days 8-9)
- [ ] Deploy to Base Sepolia
- [ ] Verify contract
- [ ] Test full flow on testnet
- [ ] Document deployment

### Phase 5: Audit Prep (Days 10-11)
- [ ] Internal security review
- [ ] Fix any issues found
- [ ] Prepare audit documentation

---

## 10. Commands Reference

```bash
# Project setup
pnpm init
forge init --no-commit
pnpm install
forge install OpenZeppelin/openzeppelin-contracts --no-commit

# Development
pnpm build                 # Compile contracts
pnpm test                  # Run all tests
pnpm test:verbose          # Run tests with traces
pnpm test:gas              # Generate gas report
pnpm coverage              # Generate coverage report
pnpm fmt                   # Format code
pnpm lint                  # Lint code

# Deployment
pnpm deploy:local          # Deploy to local node
pnpm deploy:base-sepolia   # Deploy to Base Sepolia
pnpm deploy:base           # Deploy to Base Mainnet

# Utilities
forge snapshot             # Create gas snapshot
forge snapshot --diff      # Compare gas changes
forge inspect TortoiseV1 storage-layout  # View storage
cast call $ADDR "getSongDetails(uint256)" 0  # Query contract
```

---

## Appendix A: USDC Token Details

**Base Mainnet USDC:**
- Address: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- Decimals: 6
- Symbol: USDC
- Name: USD Coin

**Base Sepolia USDC:**
- Address: `0x036CbD53842c5426634e7929541eC2318f3dCF7e`
- Decimals: 6
- Symbol: USDC
- Name: USD Coin

---

*This plan is a living document and should be updated as implementation progresses.*
