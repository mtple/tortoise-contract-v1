// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockTORT} from "../mocks/MockTORT.sol";
import {ShellHandler} from "./handlers/ShellHandler.sol";

contract TortoiseShellInvariantTest is Test {
    TortoiseShell public shell;
    MockUSDC public usdc;
    MockTORT public tort;
    ShellHandler public handler;

    address public caller = makeAddr("caller");
    uint256 public totalTortFunded;

    function setUp() public {
        usdc = new MockUSDC();
        tort = new MockTORT();
        shell = new TortoiseShell(address(tort), address(usdc), 604_800);

        vm.etch(caller, hex"00"); // must have contract code
        shell.addAuthorizedCaller(caller);
        shell.setTortRewardPerCollection(777_777e18);

        // Fund TORT pool
        totalTortFunded = 500_000_000e18;
        tort.mint(address(this), totalTortFunded);
        tort.approve(address(shell), type(uint256).max);
        shell.fundTortPool(totalTortFunded);

        // Fund caller with USDC for reward deposits
        usdc.mint(caller, type(uint128).max);
        vm.prank(caller);
        usdc.approve(address(shell), type(uint256).max);

        handler = new ShellHandler(shell, usdc, tort, caller, address(this));

        targetContract(address(handler));
    }

    /// @dev Invariant: totalStaked == sum of all individual stakedBalances
    function invariant_totalStakedEqualsSum() public view {
        uint256 count = handler.getStakerCount();
        uint256 sum = 0;
        for (uint256 i = 0; i < count; i++) {
            address staker = handler.getStakerAt(i);
            sum += shell.stakedBalance(staker);
        }
        assertEq(shell.totalStaked(), sum, "totalStaked != sum of balances");
    }

    /// @dev Invariant: tortPool + totalTortCredited <= totalTortFunded
    function invariant_tortPoolAccountingConsistent() public view {
        assertLe(
            shell.tortPool() + shell.totalTortCredited(),
            totalTortFunded,
            "TORT pool accounting broken"
        );
    }

    /// @dev Invariant: shell's TORT balance >= tortPool + totalStaked (staked TORT + pool TORT)
    function invariant_tortBalanceCoversObligations() public view {
        uint256 shellTortBalance = tort.balanceOf(address(shell));
        assertGe(
            shellTortBalance,
            shell.tortPool() + shell.totalStaked(),
            "Shell TORT balance insufficient for obligations"
        );
    }

    /// @dev Invariant: shell's USDC balance >= what's needed to pay all claims
    ///      reservedBalance (scaled) / REWARD_SCALAR should not exceed USDC balance
    function invariant_usdcBalanceCoversReserved() public view {
        uint256 shellUsdcBalance = usdc.balanceOf(address(shell));
        uint256 reserved = shell.reservedBalance() / shell.REWARD_SCALAR();
        assertGe(
            shellUsdcBalance,
            reserved,
            "Shell USDC balance < reserved"
        );
    }

    /// @dev Invariant (audit-12 Finding 1): reservedBalance never exceeds what
    ///      totalRewardsDeposited can back. Enforces the tighter form of
    ///      "the contract can pay out everything it claims to reserve" so that
    ///      accounting bugs on the deposit/forfeit/claim paths surface here
    ///      rather than silently over-reserving user rewards.
    function invariant_reservedBalanceDoesNotExceedTotalDeposited() public view {
        assertLe(
            shell.reservedBalance(),
            shell.totalRewardsDeposited() * shell.REWARD_SCALAR(),
            "reservedBalance > totalRewardsDeposited * REWARD_SCALAR"
        );
    }
}
