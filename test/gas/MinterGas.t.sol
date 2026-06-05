// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseInProcessMinter} from "../../src/TortoiseInProcessMinter.sol";
import {SplitRecipient} from "../../src/libraries/SplitLib.sol";
import {MockInProcess1155} from "../mocks/MockInProcess1155.sol";
import {MockTortoiseShellETH} from "../mocks/MockTortoiseShellETH.sol";

/// @notice Phase-2 gas target: a worst-case 20-item batch where every item's song has 10
///         split recipients must fit well under 20M gas. NOTE: this runs against the mock
///         1155, so it measures the minter's own overhead (a lower bound) — the real on-chain
///         number must be confirmed by the fork tests against the live creator implementation.
contract MinterGasTest is Test {
    TortoiseInProcessMinter internal minter;
    MockInProcess1155 internal nft;
    MockTortoiseShellETH internal shell;

    address internal platform = makeAddr("platform");
    address internal artist = makeAddr("artist");
    address internal collector = makeAddr("collector");

    uint256 internal constant ITEMS = 20;
    uint256 internal constant SPLITS = 10;
    uint256 internal constant PRICE = 1 ether;

    function setUp() public {
        shell = new MockTortoiseShellETH();
        shell.setTortRewardPerCollection(1e18);
        shell.setPool(1_000_000e18);
        shell.setNextCreditedAmount(1e18);
        minter = new TortoiseInProcessMinter(address(shell), platform, 500, 1_000);
        nft = new MockInProcess1155();

        for (uint256 tid = 1; tid <= ITEMS; tid++) {
            nft.setMaxSupply(tid, type(uint256).max);
            nft.grantPermission(tid, address(minter), nft.PERMISSION_BIT_MINTER());
            minter.registerSong(address(nft), tid, artist);
            minter.configureSplits(address(nft), tid, _tenSplits(tid));
            minter.setSale(
                address(nft),
                tid,
                TortoiseInProcessMinter.SaleUpdate({
                    saleStart: 0,
                    saleEnd: type(uint64).max,
                    maxTokensPerAddress: 0,
                    pricePerToken: PRICE
                })
            );
        }
        vm.deal(collector, 100 ether);
    }

    function _tenSplits(uint256 tid) internal pure returns (SplitRecipient[] memory) {
        SplitRecipient[] memory splits = new SplitRecipient[](SPLITS);
        for (uint256 j; j < SPLITS; j++) {
            address r = address(uint160(uint256(keccak256(abi.encode(tid, j))) | 1));
            splits[j] = SplitRecipient({recipient: r, percentage: 1000});
        }
        return splits;
    }

    function test_gas_batch20x10splits() public {
        TortoiseInProcessMinter.CollectItem[] memory items =
            new TortoiseInProcessMinter.CollectItem[](ITEMS);
        for (uint256 i; i < ITEMS; i++) {
            items[i] = TortoiseInProcessMinter.CollectItem({
                collection: address(nft),
                tokenId: i + 1,
                quantity: 1,
                mintTo: collector,
                maxTotalCost: PRICE,
                comment: ""
            });
        }

        vm.prank(collector);
        uint256 g0 = gasleft();
        minter.batchCollect{value: ITEMS * PRICE}(items, ITEMS * PRICE);
        uint256 used = g0 - gasleft();

        emit log_named_uint("batchCollect 20x10 gas (mock 1155)", used);
        assertLt(used, 20_000_000, "under 20M gas");
    }
}
