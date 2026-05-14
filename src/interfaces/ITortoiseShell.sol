// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITortoiseShell {
    function depositRewards(
        uint256 amount
    ) external;
    function creditStake(
        address user,
        uint256 quantity
    ) external returns (uint256 credited);
    function getTortPoolBalance() external view returns (uint256);
    function tortRewardPerCollection() external view returns (uint256);
    function rewardToken() external view returns (IERC20);
}
