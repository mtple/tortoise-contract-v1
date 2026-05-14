// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseV1} from "../../src/TortoiseV1.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockTORT} from "../mocks/MockTORT.sol";
import {MintShellHandler} from "./handlers/MintShellHandler.sol";

/// @notice Cross-contract invariants spanning TortoiseV1 mints and
/// TortoiseShell reward accounting. Targets Priority 1 of the audit
/// remediation plan: staking fees forwarded from V1 must match Shell's
/// reward accounting; sub-REWARD_SCALAR dust must never be burned.
contract MintShellInvariantTest is Test {
    TortoiseV1 public tortoise;
    TortoiseShell public shell;
    MockUSDC public usdc;
    MockTORT public tort;
    MintShellHandler public handler;

    address public artist = makeAddr("artist");
    uint256 public constant REWARD_SCALAR = 1e12;

    function setUp() public {
        usdc = new MockUSDC();
        tort = new MockTORT();

        shell = new TortoiseShell(address(tort), address(usdc), 7 days);
        tortoise = new TortoiseV1(
            address(usdc),
            50_000, // platform fee
            850_000, // default price
            address(shell),
            100_000 // staking fee
        );

        shell.addAuthorizedCaller(address(tortoise));
        shell.setTortRewardPerCollection(10e18);

        tort.mint(address(this), 500_000_000e18);
        tort.approve(address(shell), type(uint256).max);
        shell.fundTortPool(500_000_000e18);

        handler = new MintShellHandler(tortoise, shell, usdc, tort, artist, address(this));

        targetContract(address(handler));
    }

    /// @dev Every successful mint forwards exactly `stakingFee` USDC to shell.
    /// Shell's cumulative-ever-deposited equals ghost tracker (modulo claims/forfeits,
    /// which decrement totalRewardsDeposited). So:
    /// totalRewardsDeposited + claimed + forfeited ≈ ghost_stakingFeesForwarded
    /// We can only assert an upper bound: totalRewardsDeposited <= forwarded.
    function invariant_totalRewardsDepositedNeverExceedsForwarded() public view {
        assertLe(
            shell.totalRewardsDeposited(),
            handler.ghost_stakingFeesForwarded(),
            "shell accounts more than it received"
        );
    }

    /// @dev USDC held by shell is always at least reservedBalance / REWARD_SCALAR
    /// (i.e. shell can always honor all outstanding claims).
    function invariant_shellSolventForClaims() public view {
        uint256 reserved = shell.reservedBalance() / REWARD_SCALAR;
        assertGe(usdc.balanceOf(address(shell)), reserved, "shell insolvent vs reservedBalance");
    }

    /// @dev Conservation: USDC flowing into shell from mints equals
    /// USDC remaining in shell + USDC claimed by stakers.
    /// Accounts for emergency-withdraw-induced "forfeiture" (USDC stays in shell).
    function invariant_usdcConservation() public view {
        uint256 shellBal = usdc.balanceOf(address(shell));
        uint256 claimed = handler.ghost_rewardsClaimed();
        uint256 forwarded = handler.ghost_stakingFeesForwarded();

        // forwarded = shellBal + claimed
        assertEq(forwarded, shellBal + claimed, "USDC conservation broken");
    }

    /// @dev totalStaked equals sum of staked balances across all actors
    /// (user-staked + credited-staked).
    function invariant_totalStakedEqualsSumOfBalances() public view {
        uint256 sum = 0;
        uint256 n = handler.actorsLen();
        for (uint256 i = 0; i < n; i++) {
            sum += shell.stakedBalance(handler.actorAt(i));
        }
        assertEq(shell.totalStaked(), sum, "totalStaked drift");
    }

    /// @dev tortPool + totalTortCredited + TORT-still-staked-from-direct-stakes
    /// must equal shell's TORT balance. Simpler: shell TORT balance >= tortPool + totalStaked.
    function invariant_tortSolvency() public view {
        assertGe(
            tort.balanceOf(address(shell)),
            shell.tortPool() + shell.totalStaked(),
            "TORT balance insufficient for obligations"
        );
    }
}
