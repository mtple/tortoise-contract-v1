// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {ITortoiseShell} from "../../src/interfaces/ITortoiseShell.sol";

/// @notice Configurable ETH shell mock for driving the D.8 divergence matrix in minter
///         tests. Test-only setters control credit amount and revert behavior.
contract MockTortoiseShellETH is ITortoiseShell {
    uint256 public tortRewardPerCollection;
    uint256 public pool;

    uint256 public nextCreditedAmount;
    bool public revertOnDeposit;
    bool public revertOnCredit;

    uint256 public depositedTotal;
    mapping(address => uint256) public creditedTo;

    function setTortRewardPerCollection(uint256 v) external {
        tortRewardPerCollection = v;
    }

    function setPool(uint256 v) external {
        pool = v;
    }

    function setNextCreditedAmount(uint256 v) external {
        nextCreditedAmount = v;
    }

    function setShouldRevertOnDeposit(bool v) external {
        revertOnDeposit = v;
    }

    function setShouldRevertOnCredit(bool v) external {
        revertOnCredit = v;
    }

    function depositRewards() external payable {
        if (revertOnDeposit) revert("deposit reverted");
        depositedTotal += msg.value;
    }

    function creditStake(address user, uint256) external returns (uint256 credited) {
        if (revertOnCredit) revert("credit reverted");
        credited = nextCreditedAmount;
        creditedTo[user] += credited;
        return credited;
    }

    function getTortPoolBalance() external view returns (uint256) {
        return pool;
    }
}
