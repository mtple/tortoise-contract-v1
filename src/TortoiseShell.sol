// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITortoiseShell} from "./interfaces/ITortoiseShell.sol";

contract TortoiseShell is ITortoiseShell, Ownable2Step, ReentrancyGuardTransient, Pausable {
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
    uint256 public constant MIN_REWARD_DURATION = 1 days;
    uint256 public constant MAX_REWARD_DURATION = 365 days;
    // Floor below which a deposit pools into _queuedReward instead of extending the
    // period. Raises the cost of cap-and-extend griefing on rewardRate. Scaled (18-dec).
    uint256 public constant MIN_REWARD_DEPOSIT = 1e6 * 1e12; // 1 USDC
    uint256 public totalRewardsDeposited; // USDC accounted as still owed (native 6-decimal; decreases on claim/forfeit)
    uint256 internal _queuedReward; // Scaled rewards queued while totalStaked == 0
    uint256 internal _queuedRewardUpdatedAt; // Timestamp of last _queuedReward mutation; gates sub-floor flush
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
    event RewardsDeposited(uint256 declared, uint256 actual, uint256 newRewardRate);
    event QueuedRewardFlushed(uint256 amount, uint256 newRewardRate);
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
    error InvalidRewardDuration();

    // ============ Events (admin) ============

    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

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

    /// @dev Both `stakingToken` and `rewardToken` MUST be standard ERC20s:
    /// non-rebasing, non-fee-on-transfer, non-reentrant (not ERC777), and without
    /// transfer hooks. Accounting (`tortPool`, `stakedBalance`, `reservedBalance`,
    /// `totalRewardsDeposited`) assumes `amount` transferred equals `amount` received.
    /// Behavior is undefined under non-standard tokens.
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
        if (_rewardDuration < MIN_REWARD_DURATION || _rewardDuration > MAX_REWARD_DURATION) {
            revert InvalidRewardDuration();
        }
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

    function claimRewards() external nonReentrant updateReward(msg.sender) {
        _claimRewards(msg.sender);
    }

    function exit() external nonReentrant updateReward(msg.sender) {
        _withdraw(msg.sender, stakedBalance[msg.sender]);
        _claimRewards(msg.sender);
    }

    function emergencyWithdraw() external nonReentrant updateReward(msg.sender) {
        uint256 amount = stakedBalance[msg.sender];
        if (amount == 0) revert ZeroAmount();

        // Forfeit accrued USDC rewards back to the pool. No USDC leaves the
        // contract, so totalRewardsDeposited remains unchanged while the
        // scaled reward is queued for future distribution.
        uint256 forfeited = userUnpaidRewards[msg.sender];
        if (forfeited > 0) {
            reservedBalance -= forfeited;
            _queuedReward += forfeited;
            _queuedRewardUpdatedAt = block.timestamp;
            userUnpaidRewards[msg.sender] = 0;
        }

        stakedBalance[msg.sender] = 0;
        totalStaked -= amount;

        // If all stakers have exited mid-period, queue remaining rewards
        // so they aren't lost emitting into a zero-totalStaked void.
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

    // ============ Called by authorized mint routers ============

    function depositRewards(uint256 amount) external onlyAuthorizedCaller updateReward(address(0)) {
        // Calculate actual new USDC from balance vs cumulative deposit tracking.
        // Using totalRewardsDeposited instead of reservedBalance/REWARD_SCALAR avoids
        // precision drift from non-REWARD_SCALAR-aligned claim subtractions.
        // `actual` may exceed `amount` when forfeited rewards are being recycled.
        uint256 currentBalance = rewardToken.balanceOf(address(this));
        uint256 actual = currentBalance > totalRewardsDeposited ? currentBalance - totalRewardsDeposited : 0;
        if (actual == 0) return;
        totalRewardsDeposited += actual;
        _addReward(actual);
        emit RewardsDeposited(amount, actual, rewardRate);
    }

    function creditStake(
        address user,
        uint256 quantity
    ) external onlyAuthorizedCaller updateReward(user) returns (uint256 credited) {
        if (user == address(0)) revert ZeroAddress();
        uint256 creditAmount = quantity * tortRewardPerCollection;

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

        emit StakeCredited(user, creditAmount, quantity);
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
        require(caller.code.length > 0, "Caller must be a contract");
        authorizedCallers[caller] = true;
        emit AuthorizedCallerAdded(caller);
    }

    function renounceOwnership() public view override onlyOwner {
        revert("Renouncing ownership disabled");
    }

    function removeAuthorizedCaller(address caller) external onlyOwner {
        authorizedCallers[caller] = false;
        emit AuthorizedCallerRemoved(caller);
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

    function recoverTokens(address token, uint256 amount) external onlyOwner nonReentrant {
        require(token != address(stakingToken), "Cannot recover staking token");
        require(token != address(rewardToken), "Cannot recover reward token");
        IERC20(token).safeTransfer(owner(), amount);
        emit TokensRecovered(token, owner(), amount);
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

    function _claimRewards(address user) internal {
        uint256 reward = userUnpaidRewards[user];
        if (reward == 0) return;

        // Descale from 18 decimals back to 6
        uint256 payout = reward / REWARD_SCALAR;
        if (payout == 0) return; // dust remains in userUnpaidRewards for next claim

        uint256 exactPaid = payout * REWARD_SCALAR;
        userUnpaidRewards[user] = reward - exactPaid;
        reservedBalance -= exactPaid;
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
            _queuedRewardUpdatedAt = block.timestamp;
            return;
        }

        // Pool with any previously-queued rewards, then only flush into a rate
        // recalc if the aggregate crosses MIN_REWARD_DEPOSIT. Sub-threshold flows
        // stay in _queuedReward and fold into the next qualifying deposit.
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

        // Mirror _addReward's MIN_REWARD_DEPOSIT floor at the flush boundary —
        // otherwise sub-floor amounts queued via mid-period exits (emergencyWithdraw
        // / _withdraw last-staker branch) can be flushed by a single-wei stake into
        // a full fresh period, reproducing the cap-and-extend dilution shape the
        // floor is meant to prevent. Aged queues (sat ≥ rewardDuration) escape the
        // gate so low-activity periods can't trap rewards indefinitely.
        bool aged = block.timestamp >= _queuedRewardUpdatedAt + rewardDuration;
        if (queued < MIN_REWARD_DEPOSIT && !aged) return;

        _queuedReward = 0;
        _queuedRewardUpdatedAt = 0;

        if (block.timestamp >= periodFinish) {
            rewardRate = queued / rewardDuration;
        } else {
            // Defensive branch: symmetric with _addReward's mid-period path.
            // Under current semantics this is unreachable — every path that
            // queues rewards either exits the period (pulling periodFinish
            // to block.timestamp on last-staker exit) or comes from an
            // above-floor deposit during totalStaked==0 (no active period).
            // Kept for symmetry and future-proofing.
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (queued + leftover) / rewardDuration;
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardDuration;
        reservedBalance += queued;
        emit QueuedRewardFlushed(queued, rewardRate);
    }
}
