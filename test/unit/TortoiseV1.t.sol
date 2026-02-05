// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {TortoiseV1, Song, ContractConfig} from "../../src/TortoiseV1.sol";
import {SplitLib, SplitRecipient} from "../../src/libraries/SplitLib.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

contract TortoiseV1Test is Test {
    TortoiseV1 public tortoise;
    MockUSDC public usdc;

    address public owner = makeAddr("owner");
    address public platformFeeRecipient = makeAddr("platformFeeRecipient");
    address public artist1 = makeAddr("artist1");
    address public artist2 = makeAddr("artist2");
    address public producer = makeAddr("producer");
    address public songwriter = makeAddr("songwriter");
    address public buyer1 = makeAddr("buyer1");

    uint128 constant SONG_PRICE = 950_000; // $0.95 (artist revenue per copy)
    uint128 constant PLATFORM_FEE = 50_000; // $0.05 (flat per-transaction fee)
    // Single mint total: $0.95 + $0.05 = $1.00
    // Multi mint total: ($0.95 * qty) + $0.05

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy Tortoise
        vm.startPrank(owner);
        tortoise = new TortoiseV1(
            address(usdc),
            platformFeeRecipient,
            PLATFORM_FEE,
            SONG_PRICE
        );
        vm.stopPrank();

        // Fund test accounts with USDC
        usdc.mint(buyer1, 1_000_000_000); // $1000
    }

    // ============ Song Creation Tests ============

    function test_CreateSong_Success() public {
        vm.startPrank(artist1);

        uint256 songId = tortoise.createSong(
            "My First Song",
            SONG_PRICE,
            100,
            "ipfs://QmExample"
        );

        assertEq(songId, 0);

        Song memory song = tortoise.getSongDetails(0);
        assertEq(song.title, "My First Song");
        assertEq(song.artist, artist1);
        assertEq(song.price, SONG_PRICE);
        assertEq(song.maxSupply, 100);
        assertEq(song.currentSupply, 0);
        assertTrue(song.exists);
        assertFalse(song.splitsLocked);

        vm.stopPrank();
    }

    function test_CreateSong_UsesDefaultPrice() public {
        vm.startPrank(artist1);

        tortoise.createSong("Free Price Song", 0, 100, "ipfs://test");

        Song memory song = tortoise.getSongDetails(0);
        assertEq(song.price, SONG_PRICE); // Default $0.95

        vm.stopPrank();
    }

    function test_CreateSong_RevertWhen_EmptyTitle() public {
        vm.startPrank(artist1);
        vm.expectRevert(TortoiseV1.TitleCannotBeEmpty.selector);
        tortoise.createSong("", SONG_PRICE, 100, "ipfs://test");
        vm.stopPrank();
    }

    function test_CreateSong_RevertWhen_EmptyUri() public {
        vm.startPrank(artist1);
        vm.expectRevert(TortoiseV1.UriCannotBeEmpty.selector);
        tortoise.createSong("Test Song", SONG_PRICE, 100, "");
        vm.stopPrank();
    }

    // ============ Batch Song Creation Tests (Album Upload) ============

    function test_CreateSongs_Success() public {
        vm.startPrank(artist1);

        string[] memory titles = new string[](3);
        titles[0] = "Track 1";
        titles[1] = "Track 2";
        titles[2] = "Track 3";

        uint128[] memory prices = new uint128[](3);
        prices[0] = SONG_PRICE;
        prices[1] = 0; // Use default
        prices[2] = 1_500_000; // Custom $1.50

        uint128[] memory maxSupplies = new uint128[](3);
        maxSupplies[0] = 100;
        maxSupplies[1] = 0; // Unlimited
        maxSupplies[2] = 50;

        string[] memory uris = new string[](3);
        uris[0] = "ipfs://track1";
        uris[1] = "ipfs://track2";
        uris[2] = "ipfs://track3";

        uint256[] memory songIds = tortoise.createSongs(titles, prices, maxSupplies, uris);

        assertEq(songIds.length, 3);
        assertEq(songIds[0], 0);
        assertEq(songIds[1], 1);
        assertEq(songIds[2], 2);

        // Verify each song
        Song memory song0 = tortoise.getSongDetails(0);
        assertEq(song0.title, "Track 1");
        assertEq(song0.price, SONG_PRICE);
        assertEq(song0.maxSupply, 100);

        Song memory song1 = tortoise.getSongDetails(1);
        assertEq(song1.title, "Track 2");
        assertEq(song1.price, SONG_PRICE); // Default price applied
        assertEq(song1.maxSupply, 0);

        Song memory song2 = tortoise.getSongDetails(2);
        assertEq(song2.title, "Track 3");
        assertEq(song2.price, 1_500_000);
        assertEq(song2.maxSupply, 50);

        // All songs belong to artist1
        uint256[] memory artistSongIds = tortoise.getArtistSongs(artist1);
        assertEq(artistSongIds.length, 3);

        vm.stopPrank();
    }

    function test_CreateSongs_RevertWhen_ArrayLengthMismatch() public {
        vm.startPrank(artist1);

        string[] memory titles = new string[](2);
        titles[0] = "Track 1";
        titles[1] = "Track 2";

        uint128[] memory prices = new uint128[](3); // Mismatch!
        prices[0] = SONG_PRICE;
        prices[1] = SONG_PRICE;
        prices[2] = SONG_PRICE;

        uint128[] memory maxSupplies = new uint128[](2);
        string[] memory uris = new string[](2);
        uris[0] = "ipfs://1";
        uris[1] = "ipfs://2";

        vm.expectRevert(TortoiseV1.ArrayLengthMismatch.selector);
        tortoise.createSongs(titles, prices, maxSupplies, uris);

        vm.stopPrank();
    }

    function test_CreateSongs_RevertWhen_BatchTooLarge() public {
        vm.startPrank(artist1);

        uint256 batchSize = 51; // Exceeds MAX_BATCH_SIZE of 50

        string[] memory titles = new string[](batchSize);
        uint128[] memory prices = new uint128[](batchSize);
        uint128[] memory maxSupplies = new uint128[](batchSize);
        string[] memory uris = new string[](batchSize);

        for (uint256 i = 0; i < batchSize; i++) {
            titles[i] = "Track";
            prices[i] = SONG_PRICE;
            uris[i] = "ipfs://test";
        }

        vm.expectRevert(TortoiseV1.BatchTooLarge.selector);
        tortoise.createSongs(titles, prices, maxSupplies, uris);

        vm.stopPrank();
    }

    function test_CreateSongs_RevertWhen_EmptyTitleInBatch() public {
        vm.startPrank(artist1);

        string[] memory titles = new string[](2);
        titles[0] = "Track 1";
        titles[1] = ""; // Empty!

        uint128[] memory prices = new uint128[](2);
        uint128[] memory maxSupplies = new uint128[](2);
        string[] memory uris = new string[](2);
        uris[0] = "ipfs://1";
        uris[1] = "ipfs://2";

        vm.expectRevert(TortoiseV1.TitleCannotBeEmpty.selector);
        tortoise.createSongs(titles, prices, maxSupplies, uris);

        vm.stopPrank();
    }

    // ============ Split Configuration Tests ============

    function test_ConfigureSplits_Success() public {
        // Create song
        vm.startPrank(artist1);
        tortoise.createSong("Split Song", SONG_PRICE, 100, "ipfs://test");

        // Configure splits
        SplitRecipient[] memory splits = new SplitRecipient[](3);
        splits[0] = SplitRecipient(artist1, 7000); // 70%
        splits[1] = SplitRecipient(producer, 2000); // 20%
        splits[2] = SplitRecipient(songwriter, 1000); // 10%

        tortoise.configureSplits(0, splits);

        SplitRecipient[] memory storedSplits = tortoise.getSongSplits(0);
        assertEq(storedSplits.length, 3);
        assertEq(storedSplits[0].recipient, artist1);
        assertEq(storedSplits[0].percentage, 7000);

        vm.stopPrank();
    }

    function test_ConfigureSplits_RevertWhen_NotArtist() public {
        vm.prank(artist1);
        tortoise.createSong("Split Song", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(artist1, 10000);

        vm.prank(artist2);
        vm.expectRevert(TortoiseV1.OnlyArtistCanConfigureSplits.selector);
        tortoise.configureSplits(0, splits);
    }

    function test_ConfigureSplits_RevertWhen_InvalidTotal() public {
        vm.startPrank(artist1);
        tortoise.createSong("Split Song", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(artist1, 5000); // 50%
        splits[1] = SplitRecipient(producer, 4000); // 40% - total 90%

        vm.expectRevert(SplitLib.InvalidSplitTotal.selector);
        tortoise.configureSplits(0, splits);

        vm.stopPrank();
    }

    function test_LockSplits_Success() public {
        vm.startPrank(artist1);
        tortoise.createSong("Lock Test", SONG_PRICE, 100, "ipfs://test");

        tortoise.lockSplits(0);

        Song memory song = tortoise.getSongDetails(0);
        assertTrue(song.splitsLocked);

        // Should revert on reconfigure
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(artist1, 10000);

        vm.expectRevert(TortoiseV1.SplitsAreLocked.selector);
        tortoise.configureSplits(0, splits);

        vm.stopPrank();
    }

    // ============ Minting Tests ============

    function test_MintSong_WithoutSplits() public {
        // Create song
        vm.prank(artist1);
        tortoise.createSong("Mint Test", SONG_PRICE, 100, "ipfs://test");

        // Approve and mint: $0.95 + $0.05 = $1.00
        uint256 totalCost = SONG_PRICE + PLATFORM_FEE;

        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, 1, buyer1);
        vm.stopPrank();

        // Verify balances
        assertEq(tortoise.balanceOf(buyer1, 0), 1);
        assertEq(usdc.balanceOf(platformFeeRecipient), PLATFORM_FEE); // $0.05
        assertEq(usdc.balanceOf(artist1), SONG_PRICE); // $0.95
    }

    function test_MintSong_WithSplits() public {
        // Create song and configure splits
        vm.startPrank(artist1);
        tortoise.createSong("Split Mint", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](3);
        splits[0] = SplitRecipient(artist1, 7000); // 70%
        splits[1] = SplitRecipient(producer, 2000); // 20%
        splits[2] = SplitRecipient(songwriter, 1000); // 10%
        tortoise.configureSplits(0, splits);
        vm.stopPrank();

        // Mint: $0.95 + $0.05 flat fee = $1.00
        uint256 totalCost = SONG_PRICE + PLATFORM_FEE;

        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, 1, buyer1);
        vm.stopPrank();

        // Verify split payments (splits applied to artist revenue: $0.95)
        assertEq(usdc.balanceOf(platformFeeRecipient), PLATFORM_FEE); // $0.05
        assertEq(usdc.balanceOf(artist1), 665_000); // 70% of 950_000
        assertEq(usdc.balanceOf(producer), 190_000); // 20% of 950_000
        assertEq(usdc.balanceOf(songwriter), 95_000); // 10% of 950_000
    }

    function test_MintSong_MultipleQuantity() public {
        vm.prank(artist1);
        tortoise.createSong("Multi Mint", SONG_PRICE, 100, "ipfs://test");

        uint256 quantity = 5;
        // Platform fee is flat (once per tx), not per copy
        uint256 totalCost = (SONG_PRICE * quantity) + PLATFORM_FEE;
        // totalCost = ($0.95 * 5) + $0.05 = $4.80

        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, quantity, buyer1);
        vm.stopPrank();

        assertEq(tortoise.balanceOf(buyer1, 0), 5);
        assertEq(usdc.balanceOf(platformFeeRecipient), PLATFORM_FEE); // $0.05 flat
        assertEq(usdc.balanceOf(artist1), SONG_PRICE * quantity); // $0.95 * 5 = $4.75
    }

    function test_MintSong_RevertWhen_InsufficientAllowance() public {
        vm.prank(artist1);
        tortoise.createSong("Allowance Test", SONG_PRICE, 100, "ipfs://test");

        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), SONG_PRICE); // Missing platform fee

        vm.expectRevert();
        tortoise.mintSong(0, 1, buyer1);
        vm.stopPrank();
    }

    // ============ Batch Minting Tests ============

    function test_MintBatchSongs_Success() public {
        // Create multiple songs
        vm.startPrank(artist1);
        tortoise.createSong("Song A", SONG_PRICE, 100, "ipfs://a");
        tortoise.createSong("Song B", SONG_PRICE, 100, "ipfs://b");
        vm.stopPrank();

        vm.prank(artist2);
        tortoise.createSong("Song C", SONG_PRICE, 100, "ipfs://c");

        // Batch mint
        uint256[] memory songIds = new uint256[](3);
        songIds[0] = 0;
        songIds[1] = 1;
        songIds[2] = 2;

        uint256[] memory quantities = new uint256[](3);
        quantities[0] = 1;
        quantities[1] = 2;
        quantities[2] = 3;

        // Total: (0.95 * 1) + (0.95 * 2) + (0.95 * 3) + 0.05 = 5.75
        uint256 totalCost = (SONG_PRICE * 6) + PLATFORM_FEE;

        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintBatchSongs(songIds, quantities, buyer1);
        vm.stopPrank();

        assertEq(tortoise.balanceOf(buyer1, 0), 1);
        assertEq(tortoise.balanceOf(buyer1, 1), 2);
        assertEq(tortoise.balanceOf(buyer1, 2), 3);
        assertEq(usdc.balanceOf(platformFeeRecipient), PLATFORM_FEE); // Single flat fee
        assertEq(usdc.balanceOf(artist1), SONG_PRICE * 3); // Songs 0 and 1
        assertEq(usdc.balanceOf(artist2), SONG_PRICE * 3); // Song 2
    }

    // ============ Admin Tests ============

    function test_UpdatePlatformFee() public {
        vm.startPrank(owner);

        uint128 newFee = 100_000; // $0.10
        tortoise.updatePlatformFee(newFee);

        ContractConfig memory cfg = tortoise.getConfig();
        assertEq(cfg.platformFee, newFee);

        vm.stopPrank();
    }

    function test_UpdatePlatformFee_RevertWhen_ExceedsMax() public {
        vm.startPrank(owner);

        vm.expectRevert(TortoiseV1.FeeExceedsMaximum.selector);
        tortoise.updatePlatformFee(2_000_000); // $2, exceeds $1 max

        vm.stopPrank();
    }

    function test_UpdateDefaultPrice_RevertWhen_Zero() public {
        vm.prank(owner);
        vm.expectRevert(TortoiseV1.PriceMustBePositive.selector);
        tortoise.updateDefaultPrice(0);
    }

    // ============ Security Audit Test Cases ============

    // C-1: Split rounding dust must not stay in contract
    function test_MintSong_SplitRoundingDust_NoLeftover() public {
        vm.startPrank(artist1);
        // Use a price that causes rounding: $1.00001 (1_000_001 units)
        tortoise.createSong("Rounding Test", 1_000_001, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](3);
        splits[0] = SplitRecipient(artist1, 3333); // 33.33%
        splits[1] = SplitRecipient(producer, 3333); // 33.33%
        splits[2] = SplitRecipient(songwriter, 3334); // 33.34%
        tortoise.configureSplits(0, splits);
        vm.stopPrank();

        uint256 totalCost = tortoise.calculateTotalCost(0, 1);
        usdc.mint(buyer1, totalCost);

        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, 1, buyer1);
        vm.stopPrank();

        // Contract must hold zero USDC after distribution
        assertEq(usdc.balanceOf(address(tortoise)), 0);
    }

    // H-1: recoverTokens blocks USDC
    function test_RecoverTokens_RevertWhen_USDC() public {
        vm.prank(owner);
        vm.expectRevert(TortoiseV1.CannotRecoverUsdc.selector);
        tortoise.recoverTokens(address(usdc), 1);
    }

    // H-2: Duplicate split recipients rejected
    function test_ConfigureSplits_RevertWhen_DuplicateRecipient() public {
        vm.startPrank(artist1);
        tortoise.createSong("Dup Test", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(producer, 5000);
        splits[1] = SplitRecipient(producer, 5000); // duplicate

        vm.expectRevert(SplitLib.DuplicateRecipient.selector);
        tortoise.configureSplits(0, splits);
        vm.stopPrank();
    }

    // Split with percentage below 1% minimum
    function test_ConfigureSplits_RevertWhen_BelowMinimum() public {
        vm.startPrank(artist1);
        tortoise.createSong("Min Test", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(artist1, 9901);
        splits[1] = SplitRecipient(producer, 99); // 0.99% - below 1% minimum

        vm.expectRevert(SplitLib.PercentageBelowMinimum.selector);
        tortoise.configureSplits(0, splits);
        vm.stopPrank();
    }

    // Splits with exactly 10 recipients (boundary - should succeed)
    function test_ConfigureSplits_MaxRecipients() public {
        vm.startPrank(artist1);
        tortoise.createSong("Max Splits", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](10);
        for (uint256 i = 0; i < 10; i++) {
            splits[i] = SplitRecipient(makeAddr(string.concat("r", vm.toString(i))), 1000);
        }
        tortoise.configureSplits(0, splits); // Should succeed (10 * 1000 = 10000)

        assertEq(tortoise.getSongSplits(0).length, 10);
        vm.stopPrank();
    }

    // Splits with 11 recipients (should revert)
    function test_ConfigureSplits_RevertWhen_TooManySplits() public {
        vm.startPrank(artist1);
        tortoise.createSong("Too Many", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](11);
        for (uint256 i = 0; i < 11; i++) {
            splits[i] = SplitRecipient(makeAddr(string.concat("r", vm.toString(i))), 909);
        }

        vm.expectRevert(SplitLib.TooManySplits.selector);
        tortoise.configureSplits(0, splits);
        vm.stopPrank();
    }

    // Split recipient is zero address
    function test_ConfigureSplits_RevertWhen_ZeroAddress() public {
        vm.startPrank(artist1);
        tortoise.createSong("Zero Addr", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(address(0), 10000);

        vm.expectRevert(SplitLib.ZeroAddressRecipient.selector);
        tortoise.configureSplits(0, splits);
        vm.stopPrank();
    }

    // lockSplits by non-artist reverts
    function test_LockSplits_RevertWhen_NotArtist() public {
        vm.prank(artist1);
        tortoise.createSong("Lock Auth", SONG_PRICE, 100, "ipfs://test");

        vm.prank(artist2);
        vm.expectRevert(TortoiseV1.OnlyArtistCanLockSplits.selector);
        tortoise.lockSplits(0);
    }

    // lockSplits on already locked song reverts
    function test_LockSplits_RevertWhen_AlreadyLocked() public {
        vm.startPrank(artist1);
        tortoise.createSong("Double Lock", SONG_PRICE, 100, "ipfs://test");
        tortoise.lockSplits(0);

        vm.expectRevert(TortoiseV1.AlreadyLocked.selector);
        tortoise.lockSplits(0);
        vm.stopPrank();
    }

    // Minting with price = 0 (free song, only platform fee)
    function test_MintSong_FreeSong_PlatformFeeOnly() public {
        vm.prank(artist1);
        tortoise.createSong("Free Song", 1, 100, "ipfs://test"); // 1 unit = $0.000001

        uint256 totalCost = tortoise.calculateTotalCost(0, 1);
        assertEq(totalCost, 1 + PLATFORM_FEE); // price(1) + fee

        usdc.mint(buyer1, totalCost);
        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, 1, buyer1);
        vm.stopPrank();

        assertEq(tortoise.balanceOf(buyer1, 0), 1);
    }

    // Minting with platformFee = 0 (admin set fee to zero)
    function test_MintSong_ZeroPlatformFee() public {
        vm.prank(owner);
        tortoise.updatePlatformFee(0);

        vm.prank(artist1);
        tortoise.createSong("No Fee", SONG_PRICE, 100, "ipfs://test");

        uint256 totalCost = tortoise.calculateTotalCost(0, 1);
        assertEq(totalCost, SONG_PRICE); // No fee

        usdc.mint(buyer1, totalCost);
        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, 1, buyer1);
        vm.stopPrank();

        assertEq(usdc.balanceOf(artist1), SONG_PRICE);
        assertEq(usdc.balanceOf(platformFeeRecipient), 0);
    }

    // Unlimited supply song (maxSupply = 0)
    function test_MintSong_UnlimitedSupply() public {
        vm.prank(artist1);
        tortoise.createSong("Unlimited", SONG_PRICE, 0, "ipfs://test"); // 0 = unlimited

        uint256 qty = 1000;
        uint256 totalCost = tortoise.calculateTotalCost(0, qty);
        usdc.mint(buyer1, totalCost);

        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, qty, buyer1);
        vm.stopPrank();

        assertEq(tortoise.balanceOf(buyer1, 0), qty);
    }

    // M-4: createSong with price=0 emits default price, not zero
    function test_CreateSong_EmitsActualPrice() public {
        vm.startPrank(artist1);

        vm.expectEmit(true, true, true, true);
        emit TortoiseV1.SongCreated(0, "Default Price", artist1, SONG_PRICE, 100);

        tortoise.createSong("Default Price", 0, 100, "ipfs://test");
        vm.stopPrank();
    }

    // M-3: configureSplits reverts when paused
    function test_ConfigureSplits_RevertWhen_Paused() public {
        vm.prank(artist1);
        tortoise.createSong("Pause Test", SONG_PRICE, 100, "ipfs://test");

        vm.prank(owner);
        tortoise.pause();

        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(artist1, 10000);

        vm.prank(artist1);
        vm.expectRevert();
        tortoise.configureSplits(0, splits);
    }

    // M-3: lockSplits reverts when paused
    function test_LockSplits_RevertWhen_Paused() public {
        vm.prank(artist1);
        tortoise.createSong("Pause Lock", SONG_PRICE, 100, "ipfs://test");

        vm.prank(owner);
        tortoise.pause();

        vm.prank(artist1);
        vm.expectRevert();
        tortoise.lockSplits(0);
    }

    // Artist can assign 100% to collaborators (not in split at all)
    function test_MintSong_SplitsWithoutArtist() public {
        vm.startPrank(artist1);
        tortoise.createSong("No Artist Split", SONG_PRICE, 100, "ipfs://test");

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(producer, 6000); // 60%
        splits[1] = SplitRecipient(songwriter, 4000); // 40%
        tortoise.configureSplits(0, splits);
        vm.stopPrank();

        uint256 totalCost = SONG_PRICE + PLATFORM_FEE;
        usdc.mint(buyer1, totalCost);

        vm.startPrank(buyer1);
        usdc.approve(address(tortoise), totalCost);
        tortoise.mintSong(0, 1, buyer1);
        vm.stopPrank();

        assertEq(usdc.balanceOf(artist1), 0); // Artist gets nothing
        assertEq(usdc.balanceOf(producer), 570_000); // 60% of 950_000
        assertEq(usdc.balanceOf(songwriter), 380_000); // 40% of 950_000
    }

    // ============ Name and Symbol ============

    function test_NameAndSymbol() public view {
        assertEq(tortoise.name(), "Tortoise");
        assertEq(tortoise.symbol(), "TORT");
    }
}
