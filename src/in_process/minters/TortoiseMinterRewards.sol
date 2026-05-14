// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice TortoiseMinter Helper contract template
abstract contract TortoiseMinterRewards {
    uint256 internal constant MIN_PRICE_PER_TOKEN = 10_000;
    uint256 internal constant TORTOISE_FEE_BPS = 2_500; // 25% to TortoiseShell
    uint256 internal constant ARTIST_FEE_BPS = 7_500;   // 75% to artist
    uint256 internal constant BPS_DENOMINATOR = 10_000;
}
