// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SplitRecipient, SplitLib} from "./libraries/SplitLib.sol";
import {ITortoiseShell} from "./interfaces/ITortoiseShell.sol";
import {Song, ContractConfig} from "./interfaces/ITortoiseV1.sol";

contract TortoiseV1 is ERC1155, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using SplitLib for SplitRecipient[];

    // ============ Constants ============

    uint256 public constant MAX_MINT_QUANTITY = 100_000;
    uint128 public constant MAX_PLATFORM_FEE = 1_000_000;
    uint128 public constant MAX_STAKING_FEE = 1_000_000;
    uint128 public constant MIN_SONG_PRICE = 100_000; // $0.10 minimum
    uint128 public constant DEFAULT_SONG_PRICE = 850_000;
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
        uint256 indexed songId, address indexed recipient, uint256 amount, bool isPlatformFee
    );
    event StakingFeeDistributed(uint256 indexed songId, uint256 amount);
    event StakeCredited(uint256 indexed songId, address indexed recipient, uint256 quantity);
    event ShellCreditFailed(
        uint256 indexed songId,
        address indexed recipient,
        uint256 quantity,
        bytes reason
    );
    event PlatformFeeUpdated(uint128 oldFee, uint128 newFee);
    event StakingFeeUpdated(uint128 oldFee, uint128 newFee);
    event DefaultPriceUpdated(uint128 oldPrice, uint128 newPrice);
    event PlatformFeesWithdrawn(address indexed to, uint256 amount);
    event TortoiseShellUpdated(address indexed oldShell, address indexed newShell);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    // ============ Constructor ============

    constructor(
        address _usdcToken,
        uint128 _platformFee,
        uint128 _defaultSongPrice,
        address _tortoiseShell,
        uint128 _stakingFee
    ) ERC1155("") Ownable(msg.sender) {
        require(_usdcToken != address(0), "Invalid USDC address");
        require(_platformFee <= MAX_PLATFORM_FEE, "Platform fee exceeds maximum");
        require(_stakingFee <= MAX_STAKING_FEE, "Staking fee exceeds maximum");
        require(_stakingFee == 0 || _tortoiseShell != address(0), "No shell configured");

        config = ContractConfig({
            defaultSongPrice: _defaultSongPrice == 0 ? DEFAULT_SONG_PRICE : _defaultSongPrice,
            platformFee: _platformFee == 0 ? DEFAULT_PLATFORM_FEE : _platformFee,
            stakingFee: _stakingFee,
            usdcToken: _usdcToken,
            tortoiseShell: _tortoiseShell // Can be address(0) — shell integration is optional
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
        require(songs[songId].exists, "Song does not exist");
        return tokenUris[songId];
    }

    function getArtistSongs(address artist) external view returns (uint256[] memory) {
        return artistSongs[artist];
    }

    function getConfig() external view returns (ContractConfig memory) {
        return config;
    }

    /// @notice Total cost: (price * quantity) + platformFee + stakingFee
    function calculateTotalCost(uint256 songId, uint256 quantity) public view returns (uint256) {
        Song storage song = songs[songId];
        require(song.exists, "Song does not exist");
        return (uint256(song.price) * quantity) + config.platformFee + config.stakingFee;
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
        uint128 actualPrice = price == 0 ? config.defaultSongPrice : price;
        require(actualPrice >= MIN_SONG_PRICE, "Price below minimum");

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
        emit URI(tokenUri, songId);
    }

    function configureSplits(
        uint256 songId,
        SplitRecipient[] calldata splits
    ) external whenNotPaused {
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

    function mintSong(
        uint256 songId,
        uint256 quantity,
        address recipient
    ) external nonReentrant whenNotPaused {
        _validateMint(songId, quantity);
        uint256 totalCost = calculateTotalCost(songId, quantity);
        IERC20(config.usdcToken).safeTransferFrom(msg.sender, address(this), totalCost);
        _processMint(songId, quantity, recipient, totalCost);
    }

    // ============ Admin Functions ============

    function updatePlatformFee(uint128 newFee) external onlyOwner {
        require(newFee <= MAX_PLATFORM_FEE, "Fee exceeds maximum");
        emit PlatformFeeUpdated(config.platformFee, newFee);
        config.platformFee = newFee;
    }

    function updateStakingFee(uint128 newFee) external onlyOwner {
        require(newFee <= MAX_STAKING_FEE, "Fee exceeds maximum");
        require(newFee == 0 || config.tortoiseShell != address(0), "No shell configured");
        emit StakingFeeUpdated(config.stakingFee, newFee);
        config.stakingFee = newFee;
    }

    function updateTortoiseShell(address newShell) external onlyOwner {
        emit TortoiseShellUpdated(config.tortoiseShell, newShell);
        config.tortoiseShell = newShell;
        if (newShell == address(0) && config.stakingFee > 0) {
            emit StakingFeeUpdated(config.stakingFee, 0);
            config.stakingFee = 0;
        }
    }

    function updateDefaultPrice(uint128 newPrice) external onlyOwner {
        require(newPrice >= MIN_SONG_PRICE, "Price below minimum");
        emit DefaultPriceUpdated(config.defaultSongPrice, newPrice);
        config.defaultSongPrice = newPrice;
    }

    function withdrawPlatformFees() external onlyOwner nonReentrant {
        uint256 balance = IERC20(config.usdcToken).balanceOf(address(this));
        require(balance > 0, "No fees to withdraw");
        IERC20(config.usdcToken).safeTransfer(owner(), balance);
        emit PlatformFeesWithdrawn(owner(), balance);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function recoverTokens(address token, uint256 amount) external onlyOwner nonReentrant {
        require(token != config.usdcToken, "Cannot recover USDC");
        IERC20(token).safeTransfer(owner(), amount);
        emit TokensRecovered(token, owner(), amount);
    }

    // ============ Internal Functions ============

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
        address actualRecipient = recipient == address(0) ? msg.sender : recipient;

        require(song.currentSupply + quantity <= type(uint128).max, "Supply overflow");
        song.currentSupply += uint128(quantity);

        _mint(actualRecipient, songId, quantity, "");
        _distributePayments(songId, quantity, totalCost);
        _creditShell(songId, actualRecipient, quantity);

        emit SongMinted(songId, msg.sender, actualRecipient, quantity, totalCost);
    }

    function _distributePayments(
        uint256 songId,
        uint256 quantity,
        uint256 totalCost
    ) internal {
        Song storage song = songs[songId];

        // 1. Platform fee — held in contract, withdrawn by owner
        uint256 platformFeeAmount = config.platformFee;
        if (platformFeeAmount > 0) {
            emit PaymentDistributed(songId, address(this), platformFeeAmount, true);
        }

        // 2. Staking fee -> TortoiseShell
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
        } catch (bytes memory reason) {
            emit ShellCreditFailed(songId, recipient, quantity, reason);
        }
    }
}
