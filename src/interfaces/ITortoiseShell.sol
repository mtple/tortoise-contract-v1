// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

interface ITortoiseShell {
    function depositRewards(uint256 amount) external;
    function creditStake(address user, uint256 quantity) external;
}
