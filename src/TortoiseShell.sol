// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITortoiseShell} from "./interfaces/ITortoiseShell.sol";

contract TortoiseShell is ITortoiseShell, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============ Tokens ============

    IERC20 public immutable stakingToken; // $TORT
    IERC20 public immutable rewardToken; // USDC

    error TokensMustDiffer();

    // ============ Staking ============

    mapping(address => uint256) public stakedBalance;
    uint256 public totalStaked;

    // ============ USDC Rewards (Synthetix pattern, 7-day drip) ============

    uint256 public rewardRate; // USDC per second (scaled by rewardScalar)
    uint256 public rewardDuration; // 604800 (7 days)
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public reservedBalance; // USDC earned but not yet claimed
    uint256 public constant REWARD_SCALAR = 1e12; // Scale 6-decimal USDC to 18 internally
    uint256 public totalRewardsDeposited; // Cumulative USDC deposited (native 6-decimal)
    uint256 internal _queuedReward; // Scaled rewards queued while totalStaked == 0
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public userUnpaidRewards;

    // ============ TORT Credit Pool ============

    uint256 public tortPool; // TORT available for crediting
    uint256 public tortRewardPerCollection; // Fixed TORT per copy collected
    uint256 public totalTortCredited; // Lifetime tracking

    // ============ Access Control ============

    mapping(address => bool) public authorizedCallers;

    // ============ Events ============

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardsDeposited(uint256 amount, uint256 newRewardRate);
    event StakeCredited(address indexed user, uint256 amount, uint256 quantity);
    event TortPoolFunded(uint256 amount, uint256 newPoolBalance);
    event TortPoolWithdrawn(uint256 amount, uint256 newPoolBalance);
    event TortRewardPerCollectionUpdated(uint256 oldAmount, uint256 newAmount);
    event AuthorizedCallerAdded(address indexed caller);
    event AuthorizedCallerRemoved(address indexed caller);
    event RewardDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event EmergencyWithdraw(address indexed user, uint256 amount);

    // ============ Errors ============

    error UnauthorizedCaller();
    error ZeroAmount();
    error InsufficientBalance();
    error InsufficientTortPool();
    error ZeroAddress();
    error RewardPeriodActive();

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

    constructor(
        address _stakingToken,
        address _rewardToken,
        uint256 _rewardDuration
    ) Ownable(msg.sender) {
        if (_stakingToken == address(0)) revert ZeroAddress();
        if (_rewardToken == address(0)) revert ZeroAddress();
        if (_stakingToken == _rewardToken) revert TokensMustDiffer();

        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
        require(_rewardDuration > 0, "Duration must be positive");
        rewardDuration = _rewardDuration;
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

    function claimRewards() public nonReentrant whenNotPaused updateReward(msg.sender) {
        _claimRewards(msg.sender);
    }

    function exit() external nonReentrant whenNotPaused updateReward(msg.sender) {
        _withdraw(msg.sender, stakedBalance[msg.sender]);
        _claimRewards(msg.sender);
    }

    function emergencyWithdraw() external nonReentrant updateReward(msg.sender) {
        uint256 amount = stakedBalance[msg.sender];
        if (amount == 0) revert ZeroAmount();

        // Forfeit all accrued USDC rewards. Reduce reservedBalance and
        // totalRewardsDeposited so the forfeited USDC is recycled into future
        // rewards via depositRewards (which detects balanceOf > totalRewardsDeposited).
        uint256 forfeited = userUnpaidRewards[msg.sender];
        if (forfeited > 0) {
            reservedBalance -= forfeited;
            totalRewardsDeposited -= forfeited / REWARD_SCALAR;
            userUnpaidRewards[msg.sender] = 0;
        }
        userRewardPerTokenPaid[msg.sender] = rewardPerTokenStored;

        stakedBalance[msg.sender] = 0;
        totalStaked -= amount;

        // If all stakers have exited mid-period, queue remaining rewards
        // so they aren't lost emitting into a zero-totalStaked void.
        if (totalStaked == 0 && block.timestamp < periodFinish) {
            uint256 remaining = (periodFinish - block.timestamp) * rewardRate;
            _queuedReward += remaining;
            reservedBalance -= remaining;
            rewardRate = 0;
            periodFinish = block.timestamp;
        }

        stakingToken.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, amount);
    }

    // ============ Called by TortoiseV1 ============

    function depositRewards(uint256 /*amount*/) external onlyAuthorizedCaller updateReward(address(0)) {
        // Calculate actual new USDC from balance vs cumulative deposit tracking.
        // Using totalRewardsDeposited instead of reservedBalance/REWARD_SCALAR avoids
        // precision drift from non-REWARD_SCALAR-aligned claim subtractions.
        uint256 currentBalance = rewardToken.balanceOf(address(this));
        uint256 actual = currentBalance > totalRewardsDeposited ? currentBalance - totalRewardsDeposited : 0;
        if (actual == 0) return;
        totalRewardsDeposited += actual;
        _addReward(actual);
        emit RewardsDeposited(actual, rewardRate);
    }

    function creditStake(
        address user,
        uint256 quantity
    ) external onlyAuthorizedCaller updateReward(user) {
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

        if (_queuedReward > 0) {
            _flushQueuedReward();
        }

        emit StakeCredited(user, creditAmount, quantity);
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

    function balanceOf(address user) external view returns (uint256) {
        return stakedBalance[user];
    }

    function getUserStats(
        address user
    ) external view returns (uint256 stakedAmount, uint256 pendingUsdcRewards, uint256 shareOfPool) {
        stakedAmount = stakedBalance[user];
        pendingUsdcRewards = earned(user) / REWARD_SCALAR;
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
        authorizedCallers[caller] = true;
        emit AuthorizedCallerAdded(caller);
    }

    function removeAuthorizedCaller(address caller) external onlyOwner {
        authorizedCallers[caller] = false;
        emit AuthorizedCallerRemoved(caller);
    }

    function updateRewardDuration(uint256 newDuration) external onlyOwner {
        require(newDuration > 0, "Duration must be positive");
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

    function recoverTokens(address token, uint256 amount) external onlyOwner nonReentrant {
        require(token != address(stakingToken), "Cannot recover staking token");
        require(token != address(rewardToken), "Cannot recover reward token");
        IERC20(token).safeTransfer(owner(), amount);
    }

    // ============ Internal Functions ============

    function _withdraw(address user, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (stakedBalance[user] < amount) revert InsufficientBalance();

        stakedBalance[user] -= amount;
        totalStaked -= amount;

        // If all stakers have exited mid-period, queue remaining rewards
        // so they aren't lost emitting into a zero-totalStaked void.
        if (totalStaked == 0 && block.timestamp < periodFinish) {
            uint256 remaining = (periodFinish - block.timestamp) * rewardRate;
            _queuedReward += remaining;
            reservedBalance -= remaining;
            rewardRate = 0;
            periodFinish = block.timestamp;
        }

        stakingToken.safeTransfer(user, amount);
        emit Withdrawn(user, amount);
    }

    function _claimRewards(address user) internal {
        uint256 reward = userUnpaidRewards[user];
        if (reward == 0) return;

        userUnpaidRewards[user] = 0;

        // Descale from 18 decimals back to 6
        uint256 payout = reward / REWARD_SCALAR;
        if (payout == 0) return;

        reservedBalance -= reward;
        totalRewardsDeposited -= payout;
        rewardToken.safeTransfer(user, payout);
        emit RewardsClaimed(user, payout);
    }

    function _addReward(uint256 reward) internal {
        reward *= REWARD_SCALAR;

        // Queue rewards when no one is staked — rewardPerToken won't accumulate
        // with totalStaked == 0, so these rewards would be permanently lost.
        if (totalStaked == 0) {
            _queuedReward += reward;
            return;
        }

        reward += _queuedReward;
        _queuedReward = 0;

        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardDuration;
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardDuration;
        reservedBalance += reward;
    }

    function _flushQueuedReward() internal {
        uint256 queued = _queuedReward;
        if (queued == 0) return;
        _queuedReward = 0;

        if (block.timestamp >= periodFinish) {
            rewardRate = queued / rewardDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (queued + leftover) / rewardDuration;
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardDuration;
        reservedBalance += queued;
    }
}
