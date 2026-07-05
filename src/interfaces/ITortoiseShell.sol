// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

/// @title ITortoiseShell (ETH-native)
/// @notice Surface that the Tortoise minter depends on. Rewards are native ETH;
///         `depositRewards` is payable and reconciles from `msg.value` / contract balance.
interface ITortoiseShell {
    /// @notice Deposit native ETH rewards. The reward amount is reconciled from the
    ///         contract's ETH balance vs. accounted deposits, not from a caller argument.
    function depositRewards() external payable;

    /// @notice Credit `rewardUnits * tortRewardPerCollection` of pooled TORT to `user`'s
    ///         stake. Never reverts on pool shortfall — caps to available pool.
    /// @return credited The TORT amount actually credited (may be less than requested).
    function creditStake(address user, uint256 rewardUnits) external returns (uint256 credited);

    function getTortPoolBalance() external view returns (uint256);
    function tortRewardPerCollection() external view returns (uint256);
}
