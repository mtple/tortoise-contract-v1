// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {TortoiseV1} from "../src/TortoiseV1.sol";
import {TortoiseShell} from "../src/TortoiseShell.sol";
import {Config} from "./helpers/Config.s.sol";

contract DeployTortoise is Config {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint64 platformFee = uint64(vm.envUint("INITIAL_PLATFORM_FEE"));
        uint128 defaultPrice = uint128(vm.envUint("INITIAL_SONG_PRICE"));
        uint64 stakingFee = uint64(vm.envUint("INITIAL_STAKING_FEE"));

        address usdcAddress = getUsdcAddress();
        address tortAddress = getTortAddress();

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy TortoiseShell
        TortoiseShell shell = new TortoiseShell(tortAddress, usdcAddress, 604_800);
        console.log("TortoiseShell deployed at:", address(shell));

        // 2. Deploy TortoiseV1
        TortoiseV1 tortoise =
            new TortoiseV1(usdcAddress, platformFee, defaultPrice, address(shell), stakingFee);
        console.log("TortoiseV1 deployed at:", address(tortoise));

        // 3. Register TortoiseV1 as authorized caller
        shell.addAuthorizedCaller(address(tortoise));
        console.log("TortoiseV1 registered as authorized caller on TortoiseShell");

        vm.stopBroadcast();

        // Remaining manual steps:
        // 4. Fund TortoiseShell TORT pool via fundTortPool()
        // 5. Set tortRewardPerCollection on TortoiseShell
        // 6. Set stakingFee on TortoiseV1 (if not set at deploy)
    }
}
