// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {TortoiseV1} from "../../src/TortoiseV1.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {SplitRecipient} from "../../src/libraries/SplitLib.sol";
import {SplitLib} from "../../src/libraries/SplitLib.sol";
import {Song, ContractConfig} from "../../src/interfaces/ITortoiseV1.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockTORT} from "../mocks/MockTORT.sol";

contract TortoiseV1Test is Test {
    TortoiseV1 public tortoise;
    TortoiseShell public shell;
    MockUSDC public usdc;
    MockTORT public tort;

    address public owner = address(this);
    address public artist = makeAddr("artist");
    address public buyer = makeAddr("buyer");
    address public collab1 = makeAddr("collab1");
    address public collab2 = makeAddr("collab2");

    uint128 public constant PLATFORM_FEE = 50_000; // $0.05
    uint128 public constant STAKING_FEE = 100_000; // $0.10
    uint128 public constant DEFAULT_PRICE = 850_000; // $0.85
    uint256 public constant TORT_PER_COLLECTION = 10e18;

    function setUp() public {
        usdc = new MockUSDC();
        tort = new MockTORT();

        shell = new TortoiseShell(address(tort), address(usdc), 604_800);

        tortoise = new TortoiseV1(
            address(usdc),
            PLATFORM_FEE,
            DEFAULT_PRICE,
            address(shell),
            STAKING_FEE
        );

        // Register tortoise as authorized caller on shell
        shell.addAuthorizedCaller(address(tortoise));
        shell.setTortRewardPerCollection(TORT_PER_COLLECTION);

        // Fund TORT pool
        tort.mint(owner, 100_000e18);
        tort.approve(address(shell), type(uint256).max);
        shell.fundTortPool(50_000e18);

        // Fund buyer with USDC
        usdc.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdc.approve(address(tortoise), type(uint256).max);
    }

    // ============ Constructor ============

    function test_constructor() public view {
        ContractConfig memory cfg = tortoise.getConfig();
        assertEq(cfg.defaultSongPrice, DEFAULT_PRICE);
        assertEq(cfg.platformFee, PLATFORM_FEE);
        assertEq(cfg.stakingFee, STAKING_FEE);
        assertEq(cfg.usdcToken, address(usdc));
        assertEq(cfg.tortoiseShell, address(shell));
    }

    function test_constructor_defaultValues() public {
        TortoiseV1 t = new TortoiseV1(
            address(usdc), 0, 0, address(0), 0
        );
        ContractConfig memory cfg = t.getConfig();
        assertEq(cfg.defaultSongPrice, 850_000);
        assertEq(cfg.platformFee, 50_000);
        assertEq(cfg.stakingFee, 0);
    }

    function test_constructor_revertsInvalidUsdc() public {
        vm.expectRevert("Invalid USDC address");
        new TortoiseV1(address(0), PLATFORM_FEE, DEFAULT_PRICE, address(shell), STAKING_FEE);
    }

    function test_constructor_revertsPlatformFeeTooHigh() public {
        vm.expectRevert("Platform fee exceeds maximum");
        new TortoiseV1(address(usdc), 2_000_000, DEFAULT_PRICE, address(shell), STAKING_FEE);
    }

    function test_constructor_revertsStakingFeeTooHigh() public {
        vm.expectRevert("Staking fee exceeds maximum");
        new TortoiseV1(address(usdc), PLATFORM_FEE, DEFAULT_PRICE, address(shell), 2_000_000);
    }

    function test_constructor_revertsStakingFeeWithoutShell() public {
        vm.expectRevert("No shell configured");
        new TortoiseV1(address(usdc), PLATFORM_FEE, DEFAULT_PRICE, address(0), STAKING_FEE);
    }

    function test_constructor_allowsZeroStakingFeeWithoutShell() public {
        TortoiseV1 t = new TortoiseV1(address(usdc), PLATFORM_FEE, DEFAULT_PRICE, address(0), 0);
        ContractConfig memory cfg = t.getConfig();
        assertEq(cfg.tortoiseShell, address(0));
        assertEq(cfg.stakingFee, 0);
    }

    function test_nameAndSymbol() public view {
        assertEq(tortoise.name(), "Tortoise");
        assertEq(tortoise.symbol(), "TORT");
    }

    // ============ Song Creation ============

    function test_createSong() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        assertEq(songId, 0);
        Song memory song = tortoise.getSongDetails(songId);
        assertEq(song.title, "My Song");
        assertEq(song.artist, artist);
        assertEq(song.price, DEFAULT_PRICE);
        assertEq(song.maxSupply, 0);
        assertEq(song.currentSupply, 0);
        assertTrue(song.exists);
        assertFalse(song.splitsLocked);
    }

    function test_createSong_customPrice() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 2_000_000, 100, "ipfs://hash");

        Song memory song = tortoise.getSongDetails(songId);
        assertEq(song.price, 2_000_000);
        assertEq(song.maxSupply, 100);
    }

    function test_createSong_revertsEmptyTitle() public {
        vm.prank(artist);
        vm.expectRevert("Title cannot be empty");
        tortoise.createSong("", 0, 0, "ipfs://hash");
    }

    function test_createSong_revertsEmptyUri() public {
        vm.prank(artist);
        vm.expectRevert("URI cannot be empty");
        tortoise.createSong("My Song", 0, 0, "");
    }

    function test_createSong_revertsWhenPaused() public {
        tortoise.pause();
        vm.prank(artist);
        vm.expectRevert();
        tortoise.createSong("My Song", 0, 0, "ipfs://hash");
    }

    function test_createSong_incrementsSongId() public {
        vm.startPrank(artist);
        uint256 id0 = tortoise.createSong("Song 0", 0, 0, "ipfs://0");
        uint256 id1 = tortoise.createSong("Song 1", 0, 0, "ipfs://1");
        vm.stopPrank();
        assertEq(id0, 0);
        assertEq(id1, 1);
    }

    function test_getArtistSongs() public {
        vm.startPrank(artist);
        tortoise.createSong("Song 0", 0, 0, "ipfs://0");
        tortoise.createSong("Song 1", 0, 0, "ipfs://1");
        vm.stopPrank();

        uint256[] memory songs_ = tortoise.getArtistSongs(artist);
        assertEq(songs_.length, 2);
        assertEq(songs_[0], 0);
        assertEq(songs_[1], 1);
    }

    function test_uri() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://myhash");
        assertEq(tortoise.uri(songId), "ipfs://myhash");
    }

    function test_uri_revertsNonexistent() public {
        vm.expectRevert("Song does not exist");
        tortoise.uri(999);
    }

    // ============ Splits ============

    function test_configureSplits() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(artist, 7000);
        splits[1] = SplitRecipient(collab1, 3000);

        vm.prank(artist);
        tortoise.configureSplits(songId, splits);

        SplitRecipient[] memory stored = tortoise.getSongSplits(songId);
        assertEq(stored.length, 2);
        assertEq(stored[0].recipient, artist);
        assertEq(stored[0].percentage, 7000);
        assertEq(stored[1].recipient, collab1);
        assertEq(stored[1].percentage, 3000);
    }

    function test_configureSplits_revertsNonArtist() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(artist, 10_000);

        vm.prank(buyer);
        vm.expectRevert("Only artist can configure splits");
        tortoise.configureSplits(songId, splits);
    }

    function test_configureSplits_revertsInvalidTotal() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(artist, 5000);

        vm.prank(artist);
        vm.expectRevert(SplitLib.InvalidSplitTotal.selector);
        tortoise.configureSplits(songId, splits);
    }

    function test_configureSplits_revertsDuplicate() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(artist, 5000);
        splits[1] = SplitRecipient(artist, 5000);

        vm.prank(artist);
        vm.expectRevert(SplitLib.DuplicateRecipient.selector);
        tortoise.configureSplits(songId, splits);
    }

    function test_configureSplits_revertsZeroAddress() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(address(0), 10_000);

        vm.prank(artist);
        vm.expectRevert(SplitLib.ZeroAddressRecipient.selector);
        tortoise.configureSplits(songId, splits);
    }

    function test_configureSplits_revertsBelowMinimum() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(artist, 9950);
        splits[1] = SplitRecipient(collab1, 50); // below 100 min

        vm.prank(artist);
        vm.expectRevert(SplitLib.PercentageBelowMinimum.selector);
        tortoise.configureSplits(songId, splits);
    }

    function test_configureSplits_revertsTooMany() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        SplitRecipient[] memory splits = new SplitRecipient[](11);
        for (uint256 i = 0; i < 11; i++) {
            splits[i] = SplitRecipient(address(uint160(i + 1)), 909);
        }

        vm.prank(artist);
        vm.expectRevert(SplitLib.TooManySplits.selector);
        tortoise.configureSplits(songId, splits);
    }

    function test_lockSplits() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(artist, 10_000);

        vm.prank(artist);
        tortoise.configureSplits(songId, splits);

        vm.prank(artist);
        tortoise.lockSplits(songId);

        Song memory song = tortoise.getSongDetails(songId);
        assertTrue(song.splitsLocked);
    }

    function test_lockSplits_revertsReconfigure() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(artist, 10_000);

        vm.startPrank(artist);
        tortoise.configureSplits(songId, splits);
        tortoise.lockSplits(songId);

        vm.expectRevert("Splits are locked");
        tortoise.configureSplits(songId, splits);
        vm.stopPrank();
    }

    function test_lockSplits_revertsReLock() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        vm.startPrank(artist);
        tortoise.lockSplits(songId);

        vm.expectRevert("Already locked");
        tortoise.lockSplits(songId);
        vm.stopPrank();
    }

    // ============ Minting ============

    function test_mintSong_noSplits() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        uint256 totalCost = tortoise.calculateTotalCost(songId, 1);
        assertEq(totalCost, DEFAULT_PRICE + PLATFORM_FEE + STAKING_FEE);

        uint256 artistBalBefore = usdc.balanceOf(artist);

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        // Check balances
        assertEq(usdc.balanceOf(address(tortoise)), PLATFORM_FEE); // Fee held in contract
        assertEq(usdc.balanceOf(artist) - artistBalBefore, DEFAULT_PRICE);
        assertEq(tortoise.balanceOf(buyer, songId), 1);

        Song memory song = tortoise.getSongDetails(songId);
        assertEq(song.currentSupply, 1);
    }

    function test_mintSong_multiQuantity() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        uint256 totalCost = tortoise.calculateTotalCost(songId, 5);
        assertEq(totalCost, (uint256(DEFAULT_PRICE) * 5) + PLATFORM_FEE + STAKING_FEE);

        vm.prank(buyer);
        tortoise.mintSong(songId, 5, buyer);

        assertEq(tortoise.balanceOf(buyer, songId), 5);
    }

    function test_mintSong_withSplits() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 1_000_000, 0, "ipfs://hash");

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(artist, 7000);
        splits[1] = SplitRecipient(collab1, 3000);

        vm.prank(artist);
        tortoise.configureSplits(songId, splits);

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        uint256 artistRevenue = 1_000_000; // price * 1
        assertEq(usdc.balanceOf(artist), (artistRevenue * 7000) / 10_000);
        // collab1 gets remainder
        assertEq(usdc.balanceOf(collab1), artistRevenue - (artistRevenue * 7000) / 10_000);
    }

    function test_mintSong_toRecipient() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        address recipient = makeAddr("recipient");

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, recipient);

        assertEq(tortoise.balanceOf(recipient, songId), 1);
        assertEq(tortoise.balanceOf(buyer, songId), 0);
    }

    function test_mintSong_zeroRecipientDefaultsToSender() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, address(0));

        assertEq(tortoise.balanceOf(buyer, songId), 1);
    }

    function test_mintSong_revertsNonexistentSong() public {
        vm.prank(buyer);
        vm.expectRevert("Song does not exist");
        tortoise.mintSong(999, 1, buyer);
    }

    function test_mintSong_revertsZeroQuantity() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        vm.prank(buyer);
        vm.expectRevert("Quantity must be positive");
        tortoise.mintSong(songId, 0, buyer);
    }

    function test_mintSong_revertsExceedsMaxSupply() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 5, "ipfs://hash");

        vm.prank(buyer);
        vm.expectRevert("Would exceed max supply");
        tortoise.mintSong(songId, 6, buyer);
    }

    function test_mintSong_revertsExceedsMaxMintQuantity() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        vm.prank(buyer);
        vm.expectRevert("Exceeds max mint quantity");
        tortoise.mintSong(songId, 100_001, buyer);
    }

    function test_mintSong_revertsWhenPaused() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");
        tortoise.pause();

        vm.prank(buyer);
        vm.expectRevert();
        tortoise.mintSong(songId, 1, buyer);
    }

    // ============ Shell Integration ============

    function test_mintSong_creditsShellTort() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        vm.prank(buyer);
        tortoise.mintSong(songId, 3, buyer);

        // Buyer should have 3 * TORT_PER_COLLECTION staked in shell
        assertEq(shell.stakedBalance(buyer), 3 * TORT_PER_COLLECTION);
    }

    function test_mintSong_depositsStakingFee() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        uint256 shellUsdcBefore = usdc.balanceOf(address(shell));

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        // Shell should have received exactly the staking fee
        assertEq(usdc.balanceOf(address(shell)), shellUsdcBefore + STAKING_FEE);
        assertGt(shell.rewardRate(), 0);
        // ReservedBalance should track the deposited amount (scaled)
        assertEq(shell.reservedBalance(), uint256(STAKING_FEE) * shell.REWARD_SCALAR());
    }

    function test_mintSong_noShellConfigured() public {
        // Deploy without shell
        TortoiseV1 noShell = new TortoiseV1(
            address(usdc), PLATFORM_FEE, DEFAULT_PRICE, address(0), 0
        );

        vm.prank(artist);
        uint256 songId = noShell.createSong("My Song", 0, 0, "ipfs://hash");

        usdc.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdc.approve(address(noShell), type(uint256).max);

        uint256 artistBefore = usdc.balanceOf(artist);
        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(buyer);
        noShell.mintSong(songId, 1, buyer);

        assertEq(noShell.balanceOf(buyer, songId), 1);
        // Verify payments (no staking fee with no shell)
        assertEq(usdc.balanceOf(artist) - artistBefore, DEFAULT_PRICE);
        assertEq(buyerBefore - usdc.balanceOf(buyer), uint256(DEFAULT_PRICE) + PLATFORM_FEE);
        // Platform fee held in contract
        assertEq(usdc.balanceOf(address(noShell)), PLATFORM_FEE);
    }

    function test_mintSong_platformFeeHeldInContract() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 0, 0, "ipfs://hash");

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        // Platform fee should be held in contract
        assertEq(usdc.balanceOf(address(tortoise)), PLATFORM_FEE);
    }

    // ============ Admin Functions ============

    function test_updatePlatformFee() public {
        tortoise.updatePlatformFee(100_000);
        ContractConfig memory cfg = tortoise.getConfig();
        assertEq(cfg.platformFee, 100_000);
    }

    function test_updatePlatformFee_revertsTooHigh() public {
        vm.expectRevert("Fee exceeds maximum");
        tortoise.updatePlatformFee(2_000_000);
    }

    function test_updateStakingFee() public {
        tortoise.updateStakingFee(100_000);
        ContractConfig memory cfg = tortoise.getConfig();
        assertEq(cfg.stakingFee, 100_000);

        // Verify the new fee affects calculateTotalCost
        vm.prank(artist);
        uint256 songId = tortoise.createSong("Fee Test", 0, 0, "ipfs://hash");
        assertEq(
            tortoise.calculateTotalCost(songId, 1),
            uint256(DEFAULT_PRICE) + PLATFORM_FEE + 100_000
        );
    }

    function test_updateStakingFee_revertsTooHigh() public {
        vm.expectRevert("Fee exceeds maximum");
        tortoise.updateStakingFee(2_000_000);
    }

    function test_updateTortoiseShell() public {
        address newShell = makeAddr("newShell");
        tortoise.updateTortoiseShell(newShell);
        ContractConfig memory cfg = tortoise.getConfig();
        assertEq(cfg.tortoiseShell, newShell);
    }

    function test_updateTortoiseShell_disablesIntegration() public {
        // Disable shell by setting to address(0)
        tortoise.updateTortoiseShell(address(0));

        // Verify config actually changed — shell zeroed and staking fee auto-zeroed
        ContractConfig memory cfg = tortoise.getConfig();
        assertEq(cfg.tortoiseShell, address(0));
        assertEq(cfg.stakingFee, 0);

        vm.prank(artist);
        uint256 songId = tortoise.createSong("No Shell", 0, 0, "ipfs://hash");

        // Buyer pays only artist revenue + platform fee (no staking fee)
        uint256 expectedCost = uint256(DEFAULT_PRICE) + PLATFORM_FEE;
        assertEq(tortoise.calculateTotalCost(songId, 1), expectedCost);

        uint256 shellUsdcBefore = usdc.balanceOf(address(shell));
        uint256 shellStakedBefore = shell.totalStaked();

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        assertEq(tortoise.balanceOf(buyer, songId), 1);
        // Shell should NOT have received staking fee (no shell configured)
        assertEq(usdc.balanceOf(address(shell)), shellUsdcBefore);
        // Shell should NOT have credited any TORT
        assertEq(shell.totalStaked(), shellStakedBefore);
        assertEq(shell.stakedBalance(buyer), 0);
    }

    function test_updateDefaultPrice() public {
        tortoise.updateDefaultPrice(2_000_000);
        ContractConfig memory cfg = tortoise.getConfig();
        assertEq(cfg.defaultSongPrice, 2_000_000);
    }

    function test_updateDefaultPrice_revertsZero() public {
        vm.expectRevert("Price must be positive");
        tortoise.updateDefaultPrice(0);
    }

    function test_withdrawPlatformFees() public {
        // Mint to accumulate platform fees
        vm.prank(artist);
        uint256 songId = tortoise.createSong("Fee Song", 0, 0, "ipfs://fee");
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        assertEq(usdc.balanceOf(address(tortoise)), PLATFORM_FEE);

        uint256 ownerBefore = usdc.balanceOf(owner);
        tortoise.withdrawPlatformFees();

        assertEq(usdc.balanceOf(address(tortoise)), 0);
        assertEq(usdc.balanceOf(owner) - ownerBefore, PLATFORM_FEE);
    }

    function test_withdrawPlatformFees_revertsNoFees() public {
        vm.expectRevert("No fees to withdraw");
        tortoise.withdrawPlatformFees();
    }

    function test_withdrawPlatformFees_accumulates() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("Fee Song", 0, 0, "ipfs://fee");

        // Mint 3 times
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        // 3 platform fees accumulated
        assertEq(usdc.balanceOf(address(tortoise)), PLATFORM_FEE * 3);

        tortoise.withdrawPlatformFees();
        assertEq(usdc.balanceOf(address(tortoise)), 0);
    }

    function test_recoverTokens() public {
        MockTORT randomToken = new MockTORT();
        randomToken.mint(address(tortoise), 1000e18);

        tortoise.recoverTokens(address(randomToken), 1000e18);
        assertEq(randomToken.balanceOf(owner), 1000e18);
    }

    function test_recoverTokens_blocksUsdc() public {
        vm.expectRevert("Cannot recover USDC");
        tortoise.recoverTokens(address(usdc), 1);
    }

    function test_adminFunctions_revertNonOwner() public {
        vm.startPrank(buyer);
        vm.expectRevert();
        tortoise.updatePlatformFee(0);
        vm.expectRevert();
        tortoise.updateStakingFee(0);
        vm.expectRevert();
        tortoise.updateTortoiseShell(address(0));
        vm.expectRevert();
        tortoise.updateDefaultPrice(1);
        vm.expectRevert();
        tortoise.withdrawPlatformFees();
        vm.expectRevert();
        tortoise.pause();
        vm.expectRevert();
        tortoise.recoverTokens(address(tort), 0);
        vm.stopPrank();
    }

    // ============ Calculate Total Cost ============

    function test_calculateTotalCost() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("My Song", 1_000_000, 0, "ipfs://hash");

        assertEq(
            tortoise.calculateTotalCost(songId, 5),
            (1_000_000 * 5) + PLATFORM_FEE + STAKING_FEE
        );
    }

    function test_calculateTotalCost_revertsNonexistent() public {
        vm.expectRevert("Song does not exist");
        tortoise.calculateTotalCost(999, 1);
    }

    // ============ Issue 1: Shell disabled zeroes staking fee ============

    function test_disableShell_zerosStakingFee() public {
        // Staking fee is set in setUp
        assertGt(tortoise.getConfig().stakingFee, 0);

        // Disable shell
        tortoise.updateTortoiseShell(address(0));

        // Staking fee should be automatically zeroed
        assertEq(tortoise.getConfig().stakingFee, 0);
    }

    function test_updateStakingFee_revertsNoShell() public {
        // Disable shell first
        tortoise.updateTortoiseShell(address(0));

        // Try setting non-zero staking fee with no shell
        vm.expectRevert("No shell configured");
        tortoise.updateStakingFee(100_000);
    }

    function test_updateStakingFee_allowsZeroWithNoShell() public {
        tortoise.updateTortoiseShell(address(0));

        // Setting to zero should work even without shell
        tortoise.updateStakingFee(0);
        assertEq(tortoise.getConfig().stakingFee, 0);
    }

    function test_mintAfterShellDisabled_noStakingFee() public {
        vm.prank(artist);
        uint256 songId = tortoise.createSong("No Shell Song", 0, 0, "ipfs://hash");

        // Disable shell (auto-zeros staking fee)
        tortoise.updateTortoiseShell(address(0));

        uint256 artistBefore = usdc.balanceOf(artist);
        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        // Buyer pays only artist revenue + platform fee (no staking fee)
        uint256 buyerSpent = buyerBefore - usdc.balanceOf(buyer);
        assertEq(buyerSpent, uint256(DEFAULT_PRICE) + PLATFORM_FEE);

        // Artist gets full revenue (no staking fee subtracted)
        assertEq(usdc.balanceOf(artist) - artistBefore, DEFAULT_PRICE);
    }
}
