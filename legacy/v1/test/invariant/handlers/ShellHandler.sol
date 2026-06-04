// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseShell} from "../../../src/TortoiseShell.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {MockTORT} from "../../mocks/MockTORT.sol";

contract ShellHandler is Test {
    TortoiseShell public shell;
    MockUSDC public usdc;
    MockTORT public tort;

    address[] public stakers;
    address public caller;
    address public owner;

    uint256 public totalTortFunded;

    // Track stakers for invariant checks
    mapping(address => bool) public isStaker;
    address[] public allStakers;

    constructor(
        TortoiseShell _shell,
        MockUSDC _usdc,
        MockTORT _tort,
        address _caller,
        address _owner
    ) {
        shell = _shell;
        usdc = _usdc;
        tort = _tort;
        caller = _caller;
        owner = _owner;

        for (uint256 i = 0; i < 5; i++) {
            address s = address(uint160(0xD000 + i));
            stakers.push(s);
            tort.mint(s, 1_000_000_000e18);
            vm.prank(s);
            tort.approve(address(shell), type(uint256).max);
        }
    }

    function stake(uint256 stakerSeed, uint256 amount) external {
        address staker = stakers[stakerSeed % stakers.length];
        amount = bound(amount, 1e18, 10_000e18);

        if (!isStaker[staker]) {
            isStaker[staker] = true;
            allStakers.push(staker);
        }

        vm.prank(staker);
        try shell.stake(amount) {} catch {}
    }

    function withdraw(uint256 stakerSeed, uint256 amount) external {
        address staker = stakers[stakerSeed % stakers.length];
        uint256 balance = shell.stakedBalance(staker);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(staker);
        try shell.withdraw(amount) {} catch {}
    }

    function depositRewards(uint256 amount) external {
        // Lower bound = 1 base unit to exercise sub-REWARD_SCALAR dust path.
        amount = bound(amount, 1, 100_000e6);

        vm.startPrank(caller);
        usdc.transfer(address(shell), amount);
        shell.depositRewards(amount);
        vm.stopPrank();
    }

    function creditStake(uint256 stakerSeed, uint256 quantity) external {
        address staker = stakers[stakerSeed % stakers.length];
        quantity = bound(quantity, 1, 10);

        if (!isStaker[staker]) {
            isStaker[staker] = true;
            allStakers.push(staker);
        }

        vm.prank(caller);
        try shell.creditStake(staker, quantity) {} catch {}
    }

    function claimRewards(uint256 stakerSeed) external {
        address staker = stakers[stakerSeed % stakers.length];

        vm.prank(staker);
        try shell.claimRewards() {} catch {}
    }

    function emergencyWithdraw(uint256 stakerSeed) external {
        address staker = stakers[stakerSeed % stakers.length];
        if (shell.stakedBalance(staker) == 0) return;

        vm.prank(staker);
        try shell.emergencyWithdraw() {} catch {}
    }

    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 7 days);
        vm.warp(block.timestamp + seconds_);
    }

    // ----- Phase B: admin / owner surface -----

    /// @dev Pause/unpause toggle. Invariants must hold across both states.
    /// fundTortPool / withdrawTortPool are intentionally NOT exposed here:
    /// the existing invariant_tortPoolAccountingConsistent asserts against
    /// a fixed totalTortFunded captured at setUp, and adding mid-run funding
    /// would require widening that ghost — out of Phase B's scope budget.
    function togglePause(uint256 seed) external {
        vm.prank(owner);
        if (seed % 2 == 0) {
            try shell.pause() {} catch {}
        } else {
            try shell.unpause() {} catch {}
        }
    }

    function getStakerCount() external view returns (uint256) {
        return allStakers.length;
    }

    function getStakerAt(uint256 index) external view returns (address) {
        return allStakers[index];
    }
}
