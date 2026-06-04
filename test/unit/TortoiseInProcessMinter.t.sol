// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TortoiseInProcessMinter} from "../../src/TortoiseInProcessMinter.sol";
import {SplitRecipient} from "../../src/libraries/SplitLib.sol";
import {IMinter1155} from "../../src/interfaces/IMinter1155.sol";
import {MockInProcess1155} from "../mocks/MockInProcess1155.sol";
import {MockBadInProcess1155} from "../mocks/MockBadInProcess1155.sol";
import {MockTortoiseShellETH} from "../mocks/MockTortoiseShellETH.sol";

/// @notice Recipient that rejects plain ETH, to exercise the deferral / pending-claim path.
contract RejectETH {
    // no receive/fallback → .call with value fails
    function poke() external {}
}

contract TortoiseInProcessMinterTest is Test {
    TortoiseInProcessMinter internal minter;
    MockInProcess1155 internal nft;
    MockTortoiseShellETH internal shell;

    address internal platform = makeAddr("platform");
    address internal artist = makeAddr("artist");
    address internal collector = makeAddr("collector");

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant PRICE = 1 ether;
    uint16 internal constant PLATFORM_BPS = 500; // 5%
    uint16 internal constant STAKING_BPS = 1_000; // 10%

    function setUp() public {
        shell = new MockTortoiseShellETH();
        shell.setTortRewardPerCollection(1e18);
        shell.setPool(1_000e18);
        shell.setNextCreditedAmount(1e18); // full credit by default

        minter = new TortoiseInProcessMinter(address(shell), platform, PLATFORM_BPS, STAKING_BPS);

        nft = new MockInProcess1155();
        nft.setMaxSupply(TOKEN_ID, 1_000);
        nft.grantPermission(TOKEN_ID, address(minter), nft.PERMISSION_BIT_MINTER());

        minter.registerSong(address(nft), TOKEN_ID, artist);
        _setOpenSale(PRICE, 0);

        vm.deal(collector, 100 ether);
    }

    function _setOpenSale(uint256 price, uint64 maxPerAddr) internal {
        minter.setSale(
            address(nft),
            TOKEN_ID,
            TortoiseInProcessMinter.SaleUpdate({
                saleStart: 0,
                saleEnd: type(uint64).max,
                maxTokensPerAddress: maxPerAddr,
                pricePerToken: price
            })
        );
    }

    // ============ Happy path ============

    function test_collect_mintsAndSplits() public {
        vm.prank(collector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, "");

        assertEq(nft.balanceOf(collector, TOKEN_ID), 1, "minted");
        assertEq(platform.balance, 0.05 ether, "platform 5%");
        assertEq(artist.balance, 0.85 ether, "artist 85%");
        assertEq(shell.depositedTotal(), 0.10 ether, "shell 10%");
        assertEq(shell.creditedTo(collector), 1e18, "credited");
        assertEq(address(minter).balance, 0, "no residual");
    }

    function test_collect_multiCopyScalesCost() public {
        vm.prank(collector);
        minter.collect{value: 3 * PRICE}(address(nft), TOKEN_ID, 3, 3 * PRICE, collector, "");

        assertEq(nft.balanceOf(collector, TOKEN_ID), 3);
        assertEq(platform.balance, 0.15 ether);
        assertEq(artist.balance, 2.55 ether);
        assertEq(shell.depositedTotal(), 0.30 ether);
        // credit only once per wallet/song regardless of quantity
        assertEq(shell.creditedTo(collector), 1e18);
    }

    function test_collect_emitsMintCommentOnlyWhenNonEmpty() public {
        vm.recordLogs();
        vm.prank(collector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, "gm");
        // A non-empty comment must surface a MintComment event.
        bool found;
        bytes32 sig = keccak256("MintComment(address,uint256,address,address,uint256,string)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) found = true;
        }
        assertTrue(found, "MintComment emitted");
    }

    // ============ Validation reverts ============

    function test_collect_revertsWrongValue() public {
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(TortoiseInProcessMinter.IncorrectEthValue.selector, PRICE, PRICE - 1)
        );
        minter.collect{value: PRICE - 1}(address(nft), TOKEN_ID, 1, PRICE, collector, "");
    }

    function test_collect_revertsZeroQuantity() public {
        vm.prank(collector);
        vm.expectRevert(TortoiseInProcessMinter.ZeroQuantity.selector);
        minter.collect{value: 0}(address(nft), TOKEN_ID, 0, PRICE, collector, "");
    }

    function test_collect_revertsMaxCostExceeded() public {
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(TortoiseInProcessMinter.MaxCostExceeded.selector, PRICE, PRICE - 1)
        );
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE - 1, collector, "");
    }

    function test_collect_revertsNotRegistered() public {
        vm.prank(collector);
        vm.expectRevert(TortoiseInProcessMinter.SongNotRegistered.selector);
        minter.collect{value: PRICE}(address(nft), 999, 1, PRICE, collector, "");
    }

    function test_collect_revertsZeroMintTo() public {
        vm.prank(collector);
        vm.expectRevert(TortoiseInProcessMinter.ZeroAddress.selector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, address(0), "");
    }

    function test_collect_revertsSaleNotStarted() public {
        _setSaleWindow(uint64(block.timestamp + 1 days), type(uint64).max);
        vm.prank(collector);
        vm.expectRevert(TortoiseInProcessMinter.SaleNotStarted.selector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, "");
    }

    function test_collect_revertsSaleEnded() public {
        vm.warp(1_000);
        _setSaleWindow(0, uint64(block.timestamp - 1));
        vm.prank(collector);
        vm.expectRevert(TortoiseInProcessMinter.SaleEnded.selector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, "");
    }

    function test_collect_revertsCommentTooLong() public {
        string memory big = new string(501);
        vm.prank(collector);
        vm.expectRevert(TortoiseInProcessMinter.CommentTooLong.selector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, big);
    }

    function test_collect_perWalletCapEnforced() public {
        _setOpenSale(PRICE, 2);
        vm.startPrank(collector);
        minter.collect{value: 2 * PRICE}(address(nft), TOKEN_ID, 2, 2 * PRICE, collector, "");
        vm.expectRevert(TortoiseInProcessMinter.MaxTokensPerAddressExceeded.selector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, "");
        vm.stopPrank();
    }

    function test_collect_revertsWhenPaused() public {
        minter.pause();
        vm.prank(collector);
        vm.expectRevert();
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, "");
    }

    // ============ Shell divergence (D.8) ============

    function test_collect_shellAlreadyClaimed_stakingFoldsToArtist() public {
        // First collect claims the reward for `collector`.
        vm.prank(collector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, "");
        uint256 artistAfterFirst = artist.balance;

        // Second collect to the same wallet: already claimed → staking fee → artist.
        vm.prank(collector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, "");

        assertEq(shell.depositedTotal(), 0.10 ether, "no second deposit");
        // Second collect: artist gets 95% (85% + folded 10%).
        assertEq(artist.balance - artistAfterFirst, 0.95 ether, "staking folded to artist");
    }

    function test_collect_shellCreditReverts_stakingFoldsToArtist() public {
        shell.setShouldRevertOnCredit(true);
        vm.prank(collector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, "");

        assertEq(shell.depositedTotal(), 0, "no deposit on credit failure");
        assertEq(artist.balance, 0.95 ether, "staking folded to artist");
        assertEq(platform.balance, 0.05 ether);
    }

    function test_collect_shellDepositReverts_stakingFoldsToArtist() public {
        shell.setShouldRevertOnDeposit(true);
        vm.prank(collector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, "");

        assertEq(shell.depositedTotal(), 0, "deposit reverted");
        assertEq(artist.balance, 0.95 ether, "staking folded to artist");
    }

    // ============ Pending claims ============

    function test_collect_defersFailedArtistSend_thenClaimable() public {
        RejectETH bad = new RejectETH();
        // Re-register the song with the rejecting contract as artist.
        MockInProcess1155 nft2 = new MockInProcess1155();
        nft2.setMaxSupply(TOKEN_ID, 10);
        nft2.grantPermission(TOKEN_ID, address(minter), nft2.PERMISSION_BIT_MINTER());
        minter.registerSong(address(nft2), TOKEN_ID, address(bad));
        minter.setSale(
            address(nft2),
            TOKEN_ID,
            TortoiseInProcessMinter.SaleUpdate({
                saleStart: 0,
                saleEnd: type(uint64).max,
                maxTokensPerAddress: 0,
                pricePerToken: PRICE
            })
        );

        vm.prank(collector);
        minter.collect{value: PRICE}(address(nft2), TOKEN_ID, 1, PRICE, collector, "");

        bytes32 key = minter.songKey(address(nft2), TOKEN_ID);
        assertEq(minter.pendingClaims(key, address(bad)), 0.85 ether, "deferred");
        assertEq(minter.totalPendingClaims(), 0.85 ether);
        assertEq(address(minter).balance, 0.85 ether, "ETH backs pending claim");
    }

    // ============ Shim ============

    function test_supportsInterface() public view {
        assertTrue(minter.supportsInterface(type(IMinter1155).interfaceId), "IMinter1155");
        assertTrue(minter.supportsInterface(0x01ffc9a7), "IERC165");
        assertFalse(minter.supportsInterface(0xffffffff));
    }

    function test_requestMint_reverts() public {
        vm.expectRevert(TortoiseInProcessMinter.UseCollectInstead.selector);
        minter.requestMint(collector, TOKEN_ID, 1, PRICE, "");
    }

    // ============ helpers ============

    function _setSaleWindow(uint64 start, uint64 end) internal {
        minter.setSale(
            address(nft),
            TOKEN_ID,
            TortoiseInProcessMinter.SaleUpdate({
                saleStart: start,
                saleEnd: end,
                maxTokensPerAddress: 0,
                pricePerToken: PRICE
            })
        );
    }
}
