// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseV1} from "../../../src/TortoiseV1.sol";
import {TortoiseShell} from "../../../src/TortoiseShell.sol";
import {SplitRecipient} from "../../../src/libraries/SplitLib.sol";
import {MockUSDC} from "../../mocks/MockUSDC.sol";
import {MockTORT} from "../../mocks/MockTORT.sol";

/// @notice Cross-contract handler that drives mints, stakes, claims,
/// and emergency withdrawals to exercise the V1↔Shell boundary.
/// Tracks ghost variables for cumulative staking-fee forwarding and
/// USDC-reward claims so invariants can check conservation.
contract MintShellHandler is Test {
    TortoiseV1 public tortoise;
    TortoiseShell public shell;
    MockUSDC public usdc;
    MockTORT public tort;

    address[] public actors;
    uint256[] public songIds;
    address public immutable artist;
    address public immutable owner;
    uint128 public immutable stakingFee;

    // Ghost trackers
    uint256 public ghost_stakingFeesForwarded; // cumulative USDC forwarded to shell
    uint256 public ghost_rewardsClaimed; // cumulative USDC claimed by stakers
    uint256 public ghost_stakingCount; // number of successful stakes
    uint256 public ghost_mintsAttempted; // every mint attempt
    uint256 public ghost_mintsSucceeded; // non-reverting mints

    constructor(
        TortoiseV1 _tortoise,
        TortoiseShell _shell,
        MockUSDC _usdc,
        MockTORT _tort,
        address _artist,
        address _owner
    ) {
        tortoise = _tortoise;
        shell = _shell;
        usdc = _usdc;
        tort = _tort;
        artist = _artist;
        owner = _owner;
        stakingFee = _tortoise.getConfig().stakingFee;

        for (uint256 i = 0; i < 4; i++) {
            address a = address(uint160(uint256(keccak256(abi.encode("actor", i)))));
            actors.push(a);
            tort.mint(a, 1_000_000e18);
            usdc.mint(a, 10_000_000e6);
            vm.prank(a);
            tort.approve(address(shell), type(uint256).max);
            vm.prank(a);
            usdc.approve(address(tortoise), type(uint256).max);
        }

        // Seed one song so mints can immediately run.
        vm.prank(artist);
        songIds.push(tortoise.createSong("seed", 0, 0, "ipfs://s"));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _song(uint256 seed) internal view returns (uint256) {
        return songIds[seed % songIds.length];
    }

    // ----- V1 ops -----

    function createSong(uint256 seed) external {
        uint256 ms = uint256(keccak256(abi.encode(seed, "supply"))) % 1000;
        vm.prank(artist);
        songIds.push(
            tortoise.createSong("s", 0, uint128(ms), "ipfs://x")
        );
    }

    function mintSong(uint256 actorSeed, uint256 songSeed, uint256 qty) external {
        qty = bound(qty, 1, 5);
        address a = _actor(actorSeed);
        uint256 sid = _song(songSeed);

        ghost_mintsAttempted++;
        uint256 shellUsdcBefore = usdc.balanceOf(address(shell));
        vm.prank(a);
        try tortoise.mintSong(sid, qty, a) {
            ghost_mintsSucceeded++;
            // Staking fee scales with qty and is only forwarded when tortPool > 0.
            // Measure the actual USDC delta on shell to stay in sync.
            ghost_stakingFeesForwarded += usdc.balanceOf(address(shell)) - shellUsdcBefore;
        } catch {}
    }

    // ----- Shell ops -----

    function stake(uint256 actorSeed, uint256 amt) external {
        amt = bound(amt, 1e18, 1000e18);
        address a = _actor(actorSeed);
        vm.prank(a);
        try shell.stake(amt) {
            ghost_stakingCount++;
        } catch {}
    }

    function withdraw(uint256 actorSeed, uint256 amt) external {
        address a = _actor(actorSeed);
        uint256 bal = shell.stakedBalance(a);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        vm.prank(a);
        try shell.withdraw(amt) {} catch {}
    }

    function claimRewards(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        uint256 before = usdc.balanceOf(a);
        vm.prank(a);
        try shell.claimRewards() {
            ghost_rewardsClaimed += usdc.balanceOf(a) - before;
        } catch {}
    }

    function emergencyWithdraw(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        if (shell.stakedBalance(a) == 0) return;
        vm.prank(a);
        try shell.emergencyWithdraw() {} catch {}
    }

    function warp(uint256 t) external {
        t = bound(t, 1, 7 days);
        vm.warp(block.timestamp + t);
    }

    // ----- Phase B: admin surface -----

    /// @dev Pause/unpause the V1 contract. Invariants must hold across both.
    function toggleV1Pause(uint256 seed) external {
        vm.prank(owner);
        if (seed % 2 == 0) {
            try tortoise.pause() {} catch {}
        } else {
            try tortoise.unpause() {} catch {}
        }
    }

    /// @dev Pause/unpause the Shell contract. Invariants must hold across both.
    function toggleShellPause(uint256 seed) external {
        vm.prank(owner);
        if (seed % 2 == 0) {
            try shell.pause() {} catch {}
        } else {
            try shell.unpause() {} catch {}
        }
    }

    /// @dev Owner withdraws accrued platform fees. Exercises the
    /// platformFeesAccrued tracker path and the usdcConservation invariant
    /// (platform fees flow out of V1, don't touch the shell-side ghost).
    function withdrawPlatformFees() external {
        vm.prank(owner);
        try tortoise.withdrawPlatformFees() {} catch {}
    }

    // ----- View helpers -----

    function actorsLen() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}
