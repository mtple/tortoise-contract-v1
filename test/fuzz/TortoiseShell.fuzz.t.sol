// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockTORT} from "../mocks/MockTORT.sol";

contract TortoiseShellFuzzTest is Test {
    TortoiseShell public shell;
    MockUSDC public usdc;
    MockTORT public tort;

    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public caller = makeAddr("caller");

    uint256 constant REWARD_DURATION = 604_800;
    uint256 constant TORT_PER_COLLECTION = 777_777e18;

    function setUp() public {
        usdc = new MockUSDC();
        tort = new MockTORT();
        shell = new TortoiseShell(address(tort), address(usdc), REWARD_DURATION);

        shell.addAuthorizedCaller(caller);
        shell.setTortRewardPerCollection(TORT_PER_COLLECTION);

        // Fund TORT pool
        tort.mint(owner, 1_000_000_000e18);
        tort.approve(address(shell), type(uint256).max);
        shell.fundTortPool(500_000_000e18);

        // Fund users
        tort.mint(alice, 1_000_000_000e18);
        tort.mint(bob, 1_000_000_000e18);
        vm.prank(alice);
        tort.approve(address(shell), type(uint256).max);
        vm.prank(bob);
        tort.approve(address(shell), type(uint256).max);

        // Fund caller with USDC
        usdc.mint(caller, type(uint128).max);
        vm.prank(caller);
        usdc.approve(address(shell), type(uint256).max);
    }

    /// @dev Helper to deposit rewards (transfer + call)
    function _depositRewards(uint256 amount) internal {
        vm.startPrank(caller);
        usdc.transfer(address(shell), amount);
        shell.depositRewards(amount);
        vm.stopPrank();
    }

    /// @dev Fuzz: stake then withdraw same amount, balance returns to zero
    function testFuzz_stakeWithdraw_balanceConsistent(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000_000e18);

        vm.prank(alice);
        shell.stake(amount);

        assertEq(shell.stakedBalance(alice), amount);
        assertEq(shell.totalStaked(), amount);

        vm.prank(alice);
        shell.withdraw(amount);

        assertEq(shell.stakedBalance(alice), 0);
        assertEq(shell.totalStaked(), 0);
    }

    /// @dev Fuzz: two stakers, totalStaked == sum of balances
    function testFuzz_twoStakers_totalStakedConsistent(
        uint256 aliceAmount,
        uint256 bobAmount
    ) public {
        aliceAmount = bound(aliceAmount, 1, 500_000_000e18);
        bobAmount = bound(bobAmount, 1, 500_000_000e18);

        vm.prank(alice);
        shell.stake(aliceAmount);
        vm.prank(bob);
        shell.stake(bobAmount);

        assertEq(
            shell.totalStaked(),
            shell.stakedBalance(alice) + shell.stakedBalance(bob),
            "totalStaked != sum of balances"
        );
    }

    /// @dev Fuzz: creditStake never makes tortPool negative
    function testFuzz_creditStake_poolNeverNegative(uint256 quantity) public {
        quantity = bound(quantity, 1, 10_000);

        uint256 poolBefore = shell.tortPool();

        vm.prank(caller);
        shell.creditStake(alice, quantity);

        // Pool should never go negative (graceful degradation)
        assertLe(
            shell.stakedBalance(alice),
            poolBefore,
            "Credited more than pool had"
        );
        // tortPool + credited == original pool
        assertEq(
            shell.tortPool() + shell.totalTortCredited(),
            poolBefore,
            "Pool accounting broken"
        );
    }

    /// @dev Fuzz: creditStake totalStaked consistency
    function testFuzz_creditStake_totalStakedConsistent(
        uint256 aliceQty,
        uint256 bobQty
    ) public {
        aliceQty = bound(aliceQty, 0, 100);
        bobQty = bound(bobQty, 0, 100);

        vm.prank(caller);
        shell.creditStake(alice, aliceQty);
        vm.prank(caller);
        shell.creditStake(bob, bobQty);

        assertEq(
            shell.totalStaked(),
            shell.stakedBalance(alice) + shell.stakedBalance(bob),
            "totalStaked mismatch after credits"
        );
    }

    /// @dev Fuzz: deposit + full drip, claimable ~= deposited
    function testFuzz_rewardDrip_claimableApproxDeposited(uint256 rewardAmount) public {
        rewardAmount = bound(rewardAmount, 1e6, 1_000_000e6); // $1 to $1M

        vm.prank(alice);
        shell.stake(1_000e18);

        _depositRewards(rewardAmount);

        vm.warp(block.timestamp + REWARD_DURATION + 1);

        uint256 earned = shell.earned(alice);
        uint256 earnedUsdc = earned / shell.REWARD_SCALAR();

        // Should be within 1 USDC unit of deposited (rounding from integer division)
        assertApproxEqAbs(earnedUsdc, rewardAmount, 1, "Earned != deposited after full period");
    }

    /// @dev Fuzz: two stakers get proportional rewards
    function testFuzz_rewardDrip_proportional(
        uint256 aliceStake,
        uint256 bobStake,
        uint256 rewardAmount
    ) public {
        aliceStake = bound(aliceStake, 1e18, 1_000_000e18);
        bobStake = bound(bobStake, 1e18, 1_000_000e18);
        rewardAmount = bound(rewardAmount, 1_000e6, 1_000_000e6);

        vm.prank(alice);
        shell.stake(aliceStake);
        vm.prank(bob);
        shell.stake(bobStake);

        _depositRewards(rewardAmount);

        vm.warp(block.timestamp + REWARD_DURATION + 1);

        uint256 aliceEarned = shell.earned(alice) / shell.REWARD_SCALAR();
        uint256 bobEarned = shell.earned(bob) / shell.REWARD_SCALAR();

        // Total earned should approximate total deposited
        assertApproxEqAbs(
            aliceEarned + bobEarned,
            rewardAmount,
            2, // 2 USDC units tolerance for two divisions
            "Total earned != deposited"
        );

        // Proportionality: alice's share should be roughly aliceStake / totalStake
        if (aliceStake > bobStake) {
            assertGe(aliceEarned, bobEarned, "Larger staker earned less");
        } else if (bobStake > aliceStake) {
            assertGe(bobEarned, aliceEarned, "Larger staker earned less");
        }
    }

    /// @dev Fuzz: stake + credit + withdraw sequence, totalStaked stays consistent
    function testFuzz_mixedStakeCredit_totalStakedConsistent(
        uint256 stakeAmount,
        uint256 creditQty,
        uint256 withdrawAmount
    ) public {
        stakeAmount = bound(stakeAmount, 1e18, 100_000e18);
        creditQty = bound(creditQty, 0, 50);

        vm.prank(alice);
        shell.stake(stakeAmount);

        vm.prank(caller);
        shell.creditStake(alice, creditQty);

        uint256 totalBalance = shell.stakedBalance(alice);
        withdrawAmount = bound(withdrawAmount, 0, totalBalance);

        if (withdrawAmount > 0) {
            vm.prank(alice);
            shell.withdraw(withdrawAmount);
        }

        assertEq(
            shell.totalStaked(),
            shell.stakedBalance(alice),
            "totalStaked != stakedBalance after mixed ops"
        );
    }

    /// @dev Fuzz: emergency withdraw always returns all TORT, forfeits USDC
    function testFuzz_emergencyWithdraw_returnsAllTort(
        uint256 stakeAmount,
        uint256 rewardAmount
    ) public {
        stakeAmount = bound(stakeAmount, 1e18, 100_000e18);
        rewardAmount = bound(rewardAmount, 1e6, 1_000_000e6);

        vm.prank(alice);
        shell.stake(stakeAmount);

        _depositRewards(rewardAmount);
        vm.warp(block.timestamp + REWARD_DURATION / 2);

        uint256 tortBefore = tort.balanceOf(alice);

        vm.prank(alice);
        shell.emergencyWithdraw();

        assertEq(tort.balanceOf(alice), tortBefore + stakeAmount, "Didn't get TORT back");
        assertEq(shell.stakedBalance(alice), 0, "Balance not zeroed");
        assertEq(usdc.balanceOf(alice), 0, "Should have forfeited USDC");
    }

    /// @dev Fuzz: claim never burns dust — pre-earned must equal post-claim
    /// userUnpaidRewards plus scaled payout. Also verifies reservedBalance
    /// decreases by exactly the scaled-paid amount.
    function testFuzz_claimRewards_neverBurnsDust(
        uint256 stakeAmount,
        uint256 rewardAmount,
        uint256 elapsed
    ) public {
        stakeAmount = bound(stakeAmount, 1e18, 1_000_000_000e18);
        rewardAmount = bound(rewardAmount, 1, 1_000_000e6);
        elapsed = bound(elapsed, 1, REWARD_DURATION * 2);

        vm.prank(alice);
        shell.stake(stakeAmount);

        _depositRewards(rewardAmount);
        vm.warp(block.timestamp + elapsed);

        uint256 earnedBefore = shell.earned(alice);
        uint256 reservedBefore = shell.reservedBalance();
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        shell.claimRewards();

        uint256 paid = usdc.balanceOf(alice) - usdcBefore;
        uint256 scaledPaid = paid * 1e12; // REWARD_SCALAR

        // Full dust-preservation invariant: every scaled wei of earned rewards
        // is either paid out (scaledPaid) or carried forward (userUnpaidRewards).
        assertEq(
            shell.userUnpaidRewards(alice) + scaledPaid,
            earnedBefore,
            "dust burned on claim"
        );
        // reservedBalance drops by exactly the scaled-paid portion.
        assertEq(
            shell.reservedBalance(),
            reservedBefore - scaledPaid,
            "reservedBalance drifted"
        );
    }
}
