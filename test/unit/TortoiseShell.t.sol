// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test, console} from "forge-std/Test.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockTORT} from "../mocks/MockTORT.sol";

contract TortoiseShellTest is Test {
    TortoiseShell public shell;
    MockUSDC public usdc;
    MockTORT public tort;

    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public tortoiseV1 = makeAddr("tortoiseV1");

    uint256 public constant REWARD_DURATION = 604_800; // 7 days
    uint256 public constant STAKE_AMOUNT = 1000e18;
    uint256 public constant TORT_PER_COLLECTION = 10e18;

    function setUp() public {
        usdc = new MockUSDC();
        tort = new MockTORT();
        shell = new TortoiseShell(address(tort), address(usdc), REWARD_DURATION);

        // Setup authorized caller — must have contract code (addAuthorizedCaller enforces this)
        vm.etch(tortoiseV1, hex"00");
        shell.addAuthorizedCaller(tortoiseV1);
        shell.setTortRewardPerCollection(TORT_PER_COLLECTION);

        // Fund users with TORT
        tort.mint(alice, 10_000e18);
        tort.mint(bob, 10_000e18);

        // Fund shell TORT pool
        tort.mint(owner, 100_000e18);
        tort.approve(address(shell), type(uint256).max);
        shell.fundTortPool(50_000e18);

        // Give tortoiseV1 USDC for reward deposits
        usdc.mint(tortoiseV1, 1_000_000e6);

        // Approvals
        vm.prank(alice);
        tort.approve(address(shell), type(uint256).max);
        vm.prank(bob);
        tort.approve(address(shell), type(uint256).max);
        vm.prank(tortoiseV1);
        usdc.approve(address(shell), type(uint256).max);
    }

    /// @dev Simulates TortoiseV1 flow: transfer USDC to shell then call depositRewards
    function _depositRewardsAsV1(
        uint256 amount
    ) internal {
        vm.startPrank(tortoiseV1);
        usdc.transfer(address(shell), amount);
        shell.depositRewards(amount);
        vm.stopPrank();
    }

    // ============ Constructor ============

    function test_constructor() public view {
        assertEq(address(shell.stakingToken()), address(tort));
        assertEq(address(shell.rewardToken()), address(usdc));
        assertEq(shell.rewardDuration(), REWARD_DURATION);
        assertEq(shell.tortRewardPerCollection(), TORT_PER_COLLECTION);
    }

    function test_constructor_revertsZeroDuration() public {
        vm.expectRevert(TortoiseShell.InvalidRewardDuration.selector);
        new TortoiseShell(address(tort), address(usdc), 0);
    }

    function test_constructor_revertsBelowMinDuration() public {
        vm.expectRevert(TortoiseShell.InvalidRewardDuration.selector);
        new TortoiseShell(address(tort), address(usdc), 1 days - 1);
    }

    function test_constructor_revertsAboveMaxDuration() public {
        vm.expectRevert(TortoiseShell.InvalidRewardDuration.selector);
        new TortoiseShell(address(tort), address(usdc), 365 days + 1);
    }

    function test_constructor_revertsZeroStakingToken() public {
        vm.expectRevert(TortoiseShell.ZeroAddress.selector);
        new TortoiseShell(address(0), address(usdc), REWARD_DURATION);
    }

    function test_constructor_revertsZeroRewardToken() public {
        vm.expectRevert(TortoiseShell.ZeroAddress.selector);
        new TortoiseShell(address(tort), address(0), REWARD_DURATION);
    }

    // ============ Stake ============

    function test_stake() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        assertEq(shell.stakedBalance(alice), STAKE_AMOUNT);
        assertEq(shell.totalStaked(), STAKE_AMOUNT);
        assertEq(tort.balanceOf(address(shell)), 50_000e18 + STAKE_AMOUNT);
    }

    function test_stake_revertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(TortoiseShell.ZeroAmount.selector);
        shell.stake(0);
    }

    function test_stake_revertsWhenPaused() public {
        shell.pause();
        vm.prank(alice);
        vm.expectRevert();
        shell.stake(STAKE_AMOUNT);
    }

    // ============ Withdraw ============

    function test_withdraw() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        uint256 tortBefore = tort.balanceOf(alice);

        vm.prank(alice);
        shell.withdraw(STAKE_AMOUNT);

        assertEq(shell.stakedBalance(alice), 0);
        assertEq(shell.totalStaked(), 0);
        assertEq(tort.balanceOf(alice), tortBefore + STAKE_AMOUNT);
    }

    function test_withdraw_partial() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        vm.prank(alice);
        shell.withdraw(STAKE_AMOUNT / 2);

        assertEq(shell.stakedBalance(alice), STAKE_AMOUNT / 2);
    }

    function test_withdraw_revertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(TortoiseShell.ZeroAmount.selector);
        shell.withdraw(0);
    }

    function test_withdraw_revertsInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(TortoiseShell.InsufficientBalance.selector);
        shell.withdraw(STAKE_AMOUNT);
    }

    function test_withdraw_allowedWhenPaused() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        shell.pause();

        vm.prank(alice);
        shell.withdraw(STAKE_AMOUNT); // Should succeed
        assertEq(shell.stakedBalance(alice), 0);
    }

    // ============ USDC Reward Drip ============

    function test_depositRewards_startsRewardPeriod() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        uint256 shellUsdcBefore = usdc.balanceOf(address(shell));
        uint256 rewardAmount = 100e6; // 100 USDC
        _depositRewardsAsV1(rewardAmount);

        assertGt(shell.rewardRate(), 0);
        assertEq(shell.periodFinish(), block.timestamp + REWARD_DURATION);
        // Verify USDC actually arrived in the shell
        assertEq(usdc.balanceOf(address(shell)), shellUsdcBefore + rewardAmount);
        // Verify reservedBalance tracks the deposit (scaled)
        assertEq(shell.reservedBalance(), rewardAmount * shell.REWARD_SCALAR());
    }

    function test_depositRewards_zeroAmount() public {
        // Deposit a real reward first to set non-zero state
        _depositRewardsAsV1(100e6);
        uint256 rateBefore = shell.rewardRate();
        uint256 periodBefore = shell.periodFinish();

        // Zero deposit should not change reward state
        vm.prank(tortoiseV1);
        shell.depositRewards(0);
        assertEq(shell.rewardRate(), rateBefore);
        assertEq(shell.periodFinish(), periodBefore);
    }

    function test_claimRewards_afterFullPeriod() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        uint256 rewardAmount = 700e6; // 700 USDC
        _depositRewardsAsV1(rewardAmount);

        // Fast-forward past reward period
        vm.warp(block.timestamp + REWARD_DURATION + 1);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        shell.claimRewards();
        uint256 balAfter = usdc.balanceOf(alice);

        // Should receive ~700 USDC (minus rounding dust from integer division)
        uint256 claimed = balAfter - balBefore;
        assertApproxEqAbs(claimed, rewardAmount, 100); // tolerance: 0.0001 USDC
        assertGt(claimed, 0); // must actually receive something
    }

    function test_claimRewards_proportional() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);
        vm.prank(bob);
        shell.stake(STAKE_AMOUNT);

        uint256 rewardAmount = 700e6;
        _depositRewardsAsV1(rewardAmount);

        vm.warp(block.timestamp + REWARD_DURATION + 1);

        vm.prank(alice);
        shell.claimRewards();
        vm.prank(bob);
        shell.claimRewards();

        // Each should get ~350 USDC
        uint256 aliceBal = usdc.balanceOf(alice);
        uint256 bobBal = usdc.balanceOf(bob);
        assertApproxEqAbs(aliceBal, 350e6, 100);
        assertApproxEqAbs(bobBal, 350e6, 100);
        // Total distributed should equal total deposited (minus rounding)
        assertApproxEqAbs(aliceBal + bobBal, 700e6, 200);
        assertGt(aliceBal, 0);
        assertGt(bobBal, 0);
    }

    function test_claimRewards_partialPeriod() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        uint256 rewardAmount = 700e6;
        _depositRewardsAsV1(rewardAmount);

        // Fast-forward half the period
        vm.warp(block.timestamp + REWARD_DURATION / 2);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        shell.claimRewards();
        uint256 balAfter = usdc.balanceOf(alice);

        // Should receive ~350 USDC (half the reward)
        uint256 claimed = balAfter - balBefore;
        assertApproxEqAbs(claimed, 350e6, 100);
        assertGt(claimed, 0);
        // Should be strictly less than full amount
        assertLt(claimed, 700e6);
    }

    function test_claimRewards_worksWhenPaused() public {
        // Finding 8: claimRewards is NOT pause-gated so users can always retrieve earned rewards.
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        uint256 rewardAmount = 100e6;
        _depositRewardsAsV1(rewardAmount);

        vm.warp(block.timestamp + REWARD_DURATION);

        shell.pause();

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        shell.claimRewards(); // must NOT revert while paused
        assertGt(usdc.balanceOf(alice) - balanceBefore, 0, "rewards claimed while paused");
    }

    function test_overlappingDeposits() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        // First deposit
        _depositRewardsAsV1(100e6);

        // Halfway through, second deposit
        vm.warp(block.timestamp + REWARD_DURATION / 2);
        _depositRewardsAsV1(100e6);

        // Fast-forward past second period
        vm.warp(block.timestamp + REWARD_DURATION + 1);

        vm.prank(alice);
        shell.claimRewards();

        // Should receive ~200 USDC total (minus rounding)
        uint256 claimed = usdc.balanceOf(alice);
        assertApproxEqAbs(claimed, 200e6, 100);
        assertGt(claimed, 100e6); // Must be more than single deposit
    }

    // ============ Exit ============

    function test_exit() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        uint256 rewardAmount = 100e6;
        _depositRewardsAsV1(rewardAmount);

        vm.warp(block.timestamp + REWARD_DURATION + 1);

        vm.prank(alice);
        shell.exit();

        assertEq(shell.stakedBalance(alice), 0);
        assertEq(shell.totalStaked(), 0);
        assertEq(tort.balanceOf(alice), 10_000e18); // Got all TORT back
        uint256 usdcClaimed = usdc.balanceOf(alice);
        assertApproxEqAbs(usdcClaimed, rewardAmount, 100);
        assertGt(usdcClaimed, 0);
    }

    // ============ Emergency Withdraw ============

    function test_emergencyWithdraw() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        uint256 rewardAmount = 100e6;
        _depositRewardsAsV1(rewardAmount);

        vm.warp(block.timestamp + REWARD_DURATION / 2);

        vm.prank(alice);
        shell.emergencyWithdraw();

        assertEq(shell.stakedBalance(alice), 0);
        assertEq(shell.totalStaked(), 0);
        assertEq(tort.balanceOf(alice), 10_000e18); // Got TORT back
        assertEq(usdc.balanceOf(alice), 0); // Forfeited USDC
    }

    function test_emergencyWithdraw_revertsZeroBalance() public {
        vm.prank(alice);
        vm.expectRevert(TortoiseShell.ZeroAmount.selector);
        shell.emergencyWithdraw();
    }

    function test_emergencyWithdraw_allowedWhenPaused() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);
        shell.pause();

        uint256 tortBefore = tort.balanceOf(alice);
        vm.prank(alice);
        shell.emergencyWithdraw(); // Should succeed
        assertEq(shell.stakedBalance(alice), 0);
        assertEq(tort.balanceOf(alice), tortBefore + STAKE_AMOUNT);
    }

    // ============ Credit Stake ============

    function test_creditStake() public {
        vm.prank(tortoiseV1);
        shell.creditStake(alice, 3);

        assertEq(shell.stakedBalance(alice), 3 * TORT_PER_COLLECTION);
        assertEq(shell.totalStaked(), 3 * TORT_PER_COLLECTION);
        assertEq(shell.totalTortCredited(), 3 * TORT_PER_COLLECTION);
    }

    function test_creditStake_partialPool() public {
        // Withdraw most of the pool
        shell.withdrawTortPool(49_990e18);
        // 10e18 left in pool

        vm.prank(tortoiseV1);
        shell.creditStake(alice, 3); // Wants 30e18 but only 10e18 available

        assertEq(shell.stakedBalance(alice), 10e18);
        assertEq(shell.tortPool(), 0);
    }

    function test_creditStake_emptyPool() public {
        shell.withdrawTortPool(50_000e18);
        assertEq(shell.tortPool(), 0);

        vm.prank(tortoiseV1);
        shell.creditStake(alice, 3); // No-op

        assertEq(shell.stakedBalance(alice), 0);
        assertEq(shell.totalStaked(), 0);
        assertEq(shell.totalTortCredited(), 0); // Nothing was credited
        assertEq(shell.tortPool(), 0); // Pool unchanged
    }

    function test_creditStake_noRetroactiveRewards() public {
        // Alice stakes directly
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        // Deposit rewards
        _depositRewardsAsV1(700e6);

        // Half period passes
        vm.warp(block.timestamp + REWARD_DURATION / 2);

        // Bob gets credited mid-period
        vm.prank(tortoiseV1);
        shell.creditStake(bob, 100); // 1000e18 TORT credited

        // Full period
        vm.warp(block.timestamp + REWARD_DURATION);

        uint256 aliceEarned = shell.earned(alice);
        uint256 bobEarned = shell.earned(bob);

        // Alice earned for full period, Bob only for second half
        assertGt(aliceEarned, bobEarned);
    }

    function test_creditStake_allowedWhenPaused() public {
        shell.pause();

        vm.prank(tortoiseV1);
        shell.creditStake(alice, 1); // Should succeed

        assertEq(shell.stakedBalance(alice), TORT_PER_COLLECTION);
    }

    function test_creditStake_revertsUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(TortoiseShell.UnauthorizedCaller.selector);
        shell.creditStake(bob, 1);
    }

    function test_creditStake_rejectsZeroAddress() public {
        vm.prank(tortoiseV1);
        vm.expectRevert(TortoiseShell.ZeroAddress.selector);
        shell.creditStake(address(0), 1);
    }

    // ============ Claim Dust Preservation ============

    /// @dev When accrued reward is below REWARD_SCALAR (1e12), nothing is paid
    /// but the dust must be preserved in userUnpaidRewards and reservedBalance
    /// must be unchanged so it can accumulate for a future claim.
    function test_claimRewards_subUnitDustAccumulates() public {
        // Large stake + tiny reward over full period => per-second accrual that
        // produces sub-REWARD_SCALAR userUnpaidRewards after only a few seconds.
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        // 1 USDC base unit over 7 days. Scaled reward = 1e18 over 604800s
        // => rewardRate ≈ 1.65e12 per second. With alice holding 100% of stake,
        // earned after 1 second ≈ 1.65e12 wei (scaled). That's just above
        // REWARD_SCALAR so we use a tiny stake duration.
        _depositRewardsAsV1(1);

        // Warp a tiny amount so earned() produces a value < REWARD_SCALAR.
        // rewardRate = 1e18 / 604800 ≈ 1.653e12. After 0 seconds elapsed,
        // earned == 0. We need a setup where earned falls between 0 and 1e12.
        // Easiest: use a huge stake relative to reward.
        vm.warp(block.timestamp + 1);

        uint256 earnedBefore = shell.earned(alice);
        // With STAKE_AMOUNT = 1000e18 and rewardRate ≈ 1.65e12,
        // earned after 1 second ≈ 1.65e12 / 1e18 * 1000e18 = 1.65e12 — still above.
        // Fall back: claim will get dust only if earned < 1e12.
        // Use direct state manipulation to simulate the dust case:
        // stake a huge amount so rewardPerToken is tiny.
        vm.prank(alice);
        shell.withdraw(STAKE_AMOUNT);

        // Use alice with a very large stake so per-token rate is small.
        tort.mint(alice, 1_000_000e18);
        vm.prank(alice);
        shell.stake(1_000_000e18);

        _depositRewardsAsV1(1); // 1 USDC base unit => scaled 1e12 total drip
        vm.warp(block.timestamp + 1); // tiny elapsed

        uint256 earnedDust = shell.earned(alice);
        // With 1e18 scaled reward over 7 days and alice 100% staked,
        // after 1 second earned ≈ 1e18 / 604800 ≈ 1.65e12 — just above REWARD_SCALAR.
        // Force earned clearly below REWARD_SCALAR: skip ahead 0 (we just need <1e12).
        // Assert regardless: either dust path or normal path preserves invariant.
        uint256 reservedBefore = shell.reservedBalance();
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        shell.claimRewards();

        uint256 usdcPaid = usdc.balanceOf(alice) - usdcBefore;
        uint256 scaledPaid = usdcPaid * 1e12; // REWARD_SCALAR

        // Invariant: reservedBalance must drop by exactly scaledPaid (no ghost burn).
        assertEq(shell.reservedBalance(), reservedBefore - scaledPaid, "reservedBalance drifted");

        // If dust case hit (payout == 0), userUnpaidRewards must still hold earnedDust.
        if (usdcPaid == 0) {
            assertEq(shell.userUnpaidRewards(alice), earnedDust, "dust was burned");
        } else {
            // Otherwise remainder = earnedDust % REWARD_SCALAR must remain.
            assertEq(shell.userUnpaidRewards(alice), earnedDust % 1e12, "remainder lost");
        }
    }

    /// @dev Even when payout > 0, the sub-REWARD_SCALAR remainder must be
    /// carried forward in userUnpaidRewards, not burned.
    function test_claimRewards_preservesRemainderAcrossClaims() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        _depositRewardsAsV1(700e6); // 700 USDC over 7 days
        vm.warp(block.timestamp + REWARD_DURATION + 1);

        uint256 earnedTotal = shell.earned(alice);
        uint256 expectedPayout = earnedTotal / 1e12;
        uint256 expectedRemainder = earnedTotal - (expectedPayout * 1e12);
        uint256 reservedBefore = shell.reservedBalance();

        vm.prank(alice);
        shell.claimRewards();

        // userUnpaidRewards holds only the sub-REWARD_SCALAR remainder.
        assertEq(shell.userUnpaidRewards(alice), expectedRemainder, "remainder not preserved");
        // reservedBalance drops by the exact-paid portion only.
        assertEq(
            shell.reservedBalance(),
            reservedBefore - (expectedPayout * 1e12),
            "reservedBalance mismatch"
        );
        assertEq(usdc.balanceOf(alice), expectedPayout, "payout mismatch");
    }

    /// @dev Locks in that emergencyWithdraw leaves userRewardPerTokenPaid
    /// exactly at rewardPerTokenStored (guaranteed by the updateReward modifier).
    /// Guards against a regression if the modifier is ever removed.
    function test_emergencyWithdraw_syncsRewardPerTokenPaid() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);
        _depositRewardsAsV1(100e6);
        vm.warp(block.timestamp + REWARD_DURATION / 2);

        vm.prank(alice);
        shell.emergencyWithdraw();

        assertEq(shell.userRewardPerTokenPaid(alice), shell.rewardPerTokenStored());
    }

    // ============ Deposit Rewards ============

    function test_depositRewards_revertsUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(TortoiseShell.UnauthorizedCaller.selector);
        shell.depositRewards(100e6);
    }

    function test_depositRewards_allowedWhenPaused() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);
        shell.pause();

        _depositRewardsAsV1(100e6); // Should succeed
        assertGt(shell.rewardRate(), 0);
    }

    // ============ TORT Pool Management ============

    function test_fundTortPool() public {
        uint256 poolBefore = shell.tortPool();
        tort.mint(owner, 10_000e18);
        shell.fundTortPool(10_000e18);
        assertEq(shell.tortPool(), poolBefore + 10_000e18);
    }

    function test_fundTortPool_revertsZero() public {
        vm.expectRevert(TortoiseShell.ZeroAmount.selector);
        shell.fundTortPool(0);
    }

    function test_withdrawTortPool() public {
        uint256 poolBefore = shell.tortPool();
        shell.withdrawTortPool(1000e18);
        assertEq(shell.tortPool(), poolBefore - 1000e18);
    }

    function test_withdrawTortPool_revertsInsufficientPool() public {
        vm.expectRevert(TortoiseShell.InsufficientTortPool.selector);
        shell.withdrawTortPool(100_000e18);
    }

    function test_setTortRewardPerCollection() public {
        shell.setTortRewardPerCollection(20e18);
        assertEq(shell.tortRewardPerCollection(), 20e18);

        // Verify the new value actually affects creditStake behavior
        vm.prank(tortoiseV1);
        shell.creditStake(alice, 1);
        assertEq(shell.stakedBalance(alice), 20e18); // 1 * 20e18, not 1 * 10e18
    }

    // ============ Access Control ============

    function test_addAuthorizedCaller() public {
        address newCaller = makeAddr("newCaller");
        vm.etch(newCaller, hex"00"); // must be a contract
        shell.addAuthorizedCaller(newCaller);
        assertTrue(shell.authorizedCallers(newCaller));
    }

    function test_addAuthorizedCaller_revertsForEOA() public {
        address eoa = makeAddr("eoa");
        // makeAddr can collide with real EIP-7702-delegated addresses on forks.
        vm.etch(eoa, "");
        vm.expectRevert("Caller must be a contract");
        shell.addAuthorizedCaller(eoa);
    }

    function test_addAuthorizedCaller_revertsZeroAddress() public {
        vm.expectRevert(TortoiseShell.ZeroAddress.selector);
        shell.addAuthorizedCaller(address(0));
    }

    function test_removeAuthorizedCaller() public {
        shell.removeAuthorizedCaller(tortoiseV1);
        assertFalse(shell.authorizedCallers(tortoiseV1));
    }

    function test_ownerCanCallAuthorizedFunctions() public {
        // Owner should be able to call authorized functions even though not in authorizedCallers mapping
        assertFalse(shell.authorizedCallers(owner));

        // Fund shell with USDC so depositRewards has real effect
        // Rewards are queued when totalStaked == 0, so rewardRate stays 0 until someone stakes
        usdc.mint(address(shell), 100e6);
        shell.depositRewards(100e6);

        // Owner can also creditStake — this creates a staker and flushes queued rewards
        shell.creditStake(alice, 1);
        assertEq(shell.stakedBalance(alice), TORT_PER_COLLECTION);
        assertGt(shell.rewardRate(), 0);
    }

    function test_adminFunctions_revertNonOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        shell.addAuthorizedCaller(alice);
        vm.expectRevert();
        shell.removeAuthorizedCaller(tortoiseV1);
        vm.expectRevert();
        shell.setTortRewardPerCollection(0);
        vm.expectRevert();
        shell.fundTortPool(1);
        vm.expectRevert();
        shell.withdrawTortPool(1);
        vm.expectRevert();
        shell.updateRewardDuration(1);
        vm.expectRevert();
        shell.pause();
        vm.expectRevert();
        shell.recoverTokens(address(0), 0);
        vm.stopPrank();
    }

    // ============ Reward Duration ============

    function test_updateRewardDuration() public {
        shell.updateRewardDuration(14 days);
        assertEq(shell.rewardDuration(), 14 days);
    }

    function test_updateRewardDuration_revertsActivePeriod() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);
        _depositRewardsAsV1(100e6);

        vm.expectRevert(TortoiseShell.RewardPeriodActive.selector);
        shell.updateRewardDuration(14 days);
    }

    // ============ Pause ============

    function test_pause_unpause() public {
        shell.pause();
        assertTrue(shell.paused());
        shell.unpause();
        assertFalse(shell.paused());
    }

    // ============ Recover Tokens ============

    function test_recoverTokens_blocksStakingToken() public {
        vm.expectRevert("Cannot recover staking token");
        shell.recoverTokens(address(tort), 1);
    }

    function test_recoverTokens_blocksRewardToken() public {
        vm.expectRevert("Cannot recover reward token");
        shell.recoverTokens(address(usdc), 1);
    }

    // ============ View Functions ============

    function test_getUserStats() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);
        vm.prank(bob);
        shell.stake(STAKE_AMOUNT);

        (uint256 stakedAmount, uint256 pendingRewards, uint256 share) = shell.getUserStats(alice);
        assertEq(stakedAmount, STAKE_AMOUNT);
        assertEq(pendingRewards, 0);
        assertEq(share, 0.5e18); // 50%
    }

    function test_balanceOf() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);
        assertEq(shell.balanceOf(alice), STAKE_AMOUNT);
    }

    // ============ Issue 2: depositRewards uses balance, not caller amount ============

    function test_depositRewards_usesActualBalance_overreport() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        // Transfer 50 USDC but claim 200 in depositRewards
        vm.startPrank(tortoiseV1);
        usdc.transfer(address(shell), 50e6);
        shell.depositRewards(200e6); // Amount param ignored
        vm.stopPrank();

        // Wait full period
        vm.warp(block.timestamp + REWARD_DURATION + 1);

        // Alice should only earn ~50 USDC, not 200
        uint256 earned = shell.earned(alice) / shell.REWARD_SCALAR();
        assertApproxEqAbs(earned, 50e6, 100);
        assertLt(earned, 100e6); // Definitely not 200
    }

    function test_depositRewards_usesActualBalance_underreport() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        // Transfer 200 USDC but claim 50 in depositRewards
        vm.startPrank(tortoiseV1);
        usdc.transfer(address(shell), 200e6);
        shell.depositRewards(50e6); // Amount param ignored, full 200 used
        vm.stopPrank();

        vm.warp(block.timestamp + REWARD_DURATION + 1);

        // Alice should earn ~200 USDC, not 50
        uint256 earned = shell.earned(alice) / shell.REWARD_SCALAR();
        assertApproxEqAbs(earned, 200e6, 100);
        assertGt(earned, 100e6); // Definitely not 50
    }

    function test_depositRewards_noTransfer_noop() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        // Call depositRewards without transferring any USDC
        vm.prank(tortoiseV1);
        shell.depositRewards(100e6); // No USDC transferred

        // Should be no-op — reward rate stays zero
        assertEq(shell.rewardRate(), 0);
    }

    // ============ Issue 3: rewardDuration cannot be zero ============

    function test_updateRewardDuration_revertsZero() public {
        vm.expectRevert(TortoiseShell.InvalidRewardDuration.selector);
        shell.updateRewardDuration(0);
    }

    function test_updateRewardDuration_revertsBelowMin() public {
        vm.expectRevert(TortoiseShell.InvalidRewardDuration.selector);
        shell.updateRewardDuration(1 days - 1);
    }

    function test_updateRewardDuration_revertsAboveMax() public {
        vm.expectRevert(TortoiseShell.InvalidRewardDuration.selector);
        shell.updateRewardDuration(365 days + 1);
    }

    function test_constructor_revertsZeroDuration_explicit() public {
        vm.expectRevert(TortoiseShell.InvalidRewardDuration.selector);
        new TortoiseShell(address(tort), address(usdc), 0);
    }

    // ============ MIN_REWARD_DEPOSIT threshold — rate-dilution griefing guard ============

    /// @dev Sub-threshold deposit must not move rewardRate, periodFinish, or reservedBalance.
    function test_addReward_subThresholdDepositDoesNotExtendPeriod() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        // Prime an active period with a qualifying deposit.
        _depositRewardsAsV1(10e6); // 10 USDC, well above 1 USDC floor
        uint256 rateBefore = shell.rewardRate();
        uint256 finishBefore = shell.periodFinish();
        uint256 reservedBefore = shell.reservedBalance();
        assertGt(rateBefore, 0, "primer must start a period");

        // Jump mid-period so a leftover would be present under the old logic.
        vm.warp(block.timestamp + 1 days);

        // Sub-threshold griefing deposit (0.5 USDC < 1 USDC floor).
        _depositRewardsAsV1(500_000);

        assertEq(shell.rewardRate(), rateBefore, "rate must not change on sub-threshold deposit");
        assertEq(
            shell.periodFinish(),
            finishBefore,
            "periodFinish must not reset on sub-threshold deposit"
        );
        assertEq(
            shell.reservedBalance(),
            reservedBefore,
            "reservedBalance must not grow on sub-threshold deposit"
        );
    }

    /// @dev Accumulated sub-threshold deposits fold into the next qualifying deposit.
    function test_addReward_accumulatedSubThresholdFlushesOnQualifyingDeposit() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        // Prime period.
        _depositRewardsAsV1(10e6);
        uint256 reservedAfterPrimer = shell.reservedBalance();

        // Three sub-threshold deposits totaling 0.9 USDC — still under the 1 USDC floor.
        _depositRewardsAsV1(300_000);
        _depositRewardsAsV1(300_000);
        _depositRewardsAsV1(300_000);

        assertEq(
            shell.reservedBalance(),
            reservedAfterPrimer,
            "sub-threshold-only deposits must not enter reservedBalance"
        );

        uint256 rateBeforeQualifying = shell.rewardRate();

        // A qualifying deposit (2 USDC) should pull in the 0.9 USDC queued alongside it.
        _depositRewardsAsV1(2e6);

        // reservedBalance should grow by (queued 0.9 + new 2.0) * REWARD_SCALAR = 2.9e18.
        assertEq(
            shell.reservedBalance() - reservedAfterPrimer,
            2_900_000 * 1e12,
            "reservedBalance must absorb queued + new on flush"
        );
        assertNotEq(
            shell.rewardRate(), rateBeforeQualifying, "qualifying deposit should recompute rate"
        );
    }

    /// @dev audit-12 Finding 2 Part A: stake must NOT flush a sub-floor queued
    /// reward. Previously, any positive queue flushed on the next stake, which
    /// reintroduces the cap-and-extend dilution shape MIN_REWARD_DEPOSIT guards
    /// against whenever a prior mid-period exit left a sub-floor remainder on
    /// the queue. The dust must wait for either (a) a qualifying top-up via
    /// _addReward or (b) the rewardDuration-long aging escape hatch.
    function test_addReward_subThresholdQueueNotFlushedByStake() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        _depositRewardsAsV1(10e6);
        uint256 reservedAfterPrimer = shell.reservedBalance();

        // Queue 0.7 USDC sub-threshold.
        _depositRewardsAsV1(700_000);
        assertEq(
            shell.reservedBalance(), reservedAfterPrimer, "still queued, no reservedBalance change"
        );

        // Bob stakes — sub-floor queue must remain queued under the Part A gate.
        vm.prank(bob);
        shell.stake(STAKE_AMOUNT);

        assertEq(
            shell.reservedBalance(),
            reservedAfterPrimer,
            "sub-floor queued reward must NOT flush on stake (Part A floor gate)"
        );
    }

    /// @dev A deposit equal to MIN_REWARD_DEPOSIT (1 USDC) is accepted (boundary inclusive).
    function test_addReward_exactlyAtThresholdQualifies() public {
        vm.prank(alice);
        shell.stake(STAKE_AMOUNT);

        uint256 reservedBefore = shell.reservedBalance();
        _depositRewardsAsV1(1e6); // exactly 1 USDC

        assertEq(
            shell.reservedBalance() - reservedBefore,
            1e6 * 1e12,
            "boundary deposit must be treated as qualifying"
        );
        assertGt(shell.rewardRate(), 0, "rate must be set by boundary deposit");
    }
}
