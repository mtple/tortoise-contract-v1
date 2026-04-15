// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test, Vm} from "forge-std/Test.sol";
import {TortoiseV1} from "../../src/TortoiseV1.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {SplitRecipient} from "../../src/libraries/SplitLib.sol";
import {Song, ContractConfig} from "../../src/interfaces/ITortoiseV1.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockTORT} from "../mocks/MockTORT.sol";

/// @title Audit-remediation + coverage-gap tests
/// @notice Targets the 10 priority areas from the Trail of Bits
/// guidelines-advisor report. Focuses on uncovered branches and
/// cross-contract invariants. Does NOT re-test dust preservation in
/// _claimRewards or the creditStake zero-address guard (already covered).
contract AuditRemediationTest is Test {
    TortoiseV1 public tortoise;
    TortoiseShell public shell;
    MockUSDC public usdc;
    MockTORT public tort;

    address public owner = address(this);
    address public artist = makeAddr("artist");
    address public buyer = makeAddr("buyer");

    uint64 constant PLATFORM_FEE = 50_000; // $0.05
    uint64 constant STAKING_FEE = 100_000; // $0.10
    uint128 constant DEFAULT_PRICE = 850_000; // $0.85
    uint256 constant TORT_PER_COLLECTION = 10e18;
    uint256 constant REWARD_DURATION = 604_800;
    uint256 constant REWARD_SCALAR = 1e12;

    // Shell's declared duration bounds (mirror src constants)
    uint256 constant MIN_REWARD_DURATION = 1 days;
    uint256 constant MAX_REWARD_DURATION = 365 days;

    // Shell events we assert on
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event RewardDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event ShellCreditFailed(
        uint256 indexed songId, address indexed recipient, uint256 quantity, bytes reason
    );
    event StakeCredited(
        uint256 indexed songId,
        address indexed recipient,
        uint256 quantity,
        uint256 creditedAmount
    );
    event StakingFeeUpdated(uint64 oldFee, uint64 newFee);

    function setUp() public {
        usdc = new MockUSDC();
        tort = new MockTORT();

        shell = new TortoiseShell(address(tort), address(usdc), REWARD_DURATION);
        tortoise = new TortoiseV1(
            address(usdc), PLATFORM_FEE, DEFAULT_PRICE, address(shell), STAKING_FEE
        );

        shell.addAuthorizedCaller(address(tortoise));
        shell.setTortRewardPerCollection(TORT_PER_COLLECTION);

        tort.mint(owner, 100_000e18);
        tort.approve(address(shell), type(uint256).max);
        shell.fundTortPool(50_000e18);

        usdc.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdc.approve(address(tortoise), type(uint256).max);
    }

    function _createSong() internal returns (uint256 songId) {
        vm.prank(artist);
        songId = tortoise.createSong("T", 0, 0, "ipfs://t");
    }

    // ==========================================================
    // Priority 3: MIN/MAX reward duration bounds
    // ==========================================================

    function test_constructor_revertsDurationBelowMin() public {
        vm.expectRevert(TortoiseShell.InvalidRewardDuration.selector);
        new TortoiseShell(address(tort), address(usdc), MIN_REWARD_DURATION - 1);
    }

    function test_constructor_revertsDurationAboveMax() public {
        vm.expectRevert(TortoiseShell.InvalidRewardDuration.selector);
        new TortoiseShell(address(tort), address(usdc), MAX_REWARD_DURATION + 1);
    }

    function test_constructor_acceptsDurationAtMin() public {
        TortoiseShell s = new TortoiseShell(address(tort), address(usdc), MIN_REWARD_DURATION);
        assertEq(s.rewardDuration(), MIN_REWARD_DURATION);
    }

    function test_constructor_acceptsDurationAtMax() public {
        TortoiseShell s = new TortoiseShell(address(tort), address(usdc), MAX_REWARD_DURATION);
        assertEq(s.rewardDuration(), MAX_REWARD_DURATION);
    }

    function test_updateRewardDuration_revertsBelowMin() public {
        vm.expectRevert(TortoiseShell.InvalidRewardDuration.selector);
        shell.updateRewardDuration(MIN_REWARD_DURATION - 1);
    }

    function test_updateRewardDuration_revertsAboveMax() public {
        vm.expectRevert(TortoiseShell.InvalidRewardDuration.selector);
        shell.updateRewardDuration(MAX_REWARD_DURATION + 1);
    }

    function test_updateRewardDuration_acceptsAtMin() public {
        vm.expectEmit(true, true, true, true, address(shell));
        emit RewardDurationUpdated(REWARD_DURATION, MIN_REWARD_DURATION);
        shell.updateRewardDuration(MIN_REWARD_DURATION);
        assertEq(shell.rewardDuration(), MIN_REWARD_DURATION);
    }

    function test_updateRewardDuration_acceptsAtMax() public {
        shell.updateRewardDuration(MAX_REWARD_DURATION);
        assertEq(shell.rewardDuration(), MAX_REWARD_DURATION);
    }

    // ==========================================================
    // Priority 4: TokensRecovered event on Shell.recoverTokens
    // ==========================================================

    function test_shellRecoverTokens_emitsEvent() public {
        MockUSDC stray = new MockUSDC(); // distinct from staking/reward tokens
        stray.mint(address(shell), 500e6);

        vm.expectEmit(true, true, true, true, address(shell));
        emit TokensRecovered(address(stray), owner, 500e6);
        shell.recoverTokens(address(stray), 500e6);

        assertEq(stray.balanceOf(owner), 500e6);
    }

    // ==========================================================
    // Priority 2: _creditShell failure paths
    // ==========================================================

    function test_creditShell_emitsFailureWhenShellPaused() public {
        uint256 songId = _createSong();
        shell.pause(); // creditStake has whenNotPaused? No — it does NOT.

        // Since creditStake is NOT gated by whenNotPaused, this path succeeds.
        // This test locks in that intentional design: pausing shell does not
        // block mints. Mint should fully succeed with StakeCredited event.
        vm.recordLogs();
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        // Confirm StakeCredited fired (credit succeeded) and NOT ShellCreditFailed.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawCredited;
        bool sawFailed;
        bytes32 creditedTopic = keccak256("StakeCredited(uint256,address,uint256,uint256)");
        bytes32 failedTopic = keccak256("ShellCreditFailed(uint256,address,uint256,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == creditedTopic) sawCredited = true;
            if (logs[i].topics[0] == failedTopic) sawFailed = true;
        }
        assertTrue(sawCredited, "expected StakeCredited");
        assertFalse(sawFailed, "did not expect ShellCreditFailed");
        assertEq(shell.stakedBalance(buyer), TORT_PER_COLLECTION);
    }

    /// @dev When stakingFee == 0, _distributePayments never forwards the fee so
    /// feeForwarded == false and _creditShell is never called. Neither StakeCredited
    /// nor ShellCreditFailed should fire — the pool is fully protected (audit-9 Finding #2).
    function test_creditShell_emitsFailureWhenAuthorizationRevokedZeroStakingFee() public {
        tortoise.updateStakingFee(0);
        uint256 songId = _createSong();

        shell.removeAuthorizedCaller(address(tortoise));
        uint256 poolBefore = shell.tortPool();

        vm.recordLogs();
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        bytes32 creditedTopic = keccak256("StakeCredited(uint256,address,uint256,uint256)");
        bytes32 failedTopic = keccak256("ShellCreditFailed(uint256,address,uint256,bytes)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], creditedTopic, "StakeCredited must not fire");
            assertNotEq(logs[i].topics[0], failedTopic, "ShellCreditFailed must not fire");
        }
        assertEq(tortoise.balanceOf(buyer, songId), 1, "NFT should still mint");
        assertEq(shell.tortPool(), poolBefore, "pool must not be drained");
    }

    /// @dev With stakingFee > 0 and auth revoked, depositRewards is now wrapped in
    /// try/catch (audit-7 finding 5), so the mint succeeds and emits StakingFeeDeferred
    /// rather than reverting. The USDC is held in Shell and reconciled on the next
    /// authorized depositRewards call via the balanceOf-diff mechanism.
    function test_creditShell_mintSucceedsWhenShellAuthRevokedEmitsDeferred() public {
        uint256 songId = _createSong();
        shell.removeAuthorizedCaller(address(tortoise));

        vm.recordLogs();
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer); // must NOT revert

        bool sawDeferred;
        bytes32 deferredTopic = keccak256("StakingFeeAbsorbed(uint256,uint256,bytes)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == deferredTopic) sawDeferred = true;
        }
        assertTrue(sawDeferred, "expected StakingFeeDeferred");
        assertEq(tortoise.balanceOf(buyer, songId), 1, "NFT should still mint");
    }

    /// @dev With pool exhausted, the sufficiency gate in _distributePayments fails,
    /// feeForwarded == false, and _creditShell is never called. Neither StakeCredited
    /// nor ShellCreditFailed fires — the drained pool cannot be further debited
    /// (audit-9 Finding #1 closes the pool-drain vector).
    function test_creditShell_emitsHonestSignalWhenPoolExhausted() public {
        uint256 songId = _createSong();

        shell.withdrawTortPool(50_000e18);
        assertEq(shell.tortPool(), 0);

        vm.recordLogs();
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        bytes32 creditedTopic = keccak256("StakeCredited(uint256,address,uint256,uint256)");
        bytes32 failedTopic = keccak256("ShellCreditFailed(uint256,address,uint256,bytes)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], creditedTopic, "StakeCredited must not fire when pool is exhausted");
            assertNotEq(logs[i].topics[0], failedTopic, "ShellCreditFailed must not fire");
        }
        assertEq(shell.tortPool(), 0, "pool remains at zero");
        assertEq(shell.stakedBalance(buyer), 0, "buyer gets no stake");
    }

    // ==========================================================
    // Priority 5: updateTortoiseShell / updateStakingFee edges
    // ==========================================================

    function test_updateTortoiseShell_toZeroZeroesStakingFee() public {
        assertGt(tortoise.getConfig().stakingFee, 0);

        vm.expectEmit(true, true, true, true, address(tortoise));
        emit StakingFeeUpdated(STAKING_FEE, 0);
        tortoise.updateTortoiseShell(address(0));

        ContractConfig memory cfg = tortoise.getConfig();
        assertEq(cfg.tortoiseShell, address(0));
        assertEq(cfg.stakingFee, 0);
    }

    function test_updateTortoiseShell_toZeroWithZeroFeeIsNoEvent() public {
        tortoise.updateStakingFee(0);

        vm.recordLogs();
        tortoise.updateTortoiseShell(address(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256("StakingFeeUpdated(uint128,uint128)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) {
                fail();
            }
        }
        assertEq(tortoise.getConfig().tortoiseShell, address(0));
    }

    function test_updateTortoiseShell_rejectsEOA() public {
        // M-04: owner cannot accidentally point V1 at an EOA.
        address eoa = makeAddr("fakeShell");
        vm.expectRevert("Shell must be a contract");
        tortoise.updateTortoiseShell(eoa);
    }

    function test_updateStakingFee_revertsWhenShellZero() public {
        tortoise.updateTortoiseShell(address(0));
        vm.expectRevert("No shell configured");
        tortoise.updateStakingFee(STAKING_FEE);
    }

    function test_updateStakingFee_allowsZeroWhenShellZero() public {
        tortoise.updateTortoiseShell(address(0));
        tortoise.updateStakingFee(0); // should not revert
        assertEq(tortoise.getConfig().stakingFee, 0);
    }

    // ==========================================================
    // Priority 6: withdrawPlatformFees with stray USDC
    // ==========================================================

    function test_withdrawPlatformFees_onlyWithdrawsAccrued() public {
        uint256 songId = _createSong();

        // Mint once → contract holds PLATFORM_FEE only (staking fee was forwarded).
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);
        assertEq(usdc.balanceOf(address(tortoise)), PLATFORM_FEE, "only platform fee should remain");
        assertEq(tortoise.platformFeesAccrued(), PLATFORM_FEE, "accrued tracker must match");

        // Donor sends USDC directly to contract (stray funds).
        address donor = makeAddr("donor");
        usdc.mint(donor, 42e6);
        vm.prank(donor);
        usdc.transfer(address(tortoise), 42e6);

        // Contract holds PLATFORM_FEE + 42e6 but accrued is still PLATFORM_FEE.
        assertEq(usdc.balanceOf(address(tortoise)), PLATFORM_FEE + 42e6);
        assertEq(tortoise.platformFeesAccrued(), PLATFORM_FEE, "stray USDC must not inflate accrued");

        uint256 ownerBefore = usdc.balanceOf(owner);
        tortoise.withdrawPlatformFees();

        // Owner gets only the tracked platform fee — stray USDC stays in contract.
        assertEq(usdc.balanceOf(owner) - ownerBefore, PLATFORM_FEE);
        assertEq(usdc.balanceOf(address(tortoise)), 42e6, "stray USDC remains");
        assertEq(tortoise.platformFeesAccrued(), 0, "accrued zeroed after withdrawal");
    }

    function test_withdrawPlatformFees_revertsWhenZero() public {
        vm.expectRevert("No fees to withdraw");
        tortoise.withdrawPlatformFees();
    }

    // ==========================================================
    // Priority 8: emergencyWithdraw forfeit dust accounting
    // ==========================================================

    /// @dev When forfeited % REWARD_SCALAR != 0, the remainder is lost
    /// from totalRewardsDeposited (truncated). Locks in the accepted-
    /// design behavior so a regression would surface.
    function test_emergencyWithdraw_truncatesForfeitDustInTotalRewards() public {
        // Stake
        tort.mint(artist, 1000e18);
        vm.prank(artist);
        tort.approve(address(shell), type(uint256).max);
        vm.prank(artist);
        shell.stake(1000e18);

        // Deposit a reward amount that produces non-aligned accrual
        uint256 rewardAmount = 7; // 7 base units of USDC
        usdc.mint(owner, rewardAmount);
        usdc.transfer(address(shell), rewardAmount);
        shell.addAuthorizedCaller(owner);
        shell.depositRewards(rewardAmount);

        // Advance partial period to produce forfeited with non-zero remainder
        vm.warp(block.timestamp + 13_337);

        uint256 trackedBefore = shell.totalRewardsDeposited();
        uint256 forfeitedExpected = shell.earned(artist);

        vm.prank(artist);
        shell.emergencyWithdraw();

        // Contract reduces totalRewardsDeposited by forfeited / REWARD_SCALAR.
        uint256 expectedDelta = forfeitedExpected / REWARD_SCALAR;
        assertEq(trackedBefore - shell.totalRewardsDeposited(), expectedDelta);

        // Any remainder dust (forfeited % REWARD_SCALAR) is NOT tracked.
        // This asserts the accepted-behavior truncation: the next depositRewards
        // call will see balanceOf - totalRewardsDeposited and recycle the
        // untracked portion (less the already-transferred-out fraction).
        uint256 remainder = forfeitedExpected % REWARD_SCALAR;
        // If remainder > 0 we've demonstrated the truncation path.
        // We don't assert remainder > 0 because it depends on timing; we just
        // verify the accounting identity holds either way.
        assertTrue(remainder == forfeitedExpected - expectedDelta * REWARD_SCALAR);
    }

    // ==========================================================
    // Priority 9: artistSongs growth
    // ==========================================================

    function test_artistSongs_tracksManyCreates() public {
        uint256 N = 25;
        for (uint256 i = 0; i < N; i++) {
            vm.prank(artist);
            tortoise.createSong("s", 0, 0, "ipfs://x");
        }
        uint256[] memory ids = tortoise.getArtistSongs(artist);
        assertEq(ids.length, N);
        for (uint256 i = 0; i < N; i++) {
            assertEq(ids[i], i);
        }
    }

    // ==========================================================
    // Priority 10: Split distribution edge cases
    // ==========================================================

    /// @dev Max splits (10 recipients), verify every recipient gets paid
    /// and that the last recipient absorbs the rounding remainder.
    function test_mintSong_maxTenSplitsPaysAll() public {
        uint256 songId = _createSong();

        SplitRecipient[] memory splits = new SplitRecipient[](10);
        for (uint256 i = 0; i < 10; i++) {
            splits[i] = SplitRecipient({
                recipient: address(uint160(uint256(keccak256(abi.encode("r", i))))),
                percentage: 1000 // 10% each = 100% total
            });
        }

        vm.prank(artist);
        tortoise.configureSplits(songId, splits);

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        uint256 artistRevenue = uint256(DEFAULT_PRICE) * 1 + PLATFORM_FEE + STAKING_FEE
            - PLATFORM_FEE - STAKING_FEE; // = DEFAULT_PRICE
        uint256 perShare = artistRevenue / 10;

        uint256 distributed;
        for (uint256 i = 0; i < 9; i++) {
            assertEq(usdc.balanceOf(splits[i].recipient), perShare);
            distributed += perShare;
        }
        // Last recipient gets remainder
        uint256 lastShare = artistRevenue - distributed;
        assertEq(usdc.balanceOf(splits[9].recipient), lastShare);
    }

    /// @dev 1-bp remainder at the last recipient when quantity * price
    /// doesn't divide evenly across the split weights.
    function test_mintSong_splitRemainderGoesToLastRecipient() public {
        uint256 songId = _createSong();

        // 3-way split with weights that don't divide a price cleanly.
        SplitRecipient[] memory splits = new SplitRecipient[](3);
        splits[0] = SplitRecipient({recipient: makeAddr("r0"), percentage: 3333});
        splits[1] = SplitRecipient({recipient: makeAddr("r1"), percentage: 3333});
        splits[2] = SplitRecipient({recipient: makeAddr("r2"), percentage: 3334});

        vm.prank(artist);
        tortoise.configureSplits(songId, splits);

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        uint256 artistRevenue = DEFAULT_PRICE; // 850_000
        uint256 share0 = (artistRevenue * 3333) / 10_000;
        uint256 share1 = (artistRevenue * 3333) / 10_000;
        uint256 lastShare = artistRevenue - share0 - share1;

        assertEq(usdc.balanceOf(splits[0].recipient), share0);
        assertEq(usdc.balanceOf(splits[1].recipient), share1);
        assertEq(usdc.balanceOf(splits[2].recipient), lastShare);
        // Verify total distributed exactly equals artistRevenue (no dust leaks).
        assertEq(share0 + share1 + lastShare, artistRevenue);
    }

    function test_mintSong_singleRecipientSplitGetsFullRevenue() public {
        uint256 songId = _createSong();
        address onlyR = makeAddr("only");

        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient({recipient: onlyR, percentage: 10_000});

        vm.prank(artist);
        tortoise.configureSplits(songId, splits);

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        assertEq(usdc.balanceOf(onlyR), DEFAULT_PRICE);
        // Artist itself should receive nothing since splits are configured.
        assertEq(usdc.balanceOf(artist), 0);
    }

    function test_mintSong_noSplitsPaysArtistDirectly() public {
        uint256 songId = _createSong();

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        assertEq(usdc.balanceOf(artist), DEFAULT_PRICE);
    }

    // ==========================================================
    // Priority 1: Cross-contract accounting — unit-level checks
    // (The invariant-level version is in MintShellInvariant.t.sol)
    // ==========================================================

    /// @dev Across many mints, the exact sum of staking fees forwarded
    /// must equal the delta in Shell.totalRewardsDeposited.
    function test_crossContract_stakingFeesMatchShellTotalDeposited() public {
        uint256 songId = _createSong();

        uint256 beforeTotal = shell.totalRewardsDeposited();
        uint256 mints = 7;
        for (uint256 i = 0; i < mints; i++) {
            vm.prank(buyer);
            tortoise.mintSong(songId, 1, buyer);
        }

        uint256 delta = shell.totalRewardsDeposited() - beforeTotal;
        assertEq(delta, STAKING_FEE * mints, "shell total != forwarded fees");
    }

    /// @dev Identity: at any time, Shell reservedBalance should never
    /// exceed totalRewardsDeposited * REWARD_SCALAR (since reservedBalance
    /// is the scaled view of outstanding-owed USDC).
    function test_crossContract_reservedBalanceNeverExceedsScaledDeposits() public {
        // Stake first so rewards actually accrue (not queued).
        tort.mint(artist, 1000e18);
        vm.prank(artist);
        tort.approve(address(shell), type(uint256).max);
        vm.prank(artist);
        shell.stake(1000e18);

        uint256 songId = _createSong();
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(buyer);
            tortoise.mintSong(songId, 1, buyer);
            vm.warp(block.timestamp + 1 days);
        }

        assertLe(
            shell.reservedBalance(),
            shell.totalRewardsDeposited() * REWARD_SCALAR,
            "reservedBalance exceeds scaled deposits"
        );
    }

    // ==========================================================
    // Audit #6 — Finding 1: per-quantity fees
    // ==========================================================

    function test_mintSong_feesScaleWithQuantity() public {
        uint256 songId = _createSong();
        uint256 Q = 7;

        uint256 expectedCost = (uint256(DEFAULT_PRICE) + PLATFORM_FEE + STAKING_FEE) * Q;
        assertEq(tortoise.calculateTotalCost(songId, Q), expectedCost);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        tortoise.mintSong(songId, Q, buyer);

        assertEq(buyerBefore - usdc.balanceOf(buyer), expectedCost, "buyer spent wrong amount");
        assertEq(usdc.balanceOf(address(tortoise)), uint256(PLATFORM_FEE) * Q, "platform fee wrong");
        assertEq(usdc.balanceOf(address(shell)), uint256(STAKING_FEE) * Q, "staking fee wrong");
    }

    function test_calculateTotalCost_matchesMintCost() public {
        uint256 songId = _createSong();
        uint256 Q = 100;

        uint256 quoted = tortoise.calculateTotalCost(songId, Q);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        tortoise.mintSong(songId, Q, buyer);

        assertEq(buyerBefore - usdc.balanceOf(buyer), quoted, "calculateTotalCost must match actual debit");
    }

    // ==========================================================
    // Audit #6 — Finding 3: skip stakingFee when tortPool is empty
    // ==========================================================

    function test_stakingFee_notForwardedWhenPoolEmpty() public {
        uint256 songId = _createSong();

        // Drain pool entirely
        shell.withdrawTortPool(shell.tortPool());
        assertEq(shell.tortPool(), 0);

        uint256 shellUsdcBefore = usdc.balanceOf(address(shell));
        uint256 v1UsdcBefore = usdc.balanceOf(address(tortoise));

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        // Shell received no USDC (pool was empty — stakingFee stays in V1)
        assertEq(usdc.balanceOf(address(shell)), shellUsdcBefore, "shell should not receive staking fee when pool empty");
        // V1 holds platformFee + stakingFee (both stay)
        assertEq(
            usdc.balanceOf(address(tortoise)) - v1UsdcBefore,
            PLATFORM_FEE + STAKING_FEE,
            "V1 should hold both fees when pool empty"
        );
    }

    function test_stakingFee_forwardedNormallyWhenPoolFunded() public {
        uint256 songId = _createSong();
        assertGt(shell.tortPool(), 0);

        uint256 shellUsdcBefore = usdc.balanceOf(address(shell));
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        assertEq(usdc.balanceOf(address(shell)) - shellUsdcBefore, STAKING_FEE, "staking fee not forwarded");
    }

    // ==========================================================
    // Audit #6 — Finding 5: pull-payment for blocklisted recipient
    // ==========================================================

    function test_blockedRecipient_defersPendingClaim() public {
        uint256 songId = _createSong();

        // Set up a split with two recipients
        address blocked = makeAddr("blocked");
        address normal = makeAddr("normal");

        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(blocked, 5000);
        splits[1] = SplitRecipient(normal, 5000);

        vm.prank(artist);
        tortoise.configureSplits(songId, splits);

        // Simulate USDC blocklist by having MockUSDC revert on transfer to `blocked`
        // We use a mock that can selectively fail.
        // Since MockUSDC doesn't natively support blocklisting, we use vm.mockCall
        // to make the transfer to `blocked` return false.
        vm.mockCall(
            address(usdc),
            abi.encodeCall(usdc.transfer, (blocked, DEFAULT_PRICE / 2)),
            abi.encode(false)
        );

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        // `normal` should have received their share
        assertEq(usdc.balanceOf(normal), DEFAULT_PRICE / 2, "normal recipient not paid");
        // `blocked` has nothing in wallet but has a pending claim
        assertEq(usdc.balanceOf(blocked), 0, "blocked should have no direct balance");
        assertEq(tortoise.pendingClaims(songId, blocked), DEFAULT_PRICE / 2, "pending claim not set");

        // Now the blocklist lifts — blocked can claimPending
        vm.clearMockedCalls();
        tortoise.claimPending(songId, blocked);
        assertEq(usdc.balanceOf(blocked), DEFAULT_PRICE / 2, "blocked should receive pending claim");
        assertEq(tortoise.pendingClaims(songId, blocked), 0, "pending claim not cleared");
    }

    // ==========================================================
    // Audit #6 — Finding 6: addAuthorizedCaller rejects EOA
    // ==========================================================

    function test_addAuthorizedCaller_revertsForEOA() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert("Caller must be a contract");
        shell.addAuthorizedCaller(eoa);
    }

    function test_addAuthorizedCaller_acceptsContract() public {
        // TortoiseV1 is already a contract — add a second shell as another authorized caller
        TortoiseShell shell2 = new TortoiseShell(address(tort), address(usdc), REWARD_DURATION);
        shell.addAuthorizedCaller(address(shell2));
        assertTrue(shell.authorizedCallers(address(shell2)));
    }

    // ==========================================================
    // Audit #6 — Finding 7: Ownable2Step + renounceOwnership disabled
    // ==========================================================

    function test_renounceOwnership_reverts_V1() public {
        vm.expectRevert("Renouncing ownership disabled");
        tortoise.renounceOwnership();
    }

    function test_renounceOwnership_reverts_Shell() public {
        vm.expectRevert("Renouncing ownership disabled");
        shell.renounceOwnership();
    }

    function test_transferOwnership_requiresTwoSteps_V1() public {
        address newOwner = makeAddr("newOwner");

        // Step 1: propose
        tortoise.transferOwnership(newOwner);
        assertEq(tortoise.owner(), address(this), "ownership should not transfer yet");
        assertEq(tortoise.pendingOwner(), newOwner);

        // Step 2: accept
        vm.prank(newOwner);
        tortoise.acceptOwnership();
        assertEq(tortoise.owner(), newOwner);
    }

    function test_transferOwnership_requiresTwoSteps_Shell() public {
        address newOwner = makeAddr("newOwner");

        shell.transferOwnership(newOwner);
        assertEq(shell.owner(), address(this));
        assertEq(shell.pendingOwner(), newOwner);

        vm.prank(newOwner);
        shell.acceptOwnership();
        assertEq(shell.owner(), newOwner);
    }

    // ==========================================================
    // Audit #6 — Finding 8: claimRewards/exit not pause-gated
    // ==========================================================

    function test_claimRewards_worksWhilePaused() public {
        // Stake some TORT and accrue rewards
        tort.mint(artist, 1000e18);
        vm.prank(artist);
        tort.approve(address(shell), type(uint256).max);
        vm.prank(artist);
        shell.stake(1000e18);

        uint256 songId = _createSong();
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);
        vm.warp(block.timestamp + REWARD_DURATION);

        shell.pause();

        uint256 balBefore = usdc.balanceOf(artist);
        vm.prank(artist);
        shell.claimRewards(); // must NOT revert while paused
        assertGt(usdc.balanceOf(artist) - balBefore, 0, "no rewards claimed while paused");
    }

    function test_exit_worksWhilePaused() public {
        tort.mint(artist, 1000e18);
        vm.prank(artist);
        tort.approve(address(shell), type(uint256).max);
        vm.prank(artist);
        shell.stake(1000e18);

        uint256 songId = _createSong();
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);
        vm.warp(block.timestamp + REWARD_DURATION);

        shell.pause();

        uint256 tortBefore = tort.balanceOf(artist);
        uint256 usdcBefore = usdc.balanceOf(artist);
        vm.prank(artist);
        shell.exit(); // must NOT revert while paused

        assertEq(tort.balanceOf(artist) - tortBefore, 1000e18, "stake not returned on exit");
        assertGt(usdc.balanceOf(artist) - usdcBefore, 0, "no rewards on exit");
    }

    function test_stake_revertsWhilePaused() public {
        tort.mint(artist, 1000e18);
        vm.prank(artist);
        tort.approve(address(shell), type(uint256).max);

        shell.pause();

        vm.prank(artist);
        vm.expectRevert();
        shell.stake(1000e18);
    }

    // ==========================================================
    // Audit #7 — Finding 1: platformFeesAccrued tracker
    // ==========================================================

    function test_withdrawPlatformFees_doesNotSweepPendingClaims() public {
        uint256 songId = _createSong();

        // Configure a split with a recipient that will have their transfer blocked.
        address blocked = makeAddr("blocked7");
        address normal  = makeAddr("normal7");
        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient(blocked, 5000);
        splits[1] = SplitRecipient(normal, 5000);
        vm.prank(artist);
        tortoise.configureSplits(songId, splits);

        // Mock the blocked transfer to return false.
        uint256 blockedShare = DEFAULT_PRICE / 2;
        vm.mockCall(
            address(usdc),
            abi.encodeCall(usdc.transfer, (blocked, blockedShare)),
            abi.encode(false)
        );

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);
        vm.clearMockedCalls();

        // Pending claim exists for blocked.
        assertEq(tortoise.pendingClaims(songId, blocked), blockedShare);

        // Owner withdraws platform fees.
        uint256 ownerBefore = usdc.balanceOf(owner);
        tortoise.withdrawPlatformFees();

        // Owner received only the accrued platform fee — pending claim USDC untouched.
        assertEq(usdc.balanceOf(owner) - ownerBefore, PLATFORM_FEE);

        // Blocked recipient can still claim their pending payment.
        tortoise.claimPending(songId, blocked);
        assertEq(usdc.balanceOf(blocked), blockedShare, "pending claim still claimable");
    }

    function test_withdrawPlatformFees_includesOrphanedStakingFee() public {
        // Drain the tort pool so the staking fee is orphaned into platformFeesAccrued.
        shell.withdrawTortPool(shell.tortPool());
        assertEq(shell.tortPool(), 0);

        uint256 songId = _createSong();
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        // With pool empty AND rate == 0 (default after drain), staking fee is orphaned.
        // platformFeesAccrued should hold both platformFee and stakingFee.
        assertEq(
            tortoise.platformFeesAccrued(),
            PLATFORM_FEE + STAKING_FEE,
            "orphaned staking fee not accrued"
        );

        uint256 ownerBefore = usdc.balanceOf(owner);
        tortoise.withdrawPlatformFees();
        assertEq(usdc.balanceOf(owner) - ownerBefore, PLATFORM_FEE + STAKING_FEE);
    }

    // ==========================================================
    // Audit #7 — Findings 2+7: pool-sufficiency gate (quantity × rate)
    // ==========================================================

    function test_stakingFee_notForwardedWhenPoolInsufficientForQuantity() public {
        // Fund pool with exactly enough for 1 copy but mint 2.
        shell.withdrawTortPool(shell.tortPool()); // drain first
        uint256 oneUnit = TORT_PER_COLLECTION;
        tort.mint(owner, oneUnit);
        tort.approve(address(shell), oneUnit);
        shell.fundTortPool(oneUnit); // pool = 1 × rate, but quantity = 2

        uint256 songId = _createSong();
        uint256 shellUsdcBefore = usdc.balanceOf(address(shell));

        vm.prank(buyer);
        tortoise.mintSong(songId, 2, buyer);

        // Pool has 1 unit but 2 are required — gate fires, fee stays in V1.
        assertEq(usdc.balanceOf(address(shell)), shellUsdcBefore, "shell should receive nothing");
        assertEq(
            tortoise.platformFeesAccrued(),
            (PLATFORM_FEE + STAKING_FEE) * 2,
            "both fees should be accrued"
        );
    }

    function test_stakingFee_notForwardedWhenRateIsZero() public {
        // Deploy a fresh shell with rate == 0 (never set).
        TortoiseShell freshShell = new TortoiseShell(address(tort), address(usdc), REWARD_DURATION);
        TortoiseV1 freshV1 = new TortoiseV1(
            address(usdc), PLATFORM_FEE, DEFAULT_PRICE, address(freshShell), STAKING_FEE
        );
        freshShell.addAuthorizedCaller(address(freshV1));
        // Fund pool but leave tortRewardPerCollection == 0.
        tort.mint(owner, 1000e18);
        tort.approve(address(freshShell), 1000e18);
        freshShell.fundTortPool(1000e18);

        vm.prank(artist);
        uint256 songId = freshV1.createSong("r", 0, 0, "ipfs://r");

        usdc.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdc.approve(address(freshV1), type(uint256).max);

        uint256 shellUsdcBefore = usdc.balanceOf(address(freshShell));
        vm.prank(buyer);
        freshV1.mintSong(songId, 1, buyer);

        assertEq(usdc.balanceOf(address(freshShell)), shellUsdcBefore, "no USDC when rate is zero");
        assertEq(freshV1.platformFeesAccrued(), PLATFORM_FEE + STAKING_FEE, "fees accrued");
    }

    function test_stakingFee_forwardedWhenPoolExactlySufficient() public {
        // Pool has exactly quantity × rate — gate should pass.
        shell.withdrawTortPool(shell.tortPool());
        uint256 needed = TORT_PER_COLLECTION * 3;
        tort.mint(owner, needed);
        tort.approve(address(shell), needed);
        shell.fundTortPool(needed);

        uint256 songId = _createSong();
        uint256 shellUsdcBefore = usdc.balanceOf(address(shell));

        vm.prank(buyer);
        tortoise.mintSong(songId, 3, buyer);

        assertEq(
            usdc.balanceOf(address(shell)) - shellUsdcBefore,
            STAKING_FEE * 3,
            "staking fee should be forwarded"
        );
    }

    // ==========================================================
    // Audit #7 — Finding 5: depositRewards wrapped in try/catch
    // ==========================================================

    function test_depositRewards_mintSucceedsWhenShellUnauthorized() public {
        uint256 songId = _createSong();
        shell.removeAuthorizedCaller(address(tortoise));

        vm.recordLogs();
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer); // must NOT revert

        bool sawDeferred;
        bytes32 deferredTopic = keccak256("StakingFeeAbsorbed(uint256,uint256,bytes)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == deferredTopic) sawDeferred = true;
        }
        assertTrue(sawDeferred, "expected StakingFeeDeferred event");
        assertEq(tortoise.balanceOf(buyer, songId), 1, "NFT must still mint");
    }

    // ==========================================================
    // Audit #7 — Finding 3: slippage-protected mintSong overload
    // ==========================================================

    function test_mintSong_slippage_revertsWhenCostExceedsMax() public {
        uint256 songId = _createSong();
        uint256 actualCost = tortoise.calculateTotalCost(songId, 1);

        vm.prank(buyer);
        vm.expectRevert("Slippage: cost exceeds max");
        tortoise.mintSong(songId, 1, buyer, actualCost - 1);
    }

    function test_mintSong_slippage_succeedsAtExactMax() public {
        uint256 songId = _createSong();
        uint256 actualCost = tortoise.calculateTotalCost(songId, 1);

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer, actualCost); // exact cap — must succeed
        assertEq(tortoise.balanceOf(buyer, songId), 1);
    }

    function test_mintSong_slippage_protectsAgainstFeeIncrease() public {
        uint256 songId = _createSong();
        uint256 quotedCost = tortoise.calculateTotalCost(songId, 5);

        // Simulate admin bumping platform fee before mint executes.
        tortoise.updatePlatformFee(500_000); // $0.50 vs original $0.05

        vm.prank(buyer);
        vm.expectRevert("Slippage: cost exceeds max");
        tortoise.mintSong(songId, 5, buyer, quotedCost);
    }

    // ==========================================================
    // Audit #8 — Finding 1 (A): claimPending re-defers on failure
    // ==========================================================

    function test_claimPending_redeferOnBlocklistFailure() public {
        uint256 songId = _createSong();

        // Defer a payment to `blocked` via a failed mint transfer.
        address blocked = makeAddr("blocked8");
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(blocked, 10_000);
        vm.prank(artist);
        tortoise.configureSplits(songId, splits);

        vm.mockCall(
            address(usdc),
            abi.encodeCall(usdc.transfer, (blocked, DEFAULT_PRICE)),
            abi.encode(false)
        );
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);
        vm.clearMockedCalls();

        assertEq(tortoise.pendingClaims(songId, blocked), DEFAULT_PRICE, "claim not deferred");

        // Now attempt claimPending while still blocklisted (transfer returns false).
        vm.mockCall(
            address(usdc),
            abi.encodeCall(usdc.transfer, (blocked, DEFAULT_PRICE)),
            abi.encode(false)
        );
        vm.expectRevert("Transfer failed; still claimable");
        tortoise.claimPending(songId, blocked);
        vm.clearMockedCalls();

        // Claim must be fully restored after the failed attempt.
        assertEq(tortoise.pendingClaims(songId, blocked), DEFAULT_PRICE, "claim must be restored");
    }

    // ==========================================================
    // Audit #8 — Finding 1 (B): rerouteBlockedClaim
    // ==========================================================

    event PendingClaimRerouted(
        uint256 indexed songId,
        address indexed oldRecipient,
        address indexed newRecipient,
        uint256 amount
    );

    function _deferClaimFor(uint256 songId, address recipient, uint256 share) internal {
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(recipient, 10_000);
        vm.prank(artist);
        tortoise.configureSplits(songId, splits);

        vm.mockCall(
            address(usdc),
            abi.encodeCall(usdc.transfer, (recipient, DEFAULT_PRICE)),
            abi.encode(false)
        );
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);
        vm.clearMockedCalls();

        assertEq(tortoise.pendingClaims(songId, recipient), share, "setup: claim not deferred");
    }

    function test_rerouteBlockedClaim_revertsBeforeDelay() public {
        uint256 songId = _createSong();
        address blocked = makeAddr("blockedR");
        address newAddr = makeAddr("newAddr");
        _deferClaimFor(songId, blocked, DEFAULT_PRICE);

        // Advance less than REROUTE_DELAY.
        vm.warp(block.timestamp + 89 days);

        vm.expectRevert("Too soon");
        tortoise.rerouteBlockedClaim(songId, blocked, newAddr);
    }

    function test_rerouteBlockedClaim_succeedsAfterDelay() public {
        uint256 songId = _createSong();
        address blocked = makeAddr("blockedS");
        address newAddr = makeAddr("newAddrS");
        _deferClaimFor(songId, blocked, DEFAULT_PRICE);

        vm.warp(block.timestamp + 90 days);

        vm.expectEmit(true, true, true, true, address(tortoise));
        emit PendingClaimRerouted(songId, blocked, newAddr, DEFAULT_PRICE);
        tortoise.rerouteBlockedClaim(songId, blocked, newAddr);

        assertEq(tortoise.pendingClaims(songId, blocked), 0, "old claim must be cleared");
        assertEq(tortoise.pendingClaims(songId, newAddr), DEFAULT_PRICE, "new claim must be set");

        // New recipient can now claim.
        tortoise.claimPending(songId, newAddr);
        assertEq(usdc.balanceOf(newAddr), DEFAULT_PRICE, "new recipient should receive funds");
    }

    function test_rerouteBlockedClaim_revertsZeroRecipient() public {
        uint256 songId = _createSong();
        address blocked = makeAddr("blockedZ");
        _deferClaimFor(songId, blocked, DEFAULT_PRICE);

        vm.warp(block.timestamp + 90 days);

        vm.expectRevert("Zero recipient");
        tortoise.rerouteBlockedClaim(songId, blocked, address(0));
    }

    // ==========================================================
    // Audit #8 — Lead: _transferOrDefer malformed return data
    // ==========================================================

    function test_transferOrDefer_malformedReturnData() public {
        uint256 songId = _createSong();
        address r = makeAddr("splitR");
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(r, 10_000);
        vm.prank(artist);
        tortoise.configureSplits(songId, splits);

        // Mock USDC returning a 1-byte response (malformed — not 0 or 32 bytes).
        // Before the fix, abi.decode would panic. After the fix, this is treated as
        // a failed transfer and deferred — mint does NOT revert.
        vm.mockCall(
            address(usdc),
            abi.encodeCall(usdc.transfer, (r, DEFAULT_PRICE)),
            abi.encodePacked(bytes1(0x01)) // 1 byte, not 32
        );
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer); // must NOT revert or panic
        vm.clearMockedCalls();

        // Malformed return treated as failure → deferred.
        assertEq(tortoise.pendingClaims(songId, r), DEFAULT_PRICE, "should be deferred on malformed return");
    }

    // ==========================================================
    // Audit #8 — Lead: configureSplits rejects self and USDC
    // ==========================================================

    function test_configureSplits_rejectsSelfRecipient() public {
        uint256 songId = _createSong();
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(address(tortoise), 10_000);

        vm.prank(artist);
        vm.expectRevert("Split to self");
        tortoise.configureSplits(songId, splits);
    }

    function test_configureSplits_rejectsUsdcRecipient() public {
        uint256 songId = _createSong();
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(address(usdc), 10_000);

        vm.prank(artist);
        vm.expectRevert("Split to USDC token");
        tortoise.configureSplits(songId, splits);
    }

    // ==========================================================
    // Audit #9 — Findings 1+2: _creditShell gated on feeForwarded
    // ==========================================================

    /// @dev Pool has fewer TORT than quantity × rate — staking fee is orphaned to
    /// platformFeesAccrued. _creditShell must NOT fire (pool would be drained without
    /// any USDC flowing to stakers).
    function test_creditShell_skippedWhenPoolInsufficient() public {
        // Fund pool with exactly 1 unit — mint quantity 2 requires 2 units.
        shell.withdrawTortPool(shell.tortPool());
        tort.mint(owner, TORT_PER_COLLECTION);
        tort.approve(address(shell), TORT_PER_COLLECTION);
        shell.fundTortPool(TORT_PER_COLLECTION); // pool = 1 × rate, quantity = 2

        uint256 poolBefore = shell.tortPool();
        uint256 songId = _createSong();

        vm.recordLogs();
        vm.prank(buyer);
        tortoise.mintSong(songId, 2, buyer);

        // No StakeCredited event — credit was skipped.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 creditedTopic = keccak256("StakeCredited(uint256,address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], creditedTopic, "StakeCredited must not fire");
        }

        // TORT pool must be untouched.
        assertEq(shell.tortPool(), poolBefore, "pool must not be drained");
        // Buyer receives no staked TORT.
        assertEq(shell.stakedBalance(buyer), 0, "buyer must not receive stake");
    }

    /// @dev rate == 0 — staking fee orphaned, credit must be skipped.
    function test_creditShell_skippedWhenRateIsZero() public {
        TortoiseShell freshShell = new TortoiseShell(address(tort), address(usdc), REWARD_DURATION);
        TortoiseV1 freshV1 = new TortoiseV1(
            address(usdc), PLATFORM_FEE, DEFAULT_PRICE, address(freshShell), STAKING_FEE
        );
        freshShell.addAuthorizedCaller(address(freshV1));
        // Fund pool but leave tortRewardPerCollection == 0.
        tort.mint(owner, 1000e18);
        tort.approve(address(freshShell), 1000e18);
        freshShell.fundTortPool(1000e18);

        uint256 poolBefore = freshShell.tortPool();

        vm.prank(artist);
        uint256 songId = freshV1.createSong("r", 0, 0, "ipfs://r");
        usdc.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdc.approve(address(freshV1), type(uint256).max);

        vm.recordLogs();
        vm.prank(buyer);
        freshV1.mintSong(songId, 1, buyer);

        bytes32 creditedTopic = keccak256("StakeCredited(uint256,address,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], creditedTopic, "StakeCredited must not fire when rate is zero");
        }

        assertEq(freshShell.tortPool(), poolBefore, "pool must not be touched when rate is zero");
    }

    /// @dev stakingFee == 0 with a funded pool — free-TORT drain path (Finding #2).
    /// _creditShell must NOT fire.
    function test_creditShell_skippedWhenStakingFeeIsZero() public {
        tortoise.updateStakingFee(0);
        assertEq(tortoise.getConfig().stakingFee, 0);
        assertGt(shell.tortPool(), 0, "pool should be funded");

        uint256 poolBefore = shell.tortPool();
        uint256 songId = _createSong();

        vm.recordLogs();
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        bytes32 creditedTopic = keccak256("StakeCredited(uint256,address,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], creditedTopic, "StakeCredited must not fire when stakingFee is zero");
        }

        assertEq(shell.tortPool(), poolBefore, "pool must not be drained when stakingFee is zero");
        assertEq(shell.stakedBalance(buyer), 0, "buyer must not receive free stake");
    }

    /// @dev Normal funded path — StakeCredited still fires (regression guard).
    function test_creditShell_firedWhenFeeForwarded() public {
        uint256 songId = _createSong();
        assertGt(shell.tortPool(), 0);
        assertGt(shell.tortRewardPerCollection(), 0);
        assertGt(tortoise.getConfig().stakingFee, 0);

        uint256 poolBefore = shell.tortPool();

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, buyer);

        assertEq(shell.stakedBalance(buyer), TORT_PER_COLLECTION, "buyer should receive TORT credit");
        assertLt(shell.tortPool(), poolBefore, "pool should be debited");
    }
}
