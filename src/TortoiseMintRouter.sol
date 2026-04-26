// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IInProcessERC20Minter, InProcessSale} from "./interfaces/IInProcessERC20Minter.sol";
import {ITortoiseShell} from "./interfaces/ITortoiseShell.sol";
import {SplitRecipient, SplitLib} from "./libraries/SplitLib.sol";

contract TortoiseMintRouter is Ownable2Step, ReentrancyGuardTransient, Pausable {
    using SafeERC20 for IERC20;
    using SplitLib for SplitRecipient[];

    // ============ Constants ============

    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant MAX_FEE_BPS = 2000;
    uint256 public constant REROUTE_DELAY = 90 days;

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
    event PendingClaimRerouted(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed oldRecipient,
        address newRecipient,
        uint256 amount
    );

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
    error ZeroQuantity();
    error ZeroCost();
    error InvalidCurrency();
    error InvalidFundsRecipient();
    error PriceExceedsMax();
    error UnexpectedProceeds(uint256 expectedBalance, uint256 actualBalance);
    error FeeExceedsMaximum();
    error FeeTotalInvalid();
    error ShellRequired();
    error CannotRecoverUSDC();
    error NothingToClaim();
    error TransferFailedStillClaimable();
    error ZeroRecipient();
    error SelfReroute();
    error RerouteTooSoon();
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
    ) Ownable(msg.sender) {
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
        bytes32 key = songKey(collection, tokenId);
        if (songArtist[key] == address(0)) {
            revert SongNotRegistered();
        }
        if (quantity == 0) {
            revert ZeroQuantity();
        }

        InProcessSale memory sale = IInProcessERC20Minter(inProcessMinter).sale(collection, tokenId);
        if (sale.currency != address(usdc)) {
            revert InvalidCurrency();
        }
        if (sale.fundsRecipient != address(this)) {
            revert InvalidFundsRecipient();
        }

        uint256 totalCost = sale.pricePerToken * quantity;
        if (totalCost == 0) {
            revert ZeroCost();
        }
        if (totalCost > maxTotalCost) {
            revert PriceExceedsMax();
        }

        uint256 balanceBefore = usdc.balanceOf(address(this));

        usdc.safeTransferFrom(msg.sender, address(this), totalCost);
        usdc.forceApprove(inProcessMinter, totalCost);

        IInProcessERC20Minter(inProcessMinter)
            .mint(
                msg.sender, quantity, collection, tokenId, totalCost, address(usdc), address(0), ""
            );

        usdc.forceApprove(inProcessMinter, 0);

        uint256 expectedBalance = balanceBefore + totalCost;
        uint256 actualBalance = usdc.balanceOf(address(this));
        if (actualBalance != expectedBalance) {
            revert UnexpectedProceeds(expectedBalance, actualBalance);
        }

        _distribute(collection, tokenId, key, totalCost, msg.sender);
        emit SongCollected(collection, tokenId, msg.sender, quantity, totalCost);
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
        if (collection == address(0) || artist == address(0)) {
            revert ZeroAddress();
        }
        if (collection.code.length == 0) {
            revert CollectionMustBeContract();
        }

        bytes32 key = songKey(collection, tokenId);
        if (songArtist[key] != address(0)) {
            revert SongAlreadyRegistered();
        }

        songArtist[key] = artist;
        emit SongRegistered(collection, tokenId, artist);
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

    function rerouteBlockedClaim(
        address collection,
        uint256 tokenId,
        address oldRecipient,
        address newRecipient
    ) external onlyOwner nonReentrant {
        if (newRecipient == address(0)) {
            revert ZeroRecipient();
        }
        if (newRecipient == oldRecipient) {
            revert SelfReroute();
        }

        bytes32 key = songKey(collection, tokenId);
        uint256 amount = pendingClaims[key][oldRecipient];
        if (amount == 0) {
            revert NothingToClaim();
        }

        uint256 deferredAt = pendingClaimDeferredAt[key][oldRecipient];
        if (block.timestamp < deferredAt + REROUTE_DELAY) {
            revert RerouteTooSoon();
        }

        pendingClaims[key][oldRecipient] = 0;
        pendingClaimDeferredAt[key][oldRecipient] = 0;
        _recordPendingClaim(key, newRecipient, amount);

        emit PendingClaimRerouted(collection, tokenId, oldRecipient, newRecipient, amount);
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

    // ============ Internal Functions ============

    function _distribute(
        address collection,
        uint256 tokenId,
        bytes32 key,
        uint256 totalReceived,
        address collector
    ) internal {
        uint256 platformFee = (totalReceived * platformFeeBps) / BASIS_POINTS;
        if (platformFee > 0) {
            usdc.safeTransfer(platformFeeRecipient, platformFee);
        }

        uint256 stakingFee = (totalReceived * stakingFeeBps) / BASIS_POINTS;
        address shell = tortoiseShell;
        bool stakingFeeDeposited;
        if (stakingFee > 0 && shell != address(0)) {
            usdc.safeTransfer(shell, stakingFee);
            ITortoiseShell(shell).depositRewards(stakingFee);
            stakingFeeDeposited = true;
        }

        uint256 artistRevenue = totalReceived - platformFee - stakingFee;
        _distributeArtistRevenue(collection, tokenId, key, artistRevenue);
        if (stakingFeeDeposited) {
            _creditShell(collection, tokenId, key, collector, shell);
        }

        emit RevenueDistributed(collection, tokenId, platformFee, stakingFee, artistRevenue);
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
    ) internal {
        if (shell == address(0)) {
            return;
        }
        if (tortRewardClaimed[key][collector]) {
            return;
        }

        try ITortoiseShell(shell).creditStake(collector, 1) returns (uint256 credited) {
            if (credited == 0) {
                return;
            }
            tortRewardClaimed[key][collector] = true;
            emit StakeCredited(collection, tokenId, collector, 1);
        } catch {
            emit ShellCreditFailed(collection, tokenId, collector, 1);
        }
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
}
