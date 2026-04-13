// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseV1} from "../../src/TortoiseV1.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {SplitRecipient, SplitLib} from "../../src/libraries/SplitLib.sol";
import {Song, ContractConfig} from "../../src/interfaces/ITortoiseV1.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockTORT} from "../mocks/MockTORT.sol";

contract TortoiseV1FuzzTest is Test {
    TortoiseV1 public tortoise;
    TortoiseShell public shell;
    MockUSDC public usdc;
    MockTORT public tort;

    address public owner = address(this);
    address public artist = makeAddr("artist");
    address public buyer = makeAddr("buyer");

    uint64 constant PLATFORM_FEE = 50_000;
    uint64 constant STAKING_FEE = 100_000;
    uint128 constant DEFAULT_PRICE = 850_000;

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

        shell.addAuthorizedCaller(address(tortoise));
        shell.setTortRewardPerCollection(777_777e18);

        // Fund TORT pool
        tort.mint(owner, 1_000_000_000e18);
        tort.approve(address(shell), type(uint256).max);
        shell.fundTortPool(1_000_000_000e18);

        // Fund buyer
        usdc.mint(buyer, type(uint128).max);
        vm.prank(buyer);
        usdc.approve(address(tortoise), type(uint256).max);
    }

    /// @dev Fuzz: mint with random quantity, verify only platform fees remain in contract
    function testFuzz_mintSong_onlyPlatformFeeInContract(uint256 quantity) public {
        quantity = bound(quantity, 1, 1_000);

        vm.prank(artist);
        uint256 songId = tortoise.createSong("Fuzz Song", 0, 0, "ipfs://fuzz");

        vm.prank(buyer);
        tortoise.mintSong(songId, quantity, buyer);

        assertEq(usdc.balanceOf(address(tortoise)), PLATFORM_FEE * quantity, "Should only hold platform fees");
    }

    /// @dev Fuzz: mint with random price, verify payment sums
    function testFuzz_mintSong_paymentSumsCorrectly(uint128 price, uint256 quantity) public {
        price = uint128(bound(price, 100_000, 100_000_000)); // MIN_SONG_PRICE to $100
        quantity = bound(quantity, 1, 100);

        vm.prank(artist);
        uint256 songId = tortoise.createSong("Fuzz Song", price, 0, "ipfs://fuzz");

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 artistBefore = usdc.balanceOf(artist);
        uint256 contractBefore = usdc.balanceOf(address(tortoise));
        uint256 shellBefore = usdc.balanceOf(address(shell));

        vm.prank(buyer);
        tortoise.mintSong(songId, quantity, buyer);

        uint256 buyerSpent = buyerBefore - usdc.balanceOf(buyer);
        uint256 artistGot = usdc.balanceOf(artist) - artistBefore;
        uint256 platformHeld = usdc.balanceOf(address(tortoise)) - contractBefore;
        uint256 shellGot = usdc.balanceOf(address(shell)) - shellBefore;

        // Total spent == sum of all distributions
        assertEq(buyerSpent, artistGot + platformHeld + shellGot, "Payment sum mismatch");
        // Artist revenue matches expected
        assertEq(artistGot, uint256(price) * quantity, "Artist revenue wrong");
        // Fees scale with quantity
        assertEq(platformHeld, uint256(PLATFORM_FEE) * quantity, "Platform fee wrong");
        assertEq(shellGot, uint256(STAKING_FEE) * quantity, "Staking fee wrong");
    }

    /// @dev Fuzz: random 2-way splits always distribute full artist revenue
    function testFuzz_mintSong_twoWaySplitSumsCorrectly(
        uint96 splitPct,
        uint128 price,
        uint256 quantity
    ) public {
        splitPct = uint96(bound(splitPct, 100, 9900)); // 1% to 99%
        price = uint128(bound(price, 100_000, 100_000_000));
        quantity = bound(quantity, 1, 100);

        address collab = makeAddr("collab");

        vm.prank(artist);
        uint256 songId = tortoise.createSong("Split Song", price, 0, "ipfs://split");

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(artist, splitPct);
        splits[1] = SplitRecipient(collab, 10_000 - splitPct);

        vm.prank(artist);
        tortoise.configureSplits(songId, splits);

        vm.prank(buyer);
        tortoise.mintSong(songId, quantity, buyer);

        uint256 artistRevenue = uint256(price) * quantity;
        uint256 artistGot = usdc.balanceOf(artist);
        uint256 collabGot = usdc.balanceOf(collab);

        // Split recipients receive exactly the artist revenue
        assertEq(artistGot + collabGot, artistRevenue, "Split sum != artist revenue");
        assertEq(usdc.balanceOf(address(tortoise)), uint256(PLATFORM_FEE) * quantity, "Should only hold platform fees");
    }

    /// @dev Fuzz: random N-way splits (2-10 recipients) sum correctly
    function testFuzz_mintSong_multiSplitSumsCorrectly(
        uint8 numSplits,
        uint128 price,
        uint256 quantity
    ) public {
        numSplits = uint8(bound(numSplits, 2, 10));
        price = uint128(bound(price, 100_000, 100_000_000)); // MIN_SONG_PRICE to avoid dust issues with many splits
        quantity = bound(quantity, 1, 50);

        vm.prank(artist);
        uint256 songId = tortoise.createSong("Multi Split", price, 0, "ipfs://multi");

        // Build splits: equal percentages with remainder to last
        SplitRecipient[] memory splits = new SplitRecipient[](numSplits);
        uint96 perSplit = uint96(10_000 / numSplits);
        // Ensure perSplit >= MIN_PERCENTAGE (100 bps)
        if (perSplit < 100) perSplit = 100;

        uint96 totalAssigned = 0;
        address[] memory recipients = new address[](numSplits);
        for (uint256 i = 0; i < numSplits; i++) {
            recipients[i] = address(uint160(0xBEEF + i));
            if (i == uint256(numSplits) - 1) {
                splits[i] = SplitRecipient(recipients[i], 10_000 - totalAssigned);
            } else {
                splits[i] = SplitRecipient(recipients[i], perSplit);
                totalAssigned += perSplit;
            }
        }

        vm.prank(artist);
        tortoise.configureSplits(songId, splits);

        vm.prank(buyer);
        tortoise.mintSong(songId, quantity, buyer);

        uint256 artistRevenue = uint256(price) * quantity;
        uint256 totalDistributed = 0;
        for (uint256 i = 0; i < numSplits; i++) {
            totalDistributed += usdc.balanceOf(recipients[i]);
        }

        assertEq(totalDistributed, artistRevenue, "Multi-split sum != artist revenue");
        assertEq(usdc.balanceOf(address(tortoise)), uint256(PLATFORM_FEE) * quantity, "Should only hold platform fees");
    }

    /// @dev Fuzz: random quantity with max supply — verify supply tracking
    function testFuzz_mintSong_supplyTracking(uint128 maxSupply, uint256 quantity) public {
        maxSupply = uint128(bound(maxSupply, 1, 10_000));
        quantity = bound(quantity, 1, maxSupply);

        vm.prank(artist);
        uint256 songId = tortoise.createSong("Supply Song", 0, maxSupply, "ipfs://supply");

        vm.prank(buyer);
        tortoise.mintSong(songId, quantity, buyer);

        Song memory song = tortoise.getSongDetails(songId);
        assertEq(song.currentSupply, quantity, "Supply mismatch");
        assertEq(tortoise.balanceOf(buyer, songId), quantity, "Balance mismatch");
    }

    /// @dev Fuzz: calculateTotalCost matches what buyer actually pays
    function testFuzz_calculateTotalCost_matchesActualCost(
        uint128 price,
        uint256 quantity
    ) public {
        price = uint128(bound(price, 100_000, 100_000_000));
        quantity = bound(quantity, 1, 100);

        vm.prank(artist);
        uint256 songId = tortoise.createSong("Cost Song", price, 0, "ipfs://cost");

        uint256 expectedCost = tortoise.calculateTotalCost(songId, quantity);
        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(buyer);
        tortoise.mintSong(songId, quantity, buyer);

        uint256 actualCost = buyerBefore - usdc.balanceOf(buyer);
        assertEq(actualCost, expectedCost, "calculateTotalCost mismatch");
    }

    /// @dev Fuzz: TORT crediting matches quantity * tortRewardPerCollection
    function testFuzz_mintSong_tortCreditMatchesQuantity(uint256 quantity) public {
        quantity = bound(quantity, 1, 100);

        vm.prank(artist);
        uint256 songId = tortoise.createSong("Credit Song", 0, 0, "ipfs://credit");

        vm.prank(buyer);
        tortoise.mintSong(songId, quantity, buyer);

        uint256 expectedCredit = quantity * 777_777e18;
        assertEq(shell.stakedBalance(buyer), expectedCredit, "TORT credit mismatch");
    }
}
