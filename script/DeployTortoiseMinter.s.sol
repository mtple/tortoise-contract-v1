// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {TortoiseMinter} from "../src/in_process/minters/TortoiseMinter.sol";
import {TortoiseShell} from "../src/TortoiseShell.sol";

contract DeployTortoiseMinter is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address tortoiseShell = vm.envAddress("TORTOISE_SHELL_ADDRESS");
        uint256 platformFee = vm.envUint("INITIAL_PLATFORM_FEE");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy TortoiseMinter
        TortoiseMinter minter = new TortoiseMinter();
        console.log("TortoiseMinter deployed at:", address(minter));

        // 2. Initialize with TortoiseShell, platformFee, and owner
        minter.initialize(tortoiseShell, platformFee, deployer);
        console.log("TortoiseMinter initialized");
        console.log("  tortoiseShell:", tortoiseShell);
        console.log("  platformFee:  ", platformFee);
        console.log("  owner:        ", deployer);

        // 3. Register TortoiseMinter as authorized caller on TortoiseShell
        TortoiseShell(tortoiseShell).addAuthorizedCaller(address(minter));
        console.log("TortoiseMinter registered as authorized caller on TortoiseShell");

        vm.stopBroadcast();
    }
}
