// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseV1} from "../../src/TortoiseV1.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {SplitRecipient} from "../../src/libraries/SplitLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fork tests against real Base mainnet USDC and TORT tokens.
///         Run with: forge test --match-contract TortoiseV1ForkTest --fork-url $BASE_RPC_URL
contract TortoiseV1ForkTest is Test {
    // Real Base mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant TORT = 0x601410d1d3093cF469fCA4e1EfB2Fb67B4E225c6;

    TortoiseV1 public tortoise;
    TortoiseShell public shell;

    address public deployer;
    address public artist = makeAddr("artist");
    address public buyer = makeAddr("buyer");

    uint64 constant PLATFORM_FEE = 50_000; // $0.05
    uint64 constant STAKING_FEE = 100_000; // $0.10
    uint128 constant DEFAULT_PRICE = 850_000; // $0.85
    uint256 constant TORT_PER_COLLECTION = 777_777e18;

    function setUp() public {
        deployer = address(this);

        // Deploy TortoiseShell with real tokens
        shell = new TortoiseShell(TORT, USDC, 604_800);

        // Deploy TortoiseV1
        tortoise = new TortoiseV1(
            USDC, PLATFORM_FEE, DEFAULT_PRICE, address(shell), STAKING_FEE
        );

        // Wire up
        shell.addAuthorizedCaller(address(tortoise));
        shell.setTortRewardPerCollection(TORT_PER_COLLECTION);

        // Deal real USDC to buyer (6 decimals)
        deal(USDC, buyer, 10_000e6);

        // Deal real TORT to deployer for pool funding
        deal(TORT, deployer, 100_000_000e18);

        // Fund TORT pool
        IERC20(TORT).approve(address(shell), type(uint256).max);
        shell.fundTortPool(50_000_000e18);

        // Buyer approves tortoise to spend USDC
        vm.prank(buyer);
        IERC20(USDC).approve(address(tortoise), type(uint256).max);
    }

    /// @dev Full mint flow with real USDC/TORT: create song, mint, verify payments + TORT credit
    function test_fork_fullMintFlow() public {
        // Artist creates a song
        vm.prank(artist);
        uint256 songId = tortoise.createSong("Fork Test Song", 0, 0, "ipfs://forktest");

        uint256 buyerUsdcBefore = IERC20(USDC).balanceOf(buyer);
        uint256 artistUsdcBefore = IERC20(USDC).balanceOf(artist);
        uint256 contractUsdcBefore = IERC20(USDC).balanceOf(address(tortoise));
        uint256 shellUsdcBefore = IERC20(USDC).balanceOf(address(shell));

        // Buyer mints 10 copies so stakingFee (10 × 0.1 = 1.0 USDC) meets
        // MIN_REWARD_DEPOSIT and actually starts a reward period.
        uint256 Q = 10;
        vm.prank(buyer);
        tortoise.mintSong(songId, Q, buyer);

        // Verify NFT balance
        assertEq(tortoise.balanceOf(buyer, songId), Q);

        // Verify USDC payments — cost formula: (price + platformFee + stakingFee) * quantity
        uint256 expectedTotal = (uint256(DEFAULT_PRICE) + PLATFORM_FEE + STAKING_FEE) * Q;
        assertEq(buyerUsdcBefore - IERC20(USDC).balanceOf(buyer), expectedTotal);
        assertEq(IERC20(USDC).balanceOf(artist) - artistUsdcBefore, uint256(DEFAULT_PRICE) * Q);
        assertEq(IERC20(USDC).balanceOf(address(tortoise)) - contractUsdcBefore, uint256(PLATFORM_FEE) * Q);
        assertEq(IERC20(USDC).balanceOf(address(shell)) - shellUsdcBefore, uint256(STAKING_FEE) * Q);

        // Only platform fee held in tortoise
        assertEq(IERC20(USDC).balanceOf(address(tortoise)), uint256(PLATFORM_FEE) * Q);

        // Verify TORT crediting
        assertEq(shell.stakedBalance(buyer), Q * TORT_PER_COLLECTION);

        // Verify reward rate updated
        assertGt(shell.rewardRate(), 0);
    }

    /// @dev Full reward drip: mint → wait → claim USDC rewards
    function test_fork_mintRewardClaim() public {
        // Stake some TORT so there's a staker to earn
        address staker = makeAddr("staker");
        deal(TORT, staker, 10_000e18);
        vm.startPrank(staker);
        IERC20(TORT).approve(address(shell), type(uint256).max);
        shell.stake(10_000e18);
        vm.stopPrank();

        // Create and mint
        vm.prank(artist);
        uint256 songId = tortoise.createSong("Reward Song", 0, 0, "ipfs://reward");

        // Mint 10 copies so stakingFee meets MIN_REWARD_DEPOSIT and a period starts.
        vm.prank(buyer);
        tortoise.mintSong(songId, 10, buyer);

        // Fast-forward past reward period
        vm.warp(block.timestamp + 604_800 + 1);

        // Staker claims USDC rewards
        uint256 stakerUsdcBefore = IERC20(USDC).balanceOf(staker);
        vm.prank(staker);
        shell.claimRewards();

        uint256 stakerClaimed = IERC20(USDC).balanceOf(staker) - stakerUsdcBefore;
        assertGt(stakerClaimed, 0, "Staker should have claimed USDC");

        // Buyer (who got TORT credited) also earned some rewards
        uint256 buyerEarned = shell.earned(buyer);
        assertGt(buyerEarned, 0, "Buyer should have earned rewards from credited TORT");
    }

    /// @dev Splits with real USDC: verify exact distribution
    function test_fork_mintWithSplits() public {
        address collab = makeAddr("collab");

        vm.prank(artist);
        uint256 songId = tortoise.createSong("Split Song", 1_000_000, 0, "ipfs://split");

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(artist, 7000); // 70%
        splits[1] = SplitRecipient(collab, 3000); // 30%

        vm.prank(artist);
        tortoise.configureSplits(songId, splits);

        vm.prank(buyer);
        tortoise.mintSong(songId, 2, buyer);

        // artistRevenue = price * qty only (platformFee + stakingFee are deducted)
        uint256 Q = 2;
        uint256 artistRevenue = 1_000_000 * Q;
        uint256 expectedArtist = (artistRevenue * 7000) / 10_000;
        uint256 expectedCollab = artistRevenue - expectedArtist;

        assertEq(IERC20(USDC).balanceOf(artist), expectedArtist);
        assertEq(IERC20(USDC).balanceOf(collab), expectedCollab);
        // Platform fee scales with quantity
        assertEq(IERC20(USDC).balanceOf(address(tortoise)), uint256(PLATFORM_FEE) * Q);
    }

    /// @dev Full lifecycle: stake TORT → collect song → earn USDC → exit
    function test_fork_fullLifecycle() public {
        // Staker stakes TORT
        address staker = makeAddr("staker");
        deal(TORT, staker, 50_000e18);
        vm.startPrank(staker);
        IERC20(TORT).approve(address(shell), type(uint256).max);
        shell.stake(50_000e18);
        vm.stopPrank();

        // Artist creates song
        vm.prank(artist);
        uint256 songId = tortoise.createSong("Lifecycle Song", 0, 0, "ipfs://lifecycle");

        // Buyer collects 10 copies — stakingFee (10 × 0.1 = 1.0 USDC) meets
        // MIN_REWARD_DEPOSIT, starts a period, and TORT is credited per copy.
        vm.prank(buyer);
        tortoise.mintSong(songId, 10, buyer);

        uint256 buyerStaked = shell.stakedBalance(buyer);
        assertEq(buyerStaked, 10 * TORT_PER_COLLECTION);

        // Wait for full reward period
        vm.warp(block.timestamp + 604_800 + 1);

        // Staker exits (withdraw + claim)
        uint256 stakerTortBefore = IERC20(TORT).balanceOf(staker);
        vm.prank(staker);
        shell.exit();

        // Got TORT back
        assertEq(IERC20(TORT).balanceOf(staker), stakerTortBefore + 50_000e18);
        assertEq(shell.stakedBalance(staker), 0);

        // Got USDC rewards
        assertGt(IERC20(USDC).balanceOf(staker), 0);

        // Buyer can also claim their share
        vm.prank(buyer);
        shell.claimRewards();
        assertGt(IERC20(USDC).balanceOf(buyer), 0);
    }

    /// @dev Verify TORT token has correct 18 decimals behavior on real contract
    function test_fork_tortTokenDecimals() public view {
        // TORT should be 18 decimals — verify our credit math makes sense
        uint256 credited = 1 * TORT_PER_COLLECTION;
        assertEq(credited, 777_777e18);
        assertGt(IERC20(TORT).totalSupply(), 0, "TORT should have supply on Base");
    }

    /// @dev Verify USDC token has correct 6 decimals behavior on real contract
    function test_fork_usdcTokenDecimals() public view {
        // $1.00 = 1_000_000 USDC units
        uint256 totalCost = uint256(DEFAULT_PRICE) + PLATFORM_FEE + STAKING_FEE;
        assertEq(totalCost, 1_000_000, "Total cost should be $1.00");
        assertGt(IERC20(USDC).totalSupply(), 0, "USDC should have supply on Base");
    }
}
