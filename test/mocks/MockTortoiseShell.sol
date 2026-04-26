// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {ITortoiseShell} from "../../src/interfaces/ITortoiseShell.sol";

contract MockTortoiseShell is ITortoiseShell {
    bool public failDepositRewards;
    bool public failCreditStake;
    uint256 public rewardsDeposited;
    uint256 public depositCalls;
    uint256 public creditCalls;
    uint256 public tortPoolBalance = type(uint256).max;
    uint256 public tortRewardPerCollection = 1 ether;
    mapping(address => uint256) public creditedQuantity;

    function setFailDepositRewards(
        bool value
    ) external {
        failDepositRewards = value;
    }

    function setFailCreditStake(
        bool value
    ) external {
        failCreditStake = value;
    }

    function setTortPoolBalance(
        uint256 value
    ) external {
        tortPoolBalance = value;
    }

    function setTortRewardPerCollection(
        uint256 value
    ) external {
        tortRewardPerCollection = value;
    }

    function depositRewards(
        uint256 amount
    ) external {
        if (failDepositRewards) {
            revert("deposit failed");
        }
        rewardsDeposited += amount;
        depositCalls++;
    }

    function creditStake(
        address user,
        uint256 quantity
    ) external returns (uint256 credited) {
        if (failCreditStake) {
            revert("credit failed");
        }
        creditedQuantity[user] += quantity;
        creditCalls++;
        return quantity * tortRewardPerCollection;
    }

    function getTortPoolBalance() external view returns (uint256) {
        return tortPoolBalance;
    }
}
