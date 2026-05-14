// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";

contract Config is Script {
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant USDC_BASE_SEPOLIA = 0x14196F08a4Fa0B66B7331bC40dd6bCd8A1dEeA9F;
    address constant TORT_BASE = 0x601410d1d3093cF469fCA4e1EfB2Fb67B4E225c6;
    address constant TORS_TEST_BASE_SEPOLIA = 0x1c3879b9dabA1B51253b109726C44bb391cae8c5;

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
        if (block.chainid == 84_532) {
            require(TORS_TEST_BASE_SEPOLIA != address(0), "TORSTest not yet deployed - run DeployBaseSepolia");
            return TORS_TEST_BASE_SEPOLIA;
        }
        revert("TORT address not configured for this chain");
    }
}
