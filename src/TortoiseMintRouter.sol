// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IInProcessERC20Minter, InProcessSale} from "./interfaces/IInProcessERC20Minter.sol";
import {ITortoiseShell} from "./interfaces/ITortoiseShell.sol";
import {SplitRecipient, SplitLib} from "./libraries/SplitLib.sol";

contract TortoiseMintRouter is Ownable2Step, ReentrancyGuardTransient, Pausable, EIP712 {
    using SafeERC20 for IERC20;
    using SplitLib for SplitRecipient[];

    // ============ Constants ============

    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant MAX_FEE_BPS = 2000;
    uint256 public constant MAX_BATCH_ITEMS = 30;
    bytes32 public constant REGISTER_SONG_WITH_SPLITS_TYPEHASH = keccak256(
        "RegisterSongWithSplits(address collection,uint256 tokenId,address artist,bytes32 splitsHash,bool lockSplits,uint256 nonce,uint256 deadline)"
    );

    // ============ Structs ============

    struct CollectItem {
        address collection;
        uint256 tokenId;
        uint256 quantity;
        uint256 maxTotalCost;
    }

    struct CollectQuote {
        bytes32 key;
        InProcessSale sale;
        uint256 totalCost;
    }

    // ============ Tokens And Integrations ============

    IERC20 public immutable usdc;
    address public inProcessMinter;
    address public tortoiseShell;
    address public platformFeeRecipient;

    // ============ Fees ============

    uint256 public platformFeeBps;
    uint256 public stakingFeeBps;

    // ============ Songs And Splits ============

    mapping(bytes32 => address) public songArtist;
    mapping(bytes32 => bool) public splitsLocked;
    mapping(bytes32 => mapping(address => bool)) public tortRewardClaimed;
    mapping(bytes32 => SplitRecipient[]) internal songSplits;
    mapping(bytes32 => mapping(address => uint256)) public pendingClaims;
    mapping(bytes32 => mapping(address => uint256)) public pendingClaimDeferredAt;
    mapping(address => uint256) public splitAuthorizationNonces;

    // ============ Events ============

    event SongCollected(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed collector,
        uint256 quantity,
        uint256 totalPaid
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
        uint256 quantity
    );
    event ShellCreditFailed(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed collector,
        uint256 quantity
    );
    event SongRegistered(
        address indexed collection, uint256 indexed tokenId, address indexed artist
    );
    event SplitsConfigured(address indexed collection, uint256 indexed tokenId);
    event SplitsLocked(address indexed collection, uint256 indexed tokenId);
    event InProcessMinterUpdated(address indexed oldMinter, address indexed newMinter);
    event PlatformFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event StakingFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event TortoiseShellUpdated(address indexed oldShell, address indexed newShell);
    event PlatformFeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
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
    event BatchCollected(address indexed collector, uint256 itemCount, uint256 totalPaid);

    // ============ Errors ============

    error ZeroAddress();
    error CollectionMustBeContract();
    error MinterMustBeContract();
    error ShellMustBeContract();
    error SongAlreadyRegistered();
    error SongNotRegistered();
    error OnlyArtist();
    error SplitsAreLocked();
    error SplitToSelf();
    error SplitToUSDC();
    error SignatureExpired();
    error InvalidArtistSignature();
    error ZeroQuantity();
    error ZeroCost();
    error InvalidCurrency();
    error InvalidFundsRecipient();
    error PriceExceedsMax();
    error EmptyBatch();
    error BatchTooLarge();
    error AggregatePriceExceedsMax();
    error UnexpectedProceeds(uint256 expectedBalance, uint256 actualBalance);
    error FeeRoundsToZero(uint256 totalCost, uint256 feeBps);
    error FeeExceedsMaximum();
    error FeeTotalInvalid();
    error ShellRequired();
    error CannotRecoverUSDC();
    error NothingToClaim();
    error TransferFailedStillClaimable();
    error UnexpectedShellCredit(uint256 expected, uint256 actual);
    error RenouncingOwnershipDisabled();

    // ============ Constructor ============

    /// @dev USDC is assumed to be standard Base USDC: non-rebasing, non-fee-on-transfer,
    /// non-reentrant, and without transfer hooks. Accounting intentionally fails loudly
    /// for transfer-fee behavior through the full-proceeds balance check.
    constructor(
        address _usdc,
        address _inProcessMinter,
        address _tortoiseShell,
        address _platformFeeRecipient,
        uint256 _platformFeeBps,
        uint256 _stakingFeeBps
    ) Ownable(msg.sender) EIP712("TortoiseMintRouter", "1") {
        if (_usdc == address(0)) {
            revert ZeroAddress();
        }
        if (_platformFeeRecipient == address(0)) {
            revert ZeroAddress();
        }

        usdc = IERC20(_usdc);
        platformFeeRecipient = _platformFeeRecipient;

        _setInProcessMinter(_inProcessMinter);
        _setTortoiseShell(_tortoiseShell);
        _validateFees(_platformFeeBps, _stakingFeeBps, _tortoiseShell);

        platformFeeBps = _platformFeeBps;
        stakingFeeBps = _stakingFeeBps;

        emit PlatformFeeRecipientUpdated(address(0), _platformFeeRecipient);
        emit PlatformFeeBpsUpdated(0, _platformFeeBps);
        emit StakingFeeBpsUpdated(0, _stakingFeeBps);
    }

    // ============ User-Facing Functions ============

    function collect(
        address collection,
        uint256 tokenId,
        uint256 quantity,
        uint256 maxTotalCost
    ) external nonReentrant whenNotPaused {
        CollectItem memory item = CollectItem({
            collection: collection, tokenId: tokenId, quantity: quantity, maxTotalCost: maxTotalCost
        });
        CollectQuote memory quote = _validateCollectItem(item);

        uint256 balanceBefore = usdc.balanceOf(address(this));

        usdc.safeTransferFrom(msg.sender, address(this), quote.totalCost);

        _mintAndDistribute(item, quote, msg.sender, balanceBefore + quote.totalCost);
    }

    function batchCollect(
        CollectItem[] calldata items,
        uint256 maxAggregateCost
    ) external nonReentrant whenNotPaused {
        uint256 itemCount = items.length;
        if (itemCount == 0) {
            revert EmptyBatch();
        }
        if (itemCount > MAX_BATCH_ITEMS) {
            revert BatchTooLarge();
        }

        CollectQuote[] memory quotes = new CollectQuote[](itemCount);
        uint256 aggregateCost;
        for (uint256 i; i < itemCount;) {
            CollectItem memory item = items[i];
            CollectQuote memory quote = _validateCollectItem(item);
            quotes[i] = quote;
            aggregateCost += quote.totalCost;
            unchecked {
                ++i;
            }
        }

        if (aggregateCost > maxAggregateCost) {
            revert AggregatePriceExceedsMax();
        }

        uint256 balanceBefore = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), aggregateCost);

        uint256 expectedBalance = balanceBefore + aggregateCost;
        for (uint256 i; i < itemCount;) {
            expectedBalance = _mintAndDistribute(items[i], quotes[i], msg.sender, expectedBalance);
            unchecked {
                ++i;
            }
        }

        emit BatchCollected(msg.sender, itemCount, aggregateCost);
    }

    function claimPending(
        address collection,
        uint256 tokenId,
        address recipient
    ) external nonReentrant {
        bytes32 key = songKey(collection, tokenId);
        uint256 amount = pendingClaims[key][recipient];
        if (amount == 0) {
            revert NothingToClaim();
        }

        pendingClaims[key][recipient] = 0;
        bool transferred = _tryTransferUSDC(recipient, amount);
        if (!transferred) {
            pendingClaims[key][recipient] = amount;
            revert TransferFailedStillClaimable();
        }

        pendingClaimDeferredAt[key][recipient] = 0;
        emit PaymentDistributed(collection, tokenId, recipient, amount);
    }

    // ============ Song Management ============

    function registerSong(
        address collection,
        uint256 tokenId,
        address artist
    ) external onlyOwner {
        _registerSong(collection, tokenId, artist);
    }

    function registerSongWithSplits(
        address collection,
        uint256 tokenId,
        address artist,
        SplitRecipient[] calldata splits,
        bool lockSongSplits,
        uint256 deadline,
        bytes calldata artistSignature
    ) external onlyOwner {
        _validateSongRegistration(collection, tokenId, artist);

        if (block.timestamp > deadline) {
            revert SignatureExpired();
        }

        uint256 nonce = splitAuthorizationNonces[artist]++;
        bytes32 digest = _hashRegisterSongWithSplits(
            collection, tokenId, artist, _hashSplits(splits), lockSongSplits, nonce, deadline
        );
        if (!SignatureChecker.isValidSignatureNowCalldata(artist, digest, artistSignature)) {
            revert InvalidArtistSignature();
        }

        bytes32 key = _registerSong(collection, tokenId, artist);
        _setSplits(collection, tokenId, key, splits);

        if (lockSongSplits) {
            splitsLocked[key] = true;
            emit SplitsLocked(collection, tokenId);
        }
    }

    function configureSplits(
        address collection,
        uint256 tokenId,
        SplitRecipient[] calldata splits
    ) external whenNotPaused nonReentrant {
        bytes32 key = songKey(collection, tokenId);
        address artist = songArtist[key];
        if (artist == address(0)) {
            revert SongNotRegistered();
        }
        if (msg.sender != artist) {
            revert OnlyArtist();
        }
        if (splitsLocked[key]) {
            revert SplitsAreLocked();
        }

        _setSplits(collection, tokenId, key, splits);
    }

    function lockSplits(
        address collection,
        uint256 tokenId
    ) external whenNotPaused nonReentrant {
        bytes32 key = songKey(collection, tokenId);
        address artist = songArtist[key];
        if (artist == address(0)) {
            revert SongNotRegistered();
        }
        if (msg.sender != artist) {
            revert OnlyArtist();
        }
        if (splitsLocked[key]) {
            revert SplitsAreLocked();
        }

        splitsLocked[key] = true;
        emit SplitsLocked(collection, tokenId);
    }

    // ============ Admin Functions ============

    function updatePlatformFeeBps(
        uint256 newBps
    ) external onlyOwner {
        _validateFees(newBps, stakingFeeBps, tortoiseShell);
        emit PlatformFeeBpsUpdated(platformFeeBps, newBps);
        platformFeeBps = newBps;
    }

    function updateStakingFeeBps(
        uint256 newBps
    ) external onlyOwner {
        _validateFees(platformFeeBps, newBps, tortoiseShell);
        emit StakingFeeBpsUpdated(stakingFeeBps, newBps);
        stakingFeeBps = newBps;
    }

    function updateTortoiseShell(
        address newShell
    ) external onlyOwner {
        address oldShell = tortoiseShell;
        _setTortoiseShell(newShell);
        emit TortoiseShellUpdated(oldShell, newShell);

        if (newShell == address(0) && stakingFeeBps > 0) {
            emit StakingFeeBpsUpdated(stakingFeeBps, 0);
            stakingFeeBps = 0;
        }
    }

    function updatePlatformFeeRecipient(
        address newRecipient
    ) external onlyOwner {
        if (newRecipient == address(0)) {
            revert ZeroAddress();
        }
        emit PlatformFeeRecipientUpdated(platformFeeRecipient, newRecipient);
        platformFeeRecipient = newRecipient;
    }

    function updateInProcessMinter(
        address newMinter
    ) external onlyOwner {
        address oldMinter = inProcessMinter;
        _setInProcessMinter(newMinter);
        emit InProcessMinterUpdated(oldMinter, newMinter);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function recoverTokens(
        address token,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (token == address(usdc)) {
            revert CannotRecoverUSDC();
        }
        IERC20(token).safeTransfer(owner(), amount);
        emit TokensRecovered(token, owner(), amount);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenouncingOwnershipDisabled();
    }

    // ============ View Functions ============

    function getSongSplits(
        address collection,
        uint256 tokenId
    ) external view returns (SplitRecipient[] memory) {
        return songSplits[songKey(collection, tokenId)];
    }

    function songKey(
        address collection,
        uint256 tokenId
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(collection, tokenId));
    }

    function hashSplits(
        SplitRecipient[] calldata splits
    ) public pure returns (bytes32) {
        return _hashSplits(splits);
    }

    function hashRegisterSongWithSplits(
        address collection,
        uint256 tokenId,
        address artist,
        bytes32 splitsHash,
        bool lockSongSplits,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        return _hashRegisterSongWithSplits(
            collection, tokenId, artist, splitsHash, lockSongSplits, nonce, deadline
        );
    }

    // ============ Internal Functions ============

    function _validateSongRegistration(
        address collection,
        uint256 tokenId,
        address artist
    ) internal view {
        if (collection == address(0) || artist == address(0)) {
            revert ZeroAddress();
        }
        if (collection.code.length == 0) {
            revert CollectionMustBeContract();
        }

        if (songArtist[songKey(collection, tokenId)] != address(0)) {
            revert SongAlreadyRegistered();
        }
    }

    function _registerSong(
        address collection,
        uint256 tokenId,
        address artist
    ) internal returns (bytes32 key) {
        _validateSongRegistration(collection, tokenId, artist);

        key = songKey(collection, tokenId);
        songArtist[key] = artist;
        emit SongRegistered(collection, tokenId, artist);
    }

    function _setSplits(
        address collection,
        uint256 tokenId,
        bytes32 key,
        SplitRecipient[] calldata splits
    ) internal {
        if (splits.length > 0) {
            splits.validateSplits();
        }

        delete songSplits[key];
        for (uint256 i; i < splits.length;) {
            if (splits[i].recipient == address(this)) {
                revert SplitToSelf();
            }
            if (splits[i].recipient == address(usdc)) {
                revert SplitToUSDC();
            }
            songSplits[key].push(splits[i]);
            unchecked {
                ++i;
            }
        }

        emit SplitsConfigured(collection, tokenId);
    }

    function _hashRegisterSongWithSplits(
        address collection,
        uint256 tokenId,
        address artist,
        bytes32 splitsHash,
        bool lockSongSplits,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    REGISTER_SONG_WITH_SPLITS_TYPEHASH,
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
    }

    function _hashSplits(
        SplitRecipient[] calldata splits
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(splits));
    }

    function _validateCollectItem(
        CollectItem memory item
    ) internal view returns (CollectQuote memory quote) {
        bytes32 key = songKey(item.collection, item.tokenId);
        if (songArtist[key] == address(0)) {
            revert SongNotRegistered();
        }
        if (item.quantity == 0) {
            revert ZeroQuantity();
        }

        InProcessSale memory sale =
            IInProcessERC20Minter(inProcessMinter).sale(item.collection, item.tokenId);
        if (sale.currency != address(usdc)) {
            revert InvalidCurrency();
        }
        if (sale.fundsRecipient != address(this)) {
            revert InvalidFundsRecipient();
        }

        uint256 totalCost = sale.pricePerToken * item.quantity;
        if (totalCost == 0) {
            revert ZeroCost();
        }
        if (totalCost > item.maxTotalCost) {
            revert PriceExceedsMax();
        }
        _validateFeeMinimum(totalCost, platformFeeBps);
        _validateFeeMinimum(sale.pricePerToken, stakingFeeBps);

        quote = CollectQuote({key: key, sale: sale, totalCost: totalCost});
    }

    function _mintAndDistribute(
        CollectItem memory item,
        CollectQuote memory quote,
        address collector,
        uint256 expectedBalance
    ) internal returns (uint256 balanceAfterDistribution) {
        usdc.forceApprove(inProcessMinter, quote.totalCost);

        IInProcessERC20Minter(inProcessMinter)
            .mint(
                collector,
                item.quantity,
                item.collection,
                item.tokenId,
                quote.totalCost,
                address(usdc),
                address(0),
                ""
            );

        usdc.forceApprove(inProcessMinter, 0);

        uint256 actualBalance = usdc.balanceOf(address(this));
        if (actualBalance != expectedBalance) {
            revert UnexpectedProceeds(expectedBalance, actualBalance);
        }

        _distribute(
            item.collection,
            item.tokenId,
            quote.key,
            quote.totalCost,
            quote.sale.pricePerToken,
            collector
        );
        emit SongCollected(item.collection, item.tokenId, collector, item.quantity, quote.totalCost);

        return usdc.balanceOf(address(this));
    }

    function _distribute(
        address collection,
        uint256 tokenId,
        bytes32 key,
        uint256 totalReceived,
        uint256 rewardEligiblePrice,
        address collector
    ) internal {
        uint256 platformFee = (totalReceived * platformFeeBps) / BASIS_POINTS;
        if (platformFee > 0) {
            usdc.safeTransfer(platformFeeRecipient, platformFee);
        }

        uint256 stakingFee = (rewardEligiblePrice * stakingFeeBps) / BASIS_POINTS;
        address shell = tortoiseShell;
        uint256 stakingFeeDistributed;
        uint256 artistRevenue = totalReceived - platformFee;
        if (
            stakingFee > 0 && shell != address(0)
                && _creditShell(collection, tokenId, key, collector, shell)
        ) {
            artistRevenue -= stakingFee;
            stakingFeeDistributed = stakingFee;
            usdc.safeTransfer(shell, stakingFee);
            ITortoiseShell(shell).depositRewards(stakingFee);
        }

        _distributeArtistRevenue(collection, tokenId, key, artistRevenue);

        emit RevenueDistributed(
            collection, tokenId, platformFee, stakingFeeDistributed, artistRevenue
        );
    }

    function _distributeArtistRevenue(
        address collection,
        uint256 tokenId,
        bytes32 key,
        uint256 artistRevenue
    ) internal {
        SplitRecipient[] storage splits = songSplits[key];
        uint256 len = splits.length;

        if (len == 0) {
            _transferOrDefer(collection, tokenId, key, songArtist[key], artistRevenue);
            return;
        }

        uint256 distributed;
        for (uint256 i; i < len;) {
            SplitRecipient storage recipient = splits[i];
            uint256 amount = i == len - 1
                ? artistRevenue - distributed
                : SplitLib.calculateSplitAmount(artistRevenue, recipient.percentage);
            _transferOrDefer(collection, tokenId, key, recipient.recipient, amount);
            distributed += amount;
            unchecked {
                ++i;
            }
        }
    }

    function _transferOrDefer(
        address collection,
        uint256 tokenId,
        bytes32 key,
        address recipient,
        uint256 amount
    ) internal {
        if (amount == 0) {
            return;
        }

        bool transferred = _tryTransferUSDC(recipient, amount);
        if (transferred) {
            emit PaymentDistributed(collection, tokenId, recipient, amount);
            return;
        }

        _recordPendingClaim(key, recipient, amount);
        emit SplitPaymentDeferred(collection, tokenId, recipient, amount);
    }

    function _recordPendingClaim(
        bytes32 key,
        address recipient,
        uint256 amount
    ) internal {
        if (pendingClaims[key][recipient] == 0) {
            pendingClaimDeferredAt[key][recipient] = block.timestamp;
        }
        pendingClaims[key][recipient] += amount;
    }

    function _tryTransferUSDC(
        address recipient,
        uint256 amount
    ) internal returns (bool) {
        if (address(usdc).code.length == 0) {
            return false;
        }

        (bool ok, bytes memory ret) =
            address(usdc).call(abi.encodeCall(IERC20.transfer, (recipient, amount)));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))));
    }

    function _creditShell(
        address collection,
        uint256 tokenId,
        bytes32 key,
        address collector,
        address shell
    ) internal returns (bool creditedFullReward) {
        if (shell == address(0)) {
            return false;
        }
        if (tortRewardClaimed[key][collector]) {
            return false;
        }

        uint256 expectedCredit;
        try ITortoiseShell(shell).tortRewardPerCollection() returns (uint256 reward) {
            expectedCredit = reward;
        } catch {
            emit ShellCreditFailed(collection, tokenId, collector, 1);
            return false;
        }
        if (expectedCredit == 0) {
            return false;
        }

        try ITortoiseShell(shell).getTortPoolBalance() returns (uint256 poolBalance) {
            if (poolBalance < expectedCredit) {
                return false;
            }
        } catch {
            emit ShellCreditFailed(collection, tokenId, collector, 1);
            return false;
        }

        (bool ok, bytes memory ret) =
            shell.call(abi.encodeCall(ITortoiseShell.creditStake, (collector, 1)));
        if (!ok) {
            emit ShellCreditFailed(collection, tokenId, collector, 1);
            return false;
        }

        uint256 actualCredit;
        if (ret.length > 0) {
            actualCredit = abi.decode(ret, (uint256));
        }
        if (actualCredit != expectedCredit) {
            revert UnexpectedShellCredit(expectedCredit, actualCredit);
        }

        tortRewardClaimed[key][collector] = true;
        emit StakeCredited(collection, tokenId, collector, 1);
        return true;
    }

    function _setInProcessMinter(
        address newMinter
    ) internal {
        if (newMinter == address(0)) {
            revert ZeroAddress();
        }
        if (newMinter.code.length == 0) {
            revert MinterMustBeContract();
        }
        inProcessMinter = newMinter;
    }

    function _setTortoiseShell(
        address newShell
    ) internal {
        if (newShell != address(0) && newShell.code.length == 0) {
            revert ShellMustBeContract();
        }
        tortoiseShell = newShell;
    }

    function _validateFees(
        uint256 newPlatformFeeBps,
        uint256 newStakingFeeBps,
        address shell
    ) internal pure {
        if (newPlatformFeeBps > MAX_FEE_BPS || newStakingFeeBps > MAX_FEE_BPS) {
            revert FeeExceedsMaximum();
        }
        if (newPlatformFeeBps + newStakingFeeBps >= BASIS_POINTS) {
            revert FeeTotalInvalid();
        }
        if (newStakingFeeBps > 0 && shell == address(0)) {
            revert ShellRequired();
        }
    }

    function _validateFeeMinimum(
        uint256 totalCost,
        uint256 feeBps
    ) internal pure {
        if (feeBps > 0 && (totalCost * feeBps) / BASIS_POINTS == 0) {
            revert FeeRoundsToZero(totalCost, feeBps);
        }
    }
}
