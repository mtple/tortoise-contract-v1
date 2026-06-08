// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {console2} from "forge-std/console2.sol";
import {Config} from "./Config.s.sol";
import {TortoiseShell} from "../src/TortoiseShell.sol";
import {TortoiseInProcessMinter} from "../src/TortoiseInProcessMinter.sol";

/// @notice Deploy the ETH-native TortoiseShell + TortoiseInProcessMinter and authorize the
///         minter on the shell. Env-driven and fail-closed via Config; works on any chain whose
///         config is set (the generalized H.5 DeployBaseSepolia). Print the addresses for the
///         operator to persist into addresses/<chainId>.json.
///
/// Required: TORT_TOKEN (or registry stakingToken), PLATFORM_FEE_RECIPIENT (or registry).
/// Optional: PLATFORM_FEE_BPS (500), STAKING_FEE_BPS (1000), SHELL_REWARD_WINDOW (7 days).
contract DeployStack is Config {
    function run() external {
        address tortToken = stakingToken();
        address platform = platformFeeRecipient();
        uint16 pBps = platformFeeBps();
        uint16 sBps = stakingFeeBps();
        uint256 rewardWindow = vm.envOr("SHELL_REWARD_WINDOW", uint256(7 days));

        vm.startBroadcast();
        TortoiseShell shell = new TortoiseShell(tortToken, rewardWindow);
        TortoiseInProcessMinter minterContract =
            new TortoiseInProcessMinter(address(shell), platform, pBps, sBps);
        shell.addAuthorizedCaller(address(minterContract));
        vm.stopBroadcast();

        console2.log("chainId:                ", block.chainid);
        console2.log("TortoiseShell:          ", address(shell));
        console2.log("TortoiseInProcessMinter:", address(minterContract));
        console2.log("stakingToken:           ", tortToken);
        console2.log("platformFeeRecipient:   ", platform);
    }
}
