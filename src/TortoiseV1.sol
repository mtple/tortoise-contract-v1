// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SplitLib, SplitRecipient} from "./libraries/SplitLib.sol";

/// @notice Represents a song with its metadata and splits
struct Song {
    string title; // Song title
    address artist; // Primary artist address
    uint128 price; // Price in USDC (6 decimals)
    uint128 maxSupply; // Maximum mintable supply (0 = unlimited)
    uint128 currentSupply; // Current minted supply
    bool exists; // Whether song exists
    bool splitsLocked; // Whether splits can still be modified
}

/// @notice Configuration for the contract
struct ContractConfig {
    uint128 defaultSongPrice; // Default price for new songs (artist revenue per copy)
    uint128 platformFee; // Flat platform fee per transaction
    address platformFeeRecipient; // Where platform fees go
    address usdcToken; // USDC token address
}

/// @title Tortoise v1 - Music NFT Marketplace with USDC & Splits
/// @notice ERC1155-based NFT marketplace for music with USDC payments and revenue splits
/// @dev Implements configurable pricing, platform fees, and batch song creation for album uploads
contract TortoiseV1 is ERC1155, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

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

    event SplitsConfigured(uint256 indexed songId, SplitRecipient[] splits);

    event SplitsLocked(uint256 indexed songId);

    event PaymentDistributed(
        uint256 indexed songId,
        address indexed recipient,
        uint256 amount,
        bool isPlatformFee
    );

    event PlatformFeeUpdated(uint128 oldFee, uint128 newFee);
    event DefaultPriceUpdated(uint128 oldPrice, uint128 newPrice);

    // ============ Errors ============

    error ArrayLengthMismatch();
    error BatchTooLarge();
    error TitleCannotBeEmpty();
    error UriCannotBeEmpty();
    error SongDoesNotExist();
    error OnlyArtistCanConfigureSplits();
    error OnlyArtistCanLockSplits();
    error SplitsAreLocked();
    error AlreadyLocked();
    error QuantityMustBePositive();
    error ExceedsMaxMintQuantity();
    error WouldExceedMaxSupply();
    error SupplyOverflow();
    error InvalidUsdcAddress();
    error InvalidFeeRecipient();
    error FeeExceedsMaximum();
    error PriceMustBePositive();
    error InvalidRecipient();
    error CannotRecoverUsdc();

    // ============ Constructor ============

    constructor(
        address _usdcToken,
        address _platformFeeRecipient,
        uint128 _platformFee,
        uint128 _defaultSongPrice
    ) ERC1155("") Ownable(msg.sender) {
        if (_usdcToken == address(0)) revert InvalidUsdcAddress();
        if (_platformFeeRecipient == address(0)) revert InvalidFeeRecipient();
        if (_platformFee > MAX_PLATFORM_FEE) revert FeeExceedsMaximum();

        config = ContractConfig({
            defaultSongPrice: _defaultSongPrice == 0 ? DEFAULT_SONG_PRICE : _defaultSongPrice,
            platformFee: _platformFee == 0 ? DEFAULT_PLATFORM_FEE : _platformFee,
            platformFeeRecipient: _platformFeeRecipient,
            usdcToken: _usdcToken
        });
    }

    // ============ View Functions ============

    function name() public pure returns (string memory) {
        return _name;
    }

    function symbol() public pure returns (string memory) {
        return _symbol;
    }

    function getSongDetails(uint256 songId) external view returns (Song memory) {
        return songs[songId];
    }

    function getSongSplits(uint256 songId) external view returns (SplitRecipient[] memory) {
        return songSplits[songId];
    }

    function uri(uint256 songId) public view override returns (string memory) {
        if (!songs[songId].exists) revert SongDoesNotExist();
        return tokenUris[songId];
    }

    function getArtistSongs(address artist) external view returns (uint256[] memory) {
        return artistSongs[artist];
    }

    function getConfig() external view returns (ContractConfig memory) {
        return config;
    }

    /// @notice Get total cost for a mint: (price * quantity) + one flat platform fee
    /// @dev Platform fee is charged once per transaction, not per copy
    function calculateTotalCost(uint256 songId, uint256 quantity) public view returns (uint256) {
        Song storage song = songs[songId];
        if (!song.exists) revert SongDoesNotExist();
        return (uint256(song.price) * quantity) + config.platformFee;
    }

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
    ) external whenNotPaused returns (uint256 songId) {
        if (bytes(title).length == 0) revert TitleCannotBeEmpty();
        if (bytes(tokenUri).length == 0) revert UriCannotBeEmpty();

        songId = nextSongId++;

        uint128 actualPrice = price == 0 ? config.defaultSongPrice : price;

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

        emit SongCreated(songId, title, msg.sender, actualPrice, maxSupply);
    }

    /// @notice Create multiple songs in a single transaction (album upload)
    /// @param titles Array of song titles (cannot be empty)
    /// @param prices Array of artist revenue per copy in USDC (0 = use default)
    /// @param maxSupplies Array of maximum supplies (0 = unlimited)
    /// @param tokenUris_ Array of IPFS URIs for metadata
    /// @return songIds Array of created song IDs
    function createSongs(
        string[] calldata titles,
        uint128[] calldata prices,
        uint128[] calldata maxSupplies,
        string[] calldata tokenUris_
    ) external whenNotPaused returns (uint256[] memory songIds) {
        uint256 length = titles.length;
        if (length != prices.length || length != maxSupplies.length || length != tokenUris_.length) {
            revert ArrayLengthMismatch();
        }
        if (length > MAX_BATCH_SIZE) revert BatchTooLarge();

        songIds = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            if (bytes(titles[i]).length == 0) revert TitleCannotBeEmpty();
            if (bytes(tokenUris_[i]).length == 0) revert UriCannotBeEmpty();

            uint256 songId = nextSongId++;
            songIds[i] = songId;

            uint128 actualPrice = prices[i] == 0 ? config.defaultSongPrice : prices[i];

            songs[songId] = Song({
                title: titles[i],
                artist: msg.sender,
                price: actualPrice,
                maxSupply: maxSupplies[i],
                currentSupply: 0,
                exists: true,
                splitsLocked: false
            });

            tokenUris[songId] = tokenUris_[i];
            artistSongs[msg.sender].push(songId);

            emit SongCreated(songId, titles[i], msg.sender, actualPrice, maxSupplies[i]);
        }
    }

    /// @notice Configure revenue splits for a song
    /// @param songId The song to configure
    /// @param splits Array of split recipients (must total 10000 basis points)
    function configureSplits(
        uint256 songId,
        SplitRecipient[] calldata splits
    ) external whenNotPaused {
        Song storage song = songs[songId];
        if (!song.exists) revert SongDoesNotExist();
        if (msg.sender != song.artist) revert OnlyArtistCanConfigureSplits();
        if (song.splitsLocked) revert SplitsAreLocked();

        SplitLib.validateSplits(splits);

        // Clear existing splits
        delete songSplits[songId];

        // Store new splits
        for (uint256 i = 0; i < splits.length; i++) {
            songSplits[songId].push(splits[i]);
        }

        emit SplitsConfigured(songId, splits);
    }

    /// @notice Lock splits permanently (cannot be undone)
    /// @param songId The song to lock
    function lockSplits(uint256 songId) external whenNotPaused {
        Song storage song = songs[songId];
        if (!song.exists) revert SongDoesNotExist();
        if (msg.sender != song.artist) revert OnlyArtistCanLockSplits();
        if (song.splitsLocked) revert AlreadyLocked();

        song.splitsLocked = true;
        emit SplitsLocked(songId);
    }

    // ============ Minting ============

    /// @notice Mint songs using USDC
    /// @param songId The song to mint
    /// @param quantity Number to mint
    /// @param recipient Address to receive the NFTs
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

    /// @notice Batch mint multiple songs
    /// @param songIds Array of song IDs
    /// @param quantities Array of quantities
    /// @param recipient Address to receive all NFTs
    function mintBatchSongs(
        uint256[] calldata songIds,
        uint256[] calldata quantities,
        address recipient
    ) external nonReentrant whenNotPaused {
        uint256 length = songIds.length;
        if (length != quantities.length) revert ArrayLengthMismatch();
        if (length > MAX_BATCH_SIZE) revert BatchTooLarge();

        // Validate all mints first
        for (uint256 i = 0; i < length; i++) {
            _validateMint(songIds[i], quantities[i]);
        }

        // Calculate total cost: sum of all song prices + single flat platform fee
        uint256 totalCost = config.platformFee;
        for (uint256 i = 0; i < length; i++) {
            totalCost += uint256(songs[songIds[i]].price) * quantities[i];
        }

        // Transfer USDC from buyer
        IERC20(config.usdcToken).safeTransferFrom(msg.sender, address(this), totalCost);

        // Distribute platform fee once
        IERC20(config.usdcToken).safeTransfer(config.platformFeeRecipient, config.platformFee);

        // Process each song mint
        address actualRecipient = recipient == address(0) ? msg.sender : recipient;
        for (uint256 i = 0; i < length; i++) {
            _processBatchMintSingle(songIds[i], quantities[i], actualRecipient);
        }
    }

    // ============ Internal Functions ============

    /// @dev M-5 fix: separate validation so it can be called before USDC transfer
    function _validateMint(uint256 songId, uint256 quantity) internal view {
        Song storage song = songs[songId];
        if (!song.exists) revert SongDoesNotExist();
        if (quantity == 0) revert QuantityMustBePositive();
        if (quantity > MAX_MINT_QUANTITY) revert ExceedsMaxMintQuantity();
        if (song.maxSupply != 0 && song.currentSupply + quantity > song.maxSupply) {
            revert WouldExceedMaxSupply();
        }
    }

    function _processMint(
        uint256 songId,
        uint256 quantity,
        address recipient,
        uint256 totalCost
    ) internal {
        Song storage song = songs[songId];

        address actualRecipient = recipient == address(0) ? msg.sender : recipient;

        // Update supply (C-2 fix: safe cast check)
        if (song.currentSupply + quantity > type(uint128).max) revert SupplyOverflow();
        song.currentSupply += uint128(quantity);

        // Mint NFTs
        _mint(actualRecipient, songId, quantity, "");

        // Distribute payments
        _distributePayments(songId, totalCost);

        emit SongMinted(songId, msg.sender, actualRecipient, quantity, totalCost);
    }

    /// @dev Process a single song in batch mint (no platform fee distribution)
    function _processBatchMintSingle(
        uint256 songId,
        uint256 quantity,
        address recipient
    ) internal {
        Song storage song = songs[songId];

        // Update supply
        if (song.currentSupply + quantity > type(uint128).max) revert SupplyOverflow();
        song.currentSupply += uint128(quantity);

        // Mint NFTs
        _mint(recipient, songId, quantity, "");

        // Distribute artist revenue (no platform fee - already distributed)
        uint256 artistRevenue = uint256(song.price) * quantity;
        _distributeArtistRevenue(songId, artistRevenue);

        uint256 totalPaid = artistRevenue; // For event (fee not included per-song)
        emit SongMinted(songId, msg.sender, recipient, quantity, totalPaid);
    }

    function _distributePayments(uint256 songId, uint256 totalCost) internal {
        // Platform fee (flat, once per transaction)
        uint256 platformFeeAmount = config.platformFee;
        IERC20(config.usdcToken).safeTransfer(config.platformFeeRecipient, platformFeeAmount);
        emit PaymentDistributed(songId, config.platformFeeRecipient, platformFeeAmount, true);

        // Artist revenue = total cost - flat platform fee
        uint256 artistRevenue = totalCost - platformFeeAmount;

        _distributeArtistRevenue(songId, artistRevenue);
    }

    function _distributeArtistRevenue(uint256 songId, uint256 artistRevenue) internal {
        Song storage song = songs[songId];
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

    // ============ Admin Functions ============

    function updatePlatformFee(uint128 newFee) external onlyOwner {
        if (newFee > MAX_PLATFORM_FEE) revert FeeExceedsMaximum();
        uint128 oldFee = config.platformFee;
        config.platformFee = newFee;
        emit PlatformFeeUpdated(oldFee, newFee);
    }

    function updateDefaultPrice(uint128 newPrice) external onlyOwner {
        if (newPrice == 0) revert PriceMustBePositive();
        uint128 oldPrice = config.defaultSongPrice;
        config.defaultSongPrice = newPrice;
        emit DefaultPriceUpdated(oldPrice, newPrice);
    }

    function updatePlatformFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert InvalidRecipient();
        config.platformFeeRecipient = newRecipient;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Recover accidentally sent ERC20 tokens (cannot recover USDC)
    /// @dev H-1 fix: block USDC recovery, add nonReentrant (L-3 fix)
    function recoverTokens(address token, uint256 amount) external onlyOwner nonReentrant {
        if (token == config.usdcToken) revert CannotRecoverUsdc();
        IERC20(token).safeTransfer(owner(), amount);
    }
}
