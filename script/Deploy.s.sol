// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {console} from "forge-std/Script.sol";
import {TortoiseMintRouter} from "../src/TortoiseMintRouter.sol";
import {TortoiseShell} from "../src/TortoiseShell.sol";
import {Config} from "./helpers/Config.s.sol";

contract DeployTortoise is Config {
    uint256 internal constant DEFAULT_REWARD_DURATION = 604_800;
    uint256 internal constant DEFAULT_PLATFORM_FEE_BPS = 500;
    uint256 internal constant DEFAULT_STAKING_FEE_BPS = 1000;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address usdcAddress = getUsdcAddress();
        address tortAddress = getTortAddress();
        address inProcessMinter = vm.envOr("IN_PROCESS_ERC20_MINTER", getInProcessMinterAddress());
        address platformFeeRecipient = vm.envOr("PLATFORM_FEE_RECIPIENT", deployer);
        uint256 rewardDuration = vm.envOr("REWARD_DURATION", DEFAULT_REWARD_DURATION);
        uint256 platformFeeBps = vm.envOr("INITIAL_PLATFORM_FEE_BPS", DEFAULT_PLATFORM_FEE_BPS);
        uint256 stakingFeeBps = vm.envOr("INITIAL_STAKING_FEE_BPS", DEFAULT_STAKING_FEE_BPS);

        vm.startBroadcast(deployerPrivateKey);

        TortoiseShell shell = new TortoiseShell(tortAddress, usdcAddress, rewardDuration);
        console.log("TortoiseShell deployed at:", address(shell));

        TortoiseMintRouter router = new TortoiseMintRouter(
            usdcAddress,
            inProcessMinter,
            address(shell),
            platformFeeRecipient,
            platformFeeBps,
            stakingFeeBps
        );
        console.log("TortoiseMintRouter deployed at:", address(router));

        shell.addAuthorizedCaller(address(router));
        console.log("TortoiseMintRouter registered as authorized caller on TortoiseShell");

        vm.stopBroadcast();

        console.log("USDC:", usdcAddress);
        console.log("TORT:", tortAddress);
        console.log("In Process ERC20 minter:", inProcessMinter);
        console.log("Platform fee recipient:", platformFeeRecipient);

        // Remaining manual steps:
        // 1. Fund TortoiseShell TORT pool via fundTortPool().
        // 2. Set tortRewardPerCollection on TortoiseShell.
        // 3. Update backend so new In Process moments use router as token.payoutRecipient.
    }
}
