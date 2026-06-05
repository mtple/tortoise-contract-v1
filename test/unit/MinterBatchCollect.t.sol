// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TortoiseInProcessMinter} from "../../src/TortoiseInProcessMinter.sol";
import {MockInProcess1155} from "../mocks/MockInProcess1155.sol";
import {MockTortoiseShellETH} from "../mocks/MockTortoiseShellETH.sol";

contract MinterBatchCollectTest is Test {
    TortoiseInProcessMinter internal minter;
    MockInProcess1155 internal nft;
    MockTortoiseShellETH internal shell;

    address internal platform = makeAddr("platform");
    address internal artist = makeAddr("artist");
    address internal collector = makeAddr("collector");

    uint256 internal constant PRICE = 1 ether;

    function setUp() public {
        shell = new MockTortoiseShellETH();
        shell.setTortRewardPerCollection(1e18);
        shell.setPool(1_000e18);
        shell.setNextCreditedAmount(1e18);

        minter = new TortoiseInProcessMinter(address(shell), platform, 500, 1_000);

        nft = new MockInProcess1155();
        for (uint256 id = 1; id <= 3; id++) {
            nft.setMaxSupply(id, 1_000);
            minter.registerSong(address(nft), id, artist);
            _setSale(id, PRICE);
        }
        // tokens 1 and 2 are mintable; token 3 is registered but the minter lacks permission.
        nft.grantPermission(1, address(minter), nft.PERMISSION_BIT_MINTER());
        nft.grantPermission(2, address(minter), nft.PERMISSION_BIT_MINTER());

        vm.deal(collector, 100 ether);
    }

    function _setSale(uint256 tokenId, uint256 price) internal {
        minter.setSale(
            address(nft),
            tokenId,
            TortoiseInProcessMinter.SaleUpdate({
                saleStart: 0,
                saleEnd: type(uint64).max,
                maxTokensPerAddress: 0,
                pricePerToken: price
            })
        );
    }

    function _item(uint256 tokenId, uint256 qty, uint256 maxCost, string memory comment)
        internal
        view
        returns (TortoiseInProcessMinter.CollectItem memory)
    {
        return TortoiseInProcessMinter.CollectItem({
            collection: address(nft),
            tokenId: tokenId,
            quantity: qty,
            mintTo: collector,
            maxTotalCost: maxCost,
            comment: comment
        });
    }

    function test_batch_happyPath() public {
        TortoiseInProcessMinter.CollectItem[] memory items =
            new TortoiseInProcessMinter.CollectItem[](2);
        items[0] = _item(1, 1, PRICE, "");
        items[1] = _item(2, 2, 2 * PRICE, "");

        vm.prank(collector);
        minter.batchCollect{value: 3 * PRICE}(items, 3 * PRICE);

        assertEq(nft.balanceOf(collector, 1), 1);
        assertEq(nft.balanceOf(collector, 2), 2);
        assertEq(platform.balance, 0.15 ether, "5% of 3 ETH");
        assertEq(artist.balance, 2.55 ether, "85% of 3 ETH");
        assertEq(shell.depositedTotal(), 0.3 ether, "10% of 3 ETH");
        assertEq(address(minter).balance, 0, "no residual");
    }

    function test_batch_perItemMintToAttribution() public {
        address other = makeAddr("other");
        TortoiseInProcessMinter.CollectItem[] memory items =
            new TortoiseInProcessMinter.CollectItem[](2);
        items[0] = _item(1, 1, PRICE, "");
        items[1] = TortoiseInProcessMinter.CollectItem({
            collection: address(nft),
            tokenId: 2,
            quantity: 1,
            mintTo: other,
            maxTotalCost: PRICE,
            comment: ""
        });

        vm.prank(collector);
        minter.batchCollect{value: 2 * PRICE}(items, 2 * PRICE);

        assertEq(nft.balanceOf(collector, 1), 1, "item 0 to collector");
        assertEq(nft.balanceOf(other, 2), 1, "item 1 to other");
    }

    function test_batch_revertsWrongAggregateValue() public {
        TortoiseInProcessMinter.CollectItem[] memory items =
            new TortoiseInProcessMinter.CollectItem[](2);
        items[0] = _item(1, 1, PRICE, "");
        items[1] = _item(2, 1, PRICE, "");
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(
                TortoiseInProcessMinter.IncorrectEthValue.selector, 2 * PRICE, 2 * PRICE - 1
            )
        );
        minter.batchCollect{value: 2 * PRICE - 1}(items, 2 * PRICE);
    }

    function test_batch_revertsAggregateExceedsMax() public {
        TortoiseInProcessMinter.CollectItem[] memory items =
            new TortoiseInProcessMinter.CollectItem[](2);
        items[0] = _item(1, 1, PRICE, "");
        items[1] = _item(2, 1, PRICE, "");
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(
                TortoiseInProcessMinter.MaxCostExceeded.selector, 2 * PRICE, 2 * PRICE - 1
            )
        );
        minter.batchCollect{value: 2 * PRICE}(items, 2 * PRICE - 1);
    }

    function test_batch_revertsEmpty() public {
        TortoiseInProcessMinter.CollectItem[] memory items =
            new TortoiseInProcessMinter.CollectItem[](0);
        vm.prank(collector);
        vm.expectRevert(TortoiseInProcessMinter.EmptyBatch.selector);
        minter.batchCollect{value: 0}(items, 0);
    }

    function test_batch_revertsTooLarge() public {
        TortoiseInProcessMinter.CollectItem[] memory items =
            new TortoiseInProcessMinter.CollectItem[](21);
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(TortoiseInProcessMinter.BatchTooLarge.selector, 21, 20)
        );
        minter.batchCollect{value: 0}(items, type(uint256).max);
    }

    function test_batch_allOrNothing_unregisteredItem() public {
        TortoiseInProcessMinter.CollectItem[] memory items =
            new TortoiseInProcessMinter.CollectItem[](2);
        items[0] = _item(1, 1, PRICE, "");
        items[1] = _item(99, 1, PRICE, ""); // tokenId 99 not registered
        vm.prank(collector);
        vm.expectRevert(TortoiseInProcessMinter.SongNotRegistered.selector);
        minter.batchCollect{value: 2 * PRICE}(items, 2 * PRICE);

        // Nothing minted, no funds moved.
        assertEq(nft.balanceOf(collector, 1), 0, "all-or-nothing");
        assertEq(platform.balance, 0);
    }

    function test_batch_allOrNothing_adminMintReverts() public {
        // token 3 is registered + priced but the minter has no mint permission.
        TortoiseInProcessMinter.CollectItem[] memory items =
            new TortoiseInProcessMinter.CollectItem[](2);
        items[0] = _item(1, 1, PRICE, "");
        items[1] = _item(3, 1, PRICE, "");
        vm.prank(collector);
        vm.expectRevert(MockInProcess1155.MissingMinterPermission.selector);
        minter.batchCollect{value: 2 * PRICE}(items, 2 * PRICE);

        assertEq(nft.balanceOf(collector, 1), 0, "item 0 rolled back");
        assertEq(address(minter).balance, 0);
    }

    function test_batch_perItemComment() public {
        TortoiseInProcessMinter.CollectItem[] memory items =
            new TortoiseInProcessMinter.CollectItem[](2);
        items[0] = _item(1, 1, PRICE, "first");
        items[1] = _item(2, 1, PRICE, "");

        vm.recordLogs();
        vm.prank(collector);
        minter.batchCollect{value: 2 * PRICE}(items, 2 * PRICE);

        bytes32 sig = keccak256("MintComment(address,uint256,address,address,uint256,string)");
        uint256 count;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) count++;
        }
        assertEq(count, 1, "only the non-empty comment emits");
    }
}
