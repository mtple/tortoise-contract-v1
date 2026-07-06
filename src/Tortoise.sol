// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SplitRecipient, SplitLib} from "./libraries/SplitLib.sol";
import {ITortoiseShell} from "./interfaces/ITortoiseShell.sol";
import {IEIP3009} from "./interfaces/IEIP3009.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title Tortoise
/// @notice Custom Tortoise music ERC-1155. A single Tortoise-owned contract that is the
///         token, the minter, and the provenance registry: `createSong` records the song,
///         its revenue splits, and a `sha256(manifest)` commitment atomically; `collect`
///         takes USDC (via EIP-3009 sign-to-collect or approve/transferFrom) and distributes
///         a percentage fee waterfall (platform/staking/artist) with non-blocking shell
///         crediting and pull-payment deferral for blocklisted recipients. Immutable
///         (no proxy). See `planning/architecture-decisions-inprocess-eth-storage.md`.
/// @dev The manifest hash is the one load-bearing verifiability guarantee: a collector can
///      prove they hold the real release by recomputing `sha256` of the master against the
///      `audioSha256` inside the committed manifest — without trusting Tortoise.
contract Tortoise is ERC1155, ERC2981, Ownable2Step, ReentrancyGuardTransient, Pausable, EIP712 {
    using SafeERC20 for IERC20;
    using SplitLib for SplitRecipient[];

    // ============ Constants ============

    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_PLATFORM_FEE_BPS = 2_000; // 20%
    uint16 public constant MAX_STAKING_FEE_BPS = 2_000; // 20%
    uint16 public constant DEFAULT_PLATFORM_FEE_BPS = 500; // 5%
    uint16 public constant DEFAULT_STAKING_FEE_BPS = 1_000; // 10%
    uint96 public constant DEFAULT_ROYALTY_BPS = 500; // 5% EIP-2981

    uint256 public constant MAX_MINT_QUANTITY = 100_000;
    uint256 public constant MAX_COMMENT_BYTES = 500;
    uint256 public constant MAX_MANIFEST_BYTES = 2_048;
    uint256 public constant REROUTE_DELAY = 90 days;
    uint128 public constant MIN_SONG_PRICE = 100_000; // $0.10 (USDC, 6 decimals)
    uint128 public constant DEFAULT_SONG_PRICE = 1_000_000; // $1.00

    /// @dev Domain tag folded into the EIP-3009 nonce so a signed collect authorization is
    ///      bound to this contract + chain and cannot be replayed elsewhere.
    bytes32 private constant _COLLECT_NONCE_PREFIX = keccak256("TortoiseCollectV1");

    bytes32 private constant _CREATE_SONG_TYPEHASH = keccak256(
        "CreateSong(address artist,uint128 price,uint128 maxSupply,uint96 royaltyBps,bool lockSplitsNow,bytes32 tokenUriHash,bytes32 manifestHash,bytes32 splitsHash,uint256 nonce,uint256 deadline)"
    );

    // ============ Types ============

    struct Song {
        address artist;
        bool exists;
        bool splitsLocked;
        uint128 price; // USDC per copy (6 decimals)
        uint128 maxSupply; // 0 == unlimited
        uint128 currentSupply;
    }

    /// @dev createSong args bundled into one calldata struct so the function stays within the
    ///      stack limit under the non-viaIR `ci` profile.
    struct CreateSongParams {
        address artist;
        uint128 price; // 0 uses defaultSongPrice
        uint128 maxSupply; // 0 == unlimited
        uint96 royaltyBps; // EIP-2981; 0 uses DEFAULT_ROYALTY_BPS
        bool lockSplitsNow;
        string tokenUri;
        string manifest; // canonical JSON; its sha256 is the committed manifest hash
        SplitRecipient[] splits;
    }

    /// @dev EIP-3009 authorization fields for `collectWithAuthorization`, bundled for the same
    ///      stack-limit reason.
    struct Eip3009Auth {
        uint256 validAfter;
        uint256 validBefore;
        bytes32 salt; // uniquifier so repeated identical collects get distinct single-use nonces
        bytes signature; // EIP-712 / EIP-1271 signature over receiveWithAuthorization
    }

    // ============ State ============

    IERC20 public immutable usdc;
    ITortoiseShell public shell; // optional; may be address(0)
    uint16 public platformFeeBps;
    uint16 public stakingFeeBps;
    uint128 public defaultSongPrice;

    uint256 public nextSongId;
    mapping(uint256 => Song) public songs;
    mapping(uint256 => bytes32) public releaseManifest; // songId => sha256(canonical manifest) — the commitment
    mapping(uint256 => SplitRecipient[]) internal songSplits;
    mapping(uint256 => string) internal tokenUris;
    mapping(address => uint256[]) public artistSongs;
    mapping(address => uint256) public createSongNonces; // per-artist nonce for signed creation

    // Pull-payment (blocklisted recipients): USDC held for later claim.
    mapping(uint256 => mapping(address => uint256)) public pendingClaims;
    mapping(uint256 => mapping(address => uint256)) public pendingClaimDeferredAt;
    uint256 public platformFeesAccrued;

    string private constant _NAME = "Tortoise";
    string private constant _SYMBOL = "TORTOISE";

    // ============ Events ============

    /// @notice The single canonical creation event. `manifest` is the exact canonical JSON
    ///         preimage whose `sha256` equals `manifestHash` (and equals `releaseManifest[songId]`).
    event SongCreated(
        uint256 indexed songId,
        address indexed artist,
        bytes32 manifestHash,
        uint128 price,
        uint128 maxSupply,
        string tokenUri,
        string manifest
    );
    event SongCollected(
        uint256 indexed songId,
        address indexed payer,
        address indexed recipient,
        uint256 quantity,
        uint256 totalPaid
    );
    event MintComment(
        uint256 indexed songId,
        address indexed recipient,
        address payer,
        uint256 quantity,
        string comment
    );
    event SplitsConfigured(uint256 indexed songId, SplitRecipient[] splits);
    event SplitsLocked(uint256 indexed songId);
    event PaymentDistributed(
        uint256 indexed songId, address indexed recipient, uint256 amount, bool isPlatformFee
    );
    event StakingFeeDistributed(uint256 indexed songId, uint256 amount);
    event StakingFeeAbsorbed(uint256 indexed songId, uint256 amount, bytes reason);
    event StakeCredited(
        uint256 indexed songId, address indexed recipient, uint256 quantity, uint256 creditedAmount
    );
    event ShellCreditFailed(
        uint256 indexed songId, address indexed recipient, uint256 quantity, bytes reason
    );
    event SplitPaymentDeferred(uint256 indexed songId, address indexed recipient, uint256 amount);
    event PendingClaimRerouted(
        uint256 indexed songId,
        address indexed oldRecipient,
        address indexed newRecipient,
        uint256 amount
    );
    event PlatformFeeBpsUpdated(uint16 oldBps, uint16 newBps);
    event StakingFeeBpsUpdated(uint16 oldBps, uint16 newBps);
    event DefaultPriceUpdated(uint128 oldPrice, uint128 newPrice);
    event PlatformFeesWithdrawn(address indexed to, uint256 amount);
    event TortoiseShellUpdated(address indexed oldShell, address indexed newShell);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    // ============ Errors ============

    error ZeroAddress();
    error TitleOrUriEmpty();
    error EmptyManifest();
    error ManifestTooLong();
    error SongDoesNotExist();
    error PriceBelowMinimum();
    error NotArtist();
    error SplitsAreLocked();
    error SplitToSelf();
    error SplitToUSDC();
    error ZeroQuantity();
    error ExceedsMaxMintQuantity();
    error ExceedsMaxSupply();
    error SupplyOverflow();
    error CommentTooLong();
    error IncorrectAuthorizedValue(uint256 expected, uint256 provided);
    error MaxCostExceeded(uint256 cost, uint256 maxCost);
    error FeeTooHigh();
    error ShellRequiredForStakingFee();
    error ShellMustBeContract();
    error NothingToClaim();
    error TransferStillFails();
    error NothingToReroute();
    error RerouteTooSoon();
    error SelfReroute();
    error CannotRecoverUSDC();
    error RenounceDisabled();
    error SignatureExpired();
    error NonceMismatch(uint256 expected, uint256 provided);
    error InvalidCreateSignature();

    // ============ Constructor ============

    /// @dev `_usdc` and the shell's staking/reward tokens MUST be standard ERC20s
    ///      (non-rebasing, non-fee-on-transfer, non-ERC777, no transfer hooks). Accounting
    ///      assumes amount-sent == amount-received. Behavior is undefined otherwise.
    constructor(address _usdc, address _shell)
        ERC1155("")
        Ownable(msg.sender)
        EIP712("Tortoise", "1")
    {
        if (_usdc == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
        shell = ITortoiseShell(_shell); // may be address(0) — shell integration is optional
        platformFeeBps = DEFAULT_PLATFORM_FEE_BPS;
        // Preserve the invariant `stakingFeeBps > 0 => shell != address(0)` at construction:
        // the shell is optional, so only default a nonzero staking fee when one is configured.
        stakingFeeBps = _shell == address(0) ? 0 : DEFAULT_STAKING_FEE_BPS;
        defaultSongPrice = DEFAULT_SONG_PRICE;
        // No default royalty: royaltyInfo for never-created ids returns (address(0), 0); each
        // real song sets its own royalty in createSong via _setTokenRoyalty.
        emit PlatformFeeBpsUpdated(0, DEFAULT_PLATFORM_FEE_BPS);
        emit StakingFeeBpsUpdated(0, stakingFeeBps);
        emit DefaultPriceUpdated(0, DEFAULT_SONG_PRICE);
        if (_shell != address(0)) emit TortoiseShellUpdated(address(0), _shell);
    }

    // ============ Views ============

    function name() external pure returns (string memory) {
        return _NAME;
    }

    function symbol() external pure returns (string memory) {
        return _SYMBOL;
    }

    function getSong(uint256 songId) external view returns (Song memory) {
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

    /// @notice Total USDC cost for `quantity` copies of `songId` (fees are inclusive).
    function quote(uint256 songId, uint256 quantity) public view returns (uint256) {
        Song storage s = songs[songId];
        if (!s.exists) revert SongDoesNotExist();
        return uint256(s.price) * quantity;
    }

    /// @notice The EIP-3009 nonce a collector must sign for `collectWithAuthorization`. Binds
    ///         the full collect intent so a relayer cannot redirect the mint or change amounts.
    ///         `salt` makes repeated identical collects unique (nonces are single-use in USDC).
    function collectNonce(
        uint256 songId,
        uint256 quantity,
        address mintTo,
        uint256 totalCost,
        bytes32 commentHash,
        bytes32 salt
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                _COLLECT_NONCE_PREFIX,
                block.chainid,
                address(this),
                songId,
                quantity,
                mintTo,
                totalCost,
                commentHash,
                salt
            )
        );
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, ERC2981)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ============ Song creation (creation + manifest + splits, atomic) ============

    /// @notice Create a song: record it, commit to its manifest, set optional splits/royalty.
    ///         Owner/operator-gated — the Tortoise operator submits on a verified artist's
    ///         behalf. Gating it is also what prevents permissionless manifest front-running
    ///         (a squatter registering a copied manifest under a lower songId). The manifest
    ///         hash is derived on-chain from the emitted preimage, so the stored commitment and
    ///         the event preimage are provably the same object. Immutability is structural:
    ///         each call mints a fresh `songId`.
    /// @notice Operator-created song — the operator asserts `p.artist`. Use
    ///         `createSongWithArtistSignature` when the artist should cryptographically attest.
    /// @param p Bundled creation params — see CreateSongParams. `p.manifest` is canonical JSON
    ///          whose `sha256` is committed; `p.royaltyBps` 0 uses DEFAULT_ROYALTY_BPS.
    function createSong(CreateSongParams calldata p)
        external
        onlyOwner
        whenNotPaused
        returns (uint256 songId)
    {
        songId = _createSong(p, sha256(bytes(p.manifest)));
    }

    /// @notice Artist-attested gasless creation: the artist signs the full params off-chain
    ///         (EIP-712, EIP-1271-compatible) and the operator submits. The recovered signer
    ///         must equal `p.artist`, so the operator can neither mislabel the artist nor tamper
    ///         with any field, and mempool observers cannot squat the manifest.
    /// @param nonce Per-artist sequential nonce (see `createSongNonces`).
    /// @param deadline Signature expiry (unix seconds).
    function createSongWithArtistSignature(
        CreateSongParams calldata p,
        uint256 nonce,
        uint256 deadline,
        bytes calldata artistSignature
    ) external onlyOwner whenNotPaused returns (uint256 songId) {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (nonce != createSongNonces[p.artist]) {
            revert NonceMismatch(createSongNonces[p.artist], nonce);
        }
        bytes32 manifestHash = sha256(bytes(p.manifest));
        if (
            !SignatureChecker.isValidSignatureNowCalldata(
                p.artist, _createSongDigest(p, manifestHash, nonce, deadline), artistSignature
            )
        ) revert InvalidCreateSignature();
        createSongNonces[p.artist] = nonce + 1;
        songId = _createSong(p, manifestHash);
    }

    function configureSplits(uint256 songId, SplitRecipient[] calldata splits)
        external
        whenNotPaused
        nonReentrant
    {
        Song storage s = songs[songId];
        if (!s.exists) revert SongDoesNotExist();
        if (msg.sender != s.artist) revert NotArtist();
        if (s.splitsLocked) revert SplitsAreLocked();
        _setSplits(songId, splits);
    }

    function lockSplits(uint256 songId) external whenNotPaused {
        Song storage s = songs[songId];
        if (!s.exists) revert SongDoesNotExist();
        if (msg.sender != s.artist) revert NotArtist();
        if (s.splitsLocked) revert SplitsAreLocked();
        s.splitsLocked = true;
        emit SplitsLocked(songId);
    }

    // ============ Collect ============

    /// @notice Collect via approve/transferFrom. `msg.sender` is the payer.
    /// @param mintTo Token recipient; address(0) defaults to the payer.
    /// @param maxTotalCost Front-run guard against an artist/admin price bump.
    /// @param comment Optional ≤500-byte comment; emitted (never stored) when non-empty.
    function collect(
        uint256 songId,
        uint256 quantity,
        address mintTo,
        uint256 maxTotalCost,
        string calldata comment
    ) external nonReentrant whenNotPaused {
        address recipient = mintTo == address(0) ? msg.sender : mintTo;
        uint256 totalCost = _validateAndQuote(songId, quantity, comment);
        if (totalCost > maxTotalCost) revert MaxCostExceeded(totalCost, maxTotalCost);
        usdc.safeTransferFrom(msg.sender, address(this), totalCost);
        _processCollect(songId, quantity, recipient, msg.sender, totalCost, comment);
    }

    /// @notice Sign-to-collect via EIP-3009 — no prior USDC approval needed, and the tx can
    ///         be relayed (collector needs no ETH). The collector signs a `receiveWithAuthorization`
    ///         over `collectNonce(...)`, which binds `songId/quantity/mintTo/totalCost`, so a
    ///         relayer cannot alter the mint or amount without invalidating the signature.
    /// @param from The paying collector (authenticated by the EIP-3009 signature).
    /// @param mintTo Token recipient (must be explicit; it is bound into the signed nonce).
    /// @param totalCost The exact USDC authorized; must equal the live `quote`.
    /// @param auth EIP-3009 authorization (validity window, salt, signature). `auth.salt`
    ///             uniquifies repeated identical collects so their single-use nonces differ.
    function collectWithAuthorization(
        uint256 songId,
        uint256 quantity,
        address from,
        address mintTo,
        uint256 totalCost,
        Eip3009Auth calldata auth,
        string calldata comment
    ) external nonReentrant whenNotPaused {
        if (mintTo == address(0)) revert ZeroAddress();
        uint256 expected = _validateAndQuote(songId, quantity, comment);
        if (totalCost != expected) revert IncorrectAuthorizedValue(expected, totalCost);

        // Bind the comment into the nonce too, so a relayer on the sign-to-collect path cannot
        // substitute or strip the comment that gets attributed on-chain to `from`.
        bytes32 nonce =
            collectNonce(songId, quantity, mintTo, totalCost, keccak256(bytes(comment)), auth.salt);
        // Pulls exactly `totalCost` USDC from `from` into this contract; USDC verifies `from`
        // signed over (from, this, totalCost, validAfter, validBefore, nonce). msg.sender==to
        // holds because this contract is the payee.
        IEIP3009(address(usdc))
            .receiveWithAuthorization(
                from,
                address(this),
                totalCost,
                auth.validAfter,
                auth.validBefore,
                nonce,
                auth.signature
            );
        _processCollect(songId, quantity, mintTo, from, totalCost, comment);
    }

    // ============ Admin ============

    function updatePlatformFeeBps(uint16 newBps) external onlyOwner {
        if (newBps > MAX_PLATFORM_FEE_BPS) revert FeeTooHigh();
        emit PlatformFeeBpsUpdated(platformFeeBps, newBps);
        platformFeeBps = newBps;
    }

    function updateStakingFeeBps(uint16 newBps) external onlyOwner {
        if (newBps > MAX_STAKING_FEE_BPS) revert FeeTooHigh();
        if (newBps > 0 && address(shell) == address(0)) revert ShellRequiredForStakingFee();
        emit StakingFeeBpsUpdated(stakingFeeBps, newBps);
        stakingFeeBps = newBps;
    }

    function updateTortoiseShell(address newShell) external onlyOwner {
        if (newShell != address(0) && newShell.code.length == 0) revert ShellMustBeContract();
        emit TortoiseShellUpdated(address(shell), newShell);
        shell = ITortoiseShell(newShell);
        if (newShell == address(0) && stakingFeeBps > 0) {
            emit StakingFeeBpsUpdated(stakingFeeBps, 0);
            stakingFeeBps = 0;
        }
    }

    function updateDefaultPrice(uint128 newPrice) external onlyOwner {
        if (newPrice < MIN_SONG_PRICE) revert PriceBelowMinimum();
        emit DefaultPriceUpdated(defaultSongPrice, newPrice);
        defaultSongPrice = newPrice;
    }

    function withdrawPlatformFees() external onlyOwner nonReentrant {
        uint256 amount = platformFeesAccrued;
        if (amount == 0) revert NothingToClaim();
        platformFeesAccrued = 0;
        usdc.safeTransfer(owner(), amount);
        emit PlatformFeesWithdrawn(owner(), amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function recoverTokens(address token, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(usdc)) revert CannotRecoverUSDC();
        IERC20(token).safeTransfer(owner(), amount);
        emit TokensRecovered(token, owner(), amount);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ============ Pull-payment (blocklisted recipients) ============

    /// @notice Claim USDC deferred to `recipient` (e.g. a Circle blocklist during distribution).
    ///         Permissionless. If the recipient is still blocked, restores and reverts.
    function claimPending(uint256 songId, address recipient) external nonReentrant {
        uint256 amount = pendingClaims[songId][recipient];
        if (amount == 0) revert NothingToClaim();
        pendingClaims[songId][recipient] = 0;
        if (_usdcTransferSucceeded(recipient, amount)) {
            pendingClaimDeferredAt[songId][recipient] = 0;
            emit PaymentDistributed(songId, recipient, amount, false);
        } else {
            pendingClaims[songId][recipient] = amount; // restore
            revert TransferStillFails();
        }
    }

    /// @notice Admin escape for a permanently blocklisted claim recipient. Requires 90 days
    ///         since the claim was last deferred, so funds still normally claimable can't be seized.
    function rerouteBlockedClaim(uint256 songId, address oldRecipient, address newRecipient)
        external
        onlyOwner
        nonReentrant
    {
        if (newRecipient == address(0)) revert ZeroAddress();
        if (newRecipient == oldRecipient) revert SelfReroute();
        uint256 amount = pendingClaims[songId][oldRecipient];
        if (amount == 0) revert NothingToReroute();
        if (block.timestamp < pendingClaimDeferredAt[songId][oldRecipient] + REROUTE_DELAY) {
            revert RerouteTooSoon();
        }
        pendingClaims[songId][oldRecipient] = 0;
        pendingClaimDeferredAt[songId][oldRecipient] = 0;
        pendingClaims[songId][newRecipient] += amount;
        // Always refresh so merging into an aged destination cannot be instantly re-routed.
        pendingClaimDeferredAt[songId][newRecipient] = block.timestamp;
        emit PendingClaimRerouted(songId, oldRecipient, newRecipient, amount);
    }

    // ============ Internal ============

    function _createSong(CreateSongParams calldata p, bytes32 manifestHash)
        internal
        returns (uint256 songId)
    {
        if (p.artist == address(0)) revert ZeroAddress();
        if (bytes(p.tokenUri).length == 0) revert TitleOrUriEmpty();
        if (bytes(p.manifest).length == 0) revert EmptyManifest();
        if (bytes(p.manifest).length > MAX_MANIFEST_BYTES) revert ManifestTooLong();

        uint128 actualPrice = p.price == 0 ? defaultSongPrice : p.price;
        if (actualPrice < MIN_SONG_PRICE) revert PriceBelowMinimum();

        songId = nextSongId++;
        songs[songId] = Song({
            artist: p.artist,
            exists: true,
            splitsLocked: false,
            price: actualPrice,
            maxSupply: p.maxSupply,
            currentSupply: 0
        });
        tokenUris[songId] = p.tokenUri;
        artistSongs[p.artist].push(songId);
        releaseManifest[songId] = manifestHash;

        _setTokenRoyalty(songId, p.artist, p.royaltyBps == 0 ? DEFAULT_ROYALTY_BPS : p.royaltyBps);

        if (p.splits.length > 0) {
            _setSplits(songId, p.splits);
        }
        // Lock applies even with no splits — lets an artist freeze a "100% to me" config immutably.
        if (p.lockSplitsNow) {
            songs[songId].splitsLocked = true;
            emit SplitsLocked(songId);
        }

        emit SongCreated(
            songId, p.artist, manifestHash, actualPrice, p.maxSupply, p.tokenUri, p.manifest
        );
        emit URI(p.tokenUri, songId);
    }

    function _createSongDigest(
        CreateSongParams calldata p,
        bytes32 manifestHash,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    _CREATE_SONG_TYPEHASH,
                    p.artist,
                    p.price,
                    p.maxSupply,
                    p.royaltyBps,
                    p.lockSplitsNow,
                    keccak256(bytes(p.tokenUri)),
                    manifestHash,
                    keccak256(abi.encode(p.splits)),
                    nonce,
                    deadline
                )
            )
        );
    }

    function _setSplits(uint256 songId, SplitRecipient[] calldata splits) internal {
        splits.validateSplits();
        delete songSplits[songId];
        for (uint256 i; i < splits.length;) {
            if (splits[i].recipient == address(this)) revert SplitToSelf();
            if (splits[i].recipient == address(usdc)) revert SplitToUSDC();
            songSplits[songId].push(splits[i]);
            unchecked {
                ++i;
            }
        }
        emit SplitsConfigured(songId, splits);
    }

    function _validateAndQuote(uint256 songId, uint256 quantity, string calldata comment)
        internal
        view
        returns (uint256 totalCost)
    {
        if (bytes(comment).length > MAX_COMMENT_BYTES) revert CommentTooLong();
        Song storage s = songs[songId];
        if (!s.exists) revert SongDoesNotExist();
        if (quantity == 0) revert ZeroQuantity();
        if (quantity > MAX_MINT_QUANTITY) revert ExceedsMaxMintQuantity();
        if (s.maxSupply != 0 && s.currentSupply + quantity > s.maxSupply) {
            revert ExceedsMaxSupply();
        }
        totalCost = uint256(s.price) * quantity;
    }

    /// @dev Caller has already validated and moved `totalCost` USDC into this contract.
    function _processCollect(
        uint256 songId,
        uint256 quantity,
        address recipient,
        address payer,
        uint256 totalCost,
        string calldata comment
    ) internal {
        Song storage s = songs[songId];
        if (uint256(s.currentSupply) + quantity > type(uint128).max) revert SupplyOverflow();
        s.currentSupply += uint128(quantity);

        // CEI: all USDC movement + state changes happen before _mint, so the ERC1155
        // receiver hook cannot observe or manipulate mid-collect state.
        bool feeForwarded = _distribute(songId, quantity, totalCost);
        if (feeForwarded) {
            _creditShell(songId, recipient, quantity);
        }
        _mint(recipient, songId, quantity, "");

        emit SongCollected(songId, payer, recipient, quantity, totalCost);
        if (bytes(comment).length != 0) {
            emit MintComment(songId, recipient, payer, quantity, comment);
        }
    }

    /// @return stakingFeeForwarded true iff the staking fee reached the shell (gates TORT credit).
    function _distribute(uint256 songId, uint256 quantity, uint256 totalCost)
        internal
        returns (bool stakingFeeForwarded)
    {
        uint256 platformFee = (totalCost * platformFeeBps) / BPS;
        uint256 stakingFee = (totalCost * stakingFeeBps) / BPS;
        uint256 artistRevenue = totalCost - platformFee - stakingFee; // remainder — no dust leaks

        // 1. Platform fee — accrues in-contract, owner-withdrawn.
        if (platformFee > 0) {
            platformFeesAccrued += platformFee;
            emit PaymentDistributed(songId, address(this), platformFee, true);
        }

        // 2. Staking fee -> shell, only when the pool can fully cover quantity × rate.
        ITortoiseShell _shell = shell;
        if (stakingFee > 0 && address(_shell) != address(0)) {
            uint256 rate = _shell.tortRewardPerCollection();
            if (rate > 0 && _shell.getTortPoolBalance() >= quantity * rate) {
                usdc.safeTransfer(address(_shell), stakingFee);
                try _shell.depositRewards(stakingFee) {
                    emit StakingFeeDistributed(songId, stakingFee);
                } catch (bytes memory reason) {
                    // USDC already sent; the shell absorbs it via balance reconciliation.
                    emit StakingFeeAbsorbed(songId, stakingFee, reason);
                }
                stakingFeeForwarded = true;
            } else {
                // Pool short or rate unset — orphaned fee accrues as platform revenue.
                platformFeesAccrued += stakingFee;
            }
        } else if (stakingFee > 0) {
            // No shell configured — treat as platform revenue rather than stranding it.
            platformFeesAccrued += stakingFee;
        }

        // 3. Artist revenue -> splits (or artist), pull-payment on transfer failure.
        SplitRecipient[] storage splits = songSplits[songId];
        uint256 len = splits.length;
        if (len == 0) {
            _transferOrDefer(songId, songs[songId].artist, artistRevenue);
        } else {
            uint256 distributed;
            for (uint256 i; i < len;) {
                SplitRecipient storage r = splits[i];
                uint256 amount = (i == len - 1)
                    ? artistRevenue - distributed  // remainder to last recipient
                    : SplitLib.calculateSplitAmount(artistRevenue, r.percentage);
                if (amount > 0) {
                    _transferOrDefer(songId, r.recipient, amount);
                }
                distributed += amount;
                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @dev USDC transfer; on failure (revert or `false`) defer to pendingClaims so one bad
    ///      address cannot brick the whole collect.
    function _transferOrDefer(uint256 songId, address recipient, uint256 amount) internal {
        if (_usdcTransferSucceeded(recipient, amount)) {
            emit PaymentDistributed(songId, recipient, amount, false);
        } else {
            pendingClaims[songId][recipient] += amount;
            pendingClaimDeferredAt[songId][recipient] = block.timestamp;
            emit SplitPaymentDeferred(songId, recipient, amount);
        }
    }

    /// @dev Low-level USDC transfer shared by `_transferOrDefer` and `claimPending` so the
    ///      zero-code guard cannot drift between them. A call to a zero-code address returns
    ///      ok=true, ret.length==0 — indistinguishable from a no-return-value token success —
    ///      so guard code length first (hard revert), then decode a bool return safely.
    function _usdcTransferSucceeded(address recipient, uint256 amount) internal returns (bool) {
        if (address(usdc).code.length == 0) revert ZeroAddress();
        (bool ok, bytes memory ret) =
            address(usdc).call(abi.encodeCall(IERC20.transfer, (recipient, amount)));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }

    /// @dev Credit TORT to the collector's shell. try/catch so shell issues never block collects.
    function _creditShell(uint256 songId, address recipient, uint256 quantity) internal {
        ITortoiseShell _shell = shell;
        if (address(_shell) == address(0)) return;
        try _shell.creditStake(recipient, quantity) returns (uint256 credited) {
            emit StakeCredited(songId, recipient, quantity, credited);
        } catch (bytes memory reason) {
            emit ShellCreditFailed(songId, recipient, quantity, reason);
        }
    }
}
