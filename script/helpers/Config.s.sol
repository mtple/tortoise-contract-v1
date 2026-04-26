// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";

contract Config is Script {
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant TORT_BASE = 0x601410d1d3093cF469fCA4e1EfB2Fb67B4E225c6;
    address constant IN_PROCESS_ERC20_MINTER_BASE = 0xE27d9Dc88dAB82ACa3ebC49895c663C6a0CfA014;

    function getUsdcAddress() internal view returns (address) {
        if (block.chainid == 8453) {
            return USDC_BASE;
        }
        if (block.chainid == 84_532) {
            return USDC_BASE_SEPOLIA;
        }
        revert("Unsupported chain");
    }

    function getTortAddress() internal view returns (address) {
        if (block.chainid == 8453) {
            return TORT_BASE;
        }
        revert("TORT address not configured for this chain");
    }

    function getInProcessMinterAddress() internal view returns (address) {
        if (block.chainid == 8453) {
            return IN_PROCESS_ERC20_MINTER_BASE;
        }
        revert("In Process minter not configured for this chain");
    }
}
