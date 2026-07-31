// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {ITortoiseShell} from "../../src/interfaces/ITortoiseShell.sol";

/// @notice Shell double whose `creditStake` always reverts while the pool gate passes, used to
///         prove that `collect` is non-blocking on shell-credit failure. Not production code.
contract MockRevertingShell is ITortoiseShell {
    uint256 public tortRewardPerCollection = 1;

    function getTortPoolBalance() external pure returns (uint256) {
        return type(uint256).max;
    }

    function depositRewards(uint256) external {}

    function creditStake(address, uint256) external pure returns (uint256) {
        revert("shell down");
    }
}
