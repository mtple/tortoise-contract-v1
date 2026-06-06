// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseInProcessMinter} from "../../src/TortoiseInProcessMinter.sol";
import {SplitRecipient} from "../../src/libraries/SplitLib.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockInProcess1155} from "../mocks/MockInProcess1155.sol";
import {MockTortoiseShellETH} from "../mocks/MockTortoiseShellETH.sol";

/// @notice Recipient that defers (rejects) the stipend-capped split send while `accept` is
///         false, then accepts the full-gas claim once flipped. `claimTo` lets it drive the
///         delegated `claimPendingTo` path (msg.sender == recipient, so no signature needed).
contract ToggleRecipient {
    TortoiseInProcessMinter public immutable minter;
    bool public accept;

    constructor(TortoiseInProcessMinter _minter) {
        minter = _minter;
    }

    function setAccept(bool _accept) external {
        accept = _accept;
    }

    function claimTo(address collection, uint256 tokenId, uint256 amount) external {
        minter.claimPendingTo(collection, tokenId, address(this), address(this), amount, 0, 0, "");
    }

    receive() external payable {
        require(accept, "reject");
    }
}

contract MinterPauseTest is Test {
    TortoiseInProcessMinter internal minter;
    MockInProcess1155 internal nft;
    MockTortoiseShellETH internal shell;

    address internal platform = makeAddr("platform");
    address internal artist = makeAddr("artist");
    address internal collector = makeAddr("collector");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant PRICE = 1 ether;

    function setUp() public {
        shell = new MockTortoiseShellETH();
        shell.setTortRewardPerCollection(1e18);
        shell.setPool(1_000e18);
        shell.setNextCreditedAmount(1e18);

        minter = new TortoiseInProcessMinter(address(shell), platform, 500, 1_000);

        nft = new MockInProcess1155();
        nft.setMaxSupply(TOKEN_ID, 1_000);
        nft.grantPermission(TOKEN_ID, address(minter), nft.PERMISSION_BIT_MINTER());
        minter.registerSong(address(nft), TOKEN_ID, artist);
        _openSale(address(nft));

        vm.deal(collector, 100 ether);
    }

    function _openSale(address collection) internal {
        minter.setSale(
            collection,
            TOKEN_ID,
            TortoiseInProcessMinter.SaleUpdate({
                saleStart: 0,
                saleEnd: type(uint64).max,
                maxTokensPerAddress: 0,
                pricePerToken: PRICE
            })
        );
    }

    // ============ Access control ============

    function test_pause_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        minter.pause();
    }

    function test_unpause_onlyOwner() public {
        minter.pause();
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        minter.unpause();
    }

    function test_unpause_revertsWhenNotPaused() public {
        vm.expectRevert(Pausable.ExpectedPause.selector);
        minter.unpause();
    }

    // ============ Paused blocks the paid / mutation paths ============

    function test_paused_blocksCollect() public {
        minter.pause();
        vm.prank(collector);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, "");
    }

    function test_paused_blocksBatchCollect() public {
        minter.pause();
        TortoiseInProcessMinter.CollectItem[] memory items =
            new TortoiseInProcessMinter.CollectItem[](1);
        items[0] = TortoiseInProcessMinter.CollectItem({
            collection: address(nft),
            tokenId: TOKEN_ID,
            quantity: 1,
            mintTo: collector,
            maxTotalCost: PRICE,
            comment: ""
        });
        vm.prank(collector);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        minter.batchCollect{value: PRICE}(items, PRICE);
    }

    function test_paused_blocksConfigureSplits() public {
        minter.pause();
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient({recipient: artist, percentage: 10_000});
        vm.prank(artist);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        minter.configureSplits(address(nft), TOKEN_ID, splits);
    }

    // ============ Paused must NOT block claims or owner admin (D.7 / operational) ============

    function test_paused_claimPendingStillWorks() public {
        (ToggleRecipient recipient, address collection, bytes32 key) = _deferArtistSplit();

        recipient.setAccept(true);
        minter.pause();
        minter.claimPending(collection, TOKEN_ID, address(recipient));

        assertEq(address(recipient).balance, 0.85 ether, "claimPending paid while paused");
        assertEq(minter.pendingClaims(key, address(recipient)), 0, "cleared");
    }

    function test_paused_claimPendingToStillWorks() public {
        (ToggleRecipient recipient, address collection,) = _deferArtistSplit();

        recipient.setAccept(true);
        minter.pause();
        // recipient drives the delegated path itself (msg.sender == recipient).
        recipient.claimTo(collection, TOKEN_ID, 0.85 ether);

        assertEq(address(recipient).balance, 0.85 ether, "claimPendingTo paid while paused");
    }

    function test_paused_ownerCanStillSetSale() public {
        minter.pause();
        minter.setSale(
            address(nft),
            TOKEN_ID,
            TortoiseInProcessMinter.SaleUpdate({
                saleStart: 0,
                saleEnd: type(uint64).max,
                maxTokensPerAddress: 5,
                pricePerToken: 2 ether
            })
        );
        TortoiseInProcessMinter.SaleConfig memory s = minter.sale(address(nft), TOKEN_ID);
        assertEq(s.pricePerToken, 2 ether, "sale updated while paused");
        assertEq(uint256(s.maxTokensPerAddress), 5);
    }

    // ============ Unpause restores ============

    function test_unpause_restoresCollect() public {
        minter.pause();
        minter.unpause();
        vm.prank(collector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, "");
        assertEq(nft.balanceOf(collector, TOKEN_ID), 1, "collect works after unpause");
    }

    // ============ helpers ============

    /// @dev Collect once against a fresh collection whose artist is a `ToggleRecipient` that
    ///      rejects the stipend send, leaving the 85% artist split deferred as a pending claim.
    function _deferArtistSplit()
        internal
        returns (ToggleRecipient recipient, address collection, bytes32 key)
    {
        recipient = new ToggleRecipient(minter);
        MockInProcess1155 nft2 = new MockInProcess1155();
        nft2.setMaxSupply(TOKEN_ID, 10);
        nft2.grantPermission(TOKEN_ID, address(minter), nft2.PERMISSION_BIT_MINTER());
        collection = address(nft2);

        minter.registerSong(collection, TOKEN_ID, address(recipient));
        _openSale(collection);

        vm.prank(collector);
        minter.collect{value: PRICE}(collection, TOKEN_ID, 1, PRICE, collector, "");

        key = minter.songKey(collection, TOKEN_ID);
        assertEq(minter.pendingClaims(key, address(recipient)), 0.85 ether, "deferred");
    }
}
