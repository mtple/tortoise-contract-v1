// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseInProcessMinter} from "../../src/TortoiseInProcessMinter.sol";
import {MockInProcess1155} from "../mocks/MockInProcess1155.sol";
import {MockTortoiseShellETH} from "../mocks/MockTortoiseShellETH.sol";

/// @notice Malicious 1155 whose `adminMint` re-enters the minter's paid entrypoints to
///         probe the `nonReentrant` guard. It swallows the re-entrant revert (recording the
///         revert data) so the legitimate outer call still completes — proving the guard
///         blocks re-entry without bricking the honest path.
contract ReentrantMinter1155 {
    TortoiseInProcessMinter public minter;
    bool public batchMode;
    bool public reentryBlocked;
    bool public reentrySucceeded;
    bytes public caughtError;
    bool private _entered;
    mapping(uint256 => mapping(address => uint256)) public balances;

    function configure(TortoiseInProcessMinter _minter, bool _batchMode) external {
        minter = _minter;
        batchMode = _batchMode;
    }

    function adminMint(address recipient, uint256 tokenId, uint256 quantity, bytes calldata)
        external
    {
        balances[tokenId][recipient] += quantity;
        if (_entered) return;
        _entered = true;
        if (batchMode) {
            try this.reenterBatch(tokenId, recipient) {
                reentrySucceeded = true;
            } catch (bytes memory err) {
                reentryBlocked = true;
                caughtError = err;
            }
        } else {
            try this.reenterCollect(tokenId, recipient) {
                reentrySucceeded = true;
            } catch (bytes memory err) {
                reentryBlocked = true;
                caughtError = err;
            }
        }
    }

    function reenterCollect(uint256 tokenId, address recipient) external {
        minter.collect{value: 0}(address(this), tokenId, 1, type(uint256).max, recipient, "");
    }

    function reenterBatch(uint256 tokenId, address recipient) external {
        TortoiseInProcessMinter.CollectItem[] memory items =
            new TortoiseInProcessMinter.CollectItem[](1);
        items[0] = TortoiseInProcessMinter.CollectItem({
            collection: address(this),
            tokenId: tokenId,
            quantity: 1,
            mintTo: recipient,
            maxTotalCost: type(uint256).max,
            comment: ""
        });
        minter.batchCollect{value: 0}(items, type(uint256).max);
    }

    function balanceOf(address account, uint256 tokenId) external view returns (uint256) {
        return balances[tokenId][account];
    }
}

/// @notice A deferred-claim recipient that first rejects the stipend-capped split send
///         (forcing a pending claim) and then, once armed, re-enters `claimPending` during
///         the full-gas payout. Verifies the guard prevents a double-claim drain.
contract ReentrantClaimer {
    TortoiseInProcessMinter public immutable minter;
    address public collection;
    uint256 public tokenId;
    bool public armed;
    bool public attacked;
    bool public reentryBlocked;
    bool public reentrySucceeded;
    bytes public caughtError;

    constructor(TortoiseInProcessMinter _minter) {
        minter = _minter;
    }

    function arm(address _collection, uint256 _tokenId) external {
        collection = _collection;
        tokenId = _tokenId;
        armed = true;
    }

    receive() external payable {
        if (!armed) revert("defer"); // fail the stipend send so the split is deferred
        if (attacked) return;
        attacked = true;
        try minter.claimPending(collection, tokenId, address(this)) {
            reentrySucceeded = true;
        } catch (bytes memory err) {
            reentryBlocked = true;
            caughtError = err;
        }
    }
}

contract MinterReentrancyTest is Test {
    TortoiseInProcessMinter internal minter;
    MockTortoiseShellETH internal shell;

    address internal platform = makeAddr("platform");
    address internal artist = makeAddr("artist");
    address internal collector = makeAddr("collector");

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant PRICE = 1 ether;

    // OZ ReentrancyGuard(Transient) revert selector; a no-arg custom error encodes to exactly
    // these 4 bytes, so the full revert data equals abi.encodeWithSelector(selector).
    bytes4 internal constant REENTRANCY_GUARD_SELECTOR =
        bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    function setUp() public {
        shell = new MockTortoiseShellETH();
        shell.setTortRewardPerCollection(1e18);
        shell.setPool(1_000e18);
        shell.setNextCreditedAmount(1e18);

        minter = new TortoiseInProcessMinter(address(shell), platform, 500, 1_000);
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

    function _assertGuardRevert(bytes memory caught, string memory label) internal {
        assertEq(caught, abi.encodeWithSelector(REENTRANCY_GUARD_SELECTOR), label);
    }

    function test_collect_reentryViaAdminMintBlocked() public {
        ReentrantMinter1155 evil = new ReentrantMinter1155();
        evil.configure(minter, false);
        minter.registerSong(address(evil), TOKEN_ID, artist);
        _openSale(address(evil));

        vm.prank(collector);
        minter.collect{value: PRICE}(address(evil), TOKEN_ID, 1, PRICE, collector, "");

        // Re-entry was rejected by the guard; the honest outer collect still completed once.
        assertTrue(evil.reentryBlocked(), "re-entry blocked");
        assertFalse(evil.reentrySucceeded(), "re-entry must not succeed");
        _assertGuardRevert(evil.caughtError(), "guard selector");
        assertEq(evil.balanceOf(collector, TOKEN_ID), 1, "minted exactly once");
        assertEq(platform.balance, 0.05 ether, "platform paid once");
        assertEq(artist.balance, 0.85 ether, "artist paid once");
        assertEq(address(minter).balance, 0, "no residual");
    }

    function test_batchCollect_reentryViaAdminMintBlocked() public {
        ReentrantMinter1155 evil = new ReentrantMinter1155();
        evil.configure(minter, true);
        minter.registerSong(address(evil), TOKEN_ID, artist);
        _openSale(address(evil));

        TortoiseInProcessMinter.CollectItem[] memory items =
            new TortoiseInProcessMinter.CollectItem[](1);
        items[0] = TortoiseInProcessMinter.CollectItem({
            collection: address(evil),
            tokenId: TOKEN_ID,
            quantity: 1,
            mintTo: collector,
            maxTotalCost: PRICE,
            comment: ""
        });

        vm.prank(collector);
        minter.batchCollect{value: PRICE}(items, PRICE);

        assertTrue(evil.reentryBlocked(), "re-entry blocked");
        assertFalse(evil.reentrySucceeded(), "re-entry must not succeed");
        _assertGuardRevert(evil.caughtError(), "guard selector");
        assertEq(evil.balanceOf(collector, TOKEN_ID), 1, "minted exactly once");
        assertEq(address(minter).balance, 0, "no residual");
    }

    function test_claimPending_reentryBlocked_paysExactlyOnce() public {
        MockInProcess1155 nft = new MockInProcess1155();
        nft.setMaxSupply(TOKEN_ID, 10);
        nft.grantPermission(TOKEN_ID, address(minter), nft.PERMISSION_BIT_MINTER());

        ReentrantClaimer claimer = new ReentrantClaimer(minter);
        minter.registerSong(address(nft), TOKEN_ID, address(claimer));
        _openSale(address(nft));

        // The artist split (85%) fails the stipend send and is deferred to a pending claim.
        vm.prank(collector);
        minter.collect{value: PRICE}(address(nft), TOKEN_ID, 1, PRICE, collector, "");
        bytes32 key = minter.songKey(address(nft), TOKEN_ID);
        assertEq(minter.pendingClaims(key, address(claimer)), 0.85 ether, "deferred");

        // Arm the re-entrant attack and trigger the full-gas claim.
        claimer.arm(address(nft), TOKEN_ID);
        minter.claimPending(address(nft), TOKEN_ID, address(claimer));

        assertTrue(claimer.reentryBlocked(), "re-entry blocked");
        assertFalse(claimer.reentrySucceeded(), "re-entry must not succeed");
        _assertGuardRevert(claimer.caughtError(), "guard selector");
        assertEq(address(claimer).balance, 0.85 ether, "paid exactly once");
        assertEq(minter.pendingClaims(key, address(claimer)), 0, "claim cleared");
        assertEq(minter.totalPendingClaims(), 0, "accounting cleared");
        assertEq(address(minter).balance, 0, "no residual");
    }
}
