// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    mapping(address => bool) public transferShouldFailTo;

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function setTransferShouldFail(
        address to,
        bool shouldFail
    ) external {
        transferShouldFailTo[to] = shouldFail;
    }

    function transfer(
        address to,
        uint256 value
    ) public override returns (bool) {
        if (transferShouldFailTo[to]) {
            return false;
        }
        return super.transfer(to, value);
    }
}
