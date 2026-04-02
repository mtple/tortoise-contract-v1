// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockTORT is ERC20 {
    constructor() ERC20("Tortoise Token", "TORT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
