// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TortoiseV1} from "../../src/TortoiseV1.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {Song, ContractConfig} from "../../src/interfaces/ITortoiseV1.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockTORT} from "../mocks/MockTORT.sol";
import {TortoiseHandler} from "./handlers/TortoiseHandler.sol";

contract TortoiseV1InvariantTest is Test {
    TortoiseV1 public tortoise;
    TortoiseShell public shell;
    MockUSDC public usdc;
    MockTORT public tort;
    TortoiseHandler public handler;

    function setUp() public {
        usdc = new MockUSDC();
        tort = new MockTORT();
        shell = new TortoiseShell(address(tort), address(usdc), 604_800);
        tortoise = new TortoiseV1(
            address(usdc),
            makeAddr("platform"),
            50_000,
            850_000,
            address(shell),
            100_000
        );

        shell.addAuthorizedCaller(address(tortoise));
        shell.setTortRewardPerCollection(777_777e18);

        tort.mint(address(this), 1_000_000_000e18);
        tort.approve(address(shell), type(uint256).max);
        shell.fundTortPool(1_000_000_000e18);

        handler = new TortoiseHandler(tortoise, shell, usdc, tort);

        targetContract(address(handler));
    }

    /// @dev Invariant: TortoiseV1 should never hold USDC after any operation
    function invariant_noUsdcInContract() public view {
        assertEq(
            usdc.balanceOf(address(tortoise)),
            0,
            "USDC stranded in TortoiseV1"
        );
    }

    /// @dev Invariant: platformFee should never exceed MAX_PLATFORM_FEE
    function invariant_platformFeeWithinBounds() public view {
        ContractConfig memory cfg = tortoise.getConfig();
        assertLe(cfg.platformFee, tortoise.MAX_PLATFORM_FEE(), "Platform fee exceeds max");
    }

    /// @dev Invariant: stakingFee should never exceed MAX_STAKING_FEE
    function invariant_stakingFeeWithinBounds() public view {
        ContractConfig memory cfg = tortoise.getConfig();
        assertLe(cfg.stakingFee, tortoise.MAX_STAKING_FEE(), "Staking fee exceeds max");
    }

    /// @dev Invariant: nextSongId >= number of songs created
    function invariant_songIdMonotonicallyIncreases() public view {
        uint256 nextId = tortoise.nextSongId();
        // Every songId from 0 to nextId-1 should exist
        for (uint256 i = 0; i < nextId && i < 20; i++) {
            Song memory song = tortoise.getSongDetails(i);
            assertTrue(song.exists, "Song should exist");
        }
    }
}
