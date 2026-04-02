// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {SplitRecipient} from "../libraries/SplitLib.sol";

struct Song {
    string title;
    address artist;
    uint128 price;
    uint128 maxSupply;
    uint128 currentSupply;
    bool exists;
    bool splitsLocked;
}

struct ContractConfig {
    uint128 defaultSongPrice;
    uint128 platformFee;
    uint128 stakingFee;
    address usdcToken;
    address tortoiseShell;
}

interface ITortoiseV1 {
    function createSong(
        string calldata title,
        uint128 price,
        uint128 maxSupply,
        string calldata tokenUri
    ) external returns (uint256 songId);

    function configureSplits(uint256 songId, SplitRecipient[] calldata splits) external;
    function lockSplits(uint256 songId) external;
    function mintSong(uint256 songId, uint256 quantity, address recipient) external;
    function calculateTotalCost(uint256 songId, uint256 quantity) external view returns (uint256);
    function getSongDetails(uint256 songId) external view returns (Song memory);
    function getSongSplits(uint256 songId) external view returns (SplitRecipient[] memory);
    function getArtistSongs(address artist) external view returns (uint256[] memory);
    function getConfig() external view returns (ContractConfig memory);
}
