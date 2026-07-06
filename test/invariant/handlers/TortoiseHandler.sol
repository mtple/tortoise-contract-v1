// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Tortoise} from "../../../src/Tortoise.sol";
import {SplitRecipient} from "../../../src/libraries/SplitLib.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";

/// @notice Invariant actor. Owns the Tortoise contract (ownership is transferred to it in the
///         test's setUp) so it can createSong, and acts as its own collector.
contract TortoiseHandler {
    Tortoise public tortoise;
    MockUSDC public usdc;

    uint256[] public songIds;
    mapping(uint256 => bytes32) public manifestAtCreation;
    uint256 public maxSeenNextSongId;

    string internal constant MANIFEST = "{\"a\":\"1\"}";
    address internal constant ARTIST = address(0xA11CE);

    constructor(Tortoise _tortoise, MockUSDC _usdc) {
        tortoise = _tortoise;
        usdc = _usdc;
    }

    function createSong(uint128 price) external {
        uint128 p = uint128(_bound(uint256(price), tortoise.MIN_SONG_PRICE(), 1_000_000_000));
        Tortoise.CreateSongParams memory params;
        params.artist = ARTIST;
        params.price = p;
        params.tokenUri = "ar://u";
        params.manifest = MANIFEST;
        params.splits = new SplitRecipient[](0);
        uint256 id = tortoise.createSong(params);
        songIds.push(id);
        manifestAtCreation[id] = tortoise.releaseManifest(id);
        if (tortoise.nextSongId() > maxSeenNextSongId) {
            maxSeenNextSongId = tortoise.nextSongId();
        }
    }

    function collect(uint256 songSeed, uint256 qty) external {
        if (songIds.length == 0) return;
        uint256 id = songIds[songSeed % songIds.length];
        uint256 quantity = _bound(qty, 1, 10);
        uint256 cost = tortoise.quote(id, quantity);
        usdc.mint(address(this), cost);
        usdc.approve(address(tortoise), cost);
        tortoise.collect(id, quantity, address(this), cost, "");
    }

    function songCount() external view returns (uint256) {
        return songIds.length;
    }

    function _bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max <= min) return min;
        return min + (x % (max - min + 1));
    }
}
