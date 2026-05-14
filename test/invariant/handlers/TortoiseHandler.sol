// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseV1} from "../../../src/TortoiseV1.sol";
import {TortoiseShell} from "../../../src/TortoiseShell.sol";
import {SplitRecipient} from "../../../src/libraries/SplitLib.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {MockTORT} from "../../mocks/MockTORT.sol";

contract TortoiseHandler is Test {
    TortoiseV1 public tortoise;
    TortoiseShell public shell;
    MockUSDC public usdc;
    MockTORT public tort;

    address[] public artists;
    address[] public buyers;
    uint256[] public songIds;

    uint256 public totalMints;
    uint256 public totalQuantityMinted; // sum of quantities across all successful mints

    constructor(
        TortoiseV1 _tortoise,
        TortoiseShell _shell,
        MockUSDC _usdc,
        MockTORT _tort
    ) {
        tortoise = _tortoise;
        shell = _shell;
        usdc = _usdc;
        tort = _tort;

        // Create actors
        for (uint256 i = 0; i < 5; i++) {
            address a = address(uint160(0xA000 + i));
            artists.push(a);

            address b = address(uint160(0xB000 + i));
            buyers.push(b);
            usdc.mint(b, 1_000_000_000e6);
            vm.prank(b);
            usdc.approve(address(tortoise), type(uint256).max);
        }
    }

    function createSong(
        uint256 artistSeed,
        uint128 price
    ) external {
        address artist = artists[artistSeed % artists.length];
        price = uint128(bound(price, 100_000, 10_000_000)); // MIN_SONG_PRICE

        vm.prank(artist);
        uint256 songId = tortoise.createSong("Handler Song", price, 0, "ipfs://handler");
        songIds.push(songId);
    }

    function mintSong(
        uint256 songSeed,
        uint256 buyerSeed,
        uint256 quantity
    ) external {
        if (songIds.length == 0) {
            return;
        }

        uint256 songId = songIds[songSeed % songIds.length];
        address buyer = buyers[buyerSeed % buyers.length];
        quantity = bound(quantity, 1, 20);

        vm.prank(buyer);
        try tortoise.mintSong(songId, quantity, buyer) {
            totalMints++;
            totalQuantityMinted += quantity;
        } catch {}
    }

    function configureSplits(
        uint256 songSeed,
        uint96 splitPct
    ) external {
        if (songIds.length == 0) {
            return;
        }

        uint256 songId = songIds[songSeed % songIds.length];
        splitPct = uint96(bound(splitPct, 100, 9900));

        // Get the song artist via view function
        address artist = tortoise.getSongDetails(songId).artist;
        address collab = address(uint160(0xC0AB + songSeed));

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(artist, splitPct);
        splits[1] = SplitRecipient(collab, 10_000 - splitPct);

        vm.prank(artist);
        try tortoise.configureSplits(songId, splits) {} catch {}
    }
}
