// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TortoiseMintRouter} from "../../src/TortoiseMintRouter.sol";
import {SplitRecipient} from "../../src/libraries/SplitLib.sol";
import {MockInProcessMinter} from "../mocks/MockInProcessMinter.sol";
import {MockTortoiseShell} from "../mocks/MockTortoiseShell.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

contract MockCollection {}

contract TortoiseMintRouterTest is Test {
    TortoiseMintRouter public router;
    MockInProcessMinter public minter;
    MockTortoiseShell public shell;
    MockUSDC public usdc;
    MockCollection public collection;

    address public owner = address(this);
    address public collector = makeAddr("collector");
    address public artist = makeAddr("artist");
    address public platform = makeAddr("platform");
    address public splitA = makeAddr("splitA");
    address public splitB = makeAddr("splitB");
    address public feeRecipient = makeAddr("feeRecipient");

    uint256 public constant TOKEN_ID = 1;
    uint256 public constant PRICE = 1e6;
    uint256 public constant PLATFORM_FEE_BPS = 500;
    uint256 public constant STAKING_FEE_BPS = 1000;

    function setUp() public {
        usdc = new MockUSDC();
        minter = new MockInProcessMinter();
        shell = new MockTortoiseShell();
        collection = new MockCollection();

        router = new TortoiseMintRouter(
            address(usdc),
            address(minter),
            address(shell),
            platform,
            PLATFORM_FEE_BPS,
            STAKING_FEE_BPS
        );

        minter.setSale(address(collection), TOKEN_ID, PRICE, address(router), address(usdc));
        router.registerSong(address(collection), TOKEN_ID, artist);

        usdc.mint(collector, 1000e6);
        vm.prank(collector);
        usdc.approve(address(router), type(uint256).max);
    }

    function test_collectDistributesRevenueAndCreditsShell() public {
        vm.prank(collector);
        router.collect(address(collection), TOKEN_ID, 1, PRICE);

        assertEq(usdc.balanceOf(platform), 0.05e6);
        assertEq(usdc.balanceOf(address(shell)), 0.1e6);
        assertEq(usdc.balanceOf(artist), 0.85e6);
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(shell.rewardsDeposited(), 0.1e6);
        assertEq(shell.depositCalls(), 1);
        assertEq(shell.creditCalls(), 1);
        assertEq(shell.creditedQuantity(collector), 1);
        assertEq(minter.minted(router.songKey(address(collection), TOKEN_ID), collector), 1);
        assertEq(usdc.allowance(address(router), address(minter)), 0);
    }

    function test_collectMultiCopyDistributesRevenue() public {
        vm.prank(collector);
        router.collect(address(collection), TOKEN_ID, 5, 5 * PRICE);

        assertEq(usdc.balanceOf(platform), 0.25e6);
        assertEq(usdc.balanceOf(address(shell)), 0.5e6);
        assertEq(usdc.balanceOf(artist), 4.25e6);
        assertEq(shell.rewardsDeposited(), 0.5e6);
        assertEq(shell.creditedQuantity(collector), 1);
        assertEq(minter.minted(router.songKey(address(collection), TOKEN_ID), collector), 5);
    }

    function test_collectOnlyCreditsTortOncePerSongPerWallet() public {
        vm.startPrank(collector);
        router.collect(address(collection), TOKEN_ID, 1, PRICE);
        router.collect(address(collection), TOKEN_ID, 1, PRICE);
        vm.stopPrank();

        bytes32 key = router.songKey(address(collection), TOKEN_ID);
        assertTrue(router.tortRewardClaimed(key, collector));
        assertEq(shell.depositCalls(), 2);
        assertEq(shell.rewardsDeposited(), 0.2e6);
        assertEq(shell.creditCalls(), 1);
        assertEq(shell.creditedQuantity(collector), 1);
        assertEq(minter.minted(key, collector), 2);
    }

    function test_collectCanCreditDifferentWalletsForSameSong() public {
        address secondCollector = makeAddr("secondCollector");
        usdc.mint(secondCollector, 1000e6);
        vm.prank(secondCollector);
        usdc.approve(address(router), type(uint256).max);

        vm.prank(collector);
        router.collect(address(collection), TOKEN_ID, 1, PRICE);

        vm.prank(secondCollector);
        router.collect(address(collection), TOKEN_ID, 1, PRICE);

        bytes32 key = router.songKey(address(collection), TOKEN_ID);
        assertTrue(router.tortRewardClaimed(key, collector));
        assertTrue(router.tortRewardClaimed(key, secondCollector));
        assertEq(shell.creditCalls(), 2);
        assertEq(shell.creditedQuantity(collector), 1);
        assertEq(shell.creditedQuantity(secondCollector), 1);
    }

    function test_collectDoesNotMarkTortRewardClaimedWhenShellCreditsZero() public {
        shell.setTortRewardPerCollection(0);

        vm.prank(collector);
        router.collect(address(collection), TOKEN_ID, 1, PRICE);

        bytes32 key = router.songKey(address(collection), TOKEN_ID);
        assertFalse(router.tortRewardClaimed(key, collector));
        assertEq(shell.creditCalls(), 1);
        assertEq(shell.creditedQuantity(collector), 0);
    }

    function test_collectDoesNotCreditTortWhenStakingFeeIsZero() public {
        router.updateStakingFeeBps(0);

        vm.prank(collector);
        router.collect(address(collection), TOKEN_ID, 1, PRICE);

        bytes32 key = router.songKey(address(collection), TOKEN_ID);
        assertFalse(router.tortRewardClaimed(key, collector));
        assertEq(usdc.balanceOf(address(shell)), 0);
        assertEq(shell.depositCalls(), 0);
        assertEq(shell.creditCalls(), 0);
    }

    function test_collectUsesArtistSplits() public {
        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient({recipient: splitA, percentage: 6000});
        splits[1] = SplitRecipient({recipient: splitB, percentage: 4000});

        vm.prank(artist);
        router.configureSplits(address(collection), TOKEN_ID, splits);

        vm.prank(collector);
        router.collect(address(collection), TOKEN_ID, 1, PRICE);

        assertEq(usdc.balanceOf(splitA), 0.51e6);
        assertEq(usdc.balanceOf(splitB), 0.34e6);
        assertEq(usdc.balanceOf(artist), 0);
    }

    function test_configureSplitsOnlyArtist() public {
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient({recipient: splitA, percentage: 10_000});

        vm.prank(collector);
        vm.expectRevert(TortoiseMintRouter.OnlyArtist.selector);
        router.configureSplits(address(collection), TOKEN_ID, splits);
    }

    function test_configureSplitsCanClearSplits() public {
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient({recipient: splitA, percentage: 10_000});

        vm.prank(artist);
        router.configureSplits(address(collection), TOKEN_ID, splits);

        SplitRecipient[] memory emptySplits = new SplitRecipient[](0);
        vm.prank(artist);
        router.configureSplits(address(collection), TOKEN_ID, emptySplits);

        vm.prank(collector);
        router.collect(address(collection), TOKEN_ID, 1, PRICE);

        assertEq(usdc.balanceOf(artist), 0.85e6);
        assertEq(usdc.balanceOf(splitA), 0);
    }

    function test_lockSplitsPreventsReconfiguration() public {
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient({recipient: splitA, percentage: 10_000});

        vm.prank(artist);
        router.lockSplits(address(collection), TOKEN_ID);

        vm.prank(artist);
        vm.expectRevert(TortoiseMintRouter.SplitsAreLocked.selector);
        router.configureSplits(address(collection), TOKEN_ID, splits);
    }

    function test_collectRevertsWhenMinterTakesFee() public {
        minter.setFee(1000, feeRecipient);

        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(
                TortoiseMintRouter.UnexpectedProceeds.selector, PRICE, (PRICE * 9000) / 10_000
            )
        );
        router.collect(address(collection), TOKEN_ID, 1, PRICE);

        assertEq(usdc.balanceOf(feeRecipient), 0);
    }

    function test_collectRevertsInvalidCurrency() public {
        MockUSDC otherToken = new MockUSDC();
        minter.setSale(address(collection), TOKEN_ID, PRICE, address(router), address(otherToken));

        vm.prank(collector);
        vm.expectRevert(TortoiseMintRouter.InvalidCurrency.selector);
        router.collect(address(collection), TOKEN_ID, 1, PRICE);
    }

    function test_collectRevertsInvalidFundsRecipient() public {
        minter.setSale(address(collection), TOKEN_ID, PRICE, artist, address(usdc));

        vm.prank(collector);
        vm.expectRevert(TortoiseMintRouter.InvalidFundsRecipient.selector);
        router.collect(address(collection), TOKEN_ID, 1, PRICE);
    }

    function test_collectRevertsWhenPriceExceedsMax() public {
        vm.prank(collector);
        vm.expectRevert(TortoiseMintRouter.PriceExceedsMax.selector);
        router.collect(address(collection), TOKEN_ID, 1, PRICE - 1);
    }

    function test_collectRevertsUnregisteredSong() public {
        MockCollection otherCollection = new MockCollection();
        minter.setSale(address(otherCollection), TOKEN_ID, PRICE, address(router), address(usdc));

        vm.prank(collector);
        vm.expectRevert(TortoiseMintRouter.SongNotRegistered.selector);
        router.collect(address(otherCollection), TOKEN_ID, 1, PRICE);
    }

    function test_collectRevertsZeroQuantity() public {
        vm.prank(collector);
        vm.expectRevert(TortoiseMintRouter.ZeroQuantity.selector);
        router.collect(address(collection), TOKEN_ID, 0, PRICE);
    }

    function test_shellCreditFailureDoesNotRevertCollect() public {
        shell.setFailCreditStake(true);

        vm.prank(collector);
        router.collect(address(collection), TOKEN_ID, 1, PRICE);

        assertEq(usdc.balanceOf(artist), 0.85e6);
        assertEq(shell.depositCalls(), 1);
        assertEq(shell.creditCalls(), 0);
    }

    function test_shellDepositFailureRevertsCollect() public {
        shell.setFailDepositRewards(true);

        vm.prank(collector);
        vm.expectRevert("deposit failed");
        router.collect(address(collection), TOKEN_ID, 1, PRICE);

        assertEq(usdc.balanceOf(artist), 0);
        assertEq(usdc.balanceOf(address(shell)), 0);
    }

    function test_updateTortoiseShellToZeroAlsoZerosStakingFee() public {
        router.updateTortoiseShell(address(0));

        assertEq(router.tortoiseShell(), address(0));
        assertEq(router.stakingFeeBps(), 0);

        vm.prank(collector);
        router.collect(address(collection), TOKEN_ID, 1, PRICE);

        assertEq(usdc.balanceOf(platform), 0.05e6);
        assertEq(usdc.balanceOf(artist), 0.95e6);
        assertEq(shell.depositCalls(), 0);
        assertEq(shell.creditCalls(), 0);
    }

    function test_updateStakingFeeRequiresShell() public {
        router.updateTortoiseShell(address(0));

        vm.expectRevert(TortoiseMintRouter.ShellRequired.selector);
        router.updateStakingFeeBps(1);
    }

    function test_updateFeesEnforcesIndividualCaps() public {
        uint256 overMax = router.MAX_FEE_BPS() + 1;

        vm.expectRevert(TortoiseMintRouter.FeeExceedsMaximum.selector);
        router.updatePlatformFeeBps(overMax);

        vm.expectRevert(TortoiseMintRouter.FeeExceedsMaximum.selector);
        router.updateStakingFeeBps(overMax);
    }

    function test_recoverTokensBlocksUsdc() public {
        vm.expectRevert(TortoiseMintRouter.CannotRecoverUSDC.selector);
        router.recoverTokens(address(usdc), 1);
    }

    function test_registerSongOnlyOwner() public {
        MockCollection otherCollection = new MockCollection();

        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, artist));
        router.registerSong(address(otherCollection), TOKEN_ID, artist);
    }

    function test_registerSongRejectsCollectionWithoutCode() public {
        vm.expectRevert(TortoiseMintRouter.CollectionMustBeContract.selector);
        router.registerSong(makeAddr("notCollection"), TOKEN_ID, artist);
    }

    function test_liveMinterConfigSurfaceInMockDefaultsToZero() public view {
        (address rewardRecipient, uint256 rewardPct, uint256 ethReward) =
            minter.getERC20MinterConfig();

        assertEq(minter.totalRewardPct(), 0);
        assertEq(minter.ethRewardAmount(), 0);
        assertEq(rewardRecipient, address(0));
        assertEq(rewardPct, 0);
        assertEq(ethReward, 0);
    }
}
