// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {Tortoise} from "../src/Tortoise.sol";
import {TortoiseShell} from "../src/TortoiseShell.sol";

/// @notice Deploys the USDC Tortoise stack (staking shell + Tortoise music NFT) and wires the
///         NFT as an authorized shell caller. The operator (broadcaster) is owner of both.
/// @dev Env:
///   USDC                        payment/reward token (Base mainnet 0x833589fCD6...2913)
///   TORT                        staking token
///   REWARD_DURATION             shell drip window, seconds (default 7 days)
///   TORT_REWARD_PER_COLLECTION  TORT credited per copy collected (default 0; set later)
/// After deploy, fund the shell's TORT pool (`fundTortPool`) and, if not set here,
/// `setTortRewardPerCollection` before staking rewards flow.
contract Deploy is Script {
    function run() external returns (Tortoise tortoise, TortoiseShell shell) {
        address usdc = vm.envAddress("USDC");
        address tort = vm.envAddress("TORT");
        uint256 rewardDuration = vm.envOr("REWARD_DURATION", uint256(7 days));
        uint256 tortReward = vm.envOr("TORT_REWARD_PER_COLLECTION", uint256(0));

        vm.startBroadcast();
        shell = new TortoiseShell(tort, usdc, rewardDuration);
        tortoise = new Tortoise(usdc, address(shell));
        shell.addAuthorizedCaller(address(tortoise));
        if (tortReward > 0) {
            shell.setTortRewardPerCollection(tortReward);
        }
        vm.stopBroadcast();

        console2.log("TortoiseShell deployed:", address(shell));
        console2.log("Tortoise deployed:", address(tortoise));
    }
}
