// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseInProcessMinter} from "../../src/TortoiseInProcessMinter.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {MockInProcess1155} from "../mocks/MockInProcess1155.sol";
import {MockTORT} from "../mocks/MockTORT.sol";

/// @notice End-to-end: the real ETH TortoiseShell wired to the minter. Verifies a collect
///         routes 10% to the shell as ETH rewards, credits the collector TORT from the pool,
///         lets a staker claim ETH, and that an empty pool folds the staking fee to the artist.
contract MinterShellIntegrationTest is Test {
    TortoiseShell internal shell;
    TortoiseInProcessMinter internal minter;
    MockInProcess1155 internal nft;
    MockTORT internal tort;

    address internal platform = makeAddr("platform");
    address internal artist = makeAddr("artist");
    address internal collector = makeAddr("collector");
    address internal staker = makeAddr("staker");

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant PRICE = 1 ether;
    uint256 internal constant DURATION = 7 days;
    uint256 internal constant REWARD_PER_COLLECTION = 100e18;

    function setUp() public {
        tort = new MockTORT();
        shell = new TortoiseShell(address(tort), DURATION);
        minter = new TortoiseInProcessMinter(address(shell), platform, 500, 1_000);
        shell.addAuthorizedCaller(address(minter));

        // Fund the TORT credit pool.
        tort.mint(address(this), 1_000e18);
        tort.approve(address(shell), type(uint256).max);
        shell.fundTortPool(1_000e18);
        shell.setTortRewardPerCollection(REWARD_PER_COLLECTION);

        nft = new MockInProcess1155();
        nft.setMaxSupply(TOKEN_ID, 1_000);
        nft.grantPermission(TOKEN_ID, address(minter), nft.PERMISSION_BIT_MINTER());
        minter.registerSong(address(nft), TOKEN_ID, artist);
        _setSale(minter, TOKEN_ID, PRICE);

        // A pre-existing staker so deposited rewards have a recipient.
        tort.mint(staker, 100e18);
        vm.startPrank(staker);
        tort.approve(address(shell), type(uint256).max);
        shell.stake(100e18);
        vm.stopPrank();

        vm.deal(collector, 100 ether);
    }

    function _setSale(TortoiseInProcessMinter m, uint256 tokenId, uint256 price) internal {
        m.setSale(
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

    function test_collect_routesEthAndCreditsTort() public {
        vm.prank(collector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, "");

        assertEq(nft.balanceOf(collector, TOKEN_ID), 1, "minted");
        assertEq(platform.balance, 0.05 ether, "platform 5%");
        assertEq(artist.balance, 0.85 ether, "artist 85%");
        assertEq(address(shell).balance, 0.1 ether, "shell received 10% ETH");
        assertEq(shell.totalRewardsDeposited(), 0.1 ether);
        assertEq(shell.stakedBalance(collector), REWARD_PER_COLLECTION, "collector credited TORT");
        assertEq(shell.getTortPoolBalance(), 1_000e18 - REWARD_PER_COLLECTION, "pool debited");
    }

    function test_stakerClaimsEthReward() public {
        vm.prank(collector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, "");

        // totalStaked = 100e18 (staker) + 100e18 (collector credit); staker share = 50%.
        vm.warp(block.timestamp + DURATION);
        uint256 before = staker.balance;
        vm.prank(staker);
        shell.claimRewards();
        assertApproxEqAbs(staker.balance - before, 0.05 ether, 1e13, "staker ~50% of 0.1 ETH");
    }

    function test_collect_emptyPool_foldsStakingToArtist() public {
        // Fresh stack with an unfunded pool.
        TortoiseShell shell2 = new TortoiseShell(address(tort), DURATION);
        TortoiseInProcessMinter minter2 =
            new TortoiseInProcessMinter(address(shell2), platform, 500, 1_000);
        shell2.addAuthorizedCaller(address(minter2));
        shell2.setTortRewardPerCollection(REWARD_PER_COLLECTION); // pool stays empty

        MockInProcess1155 nft2 = new MockInProcess1155();
        nft2.setMaxSupply(TOKEN_ID, 10);
        nft2.grantPermission(TOKEN_ID, address(minter2), nft2.PERMISSION_BIT_MINTER());
        minter2.registerSong(address(nft2), TOKEN_ID, artist);
        minter2.setSale(
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
        minter2.collect{value: PRICE}(address(nft2), TOKEN_ID, 1, PRICE, collector, "");

        // creditStake returns 0 (empty pool) → staking fee folds into artist revenue.
        assertEq(address(shell2).balance, 0, "no ETH to shell");
        assertEq(artist.balance, 0.95 ether, "artist 85% + folded 10%");
        assertEq(platform.balance, 0.05 ether);
    }
}
