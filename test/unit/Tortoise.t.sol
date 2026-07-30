// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Tortoise} from "../../src/Tortoise.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {SplitRecipient} from "../../src/libraries/SplitLib.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockTORT} from "../mocks/MockTORT.sol";
import {MockRevertingShell} from "../mocks/MockRevertingShell.sol";

contract TortoiseTest is Test {
    Tortoise internal tortoise;
    TortoiseShell internal shell;
    MockUSDC internal usdc;
    MockTORT internal tort;

    address internal artist;
    uint256 internal artistPk;
    address internal collector;
    uint256 internal collectorPk;
    address internal stranger = makeAddr("stranger");
    address internal splitA = makeAddr("splitA");
    address internal splitB = makeAddr("splitB");

    uint128 internal constant PRICE = 10_000_000; // 10 USDC
    string internal constant URI = "ar://uri";
    string internal constant MANIFEST =
        '{"artSha256":"0xaa","artist":"a.eth","audioSha256":"0xbb","date":"2026-01-01","title":"X"}';

    bytes32 internal constant CREATE_SONG_TYPEHASH = keccak256(
        "CreateSong(address artist,uint128 price,uint128 maxSupply,uint96 royaltyBps,bool lockSplitsNow,bytes32 tokenUriHash,bytes32 manifestHash,bytes32 splitsHash,uint256 nonce,uint256 deadline)"
    );

    function setUp() public {
        (artist, artistPk) = makeAddrAndKey("artist");
        (collector, collectorPk) = makeAddrAndKey("collector");

        usdc = new MockUSDC();
        tort = new MockTORT();
        shell = new TortoiseShell(address(tort), address(usdc), 7 days);
        tortoise = new Tortoise(address(usdc), address(shell));
        shell.addAuthorizedCaller(address(tortoise));
        // Default: shell configured but pool unfunded (rate 0) -> staking fee orphans to platform.
    }

    // ----------------------------------------------------------------- helpers

    function _params(address _artist) internal pure returns (Tortoise.CreateSongParams memory p) {
        p.artist = _artist;
        p.price = PRICE;
        p.maxSupply = 0;
        p.royaltyBps = 0;
        p.lockSplitsNow = false;
        p.tokenUri = URI;
        p.manifest = MANIFEST;
        p.splits = new SplitRecipient[](0);
    }

    function _createSong(address _artist) internal returns (uint256 songId) {
        songId = tortoise.createSong(_params(_artist));
    }

    function _fundCollector(uint256 amount) internal {
        usdc.mint(collector, amount);
        vm.prank(collector);
        usdc.approve(address(tortoise), amount);
    }

    function _fundPool(uint256 rate, uint256 tortAmount) internal {
        shell.setTortRewardPerCollection(rate);
        tort.mint(address(this), tortAmount);
        tort.approve(address(shell), tortAmount);
        shell.fundTortPool(tortAmount);
    }

    function _tortoiseDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("Tortoise")),
                keccak256(bytes("1")),
                block.chainid,
                address(tortoise)
            )
        );
    }

    function _signCreate(
        uint256 pk,
        Tortoise.CreateSongParams memory p,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_SONG_TYPEHASH,
                p.artist,
                p.price,
                p.maxSupply,
                p.royaltyBps,
                p.lockSplitsNow,
                keccak256(bytes(p.tokenUri)),
                sha256(bytes(p.manifest)),
                keccak256(abi.encode(p.splits)),
                nonce,
                deadline
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", _tortoiseDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signReceive(
        uint256 pk,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                from,
                to,
                value,
                validAfter,
                validBefore,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ----------------------------------------------------------------- createSong

    function test_createSong_recordsSongAndManifest() public {
        uint256 id = _createSong(artist);
        Tortoise.Song memory s = tortoise.getSong(id);
        assertEq(s.artist, artist);
        assertEq(s.price, PRICE);
        assertTrue(s.exists);
        assertEq(tortoise.releaseManifest(id), sha256(bytes(MANIFEST)));
        assertEq(tortoise.uri(id), URI);
        assertEq(tortoise.getArtistSongs(artist).length, 1);
        assertEq(tortoise.nextSongId(), id + 1);
        assertFalse(tortoise.artistAttested(id));
    }

    function test_createSong_defaultRoyaltyToArtist() public {
        uint256 id = _createSong(artist);
        (address recv, uint256 amt) = tortoise.royaltyInfo(id, 10_000);
        assertEq(recv, artist);
        assertEq(amt, 500); // 5%
    }

    function test_createSong_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        tortoise.createSong(_params(artist));
    }

    function test_createSong_revertsEmptyManifest() public {
        Tortoise.CreateSongParams memory p = _params(artist);
        p.manifest = "";
        vm.expectRevert(Tortoise.EmptyManifest.selector);
        tortoise.createSong(p);
    }

    function test_createSong_revertsPriceBelowMin() public {
        Tortoise.CreateSongParams memory p = _params(artist);
        p.price = 1; // below MIN_SONG_PRICE
        vm.expectRevert(Tortoise.PriceBelowMinimum.selector);
        tortoise.createSong(p);
    }

    function test_createSong_lockWithoutSplits_freezesConfig() public {
        Tortoise.CreateSongParams memory p = _params(artist);
        p.lockSplitsNow = true; // empty splits + lock (review finding 4)
        uint256 id = tortoise.createSong(p);
        assertTrue(tortoise.getSong(id).splitsLocked);

        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient({recipient: splitA, percentage: 10_000});
        vm.prank(artist);
        vm.expectRevert(Tortoise.SplitsAreLocked.selector);
        tortoise.configureSplits(id, splits);
    }

    // ----------------------------------------------------------------- createSongWithArtistSignature

    function test_createSongSigned_happy() public {
        Tortoise.CreateSongParams memory p = _params(artist);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCreate(artistPk, p, 0, deadline);
        uint256 id = tortoise.createSongWithArtistSignature(p, 0, deadline, sig);
        assertEq(tortoise.getSong(id).artist, artist);
        assertEq(tortoise.createSongNonces(artist), 1);
        assertTrue(tortoise.artistAttested(id));
    }

    function test_createSongSigned_wrongSignerReverts() public {
        Tortoise.CreateSongParams memory p = _params(artist);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCreate(collectorPk, p, 0, deadline); // not the artist
        vm.expectRevert(Tortoise.InvalidCreateSignature.selector);
        tortoise.createSongWithArtistSignature(p, 0, deadline, sig);
    }

    function test_createSongSigned_tamperedFieldReverts() public {
        Tortoise.CreateSongParams memory p = _params(artist);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCreate(artistPk, p, 0, deadline);
        p.price = PRICE + 1; // operator tampers after the artist signed
        vm.expectRevert(Tortoise.InvalidCreateSignature.selector);
        tortoise.createSongWithArtistSignature(p, 0, deadline, sig);
    }

    function test_createSongSigned_expiredReverts() public {
        Tortoise.CreateSongParams memory p = _params(artist);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCreate(artistPk, p, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(Tortoise.SignatureExpired.selector);
        tortoise.createSongWithArtistSignature(p, 0, deadline, sig);
    }

    // ----------------------------------------------------------------- collect (approve path)

    function test_collect_splitsFeesFivePctTenPctToPlatformStakingArtist() public {
        uint256 id = _createSong(artist);
        uint256 qty = 3;
        uint256 total = uint256(PRICE) * qty; // 30 USDC
        _fundCollector(total);

        vm.prank(collector);
        tortoise.collect(id, qty, collector, total, "");

        // 5% platform + 10% staking (orphaned, pool unfunded) held; 85% to artist.
        assertEq(usdc.balanceOf(artist), 25_500_000);
        assertEq(tortoise.platformFeesAccrued(), 4_500_000); // 1.5 + 3.0 USDC
        assertEq(usdc.balanceOf(address(tortoise)), 4_500_000);
        assertEq(tortoise.balanceOf(collector, id), qty);
        assertEq(usdc.balanceOf(collector), 0);
    }

    function test_collect_mintToZeroDefaultsToPayer() public {
        uint256 id = _createSong(artist);
        uint256 total = uint256(PRICE);
        _fundCollector(total);
        vm.prank(collector);
        tortoise.collect(id, 1, address(0), total, "");
        assertEq(tortoise.balanceOf(collector, id), 1);
    }

    function test_collect_maxCostExceededReverts() public {
        uint256 id = _createSong(artist);
        uint256 total = uint256(PRICE);
        _fundCollector(total);
        vm.prank(collector);
        vm.expectRevert(abi.encodeWithSelector(Tortoise.MaxCostExceeded.selector, total, total - 1));
        tortoise.collect(id, 1, collector, total - 1, "");
    }

    function test_collect_supplyCapReverts() public {
        Tortoise.CreateSongParams memory p = _params(artist);
        p.maxSupply = 2;
        uint256 id = tortoise.createSong(p);
        uint256 total = uint256(PRICE) * 3;
        _fundCollector(total);
        vm.prank(collector);
        vm.expectRevert(Tortoise.ExceedsMaxSupply.selector);
        tortoise.collect(id, 3, collector, total, "");
    }

    function test_collect_whenPausedReverts() public {
        uint256 id = _createSong(artist);
        tortoise.pause();
        _fundCollector(uint256(PRICE));
        vm.prank(collector);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        tortoise.collect(id, 1, collector, uint256(PRICE), "");
    }

    function test_collect_withSplitsDistributesRemainderToLast() public {
        Tortoise.CreateSongParams memory p = _params(artist);
        p.splits = new SplitRecipient[](2);
        p.splits[0] = SplitRecipient({recipient: splitA, percentage: 3_000}); // 30%
        p.splits[1] = SplitRecipient({recipient: splitB, percentage: 7_000}); // 70%
        uint256 id = tortoise.createSong(p);

        uint256 qty = 3;
        uint256 total = uint256(PRICE) * qty;
        _fundCollector(total);
        vm.prank(collector);
        tortoise.collect(id, qty, collector, total, "");

        // artistRevenue = 85% of 30 USDC = 25.5 USDC; 30% / 70% of that.
        uint256 artistRevenue = 25_500_000;
        assertEq(usdc.balanceOf(splitA), (artistRevenue * 3_000) / 10_000);
        assertEq(usdc.balanceOf(splitB), artistRevenue - (artistRevenue * 3_000) / 10_000);
        assertEq(usdc.balanceOf(splitA) + usdc.balanceOf(splitB), artistRevenue);
    }

    // ----------------------------------------------------------------- collect (EIP-3009 path)

    function _collectAuth(
        uint256 id,
        uint256 qty,
        address mintTo,
        uint256 total,
        bytes32 salt,
        string memory comment
    ) internal {
        uint256 vb = block.timestamp + 1 hours;
        bytes32 nonce =
            tortoise.collectNonce(id, qty, mintTo, total, keccak256(bytes(comment)), salt);
        bytes memory sig =
            _signReceive(collectorPk, collector, address(tortoise), total, 0, vb, nonce);
        Tortoise.Eip3009Auth memory auth =
            Tortoise.Eip3009Auth({validAfter: 0, validBefore: vb, salt: salt, signature: sig});
        tortoise.collectWithAuthorization(id, qty, collector, mintTo, total, auth, comment);
    }

    function test_collectAuth_happy() public {
        uint256 id = _createSong(artist);
        uint256 qty = 2;
        uint256 total = uint256(PRICE) * qty;
        usdc.mint(collector, total); // no approve needed
        _collectAuth(id, qty, collector, total, bytes32("s1"), "gm");
        assertEq(tortoise.balanceOf(collector, id), qty);
        assertEq(usdc.balanceOf(artist), (total * 8_500) / 10_000);
        assertEq(usdc.balanceOf(collector), 0);
    }

    function test_collectAuth_relayerCannotRedirectMint() public {
        uint256 id = _createSong(artist);
        uint256 qty = 1;
        uint256 total = uint256(PRICE);
        usdc.mint(collector, total);

        // Collector signs for mintTo = collector.
        uint256 vb = block.timestamp + 1 hours;
        bytes32 nonce =
            tortoise.collectNonce(id, qty, collector, total, keccak256(bytes("")), bytes32("s"));
        bytes memory sig =
            _signReceive(collectorPk, collector, address(tortoise), total, 0, vb, nonce);
        Tortoise.Eip3009Auth memory auth = Tortoise.Eip3009Auth({
            validAfter: 0, validBefore: vb, salt: bytes32("s"), signature: sig
        });

        // Relayer submits with mintTo = stranger; contract recomputes a different nonce, so the
        // signature no longer verifies inside the token.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "MockUSDC: invalid signature"));
        tortoise.collectWithAuthorization(id, qty, collector, stranger, total, auth, "");
    }

    function test_collectAuth_wrongValueReverts() public {
        uint256 id = _createSong(artist);
        uint256 total = uint256(PRICE);
        usdc.mint(collector, total);
        uint256 vb = block.timestamp + 1 hours;
        bytes32 nonce =
            tortoise.collectNonce(id, 1, collector, total + 1, keccak256(bytes("")), bytes32("s"));
        bytes memory sig =
            _signReceive(collectorPk, collector, address(tortoise), total + 1, 0, vb, nonce);
        Tortoise.Eip3009Auth memory auth = Tortoise.Eip3009Auth({
            validAfter: 0, validBefore: vb, salt: bytes32("s"), signature: sig
        });
        vm.expectRevert(
            abi.encodeWithSelector(Tortoise.IncorrectAuthorizedValue.selector, total, total + 1)
        );
        tortoise.collectWithAuthorization(id, 1, collector, collector, total + 1, auth, "");
    }

    function test_collectAuth_replayReverts() public {
        uint256 id = _createSong(artist);
        uint256 total = uint256(PRICE);
        usdc.mint(collector, total * 2);
        _collectAuth(id, 1, collector, total, bytes32("dup"), "");
        // Same params + same salt -> same nonce -> USDC rejects reuse.
        uint256 vb = block.timestamp + 1 hours;
        bytes32 nonce =
            tortoise.collectNonce(id, 1, collector, total, keccak256(bytes("")), bytes32("dup"));
        bytes memory sig =
            _signReceive(collectorPk, collector, address(tortoise), total, 0, vb, nonce);
        Tortoise.Eip3009Auth memory auth = Tortoise.Eip3009Auth({
            validAfter: 0, validBefore: vb, salt: bytes32("dup"), signature: sig
        });
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "MockUSDC: authorization used"));
        tortoise.collectWithAuthorization(id, 1, collector, collector, total, auth, "");
    }

    // ----------------------------------------------------------------- shell credit

    function test_collect_creditsStakeWhenPoolFunded() public {
        uint256 rate = 100;
        _fundPool(rate, 1e18);
        uint256 id = _createSong(artist);
        uint256 qty = 3;
        uint256 total = uint256(PRICE) * qty;
        _fundCollector(total);
        vm.prank(collector);
        tortoise.collect(id, qty, collector, total, "");

        assertEq(shell.stakedBalance(collector), qty * rate); // TORT credited
        assertEq(tortoise.platformFeesAccrued(), 1_500_000); // only platform 5%, staking forwarded
        assertEq(usdc.balanceOf(address(shell)), 3_000_000); // staking fee 10% forwarded
    }

    function test_collect_nonBlockingWhenShellCreditReverts() public {
        MockRevertingShell rev = new MockRevertingShell();
        tortoise.updateTortoiseShell(address(rev));
        uint256 id = _createSong(artist);
        uint256 qty = 2;
        uint256 total = uint256(PRICE) * qty;
        _fundCollector(total);
        vm.prank(collector);
        tortoise.collect(id, qty, collector, total, ""); // must not revert
        assertEq(tortoise.balanceOf(collector, id), qty);
        assertEq(usdc.balanceOf(address(rev)), (total * 1_000) / 10_000); // staking fee forwarded
    }

    // ----------------------------------------------------------------- pull-payment (blocklist)

    function test_collect_defersBlockedRecipientThenClaim() public {
        uint256 id = _createSong(artist);
        usdc.setBlocked(artist, true);
        uint256 total = uint256(PRICE);
        _fundCollector(total);
        vm.prank(collector);
        tortoise.collect(id, 1, collector, total, "");

        uint256 artistRevenue = (total * 8_500) / 10_000;
        assertEq(usdc.balanceOf(artist), 0);
        assertEq(tortoise.pendingClaims(id, artist), artistRevenue);

        usdc.setBlocked(artist, false);
        tortoise.claimPending(id, artist);
        assertEq(usdc.balanceOf(artist), artistRevenue);
        assertEq(tortoise.pendingClaims(id, artist), 0);
    }

    function test_claimPending_revertsIfStillBlocked() public {
        uint256 id = _createSong(artist);
        usdc.setBlocked(artist, true);
        uint256 total = uint256(PRICE);
        _fundCollector(total);
        vm.prank(collector);
        tortoise.collect(id, 1, collector, total, "");
        vm.expectRevert(Tortoise.TransferStillFails.selector);
        tortoise.claimPending(id, artist);
    }

    function test_rerouteBlockedClaim_timelock() public {
        uint256 id = _createSong(artist);
        usdc.setBlocked(artist, true);
        uint256 total = uint256(PRICE);
        _fundCollector(total);
        vm.prank(collector);
        tortoise.collect(id, 1, collector, total, "");

        uint256 artistRevenue = (total * 8_500) / 10_000;
        vm.expectRevert(Tortoise.RerouteTooSoon.selector);
        tortoise.rerouteBlockedClaim(id, artist, stranger);

        vm.warp(block.timestamp + 90 days);
        tortoise.rerouteBlockedClaim(id, artist, stranger);
        assertEq(tortoise.pendingClaims(id, artist), 0);
        assertEq(tortoise.pendingClaims(id, stranger), artistRevenue);
    }

    // ----------------------------------------------------------------- admin

    function test_updatePlatformFeeBps_capReverts() public {
        vm.expectRevert(Tortoise.FeeTooHigh.selector);
        tortoise.updatePlatformFeeBps(2_001);
    }

    function test_updateStakingFeeBps_requiresShell() public {
        tortoise.updateTortoiseShell(address(0)); // also zeroes stakingFeeBps
        vm.expectRevert(Tortoise.ShellRequiredForStakingFee.selector);
        tortoise.updateStakingFeeBps(500);
    }

    function test_renounceOwnership_disabled() public {
        vm.expectRevert(Tortoise.RenounceDisabled.selector);
        tortoise.renounceOwnership();
    }

    function test_withdrawPlatformFees() public {
        uint256 id = _createSong(artist);
        uint256 total = uint256(PRICE);
        _fundCollector(total);
        vm.prank(collector);
        tortoise.collect(id, 1, collector, total, "");
        uint256 accrued = tortoise.platformFeesAccrued();
        assertGt(accrued, 0);
        uint256 before = usdc.balanceOf(address(this));
        tortoise.withdrawPlatformFees();
        assertEq(usdc.balanceOf(address(this)), before + accrued);
        assertEq(tortoise.platformFeesAccrued(), 0);
    }

    function test_recoverTokens_cannotRecoverUsdc() public {
        vm.expectRevert(Tortoise.CannotRecoverUSDC.selector);
        tortoise.recoverTokens(address(usdc), 1);
    }

    // ----------------------------------------------------------------- batchCollect

    function test_batchCollect_happy() public {
        uint256 id0 = _createSong(artist);
        uint256 id1 = _createSong(artist);
        Tortoise.BatchItem[] memory items = new Tortoise.BatchItem[](2);
        items[0].songId = id0;
        items[0].quantity = 2;
        items[0].mintTo = collector;
        items[1].songId = id1;
        items[1].quantity = 1;
        items[1].mintTo = collector;
        uint256 total = uint256(PRICE) * 3;
        _fundCollector(total);
        vm.prank(collector);
        tortoise.batchCollect(items, total);
        assertEq(tortoise.balanceOf(collector, id0), 2);
        assertEq(tortoise.balanceOf(collector, id1), 1);
        assertEq(usdc.balanceOf(collector), 0);
    }

    function test_batchCollect_emptyReverts() public {
        Tortoise.BatchItem[] memory items = new Tortoise.BatchItem[](0);
        vm.expectRevert(Tortoise.EmptyBatch.selector);
        tortoise.batchCollect(items, 0);
    }

    function test_batchCollect_maxAggregateReverts() public {
        uint256 id = _createSong(artist);
        Tortoise.BatchItem[] memory items = new Tortoise.BatchItem[](1);
        items[0].songId = id;
        items[0].quantity = 1;
        items[0].mintTo = collector;
        uint256 cost = uint256(PRICE);
        _fundCollector(cost);
        bytes memory err = abi.encodeWithSelector(Tortoise.MaxCostExceeded.selector, cost, cost - 1);
        vm.prank(collector);
        vm.expectRevert(err);
        tortoise.batchCollect(items, cost - 1);
    }

    function test_batchCollect_duplicateSongCannotBypassMaxSupply() public {
        Tortoise.CreateSongParams memory p = _params(artist);
        p.maxSupply = 2;
        uint256 id = tortoise.createSong(p);

        Tortoise.BatchItem[] memory items = new Tortoise.BatchItem[](2);
        items[0].songId = id;
        items[0].quantity = 2;
        items[0].mintTo = collector;
        items[1].songId = id;
        items[1].quantity = 1;
        items[1].mintTo = collector;

        vm.expectRevert(Tortoise.ExceedsMaxSupply.selector);
        tortoise.batchCollect(items, uint256(PRICE) * 3);
        assertEq(tortoise.getSong(id).currentSupply, 0);
    }

    function test_batchCollectAuth_happy() public {
        uint256 id0 = _createSong(artist);
        uint256 id1 = _createSong(artist);
        Tortoise.BatchItem[] memory items = new Tortoise.BatchItem[](2);
        items[0].songId = id0;
        items[0].quantity = 1;
        items[0].mintTo = collector;
        items[1].songId = id1;
        items[1].quantity = 1;
        items[1].mintTo = collector;
        uint256 total = uint256(PRICE) * 2;
        usdc.mint(collector, total);
        uint256 vb = block.timestamp + 1 hours;
        bytes32 nonce = tortoise.batchCollectNonce(items, collector, total, bytes32("b1"));
        bytes memory sig =
            _signReceive(collectorPk, collector, address(tortoise), total, 0, vb, nonce);
        Tortoise.Eip3009Auth memory auth = Tortoise.Eip3009Auth({
            validAfter: 0, validBefore: vb, salt: bytes32("b1"), signature: sig
        });
        tortoise.batchCollectWithAuthorization(items, collector, total, auth);
        assertEq(tortoise.balanceOf(collector, id0), 1);
        assertEq(tortoise.balanceOf(collector, id1), 1);
    }

    function test_batchCollectAuth_relayerCannotAlterItem() public {
        uint256 id0 = _createSong(artist);
        Tortoise.BatchItem[] memory items = new Tortoise.BatchItem[](1);
        items[0].songId = id0;
        items[0].quantity = 1;
        items[0].mintTo = collector;
        uint256 total = uint256(PRICE);
        usdc.mint(collector, total);
        uint256 vb = block.timestamp + 1 hours;
        bytes32 nonce = tortoise.batchCollectNonce(items, collector, total, bytes32("b"));
        bytes memory sig =
            _signReceive(collectorPk, collector, address(tortoise), total, 0, vb, nonce);
        Tortoise.Eip3009Auth memory auth = Tortoise.Eip3009Auth({
            validAfter: 0, validBefore: vb, salt: bytes32("b"), signature: sig
        });
        // Relayer swaps an item's mintTo -> keccak(items) changes -> nonce changes -> bad sig.
        items[0].mintTo = stranger;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "MockUSDC: invalid signature"));
        tortoise.batchCollectWithAuthorization(items, collector, total, auth);
    }

    // ----------------------------------------------------------------- fuzz

    /// @dev Fee waterfall conserves value: platform + staking + artist == totalCost, exactly,
    ///      for any price/quantity (no shell credit -> staking orphans to platform).
    function testFuzz_feeWaterfallConservesValue(uint128 price, uint8 qtyRaw) public {
        price = uint128(bound(uint256(price), tortoise.MIN_SONG_PRICE(), 1_000_000_000_000));
        uint256 qty = bound(uint256(qtyRaw), 1, 100);

        Tortoise.CreateSongParams memory p = _params(artist);
        p.price = price;
        uint256 id = tortoise.createSong(p);

        uint256 total = uint256(price) * qty;
        _fundCollector(total);
        vm.prank(collector);
        tortoise.collect(id, qty, collector, total, "");

        // artist got 85%-with-remainder; platform holds the rest; nothing lost or minted.
        assertEq(usdc.balanceOf(artist) + tortoise.platformFeesAccrued(), total);
        assertEq(usdc.balanceOf(address(tortoise)), tortoise.platformFeesAccrued());
    }
}
