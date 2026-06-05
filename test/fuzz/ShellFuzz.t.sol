// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {MockTORT} from "../mocks/MockTORT.sol";

contract ShellFuzzTest is Test {
    TortoiseShell internal shell;
    MockTORT internal tort;
    address internal alice = makeAddr("alice");

    function setUp() public {
        tort = new MockTORT();
        shell = new TortoiseShell(address(tort), 7 days);
        shell.addAuthorizedCaller(address(this)); // test contract relays deposits
    }

    function testFuzz_stakeWithdraw(uint256 a, uint256 b) public {
        a = bound(a, 1, 1e30);
        b = bound(b, 1, a);
        tort.mint(alice, a);
        vm.startPrank(alice);
        tort.approve(address(shell), a);
        shell.stake(a);
        assertEq(shell.stakedBalance(alice), a);
        assertEq(shell.totalStaked(), a);
        shell.withdraw(b);
        vm.stopPrank();
        assertEq(shell.stakedBalance(alice), a - b);
        assertEq(shell.totalStaked(), a - b);
    }

    /// @notice After a deposit + full-period claim, the shell never pays more ETH than was
    ///         deposited and stays solvent (balance == accounted rewards).
    function testFuzz_depositClaimSolvency(uint256 amt) public {
        amt = bound(amt, 1e15, 1e24); // >= MIN_REWARD_DEPOSIT
        tort.mint(alice, 1e18);
        vm.startPrank(alice);
        tort.approve(address(shell), 1e18);
        shell.stake(1e18);
        vm.stopPrank();

        vm.deal(address(this), amt);
        shell.depositRewards{value: amt}();
        assertEq(address(shell).balance, shell.totalRewardsDeposited(), "solvent after deposit");

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        shell.claimRewards();

        assertEq(address(shell).balance, shell.totalRewardsDeposited(), "solvent after claim");
        assertLe(alice.balance, amt, "never paid more than deposited");
    }
}
