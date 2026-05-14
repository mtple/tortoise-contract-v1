// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {TORSTest} from "../src/TORSTest.sol";
import {TortoiseShell} from "../src/TortoiseShell.sol";
import {TortoiseV1} from "../src/TortoiseV1.sol";
import {TortoiseMinter} from "../src/in_process/minters/TortoiseMinter.sol";

/// @notice Full deployment on Base Sepolia.
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY     — deployer's private key
///   INITIAL_PLATFORM_FEE     — TortoiseV1 platform fee (bps, e.g. 50000)
///   INITIAL_SONG_PRICE       — TortoiseV1 default song price in USDC 6-dec (e.g. 850000)
///   INITIAL_STAKING_FEE      — TortoiseV1 staking fee (bps, e.g. 50000)
///   TORS_INITIAL_SUPPLY      — initial TORS minted to deployer (18-dec, e.g. 1000000000000000000000000)
///
/// Optional:
///   TORT_REWARD_PER_COLLECTION — TORT credited per mint (18-dec, default 0)
///
/// After deployment, fund TortoiseShell TORT pool:
///   TORSTest.approve(shell, amount) + shell.fundTortPool(amount)
contract DeployBaseSepolia is Script {
    // Base Sepolia USDC (Circle official testnet deployment)
    address constant USDC_BASE_SEPOLIA = 0x14196F08a4Fa0B66B7331bC40dd6bCd8A1dEeA9F;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        uint64 platformFee = uint64(vm.envUint("INITIAL_PLATFORM_FEE"));
        uint128 defaultPrice = uint128(vm.envUint("INITIAL_SONG_PRICE"));
        uint64 stakingFee = uint64(vm.envUint("INITIAL_STAKING_FEE"));
        uint256 torsInitialSupply = vm.envOr("TORS_INITIAL_SUPPLY", uint256(10_000_000 * 1e18));
        uint256 tortRewardPerCollection = vm.envOr("TORT_REWARD_PER_COLLECTION", uint256(0));

        console.log("=== Base Sepolia Deployment ===");
        console.log("Deployer:", deployer);
        console.log("USDC:    ", USDC_BASE_SEPOLIA);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy TORSTest
        TORSTest tors = new TORSTest(deployer, torsInitialSupply);
        console.log("TORSTest deployed at:     ", address(tors));

        // 2. Deploy TortoiseShell (stakingToken=TORS, rewardToken=USDC)
        TortoiseShell shell = new TortoiseShell(address(tors), USDC_BASE_SEPOLIA, 604_800);
        console.log("TortoiseShell deployed at:", address(shell));

        // 3. Deploy TortoiseV1
        TortoiseV1 tortoiseV1 =
            new TortoiseV1(USDC_BASE_SEPOLIA, platformFee, defaultPrice, address(shell), stakingFee);
        console.log("TortoiseV1 deployed at:   ", address(tortoiseV1));

        // 4. Register TortoiseV1 as authorized caller on TortoiseShell
        shell.addAuthorizedCaller(address(tortoiseV1));
        console.log("TortoiseV1 authorized on TortoiseShell");

        // 5. Deploy TortoiseMinter
        TortoiseMinter minter = new TortoiseMinter();
        console.log("TortoiseMinter deployed at:", address(minter));

        // 6. Initialize TortoiseMinter
        minter.initialize(address(shell), platformFee, deployer);
        console.log("TortoiseMinter initialized");

        // 7. Register TortoiseMinter as authorized caller on TortoiseShell
        shell.addAuthorizedCaller(address(minter));
        console.log("TortoiseMinter authorized on TortoiseShell");

        // 8. (Optional) Set tortRewardPerCollection if provided
        if (tortRewardPerCollection > 0) {
            shell.setTortRewardPerCollection(tortRewardPerCollection);
            console.log("tortRewardPerCollection set to:", tortRewardPerCollection);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("TORSTest:       ", address(tors));
        console.log("TortoiseShell:  ", address(shell));
        console.log("TortoiseV1:     ", address(tortoiseV1));
        console.log("TortoiseMinter: ", address(minter));
        console.log("");
        console.log("Next steps:");
        console.log("  1. Fund TORT pool: tors.approve(shell, amount) + shell.fundTortPool(amount)");
        console.log("  2. Set tortRewardPerCollection if not done above");
        console.log("  3. Verify contracts on Basescan");
    }
}
