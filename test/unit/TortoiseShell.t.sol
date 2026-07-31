// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockTORT} from "../mocks/MockTORT.sol";

contract TortoiseShellTest is Test {
    TortoiseShell internal shell;
    MockUSDC internal usdc;
    MockTORT internal tort;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal caller = makeAddr("authorizedCaller");

    uint256 internal constant REWARD_DURATION = 7 days;
    uint256 internal constant STAKE_AMOUNT = 1_000e18;

    function setUp() public {
        usdc = new MockUSDC();
        tort = new MockTORT();
        shell = new TortoiseShell(address(tort), address(usdc), REWARD_DURATION);

        vm.etch(caller, hex"00");
        shell.addAuthorizedCaller(caller);

        tort.mint(alice, 10_000e18);
        tort.mint(bob, 10_000e18);
        usdc.mint(caller, 1_000_000e6);

        vm.prank(alice);
        tort.approve(address(shell), type(uint256).max);
        vm.prank(bob);
        tort.approve(address(shell), type(uint256).max);
    }

    function _stake(address user, uint256 amount) internal {
        vm.prank(user);
        shell.stake(amount);
    }

    function _deposit(uint256 amount) internal {
        vm.startPrank(caller);
        assertTrue(usdc.transfer(address(shell), amount));
        shell.depositRewards(amount);
        vm.stopPrank();
    }

    function test_stakeAndWithdrawMaintainsAccounting() public {
        _stake(alice, STAKE_AMOUNT);
        assertEq(shell.stakedBalance(alice), STAKE_AMOUNT);
        assertEq(shell.totalStaked(), STAKE_AMOUNT);

        vm.prank(alice);
        shell.withdraw(STAKE_AMOUNT);
        assertEq(shell.stakedBalance(alice), 0);
        assertEq(shell.totalStaked(), 0);
        assertEq(tort.balanceOf(alice), 10_000e18);
    }

    function test_stakeRevertsWhenPaused() public {
        shell.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        shell.stake(STAKE_AMOUNT);
    }

    function test_depositRewardsRequiresAuthorizedCaller() public {
        vm.prank(alice);
        vm.expectRevert(TortoiseShell.UnauthorizedCaller.selector);
        shell.depositRewards(100e6);
    }

    function test_depositRewardsUsesActualBalance() public {
        _stake(alice, STAKE_AMOUNT);

        vm.startPrank(caller);
        assertTrue(usdc.transfer(address(shell), 50e6));
        shell.depositRewards(200e6);
        vm.stopPrank();

        vm.warp(block.timestamp + REWARD_DURATION);
        assertApproxEqAbs(shell.earned(alice) / shell.REWARD_SCALAR(), 50e6, 2);
    }

    function test_claimRewardsPaysCompletedDrip() public {
        _stake(alice, STAKE_AMOUNT);
        _deposit(100e6);
        vm.warp(block.timestamp + REWARD_DURATION);

        vm.prank(alice);
        shell.claimRewards();

        assertApproxEqAbs(usdc.balanceOf(alice), 100e6, 2);
        assertApproxEqAbs(shell.totalRewardsDeposited(), 0, 2);
    }

    function test_rewardsDepositedWithoutStakersFlushOnFirstStake() public {
        _deposit(100e6);
        assertEq(shell.rewardRate(), 0);

        _stake(alice, STAKE_AMOUNT);
        assertGt(shell.rewardRate(), 0);

        vm.warp(block.timestamp + REWARD_DURATION);
        assertApproxEqAbs(shell.earned(alice) / shell.REWARD_SCALAR(), 100e6, 2);
    }

    function test_emergencyWithdrawRecyclesForfeitedRewardsToRemainingStaker() public {
        _stake(alice, STAKE_AMOUNT);
        _stake(bob, STAKE_AMOUNT);
        _deposit(100e6);
        vm.warp(block.timestamp + REWARD_DURATION / 2);

        uint256 forfeited = shell.earned(alice);
        uint256 remaining = (shell.periodFinish() - block.timestamp) * shell.rewardRate();

        vm.prank(alice);
        shell.emergencyWithdraw();

        assertEq(shell.userUnpaidRewards(alice), 0);
        assertEq(shell.rewardRate(), (forfeited + remaining) / REWARD_DURATION);

        vm.warp(block.timestamp + REWARD_DURATION);
        assertApproxEqAbs(shell.earned(bob) / shell.REWARD_SCALAR(), 100e6, 3);
    }

    function test_lastEmergencyWithdrawQueuesAllRewardsForNextStaker() public {
        _stake(alice, STAKE_AMOUNT);
        _deposit(100e6);
        vm.warp(block.timestamp + REWARD_DURATION / 2);

        vm.prank(alice);
        shell.emergencyWithdraw();
        assertEq(shell.rewardRate(), 0);

        _stake(bob, STAKE_AMOUNT);
        assertGt(shell.rewardRate(), 0);

        vm.warp(block.timestamp + REWARD_DURATION);
        assertApproxEqAbs(shell.earned(bob) / shell.REWARD_SCALAR(), 100e6, 3);
    }

    function test_creditStakeCapsAtAvailablePool() public {
        tort.mint(address(this), 5e18);
        tort.approve(address(shell), 5e18);
        shell.fundTortPool(5e18);
        shell.setTortRewardPerCollection(3e18);

        vm.prank(caller);
        uint256 credited = shell.creditStake(alice, 2);

        assertEq(credited, 5e18);
        assertEq(shell.stakedBalance(alice), 5e18);
        assertEq(shell.tortPool(), 0);
    }
}
