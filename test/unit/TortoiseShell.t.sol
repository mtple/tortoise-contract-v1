// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {MockTORT} from "../mocks/MockTORT.sol";

/// @notice Authorized caller that forwards ETH into the shell via depositRewards.
contract Depositor {
    TortoiseShell internal shell;

    constructor(TortoiseShell _shell) {
        shell = _shell;
    }

    function deposit() external payable {
        shell.depositRewards{value: msg.value}();
    }
}

contract TortoiseShellETHTest is Test {
    TortoiseShell internal shell;
    MockTORT internal tort;
    Depositor internal depositor;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant DURATION = 7 days;

    function setUp() public {
        tort = new MockTORT();
        shell = new TortoiseShell(address(tort), DURATION);
        depositor = new Depositor(shell);
        shell.addAuthorizedCaller(address(depositor));

        tort.mint(alice, 1_000e18);
        tort.mint(bob, 1_000e18);
        vm.prank(alice);
        tort.approve(address(shell), type(uint256).max);
        vm.prank(bob);
        tort.approve(address(shell), type(uint256).max);
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        shell.stake(amount);
    }

    function _deposit(uint256 amount) internal {
        vm.deal(address(this), amount);
        depositor.deposit{value: amount}();
    }

    function test_stakeAndAccrueEthRewards() public {
        _stake(alice, 100e18);
        _deposit(7 ether); // 1 ETH/day over 7 days
        vm.warp(block.timestamp + DURATION);

        uint256 earned = shell.earned(alice);
        assertApproxEqAbs(earned, 7 ether, 1e13, "alice earns full period");
    }

    function test_claimRewardsPaysEth() public {
        _stake(alice, 100e18);
        _deposit(7 ether);
        vm.warp(block.timestamp + DURATION);

        uint256 before = alice.balance;
        vm.prank(alice);
        shell.claimRewards();
        assertApproxEqAbs(alice.balance - before, 7 ether, 1e13, "paid in ETH");
    }

    function test_proportionalSplit() public {
        _stake(alice, 100e18);
        _stake(bob, 300e18);
        _deposit(8 ether);
        vm.warp(block.timestamp + DURATION);

        // alice 25%, bob 75%
        assertApproxEqAbs(shell.earned(alice), 2 ether, 1e13);
        assertApproxEqAbs(shell.earned(bob), 6 ether, 1e13);
    }

    function test_depositReconcilesFromBalance() public {
        _stake(alice, 100e18);
        _deposit(7 ether);
        assertEq(shell.totalRewardsDeposited(), 7 ether);
    }

    function test_receiveRejectsUnauthorized() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(shell).call{value: 1 ether}("");
        assertFalse(ok, "plain send from unauthorized rejected");
    }

    function test_creditStakeCapsToPool() public {
        tort.mint(address(this), 500e18);
        tort.approve(address(shell), type(uint256).max);
        shell.fundTortPool(500e18);
        shell.setTortRewardPerCollection(1_000e18); // request exceeds pool
        shell.addAuthorizedCaller(address(this));

        uint256 credited = shell.creditStake(alice, 1);
        assertEq(credited, 500e18, "capped to pool, never reverts");
        assertEq(shell.getTortPoolBalance(), 0);
    }

    function test_creditStakeReturnsZeroWhenPoolEmpty() public {
        shell.setTortRewardPerCollection(1_000e18);
        shell.addAuthorizedCaller(address(this));
        assertEq(shell.creditStake(alice, 1), 0);
    }

    function test_renounceOwnershipDisabled() public {
        vm.expectRevert(TortoiseShell.RenouncingOwnershipDisabled.selector);
        shell.renounceOwnership();
    }

    function test_recoverStakingTokenReverts() public {
        vm.expectRevert(TortoiseShell.CannotRecoverStakingToken.selector);
        shell.recoverTokens(address(tort), 1);
    }

    function test_depositRevertsUnauthorized() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(TortoiseShell.UnauthorizedCaller.selector);
        shell.depositRewards{value: 1 ether}();
    }
}
