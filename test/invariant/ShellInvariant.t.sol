// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {MockTORT} from "../mocks/MockTORT.sol";

contract ShellInvariantHandler is Test {
    TortoiseShell internal shell;
    MockTORT internal tort;
    address[] internal stakers;

    constructor(TortoiseShell _shell, MockTORT _tort, address[] memory _stakers) {
        shell = _shell;
        tort = _tort;
        stakers = _stakers;
    }

    function stake(uint256 seed, uint256 amt) public {
        address st = stakers[seed % stakers.length];
        amt = bound(amt, 1, 1e24);
        tort.mint(st, amt);
        vm.startPrank(st);
        tort.approve(address(shell), amt);
        shell.stake(amt);
        vm.stopPrank();
    }

    function withdraw(uint256 seed, uint256 amt) public {
        address st = stakers[seed % stakers.length];
        uint256 bal = shell.stakedBalance(st);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        vm.prank(st);
        shell.withdraw(amt);
    }

    function deposit(uint256 amt) public {
        amt = bound(amt, 1, 1e24);
        vm.deal(address(this), amt);
        shell.depositRewards{value: amt}();
    }

    function claim(uint256 seed) public {
        address st = stakers[seed % stakers.length];
        vm.prank(st);
        try shell.claimRewards() {} catch {}
    }

    function warp(uint256 t) public {
        t = bound(t, 1, 10 days);
        vm.warp(block.timestamp + t);
    }
}

contract ShellInvariantTest is Test {
    TortoiseShell internal shell;
    MockTORT internal tort;
    ShellInvariantHandler internal handler;

    function setUp() public {
        tort = new MockTORT();
        shell = new TortoiseShell(address(tort), 7 days);

        address[] memory stakers = new address[](3);
        stakers[0] = makeAddr("s0");
        stakers[1] = makeAddr("s1");
        stakers[2] = makeAddr("s2");

        handler = new ShellInvariantHandler(shell, tort, stakers);
        shell.addAuthorizedCaller(address(handler));
        targetContract(address(handler));
    }

    /// @notice The shell's ETH balance always equals its accounted reward liability — it can
    ///         never pay out more ETH than was deposited.
    function invariant_ethBalanceMatchesAccountedRewards() public view {
        assertEq(address(shell).balance, shell.totalRewardsDeposited());
    }
}
