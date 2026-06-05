// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseInProcessMinter} from "../../src/TortoiseInProcessMinter.sol";
import {SplitRecipient} from "../../src/libraries/SplitLib.sol";
import {MockInProcess1155} from "../mocks/MockInProcess1155.sol";
import {MockTortoiseShellETH} from "../mocks/MockTortoiseShellETH.sol";

/// @notice Recipient that can toggle whether it accepts ETH, to drive the deferral /
///         pending-claim paths, and relay a direct claimPendingTo (msg.sender == recipient).
contract Togglable {
    bool public accept;

    function setAccept(bool a) external {
        accept = a;
    }

    function claimTo(
        address minter,
        address collection,
        uint256 tokenId,
        address payoutTo,
        uint256 amount
    ) external {
        TortoiseInProcessMinter(minter)
            .claimPendingTo(collection, tokenId, address(this), payoutTo, amount, 0, 0, "");
    }

    receive() external payable {
        require(accept, "reject");
    }
}

contract MinterSplitsAndClaimsTest is Test {
    TortoiseInProcessMinter internal minter;
    MockInProcess1155 internal nft;
    MockTortoiseShellETH internal shell;

    address internal platform = makeAddr("platform");
    address internal artist = makeAddr("artist");
    address internal collector = makeAddr("collector");

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
        minter.setSale(
            address(nft),
            TOKEN_ID,
            TortoiseInProcessMinter.SaleUpdate({
                saleStart: 0,
                saleEnd: type(uint64).max,
                maxTokensPerAddress: 0,
                pricePerToken: PRICE
            })
        );
        vm.deal(collector, 100 ether);
    }

    function _collect() internal {
        vm.prank(collector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, "");
    }

    // ============ Multi-recipient splits ============

    function test_multiRecipientSplit_remainderToLast() public {
        address r0 = makeAddr("r0");
        address r1 = makeAddr("r1");
        address r2 = makeAddr("r2");
        SplitRecipient[] memory splits = new SplitRecipient[](3);
        splits[0] = SplitRecipient({recipient: r0, percentage: 5000});
        splits[1] = SplitRecipient({recipient: r1, percentage: 3000});
        splits[2] = SplitRecipient({recipient: r2, percentage: 2000});
        vm.prank(artist);
        minter.configureSplits(address(nft), TOKEN_ID, splits);

        _collect();

        // artistRevenue = 0.85 ETH; 50/30/remainder.
        assertEq(r0.balance, 0.425 ether);
        assertEq(r1.balance, 0.255 ether);
        assertEq(r2.balance, 0.17 ether, "remainder to last");
        assertEq(r0.balance + r1.balance + r2.balance, 0.85 ether);
    }

    function test_configureSplits_onlyArtistOrOwner() public {
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient({recipient: makeAddr("r0"), percentage: 10000});
        vm.prank(collector);
        vm.expectRevert(TortoiseInProcessMinter.NotArtist.selector);
        minter.configureSplits(address(nft), TOKEN_ID, splits);
    }

    function test_configureSplits_revertsWhenLocked() public {
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient({recipient: makeAddr("r0"), percentage: 10000});
        vm.startPrank(artist);
        minter.configureSplits(address(nft), TOKEN_ID, splits);
        minter.lockSplits(address(nft), TOKEN_ID);
        vm.expectRevert(TortoiseInProcessMinter.SplitsAreLocked.selector);
        minter.configureSplits(address(nft), TOKEN_ID, splits);
        vm.stopPrank();
    }

    function test_configureSplits_rejectsSelf() public {
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient({recipient: address(minter), percentage: 10000});
        vm.prank(artist);
        vm.expectRevert(TortoiseInProcessMinter.SplitToSelf.selector);
        minter.configureSplits(address(nft), TOKEN_ID, splits);
    }

    // ============ Pending claims ============

    function _registerDeferredArtist() internal returns (Togglable bad, bytes32 key) {
        bad = new Togglable();
        bad.setAccept(false);
        uint256 t = 2;
        nft.setMaxSupply(t, 10);
        nft.grantPermission(t, address(minter), nft.PERMISSION_BIT_MINTER());
        minter.registerSong(address(nft), t, address(bad));
        minter.setSale(
            address(nft),
            t,
            TortoiseInProcessMinter.SaleUpdate({
                saleStart: 0,
                saleEnd: type(uint64).max,
                maxTokensPerAddress: 0,
                pricePerToken: PRICE
            })
        );
        vm.prank(collector);
        minter.collect{value: PRICE}(address(nft), t, 1, PRICE, collector, "");
        key = minter.songKey(address(nft), t);
    }

    function test_claimPending_fullRetrieval() public {
        (Togglable bad, bytes32 key) = _registerDeferredArtist();
        assertEq(minter.pendingClaims(key, address(bad)), 0.85 ether, "deferred");
        assertEq(minter.totalPendingClaims(), 0.85 ether);

        bad.setAccept(true);
        minter.claimPending(address(nft), 2, address(bad));

        assertEq(address(bad).balance, 0.85 ether, "claimed");
        assertEq(minter.pendingClaims(key, address(bad)), 0);
        assertEq(minter.totalPendingClaims(), 0);

        vm.expectRevert(TortoiseInProcessMinter.NothingToClaim.selector);
        minter.claimPending(address(nft), 2, address(bad));
    }

    function test_claimPendingTo_directPartial() public {
        (Togglable bad, bytes32 key) = _registerDeferredArtist();
        address payoutTo = makeAddr("payoutTo");

        bad.claimTo(address(minter), address(nft), 2, payoutTo, 0.5 ether);

        assertEq(payoutTo.balance, 0.5 ether, "partial paid out");
        assertEq(minter.pendingClaims(key, address(bad)), 0.35 ether, "remainder still pending");
        assertEq(minter.totalPendingClaims(), 0.35 ether);
        assertEq(minter.claimPayoutNonces(key, address(bad)), 1, "nonce advanced");
    }
}
