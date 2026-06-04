// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {SplitRecipient, SplitLib} from "./libraries/SplitLib.sol";
import {ITortoiseShell} from "./interfaces/ITortoiseShell.sol";
import {ITortoiseInProcess1155} from "./interfaces/ITortoiseInProcess1155.sol";
import {IMinter1155, ICreatorCommands} from "./interfaces/IMinter1155.sol";

/// @title TortoiseInProcessMinter
/// @notice Tortoise-owned minter for In Process / Zora-compatible ERC-1155 music tokens.
///         Collectors pay native ETH to `collect()`; the minter mints via `adminMint`,
///         credits TortoiseShell, and splits revenue 5/10/85 (platform/staking/artist) with
///         multi-recipient artist splits, non-blocking shell crediting, and deferred ETH
///         pending-claims. Immutable (no proxy). See
///         `planning/eth-minter-implementation-plan.md`.
/// @dev Implements `IMinter1155` for discovery/recognition only — `requestMint` reverts.
///      The single paid entrypoint is `collect()`. `batchCollect` lands in Phase 2.
contract TortoiseInProcessMinter is
    IMinter1155,
    Ownable2Step,
    ReentrancyGuardTransient,
    Pausable,
    EIP712
{
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_PLATFORM_FEE_BPS = 2_000; // 20%
    uint16 public constant MAX_STAKING_FEE_BPS = 2_000; // 20%
    uint256 public constant MAX_COMMENT_BYTES = 500;
    uint256 internal constant ETH_SEND_GAS_STIPEND = 30_000;

    bytes32 private constant _SET_SALE_TYPEHASH =
        keccak256("SetSale(address collection,uint256 tokenId,bytes32 saleHash,uint256 nonce,uint256 deadline)");
    bytes32 private constant _REGISTER_SONG_WITH_SPLITS_TYPEHASH = keccak256(
        "RegisterSongWithSplits(address collection,uint256 tokenId,address artist,bytes32 splitsHash,bool lockSplits,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant _CLAIM_PENDING_TO_TYPEHASH = keccak256(
        "ClaimPendingTo(address collection,uint256 tokenId,address recipient,address payoutTo,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    // ============ Types ============

    struct SaleConfig {
        uint64 saleStart;
        uint64 saleEnd;
        uint64 maxTokensPerAddress; // 0 == unlimited
        uint256 pricePerToken;
        bool exists;
    }

    struct SaleUpdate {
        uint64 saleStart;
        uint64 saleEnd;
        uint64 maxTokensPerAddress;
        uint256 pricePerToken;
    }

    // ============ State ============

    ITortoiseShell public shell;
    address public platformFeeRecipient;
    uint16 public platformFeeBps;
    uint16 public stakingFeeBps;

    mapping(bytes32 => SaleConfig) internal sales;
    mapping(bytes32 => address) public songArtist;
    mapping(bytes32 => SplitRecipient[]) internal songSplits;
    mapping(bytes32 => bool) public splitsLocked;

    mapping(bytes32 => mapping(address => uint64)) public mintedByAddress;
    mapping(bytes32 => mapping(address => bool)) public tortRewardClaimed;

    mapping(bytes32 => mapping(address => uint256)) public pendingClaims;
    uint256 public totalPendingClaims;

    mapping(bytes32 => uint256) public saleUpdateNonces;
    mapping(address => uint256) public splitAuthorizationNonces;
    mapping(bytes32 => mapping(address => uint256)) public claimPayoutNonces;

    // ============ Events ============

    event SaleSet(
        address indexed collection,
        uint256 indexed tokenId,
        uint256 pricePerToken,
        uint64 saleStart,
        uint64 saleEnd,
        uint64 maxTokensPerAddress
    );
    event SongRegistered(address indexed collection, uint256 indexed tokenId, address indexed artist);
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
        address indexed collection, uint256 indexed tokenId, address indexed collector, uint256 rewardUnits
    );
    event ShellCreditFailed(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed collector,
        uint256 rewardUnits,
        uint256 expectedCredit,
        uint256 actualCredit
    );
    event ShellDepositFailed(address indexed collection, uint256 indexed tokenId, uint256 amount);
    event SplitsConfigured(address indexed collection, uint256 indexed tokenId);
    event SplitsLocked(address indexed collection, uint256 indexed tokenId);
    event SplitPaymentDeferred(
        address indexed collection, uint256 indexed tokenId, address indexed recipient, uint256 amount
    );
    event PaymentDistributed(
        address indexed collection, uint256 indexed tokenId, address indexed recipient, uint256 amount
    );
    event PlatformFeeBpsUpdated(uint16 oldBps, uint16 newBps);
    event StakingFeeBpsUpdated(uint16 oldBps, uint16 newBps);
    event TortoiseShellUpdated(address indexed oldShell, address indexed newShell);
    event PlatformFeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    // ============ Errors ============

    error ZeroAddress();
    error SongNotRegistered();
    error SaleNotConfigured();
    error SaleNotStarted();
    error SaleEnded();
    error InvalidSaleWindow();
    error ZeroQuantity();
    error IncorrectEthValue(uint256 expected, uint256 actual);
    error MaxCostExceeded(uint256 cost, uint256 maxCost);
    error MaxTokensPerAddressExceeded();
    error CommentTooLong();
    error NotArtist();
    error SplitsAreLocked();
    error SplitToSelf();
    error FeeTooHigh();
    error ShellRequiredForStakingFee();
    error NothingToClaim();
    error InsufficientPendingClaim();
    error ETHTransferFailed();
    error SignatureExpired();
    error InvalidSaleSignature();
    error InvalidSplitSignature();
    error InvalidClaimSignature();
    error NonceMismatch(uint256 expected, uint256 provided);
    error UseCollectInstead();

    // ============ Constructor ============

    constructor(
        address _shell,
        address _platformFeeRecipient,
        uint16 _platformFeeBps,
        uint16 _stakingFeeBps
    ) Ownable(msg.sender) EIP712("TortoiseInProcessMinter", "1") {
        if (_platformFeeRecipient == address(0)) revert ZeroAddress();
        if (_platformFeeBps > MAX_PLATFORM_FEE_BPS) revert FeeTooHigh();
        if (_stakingFeeBps > MAX_STAKING_FEE_BPS) revert FeeTooHigh();
        if (uint256(_platformFeeBps) + _stakingFeeBps >= BPS) revert FeeTooHigh();
        if (_stakingFeeBps > 0 && _shell == address(0)) revert ShellRequiredForStakingFee();

        shell = ITortoiseShell(_shell);
        platformFeeRecipient = _platformFeeRecipient;
        platformFeeBps = _platformFeeBps;
        stakingFeeBps = _stakingFeeBps;

        emit PlatformFeeRecipientUpdated(address(0), _platformFeeRecipient);
        emit PlatformFeeBpsUpdated(0, _platformFeeBps);
        emit StakingFeeBpsUpdated(0, _stakingFeeBps);
        if (_shell != address(0)) emit TortoiseShellUpdated(address(0), _shell);
    }

    // ============ Collect ============

    /// @notice Pay native ETH to mint `quantity` of `(collection, tokenId)` to `mintTo`.
    /// @param maxTotalCost Front-run guard; reverts if the live cost exceeds it.
    /// @param mintTo Token recipient (attribution is on the recipient, not the relayer).
    /// @param comment Optional ≤500-byte comment; emitted (never stored) when non-empty.
    function collect(
        address collection,
        uint256 tokenId,
        uint256 quantity,
        uint256 maxTotalCost,
        address mintTo,
        string calldata comment
    ) external payable nonReentrant whenNotPaused {
        if (mintTo == address(0)) revert ZeroAddress();
        if (quantity == 0) revert ZeroQuantity();
        if (bytes(comment).length > MAX_COMMENT_BYTES) revert CommentTooLong();

        bytes32 key = _songKey(collection, tokenId);
        if (songArtist[key] == address(0)) revert SongNotRegistered();

        SaleConfig memory s = sales[key];
        if (!s.exists) revert SaleNotConfigured();
        if (block.timestamp < s.saleStart) revert SaleNotStarted();
        if (block.timestamp > s.saleEnd) revert SaleEnded();

        uint256 totalCost = s.pricePerToken * quantity;
        if (msg.value != totalCost) revert IncorrectEthValue(totalCost, msg.value);
        if (totalCost > maxTotalCost) revert MaxCostExceeded(totalCost, maxTotalCost);

        // Per-wallet cap: increment-then-check on the recipient (write before adminMint).
        if (s.maxTokensPerAddress != 0) {
            uint256 newTotal = uint256(mintedByAddress[key][mintTo]) + quantity;
            if (newTotal > s.maxTokensPerAddress) revert MaxTokensPerAddressExceeded();
            mintedByAddress[key][mintTo] = uint64(newTotal);
        }

        ITortoiseInProcess1155(collection).adminMint(mintTo, tokenId, quantity, "");

        _distribute(collection, tokenId, key, mintTo, totalCost);

        emit SongCollected(collection, tokenId, mintTo, msg.sender, quantity, totalCost);
        if (bytes(comment).length != 0) {
            emit MintComment(collection, tokenId, mintTo, msg.sender, quantity, comment);
        }
    }

    // ============ Sale Config ============

    /// @notice Owner-set sale config (emergency / initial / operator-as-owner). Bumps the
    ///         per-song nonce, invalidating any in-flight artist signature.
    function setSale(address collection, uint256 tokenId, SaleUpdate calldata cfg) external onlyOwner {
        bytes32 key = _songKey(collection, tokenId);
        _applySale(collection, tokenId, key, cfg);
        saleUpdateNonces[key] += 1;
    }

    /// @notice Artist-signed, operator-relayed sale update (EIP-712 / EIP-1271).
    function setSaleWithArtistSignature(
        address collection,
        uint256 tokenId,
        SaleUpdate calldata cfg,
        uint256 nonce,
        uint256 deadline,
        bytes calldata artistSignature
    ) external {
        bytes32 key = _songKey(collection, tokenId);
        address artist = songArtist[key];
        if (artist == address(0)) revert SongNotRegistered();
        if (block.timestamp > deadline) revert SignatureExpired();
        if (nonce != saleUpdateNonces[key]) revert NonceMismatch(saleUpdateNonces[key], nonce);

        bytes32 saleHash =
            keccak256(abi.encode(cfg.saleStart, cfg.saleEnd, cfg.maxTokensPerAddress, cfg.pricePerToken));
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(_SET_SALE_TYPEHASH, collection, tokenId, saleHash, nonce, deadline))
        );
        if (!SignatureChecker.isValidSignatureNowCalldata(artist, digest, artistSignature)) {
            revert InvalidSaleSignature();
        }
        saleUpdateNonces[key] = nonce + 1;
        _applySale(collection, tokenId, key, cfg);
    }

    function _applySale(address collection, uint256 tokenId, bytes32 key, SaleUpdate calldata cfg)
        internal
    {
        if (cfg.saleEnd < cfg.saleStart) revert InvalidSaleWindow();
        sales[key] = SaleConfig({
            saleStart: cfg.saleStart,
            saleEnd: cfg.saleEnd,
            maxTokensPerAddress: cfg.maxTokensPerAddress,
            pricePerToken: cfg.pricePerToken,
            exists: true
        });
        emit SaleSet(
            collection, tokenId, cfg.pricePerToken, cfg.saleStart, cfg.saleEnd, cfg.maxTokensPerAddress
        );
    }

    // ============ Registration & Splits ============

    function registerSong(address collection, uint256 tokenId, address artist) external onlyOwner {
        _register(collection, tokenId, artist);
    }

    /// @notice Register a song and set artist-approved splits in one call. The artist signs
    ///         the splits (and optional lock) off-chain; the operator/owner submits.
    function registerSongWithSplits(
        address collection,
        uint256 tokenId,
        address artist,
        SplitRecipient[] calldata splits,
        bool lockSongSplits,
        uint256 nonce,
        uint256 deadline,
        bytes calldata artistSignature
    ) external onlyOwner {
        if (artist == address(0)) revert ZeroAddress();
        if (block.timestamp > deadline) revert SignatureExpired();
        if (nonce != splitAuthorizationNonces[artist]) {
            revert NonceMismatch(splitAuthorizationNonces[artist], nonce);
        }
        bytes32 splitsHash = keccak256(abi.encode(splits));
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    _REGISTER_SONG_WITH_SPLITS_TYPEHASH,
                    collection,
                    tokenId,
                    artist,
                    splitsHash,
                    lockSongSplits,
                    nonce,
                    deadline
                )
            )
        );
        if (!SignatureChecker.isValidSignatureNowCalldata(artist, digest, artistSignature)) {
            revert InvalidSplitSignature();
        }
        splitAuthorizationNonces[artist] = nonce + 1;

        bytes32 key = _register(collection, tokenId, artist);
        _setSplits(collection, tokenId, key, splits);
        if (lockSongSplits) {
            splitsLocked[key] = true;
            emit SplitsLocked(collection, tokenId);
        }
    }

    /// @notice Artist (or owner) reconfigures splits while unlocked.
    function configureSplits(address collection, uint256 tokenId, SplitRecipient[] calldata splits)
        external
        whenNotPaused
    {
        bytes32 key = _songKey(collection, tokenId);
        _requireArtistOrOwner(key);
        if (splitsLocked[key]) revert SplitsAreLocked();
        _setSplits(collection, tokenId, key, splits);
    }

    function lockSplits(address collection, uint256 tokenId) external {
        bytes32 key = _songKey(collection, tokenId);
        _requireArtistOrOwner(key);
        if (splitsLocked[key]) revert SplitsAreLocked();
        splitsLocked[key] = true;
        emit SplitsLocked(collection, tokenId);
    }

    function _register(address collection, uint256 tokenId, address artist)
        internal
        returns (bytes32 key)
    {
        if (artist == address(0)) revert ZeroAddress();
        key = _songKey(collection, tokenId);
        songArtist[key] = artist;
        emit SongRegistered(collection, tokenId, artist);
    }

    function _setSplits(address collection, uint256 tokenId, bytes32 key, SplitRecipient[] calldata splits)
        internal
    {
        SplitLib.validateSplits(splits);
        delete songSplits[key];
        for (uint256 i; i < splits.length;) {
            if (splits[i].recipient == address(this)) revert SplitToSelf();
            songSplits[key].push(splits[i]);
            unchecked {
                ++i;
            }
        }
        emit SplitsConfigured(collection, tokenId);
    }

    function _requireArtistOrOwner(bytes32 key) internal view {
        address artist = songArtist[key];
        if (artist == address(0)) revert SongNotRegistered();
        if (msg.sender != artist && msg.sender != owner()) revert NotArtist();
    }

    // ============ Distribution ============

    function _distribute(
        address collection,
        uint256 tokenId,
        bytes32 key,
        address mintTo,
        uint256 totalCost
    ) internal {
        uint256 platformFee = (totalCost * platformFeeBps) / BPS;
        uint256 stakingFee = (totalCost * stakingFeeBps) / BPS;

        // Shell credit + staking-fee routing (D.8). Returns the staking fee actually sent
        // to the shell; anything not sent folds into artist revenue below.
        uint256 stakingFeeToShell = _creditAndDeposit(collection, tokenId, key, mintTo, stakingFee);
        uint256 artistRevenue = totalCost - platformFee - stakingFeeToShell;

        emit RevenueDistributed(collection, tokenId, platformFee, stakingFeeToShell, artistRevenue);

        _sendOrDefer(collection, tokenId, key, platformFeeRecipient, platformFee);

        SplitRecipient[] storage splits = songSplits[key];
        uint256 len = splits.length;
        if (len == 0) {
            _sendOrDefer(collection, tokenId, key, songArtist[key], artistRevenue);
        } else {
            uint256 distributed;
            for (uint256 i; i < len;) {
                SplitRecipient storage r = splits[i];
                uint256 amount = (i == len - 1)
                    ? artistRevenue - distributed
                    : SplitLib.calculateSplitAmount(artistRevenue, r.percentage);
                _sendOrDefer(collection, tokenId, key, r.recipient, amount);
                distributed += amount;
                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @dev Credit the shell once per wallet/song (1 reward unit) and, on full credit,
    ///      forward the staking fee. Never reverts the collect. See D.8 divergence matrix.
    function _creditAndDeposit(
        address collection,
        uint256 tokenId,
        bytes32 key,
        address mintTo,
        uint256 stakingFee
    ) internal returns (uint256 sentToShell) {
        ITortoiseShell sh = shell;
        if (stakingFee == 0 || address(sh) == address(0)) return 0;
        if (tortRewardClaimed[key][mintTo]) return 0; // already claimed: fee folds to artist

        uint256 expected = sh.tortRewardPerCollection();
        try sh.creditStake(mintTo, 1) returns (uint256 actualCredit) {
            if (actualCredit > 0 && actualCredit >= expected) {
                tortRewardClaimed[key][mintTo] = true;
                emit StakeCredited(collection, tokenId, mintTo, 1);
                try sh.depositRewards{value: stakingFee}() {
                    return stakingFee;
                } catch {
                    emit ShellDepositFailed(collection, tokenId, stakingFee);
                    return 0;
                }
            }
            emit ShellCreditFailed(collection, tokenId, mintTo, 1, expected, actualCredit);
            return 0;
        } catch {
            emit ShellCreditFailed(collection, tokenId, mintTo, 1, expected, 0);
            return 0;
        }
    }

    function _sendOrDefer(
        address collection,
        uint256 tokenId,
        bytes32 key,
        address recipient,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        (bool ok,) = recipient.call{value: amount, gas: ETH_SEND_GAS_STIPEND}("");
        if (ok) {
            emit PaymentDistributed(collection, tokenId, recipient, amount);
        } else {
            pendingClaims[key][recipient] += amount;
            totalPendingClaims += amount;
            emit SplitPaymentDeferred(collection, tokenId, recipient, amount);
        }
    }

    // ============ Pending Claims ============

    /// @notice Claim the full deferred balance for `recipient`. Anyone may trigger it; funds
    ///         go to `recipient`. Reverts (rolling back) if the send fails so it stays claimable.
    function claimPending(address collection, uint256 tokenId, address recipient)
        external
        nonReentrant
    {
        bytes32 key = _songKey(collection, tokenId);
        uint256 amount = pendingClaims[key][recipient];
        if (amount == 0) revert NothingToClaim();

        pendingClaims[key][recipient] = 0;
        totalPendingClaims -= amount;
        claimPayoutNonces[key][recipient] += 1;

        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert ETHTransferFailed();
        emit PaymentDistributed(collection, tokenId, recipient, amount);
    }

    /// @notice Claim `amount` of `recipient`'s deferred balance to `payoutTo`. The recipient
    ///         may call directly (`msg.sender == recipient`) or authorize a relayer via
    ///         EIP-712/EIP-1271. The amount is signed and the nonce advances on every payout.
    function claimPendingTo(
        address collection,
        uint256 tokenId,
        address recipient,
        address payoutTo,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        if (payoutTo == address(0)) revert ZeroAddress();
        bytes32 key = _songKey(collection, tokenId);

        if (msg.sender != recipient) {
            if (block.timestamp > deadline) revert SignatureExpired();
            if (nonce != claimPayoutNonces[key][recipient]) {
                revert NonceMismatch(claimPayoutNonces[key][recipient], nonce);
            }
            bytes32 digest = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        _CLAIM_PENDING_TO_TYPEHASH,
                        collection,
                        tokenId,
                        recipient,
                        payoutTo,
                        amount,
                        nonce,
                        deadline
                    )
                )
            );
            if (!SignatureChecker.isValidSignatureNowCalldata(recipient, digest, signature)) {
                revert InvalidClaimSignature();
            }
        }

        if (amount == 0) revert NothingToClaim();
        if (amount > pendingClaims[key][recipient]) revert InsufficientPendingClaim();

        pendingClaims[key][recipient] -= amount;
        totalPendingClaims -= amount;
        claimPayoutNonces[key][recipient] += 1;

        (bool ok,) = payoutTo.call{value: amount}("");
        if (!ok) revert ETHTransferFailed();
        emit PaymentDistributed(collection, tokenId, payoutTo, amount);
    }

    // ============ Admin ============

    function updatePlatformFeeBps(uint16 newBps) external onlyOwner {
        if (newBps > MAX_PLATFORM_FEE_BPS) revert FeeTooHigh();
        if (uint256(newBps) + stakingFeeBps >= BPS) revert FeeTooHigh();
        emit PlatformFeeBpsUpdated(platformFeeBps, newBps);
        platformFeeBps = newBps;
    }

    function updateStakingFeeBps(uint16 newBps) external onlyOwner {
        if (newBps > MAX_STAKING_FEE_BPS) revert FeeTooHigh();
        if (uint256(platformFeeBps) + newBps >= BPS) revert FeeTooHigh();
        if (newBps > 0 && address(shell) == address(0)) revert ShellRequiredForStakingFee();
        emit StakingFeeBpsUpdated(stakingFeeBps, newBps);
        stakingFeeBps = newBps;
    }

    /// @notice Update the shell. Setting it to address(0) auto-zeros the staking fee.
    function updateTortoiseShell(address newShell) external onlyOwner {
        emit TortoiseShellUpdated(address(shell), newShell);
        shell = ITortoiseShell(newShell);
        if (newShell == address(0) && stakingFeeBps > 0) {
            emit StakingFeeBpsUpdated(stakingFeeBps, 0);
            stakingFeeBps = 0;
        }
    }

    function updatePlatformFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit PlatformFeeRecipientUpdated(platformFeeRecipient, newRecipient);
        platformFeeRecipient = newRecipient;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Recover stray ERC20s to the owner. There is no ETH recovery path — ETH held
    ///         here backs `totalPendingClaims` (D.7).
    function recoverTokens(address token, uint256 amount) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(owner(), amount);
        emit TokensRecovered(token, owner(), amount);
    }

    function renounceOwnership() public view override onlyOwner {
        revert();
    }

    // ============ Discovery / recognition shim (H.2) ============

    /// @dev The standard 1155 mint path is intentionally unusable — use `collect()`.
    function requestMint(address, uint256, uint256, uint256, bytes calldata)
        external
        pure
        returns (ICreatorCommands.CommandSet memory)
    {
        revert UseCollectInstead();
    }

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IMinter1155).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ============ Views ============

    function sale(address collection, uint256 tokenId) external view returns (SaleConfig memory) {
        return sales[_songKey(collection, tokenId)];
    }

    function getSongSplits(address collection, uint256 tokenId)
        external
        view
        returns (SplitRecipient[] memory)
    {
        return songSplits[_songKey(collection, tokenId)];
    }

    function songKey(address collection, uint256 tokenId) external pure returns (bytes32) {
        return _songKey(collection, tokenId);
    }

    function _songKey(address collection, uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(abi.encode(collection, tokenId));
    }
}
