// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Tortoise} from "../../src/Tortoise.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockTORT} from "../mocks/MockTORT.sol";
import {TortoiseHandler} from "./handlers/TortoiseHandler.sol";

contract TortoiseInvariantTest is Test {
    Tortoise internal tortoise;
    TortoiseShell internal shell;
    MockUSDC internal usdc;
    MockTORT internal tort;
    TortoiseHandler internal handler;

    function setUp() public {
        usdc = new MockUSDC();
        tort = new MockTORT();
        shell = new TortoiseShell(address(tort), address(usdc), 7 days);
        tortoise = new Tortoise(address(usdc), address(shell));
        shell.addAuthorizedCaller(address(tortoise));

        handler = new TortoiseHandler(tortoise, usdc);
        tortoise.transferOwnership(address(handler));
        vm.prank(address(handler));
        tortoise.acceptOwnership();

        targetContract(address(handler));
    }

    /// @dev The contract always holds at least the platform fees it has accrued (fees are
    ///      retained; artist revenue is paid out or deferred to pendingClaims).
    function invariant_balanceCoversPlatformFees() public view {
        assertGe(usdc.balanceOf(address(tortoise)), tortoise.platformFeesAccrued());
    }

    /// @dev Song ids are permanent: nextSongId never decreases.
    function invariant_nextSongIdMonotonic() public view {
        assertGe(tortoise.nextSongId(), handler.maxSeenNextSongId());
    }

    /// @dev Every song's committed manifest is immutable after creation.
    function invariant_manifestImmutable() public view {
        uint256 n = handler.songCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.songIds(i);
            assertEq(tortoise.releaseManifest(id), handler.manifestAtCreation(id));
        }
    }
}
