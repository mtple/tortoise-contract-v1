// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test, Vm, console} from "forge-std/Test.sol";
import {TortoiseV1} from "../../src/TortoiseV1.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {SplitRecipient} from "../../src/libraries/SplitLib.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockTORT} from "../mocks/MockTORT.sol";

contract MintToShellTest is Test {
    TortoiseV1 public tortoise;
    TortoiseShell public shell;
    MockUSDC public usdc;
    MockTORT public tort;

    address public owner = address(this);
    address public artist = makeAddr("artist");
    address public buyer1 = makeAddr("buyer1");
    address public buyer2 = makeAddr("buyer2");
    address public staker = makeAddr("staker");

    uint64 constant PLATFORM_FEE = 50_000;
    uint64 constant STAKING_FEE = 100_000;
    uint128 constant DEFAULT_PRICE = 850_000;
    uint256 constant TORT_PER_COLLECTION = 10e18;
    uint256 constant REWARD_DURATION = 604_800;

    function setUp() public {
        usdc = new MockUSDC();
        tort = new MockTORT();

        shell = new TortoiseShell(address(tort), address(usdc), REWARD_DURATION);
        tortoise = new TortoiseV1(
            address(usdc), PLATFORM_FEE, DEFAULT_PRICE, address(shell), STAKING_FEE
        );

        shell.addAuthorizedCaller(address(tortoise));
        shell.setTortRewardPerCollection(TORT_PER_COLLECTION);

        // Fund TORT pool
        tort.mint(owner, 100_000e18);
        tort.approve(address(shell), type(uint256).max);
        shell.fundTortPool(50_000e18);

        // Fund staker
        tort.mint(staker, 10_000e18);
        vm.prank(staker);
        tort.approve(address(shell), type(uint256).max);

        // Fund buyers
        usdc.mint(buyer1, 10_000e6);
        usdc.mint(buyer2, 10_000e6);
        vm.prank(buyer1);
        usdc.approve(address(tortoise), type(uint256).max);
        vm.prank(buyer2);
        usdc.approve(address(tortoise), type(uint256).max);
    }

    function test_fullMintToShellFlow() public {
        // 1. Staker stakes TORT
        vm.prank(staker);
        shell.stake(5_000e18);

        // 2. Artist creates song
        vm.prank(artist);
        uint256 songId = tortoise.createSong("Integration Song", 0, 0, "ipfs://test");

        // 3. Buyer1 mints — triggers staking fee deposit + TORT credit
        vm.prank(buyer1);
        tortoise.mintSong(songId, 1, buyer1);

        // Verify: buyer1 got NFT
        assertEq(tortoise.balanceOf(buyer1, songId), 1);

        // Verify: buyer1 got TORT credited
        assertEq(shell.stakedBalance(buyer1), TORT_PER_COLLECTION);

        // Verify: shell received staking fee
        assertGt(shell.rewardRate(), 0);

        // 4. Time passes
        vm.warp(block.timestamp + REWARD_DURATION + 1);

        // 5. Staker claims USDC rewards
        uint256 stakerUsdcBefore = usdc.balanceOf(staker);
        vm.prank(staker);
        shell.claimRewards();

        // Staker should have received some USDC (staking fee dripped over 7 days)
        assertGt(usdc.balanceOf(staker), stakerUsdcBefore);

        // Buyer1 should also have earned some USDC (they got TORT credited mid-period)
        uint256 buyer1Earned = shell.earned(buyer1);
        assertGt(buyer1Earned, 0);
    }

    function test_multipleMints_compoundRewards() public {
        vm.prank(staker);
        shell.stake(5_000e18);

        vm.prank(artist);
        uint256 songId = tortoise.createSong("Song", 0, 0, "ipfs://test");

        // Multiple mints over time
        vm.prank(buyer1);
        tortoise.mintSong(songId, 1, buyer1);

        vm.warp(block.timestamp + 1 days);

        vm.prank(buyer2);
        tortoise.mintSong(songId, 3, buyer2);

        vm.warp(block.timestamp + 1 days);

        vm.prank(buyer1);
        tortoise.mintSong(songId, 2, buyer1);

        // Both buyers and staker should have accumulated rewards
        vm.warp(block.timestamp + REWARD_DURATION);

        assertGt(shell.earned(staker), 0);
        assertGt(shell.earned(buyer1), 0);
        assertGt(shell.earned(buyer2), 0);
    }

    function test_fullAccounting_noUsdcUnaccounted() public {
        vm.prank(staker);
        shell.stake(1_000e18);

        vm.prank(artist);
        uint256 songId = tortoise.createSong("Song", 1_000_000, 0, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(artist, 6000);
        splits[1] = SplitRecipient(makeAddr("collab"), 4000);
        vm.prank(artist);
        tortoise.configureSplits(songId, splits);

        uint256 buyer1Before = usdc.balanceOf(buyer1);

        vm.prank(buyer1);
        tortoise.mintSong(songId, 2, buyer1);

        uint256 totalCost = buyer1Before - usdc.balanceOf(buyer1);
        uint256 platformHeld = usdc.balanceOf(address(tortoise)); // Held in contract
        uint256 artistGot = usdc.balanceOf(artist);
        uint256 collabGot = usdc.balanceOf(makeAddr("collab"));
        uint256 shellGot = usdc.balanceOf(address(shell));

        // Total cost should equal sum of all distributions
        assertEq(totalCost, platformHeld + artistGot + collabGot + shellGot);

        // Platform fee held in contract — scales with quantity (qty=2 here)
        assertEq(platformHeld, PLATFORM_FEE * 2);
    }

    /// @dev With pool exhausted, the sufficiency gate fails and _creditShell is never
    /// called — neither StakeCredited nor ShellCreditFailed fires (audit-9 finding #1).
    /// Mint still completes; buyer gets the NFT; pool remains untouched.
    function test_shellCreditFailure_mintStillSucceeds() public {
        // Drain the TORT pool
        shell.withdrawTortPool(50_000e18);
        assertEq(shell.tortPool(), 0);

        vm.prank(artist);
        uint256 songId = tortoise.createSong("Song", 0, 0, "ipfs://test");

        vm.recordLogs();
        vm.prank(buyer1);
        tortoise.mintSong(songId, 1, buyer1);

        // No credit events should fire — _creditShell is gated on feeForwarded.
        bytes32 creditedTopic = keccak256("StakeCredited(uint256,address,uint256,uint256)");
        bytes32 failedTopic = keccak256("ShellCreditFailed(uint256,address,uint256,bytes)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], creditedTopic, "StakeCredited must not fire");
            assertNotEq(logs[i].topics[0], failedTopic, "ShellCreditFailed must not fire");
        }

        assertEq(tortoise.balanceOf(buyer1, songId), 1);
        assertEq(shell.stakedBalance(buyer1), 0);
        assertEq(shell.tortPool(), 0);
        assertEq(shell.totalTortCredited(), 0);
    }

    function test_collectAndStake_flywheel() public {
        // Staker stakes TORT directly
        vm.prank(staker);
        shell.stake(1_000e18);

        vm.prank(artist);
        uint256 songId = tortoise.createSong("Song", 0, 0, "ipfs://test");

        // Buyer1 collects — gets TORT credited into shell
        vm.prank(buyer1);
        tortoise.mintSong(songId, 5, buyer1);

        // Buyer1's TORT in shell
        uint256 buyer1Staked = shell.stakedBalance(buyer1);
        assertEq(buyer1Staked, 5 * TORT_PER_COLLECTION);

        // Time passes, buyer1 earns USDC from their credited TORT
        vm.warp(block.timestamp + REWARD_DURATION + 1);

        uint256 buyer1Earned = shell.earned(buyer1);
        assertGt(buyer1Earned, 0);

        // Buyer1 claims USDC
        vm.prank(buyer1);
        shell.claimRewards();
        assertGt(usdc.balanceOf(buyer1), 10_000e6 - tortoise.calculateTotalCost(songId, 5));
    }
}
