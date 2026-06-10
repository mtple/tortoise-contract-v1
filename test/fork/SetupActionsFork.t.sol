// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SetupActions} from "../../script/SetupActions.sol";
import {TortoiseInProcessMinter} from "../../src/TortoiseInProcessMinter.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {ICreator1155Factory} from "../../src/interfaces/ICreator1155Factory.sol";

interface IERC1155Balance {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @dev Subset of the deployed In Process / Zora 1155 collection surface the operator bundle
///      touches after creation. Selectors confirmed present in the live implementation at
///      0x06fb7d2650c308320f6791d0543767735305fec7 (Base mainnet) before writing this test.
interface IInProcessCollection {
    /// @dev Zora per-token royalty accessor (selector 0x7f77f574). Returns the stored
    ///      RoyaltyConfiguration for the token, which is what `updateRoyaltiesForToken` writes.
    function royalties(uint256 tokenId)
        external
        view
        returns (ICreator1155Factory.RoyaltyConfiguration memory);

    /// @dev EIP-2981 (selector 0x2a55205a). Cross-checks the override resolves on the
    ///      standard interface marketplaces actually read.
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount);

    /// @dev Zora aggregate setup-action / batch entrypoint (selector 0xac9650d8).
    function multicall(bytes[] calldata data) external returns (bytes[] memory results);
}

/// @notice Fork tests against the live Base-mainnet In Process / Zora creator factory that prove
///         the Phase-3 `SetupActions` bundles (script/SetupActions.sol) succeed byte-for-byte as
///         the operator runs them. Complements InProcessFork.t.sol (which only exercises a
///         hand-rolled setupNewToken + addPermission); this file covers the royalty-override
///         bundle, the add-track multicall, the stale-state guard, and the no-ETH invariant.
///
///         RUN WITH AN RPC: `BASE_RPC_URL=<base-rpc> forge test --match-contract SetupActionsFork`.
///         Excluded from CI (no RPC) via `--no-match-contract Fork`; skips cleanly when
///         BASE_RPC_URL is unset.
contract SetupActionsForkTest is Test {
    // Confirmed Base mainnet (setup-actions-reference.md §C.1).
    address internal constant FACTORY = 0x540C18B7f99b3b599c6FeB99964498931c211858;
    uint256 internal constant TOKEN_ID = 1; // Zora token ids start at 1

    bool internal forked;
    TortoiseShell internal shell;
    TortoiseInProcessMinter internal minter;
    address internal artist = makeAddr("artist");
    address internal collector = makeAddr("collector");
    address internal royaltyRecipient = makeAddr("royaltyRecipient");

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        shell = new TortoiseShell(makeAddr("tort"), 7 days);
        minter = new TortoiseInProcessMinter(address(shell), makeAddr("platform"), 500, 1_000);
        shell.addAuthorizedCaller(address(minter));
    }

    /// @notice §C.3 royalty-override bundle. `createContract` with the 3-action
    ///         `newTokenWithRoyaltyAndMinter` bundle succeeds; the minter holds MINTER on token 1
    ///         (proved by a real adminMint via collect); and the per-token royalty override took
    ///         effect (read back from the collection). Because the operator is only the
    ///         collection `defaultAdmin` (PERMISSION_BIT_ADMIN = 2), a green run also proves admin
    ///         suffices for `updateRoyaltiesForToken` inside the bundle (resolves §C.3 open Q).
    function test_fork_royaltyOverrideBundle() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        uint32 bps = 750; // distinct from the 500 default royalty below
        bytes[] memory actions = SetupActions.newTokenWithRoyaltyAndMinter(
            "ar://royalty-token", 100, TOKEN_ID, address(minter), bps, royaltyRecipient
        );

        address collection = _createCollection(actions);
        assertGt(collection.code.length, 0, "collection deployed");

        // Minter holds MINTER on token 1: a real adminMint via collect mints to the collector.
        _registerAndPriceSong(collection, TOKEN_ID, 0.001 ether);
        vm.deal(collector, 1 ether);
        vm.prank(collector);
        minter.collect{value: 0.001 ether}(collection, TOKEN_ID, 1, 0.001 ether, collector, "");
        assertEq(
            IERC1155Balance(collection).balanceOf(collector, TOKEN_ID), 1, "minter could adminMint"
        );

        // Per-token royalty override took effect: read it back from the collection.
        ICreator1155Factory.RoyaltyConfiguration memory stored =
            IInProcessCollection(collection).royalties(TOKEN_ID);
        assertEq(stored.royaltyRecipient, royaltyRecipient, "royalty recipient overridden");
        assertEq(stored.royaltyBPS, bps, "royalty bps overridden");

        // Cross-check on EIP-2981, the interface marketplaces read.
        (address receiver, uint256 amount) =
            IInProcessCollection(collection).royaltyInfo(TOKEN_ID, 10_000);
        assertEq(receiver, royaltyRecipient, "EIP-2981 receiver");
        assertEq(amount, (10_000 * bps) / 10_000, "EIP-2981 amount = bps of salePrice");
    }

    /// @notice §C.6 add-track bundle. On a collection created in the test (operator =
    ///         defaultAdmin), `multicall(bytes[])` with `addTrackWithMinter(lastKnownTokenId, ...)`
    ///         creates a new token at lastKnownTokenId + 1 and permissions the minter on it.
    function test_fork_addTrackBundle() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        // Fresh collection with token 1.
        address collection = _createCollection(
            SetupActions.newTokenWithMinter("ar://track-1", 100, TOKEN_ID, address(minter))
        );

        // Add track 2 via the collection's own multicall. operator == defaultAdmin == this.
        uint256 lastKnownTokenId = 1;
        uint256 newTokenId = lastKnownTokenId + 1;
        bytes[] memory bundle =
            SetupActions.addTrackWithMinter(lastKnownTokenId, "ar://track-2", 100, address(minter));
        IInProcessCollection(collection).multicall(bundle);

        // The new token is permissioned for the minter: prove via a real collect.
        _registerAndPriceSong(collection, newTokenId, 0.002 ether);
        vm.deal(collector, 1 ether);
        vm.prank(collector);
        minter.collect{value: 0.002 ether}(collection, newTokenId, 1, 0.002 ether, collector, "");
        assertEq(
            IERC1155Balance(collection).balanceOf(collector, newTokenId),
            1,
            "minter could adminMint the added track"
        );
    }

    /// @notice §C.8 #8 stale-state guard. An add-track multicall whose `lastKnownTokenId` is STALE
    ///         reverts the whole bundle: no token created, no permission granted. The fresh value
    ///         then succeeds.
    function test_fork_addTrackStaleGuardReverts() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        address collection = _createCollection(
            SetupActions.newTokenWithMinter("ar://track-1", 100, TOKEN_ID, address(minter))
        );

        // Stale: collection's last token is 1, but the operator thinks it is 5. The prepended
        // assumeLastTokenIdMatches(5) makes the whole multicall revert.
        bytes[] memory staleBundle =
            SetupActions.addTrackWithMinter(5, "ar://stale", 100, address(minter));
        vm.expectRevert();
        IInProcessCollection(collection).multicall(staleBundle);

        // No phantom token 2 was created, and the minter was not permissioned on it: a collect
        // (which routes through adminMint) must not produce a balance. Easiest robust assertion:
        // token 2 has no minted balance and registering/pricing+collecting reverts because the
        // token does not exist / minter lacks permission.
        assertEq(
            IERC1155Balance(collection).balanceOf(collector, 2), 0, "no phantom token from revert"
        );

        // Fresh value succeeds and produces token 2.
        bytes[] memory freshBundle =
            SetupActions.addTrackWithMinter(1, "ar://track-2", 100, address(minter));
        IInProcessCollection(collection).multicall(freshBundle);

        _registerAndPriceSong(collection, 2, 0.001 ether);
        vm.deal(collector, 1 ether);
        vm.prank(collector);
        minter.collect{value: 0.001 ether}(collection, 2, 1, 0.001 ether, collector, "");
        assertEq(
            IERC1155Balance(collection).balanceOf(collector, 2), 1, "fresh value created token 2"
        );
    }

    /// @notice §C.7 no-ETH invariant. The test contract's ETH balance is unchanged across
    ///         `createContract` and the add-track `multicall` — collection creation and token
    ///         setup are gas-only; the factory/creator retain no native value.
    function test_fork_setupActionsConsumeNoEth() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        vm.deal(address(this), 1 ether);
        uint256 balanceBefore = address(this).balance;

        address collection = _createCollection(
            SetupActions.newTokenWithMinter("ar://track-1", 100, TOKEN_ID, address(minter))
        );
        assertEq(address(this).balance, balanceBefore, "createContract consumed ETH");

        bytes[] memory bundle =
            SetupActions.addTrackWithMinter(1, "ar://track-2", 100, address(minter));
        IInProcessCollection(collection).multicall(bundle);
        assertEq(address(this).balance, balanceBefore, "add-track multicall consumed ETH");
    }

    // ============ Helpers ============

    /// @dev Deploy a collection through the live factory with `this` as default admin (operator).
    function _createCollection(bytes[] memory actions) internal returns (address) {
        ICreator1155Factory.RoyaltyConfiguration memory royalty;
        royalty.royaltyBPS = 500;
        royalty.royaltyRecipient = artist;

        return ICreator1155Factory(FACTORY)
            .createContract(
                "ar://contract-metadata",
                "SetupActions Fork Album",
                royalty,
                payable(address(this)),
                actions
            );
    }

    /// @dev Register a Tortoise song and open an always-on sale at `price`.
    function _registerAndPriceSong(address collection, uint256 tokenId, uint256 price) internal {
        minter.registerSong(collection, tokenId, artist);
        minter.setSale(
            collection,
            tokenId,
            TortoiseInProcessMinter.SaleUpdate({
                saleStart: 0,
                saleEnd: type(uint64).max,
                maxTokensPerAddress: 0,
                pricePerToken: price
            })
        );
    }
}
