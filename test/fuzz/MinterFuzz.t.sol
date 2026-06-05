// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseInProcessMinter} from "../../src/TortoiseInProcessMinter.sol";
import {MockInProcess1155} from "../mocks/MockInProcess1155.sol";
import {MockTortoiseShellETH} from "../mocks/MockTortoiseShellETH.sol";

contract MinterFuzzTest is Test {
    TortoiseInProcessMinter internal minter;
    MockInProcess1155 internal nft;
    MockTortoiseShellETH internal shell;

    address internal platform = makeAddr("platform");
    address internal artist = makeAddr("artist");
    address internal collector = makeAddr("collector");
    uint256 internal constant TOKEN_ID = 1;

    function setUp() public {
        shell = new MockTortoiseShellETH();
        shell.setTortRewardPerCollection(1e18);
        shell.setPool(1_000_000e18);
        shell.setNextCreditedAmount(1e18);
        minter = new TortoiseInProcessMinter(address(shell), platform, 500, 1_000);
        nft = new MockInProcess1155();
        nft.setMaxSupply(TOKEN_ID, type(uint256).max);
        nft.grantPermission(TOKEN_ID, address(minter), nft.PERMISSION_BIT_MINTER());
        minter.registerSong(address(nft), TOKEN_ID, artist);
    }

    function _setSale(uint256 price) internal {
        minter.setSale(
            address(nft),
            TOKEN_ID,
            TortoiseInProcessMinter.SaleUpdate({
                saleStart: 0,
                saleEnd: type(uint64).max,
                maxTokensPerAddress: 0,
                pricePerToken: price
            })
        );
    }

    /// @notice Distribution always splits exactly to platform/shell/artist with no residual.
    function testFuzz_collectDistributionSumsToValue(uint256 price, uint256 quantity) public {
        price = bound(price, 0, 1e6 ether);
        quantity = bound(quantity, 1, 1000);
        _setSale(price);

        uint256 total = price * quantity;
        vm.deal(collector, total);
        vm.prank(collector);
        minter.collect{value: total}(address(nft), TOKEN_ID, quantity, total, collector, "");

        uint256 platformFee = (total * 500) / 10_000;
        uint256 stakingFee = (total * 1_000) / 10_000;
        assertEq(platform.balance, platformFee, "platform");
        assertEq(shell.depositedTotal(), stakingFee, "shell");
        assertEq(artist.balance, total - platformFee - stakingFee, "artist");
        assertEq(address(minter).balance, 0, "no residual");
    }
}
