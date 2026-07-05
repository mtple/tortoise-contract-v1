// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ITortoiseShell} from "./interfaces/ITortoiseShell.sol";

/// @title TortoiseShell (ETH-native)
/// @notice TORT staking with native-ETH rewards (Synthetix-style drip) and automatic TORT
///         crediting for collectors. ETH-native rewrite of the audited USDC v1 shell
///         (`legacy/v1/src/TortoiseShell.sol`); no migration logic, no shared state.
/// @dev `stakingToken` MUST be a standard ERC20 (non-rebasing, non-fee-on-transfer, no
///      transfer hooks). Reward accounting assumes amount-transferred == amount-received.
///      All reward amounts are native wei — no scaling.
contract TortoiseShell is ITortoiseShell, Ownable2Step, ReentrancyGuardTransient, Pausable, EIP712 {
    using SafeERC20 for IERC20;

    // ============ Token ============

    IERC20 public immutable stakingToken; // $TORT

    // ============ Staking ============

    mapping(address => uint256) public stakedBalance;
    uint256 public totalStaked;

    // ============ ETH Rewards (Synthetix pattern, 7-day drip) ============

    uint256 public rewardRate; // wei per second
    uint256 public rewardDuration; // e.g. 604800 (7 days)
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public reservedBalance; // ETH earned-but-unclaimed, reserved into a period (wei)
    uint256 public constant MIN_REWARD_DURATION = 1 days;
    uint256 public constant MAX_REWARD_DURATION = 365 days;
    // Floor below which a deposit pools into _queuedReward instead of extending the
    // period. Raises the cost of cap-and-extend griefing on rewardRate.
    uint256 public constant MIN_REWARD_DEPOSIT = 1e15; // 0.001 ETH
    uint256 public totalRewardsDeposited; // ETH accounted as still owed (wei; decreases on claim)
    uint256 internal _queuedReward; // rewards queued while totalStaked == 0 or sub-floor (wei)
    uint256 internal _queuedRewardUpdatedAt; // timestamp of last _queuedReward mutation
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public userUnpaidRewards;

    // ============ TORT Credit Pool ============

    uint256 public tortPool; // TORT available for crediting
    uint256 public tortRewardPerCollection; // Fixed TORT per reward unit credited
    uint256 public totalTortCredited; // Lifetime tracking

    // ============ Access Control ============

    mapping(address => bool) public authorizedCallers;

    // ============ Delegated reward claims (EIP-712) ============

    mapping(address => uint256) public rewardClaimNonces;

    bytes32 private constant _CLAIM_SHELL_REWARDS_TO_TYPEHASH = keccak256(
        "ClaimShellRewardsTo(address user,address payoutTo,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    // ============ Events ============

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, address indexed payoutTo, uint256 amount);
    event RewardsDeposited(uint256 actual, uint256 newRewardRate);
    event QueuedRewardFlushed(uint256 amount, uint256 newRewardRate);
    event StakeCredited(address indexed user, uint256 amount, uint256 rewardUnits);
    event TortPoolFunded(uint256 amount, uint256 newPoolBalance);
    event TortPoolWithdrawn(uint256 amount, uint256 newPoolBalance);
    event TortRewardPerCollectionUpdated(uint256 oldAmount, uint256 newAmount);
    event AuthorizedCallerAdded(address indexed caller);
    event AuthorizedCallerRemoved(address indexed caller);
    event RewardDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    // ============ Errors ============

    error UnauthorizedCaller();
    error ZeroAmount();
    error InsufficientBalance();
    error InsufficientTortPool();
    error ZeroAddress();
    error RewardPeriodActive();
    error InvalidRewardDuration();
    error CallerMustBeContract();
    error RenouncingOwnershipDisabled();
    error CannotRecoverStakingToken();
    error ETHTransferFailed();
    error RewardClaimExpired();
    error InvalidRewardSignature();
    error RewardNonceMismatch(uint256 expected, uint256 provided);

    // ============ Modifiers ============

    modifier onlyAuthorizedCaller() {
        if (!authorizedCallers[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedCaller();
        }
        _;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            userUnpaidRewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ============ Constructor ============

    constructor(address _stakingToken, uint256 _rewardDuration)
        Ownable(msg.sender)
        EIP712("TortoiseShell", "1")
    {
        if (_stakingToken == address(0)) revert ZeroAddress();
        if (_rewardDuration < MIN_REWARD_DURATION || _rewardDuration > MAX_REWARD_DURATION) {
            revert InvalidRewardDuration();
        }
        stakingToken = IERC20(_stakingToken);
        rewardDuration = _rewardDuration;
        emit RewardDurationUpdated(0, _rewardDuration);
    }

    // ============ User-Facing Functions ============

    function stake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        stakedBalance[msg.sender] += amount;
        totalStaked += amount;

        if (_queuedReward > 0) {
            _flushQueuedReward();
        }

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant updateReward(msg.sender) {
        _withdraw(msg.sender, amount);
    }

    /// @notice Claim all accrued ETH rewards to the caller.
    function claimRewards() external nonReentrant updateReward(msg.sender) {
        _claimRewards(msg.sender, msg.sender, userUnpaidRewards[msg.sender]);
    }

    /// @notice Claim `amount` of the caller's accrued ETH rewards to a chosen recipient.
    /// @dev Lets stakers route rewards to a payable address (e.g. when staking from a
    ///      contract wallet that cannot receive raw ETH).
    function claimRewardsTo(address payoutTo, uint256 amount)
        external
        nonReentrant
        updateReward(msg.sender)
    {
        _claimRewards(msg.sender, payoutTo, amount);
    }

    /// @notice Delegated claim: anyone may relay a claim authorized by `user` via EIP-712
    ///         (or EIP-1271 for contract wallets). The amount is signed so an authorization
    ///         cannot be replayed against future rewards; the nonce advances on every
    ///         successful payout (direct or delegated), staling outstanding authorizations.
    function claimRewardsWithAuthorization(
        address user,
        address payoutTo,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant updateReward(user) {
        if (block.timestamp > deadline) revert RewardClaimExpired();
        if (nonce != rewardClaimNonces[user]) {
            revert RewardNonceMismatch(rewardClaimNonces[user], nonce);
        }
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    _CLAIM_SHELL_REWARDS_TO_TYPEHASH, user, payoutTo, amount, nonce, deadline
                )
            )
        );
        if (!SignatureChecker.isValidSignatureNowCalldata(user, digest, signature)) {
            revert InvalidRewardSignature();
        }
        _claimRewards(user, payoutTo, amount);
    }

    function exit() external nonReentrant updateReward(msg.sender) {
        _withdraw(msg.sender, stakedBalance[msg.sender]);
        _claimRewards(msg.sender, msg.sender, userUnpaidRewards[msg.sender]);
    }

    function emergencyWithdraw() external nonReentrant updateReward(msg.sender) {
        uint256 amount = stakedBalance[msg.sender];
        if (amount == 0) revert ZeroAmount();

        // Forfeit all accrued ETH rewards. Release the accrual slot (reservedBalance) so
        // the forfeited ETH is recycled into future rewards via the next depositRewards
        // (balance - totalRewardsDeposited picks it up as excess). totalRewardsDeposited is
        // intentionally NOT decremented: no ETH leaves here, so the liability remains owed
        // to the reward pool as a whole. Decrementing would double-count on next deposit.
        uint256 forfeited = userUnpaidRewards[msg.sender];
        if (forfeited > 0) {
            reservedBalance -= forfeited;
            userUnpaidRewards[msg.sender] = 0;
        }

        stakedBalance[msg.sender] = 0;
        totalStaked -= amount;

        // If all stakers have exited mid-period, queue remaining rewards so they aren't
        // lost emitting into a zero-totalStaked void.
        if (totalStaked == 0 && block.timestamp < periodFinish) {
            uint256 remaining = (periodFinish - block.timestamp) * rewardRate;
            if (remaining > 0) {
                _queuedReward += remaining;
                _queuedRewardUpdatedAt = block.timestamp;
                reservedBalance -= remaining;
                rewardRate = 0;
                periodFinish = block.timestamp;
            }
        }

        stakingToken.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, amount);
    }

    // ============ Called by the Tortoise minter ============

    function depositRewards() external payable onlyAuthorizedCaller updateReward(address(0)) {
        // Reconcile actual new ETH from balance vs cumulative deposit tracking. `actual`
        // may exceed msg.value when forfeited rewards (recycled via emergencyWithdraw) or
        // stray ETH are being swept in. Staking is TORT (a separate ERC20 balance), so the
        // ETH balance reflects rewards only.
        uint256 currentBalance = address(this).balance;
        uint256 actual =
            currentBalance > totalRewardsDeposited ? currentBalance - totalRewardsDeposited : 0;
        if (actual == 0) return;
        totalRewardsDeposited += actual;
        _addReward(actual);
        emit RewardsDeposited(actual, rewardRate);
    }

    function creditStake(address user, uint256 rewardUnits)
        external
        onlyAuthorizedCaller
        updateReward(user)
        returns (uint256 credited)
    {
        if (user == address(0)) revert ZeroAddress();
        uint256 creditAmount = rewardUnits * tortRewardPerCollection;

        // Graceful degradation — never revert, never block mints
        if (creditAmount > tortPool) {
            creditAmount = tortPool;
        }
        if (creditAmount == 0) return 0;

        tortPool -= creditAmount;
        stakedBalance[user] += creditAmount;
        totalStaked += creditAmount;
        totalTortCredited += creditAmount;

        if (_queuedReward > 0) {
            _flushQueuedReward();
        }

        emit StakeCredited(user, creditAmount, rewardUnits);
        return creditAmount;
    }

    // ============ View Functions ============

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        return (stakedBalance[account] * (rewardPerToken() - userRewardPerTokenPaid[account]))
            / 1e18 + userUnpaidRewards[account];
    }

    /// @notice ETH rewards currently claimable by `user` (accrued + previously settled).
    function claimableRewards(address user) external view returns (uint256) {
        return earned(user);
    }

    function balanceOf(address user) external view returns (uint256) {
        return stakedBalance[user];
    }

    function getUserStats(address user)
        external
        view
        returns (uint256 stakedAmount, uint256 pendingEthRewards, uint256 shareOfPool)
    {
        stakedAmount = stakedBalance[user];
        pendingEthRewards = earned(user);
        shareOfPool = totalStaked == 0 ? 0 : (stakedAmount * 1e18) / totalStaked;
    }

    function getTortPoolBalance() external view returns (uint256) {
        return tortPool;
    }

    function getRewardRate() external view returns (uint256) {
        return rewardRate;
    }

    // ============ Owner Functions ============

    function fundTortPool(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();

        tortPool += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit TortPoolFunded(amount, tortPool);
    }

    function withdrawTortPool(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > tortPool) revert InsufficientTortPool();

        tortPool -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit TortPoolWithdrawn(amount, tortPool);
    }

    function setTortRewardPerCollection(uint256 amount) external onlyOwner {
        emit TortRewardPerCollectionUpdated(tortRewardPerCollection, amount);
        tortRewardPerCollection = amount;
    }

    function addAuthorizedCaller(address caller) external onlyOwner {
        if (caller == address(0)) revert ZeroAddress();
        if (caller.code.length == 0) revert CallerMustBeContract();
        authorizedCallers[caller] = true;
        emit AuthorizedCallerAdded(caller);
    }

    function removeAuthorizedCaller(address caller) external onlyOwner {
        authorizedCallers[caller] = false;
        emit AuthorizedCallerRemoved(caller);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenouncingOwnershipDisabled();
    }

    function updateRewardDuration(uint256 newDuration) external onlyOwner {
        if (newDuration < MIN_REWARD_DURATION || newDuration > MAX_REWARD_DURATION) {
            revert InvalidRewardDuration();
        }
        if (block.timestamp < periodFinish) revert RewardPeriodActive();
        emit RewardDurationUpdated(rewardDuration, newDuration);
        rewardDuration = newDuration;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Recover stray ERC20s. The staking token cannot be recovered. There is no
    ///         ETH recovery path — ETH is reward liability and is swept into reward periods.
    function recoverTokens(address token, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(stakingToken)) revert CannotRecoverStakingToken();
        IERC20(token).safeTransfer(owner(), amount);
        emit TokensRecovered(token, owner(), amount);
    }

    // ============ Internal Functions ============

    function _withdraw(address user, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (stakedBalance[user] < amount) revert InsufficientBalance();

        stakedBalance[user] -= amount;
        totalStaked -= amount;

        // If all stakers have exited mid-period, queue remaining rewards so they aren't
        // lost emitting into a zero-totalStaked void.
        if (totalStaked == 0 && block.timestamp < periodFinish) {
            uint256 remaining = (periodFinish - block.timestamp) * rewardRate;
            if (remaining > 0) {
                _queuedReward += remaining;
                _queuedRewardUpdatedAt = block.timestamp;
                reservedBalance -= remaining;
                rewardRate = 0;
                periodFinish = block.timestamp;
            }
        }

        stakingToken.safeTransfer(user, amount);
        emit Withdrawn(user, amount);
    }

    /// @dev Debit exactly `amount` from `user`'s settled rewards and send it to `payoutTo`.
    ///      Reverts on a failed ETH send (unlike the minter's deferral path) — the claimer
    ///      can retry with a different `payoutTo`. Advances the user's claim nonce on every
    ///      successful payout so outstanding delegated authorizations go stale.
    function _claimRewards(address user, address payoutTo, uint256 amount) internal {
        if (amount == 0) return;
        if (amount > userUnpaidRewards[user]) revert InsufficientBalance();
        if (payoutTo == address(0)) revert ZeroAddress();

        userUnpaidRewards[user] -= amount;
        reservedBalance -= amount;
        totalRewardsDeposited -= amount;
        rewardClaimNonces[user] += 1;

        (bool ok,) = payoutTo.call{value: amount}("");
        if (!ok) revert ETHTransferFailed();

        emit RewardsClaimed(user, payoutTo, amount);
    }

    function _addReward(uint256 reward) internal {
        // Queue rewards when no one is staked — rewardPerToken won't accumulate with
        // totalStaked == 0, so these rewards would be permanently lost.
        if (totalStaked == 0) {
            _queuedReward += reward;
            _queuedRewardUpdatedAt = block.timestamp;
            return;
        }

        // Pool with any previously-queued rewards, then only flush into a rate recalc if
        // the aggregate crosses MIN_REWARD_DEPOSIT. Sub-threshold flows stay queued and
        // fold into the next qualifying deposit.
        uint256 pooled = reward + _queuedReward;
        if (pooled < MIN_REWARD_DEPOSIT) {
            _queuedReward = pooled;
            _queuedRewardUpdatedAt = block.timestamp;
            return;
        }
        _queuedReward = 0;
        _queuedRewardUpdatedAt = 0;

        if (block.timestamp >= periodFinish) {
            rewardRate = pooled / rewardDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (pooled + leftover) / rewardDuration;
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardDuration;
        reservedBalance += pooled;
    }

    function _flushQueuedReward() internal {
        uint256 queued = _queuedReward;
        if (queued == 0) return;

        // Mirror _addReward's MIN_REWARD_DEPOSIT floor at the flush boundary — otherwise
        // sub-floor amounts queued via mid-period exits can be flushed by a single-wei
        // stake into a full fresh period, reproducing the cap-and-extend dilution shape the
        // floor prevents. Aged queues (sat >= rewardDuration) escape the gate so
        // low-activity periods can't trap rewards indefinitely.
        bool aged = block.timestamp >= _queuedRewardUpdatedAt + rewardDuration;
        if (queued < MIN_REWARD_DEPOSIT && !aged) return;

        _queuedReward = 0;
        _queuedRewardUpdatedAt = 0;

        if (block.timestamp >= periodFinish) {
            rewardRate = queued / rewardDuration;
        } else {
            // Defensive branch, symmetric with _addReward's mid-period path. Under current
            // semantics this is unreachable — every path that queues rewards either exits
            // the period or comes from an above-floor deposit during totalStaked == 0.
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (queued + leftover) / rewardDuration;
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardDuration;
        reservedBalance += queued;
        emit QueuedRewardFlushed(queued, rewardRate);
    }

    /// @notice Accept ETH only from authorized callers (e.g. the minter). Plain sends are
    ///         rejected; any ETH that still lands (e.g. via selfdestruct) is swept into the
    ///         next reward period by the depositRewards reconciliation.
    receive() external payable {
        if (!authorizedCallers[msg.sender]) revert UnauthorizedCaller();
    }
}
