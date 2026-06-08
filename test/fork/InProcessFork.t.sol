// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseInProcessMinter} from "../../src/TortoiseInProcessMinter.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {ICreator1155Factory} from "../../src/interfaces/ICreator1155Factory.sol";
import {IMinter1155} from "../../src/interfaces/IMinter1155.sol";

interface IERC1155Balance {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @notice Fork tests against the live Base-mainnet In Process / Zora creator factory.
///         RUN WITH AN RPC: `BASE_RPC_URL=<base-rpc> forge test --match-contract InProcessFork`.
///         Excluded from CI (no RPC) via `--no-match-contract Fork`; skips cleanly when
///         BASE_RPC_URL is unset. The factory ABI here is the expected Zora 1155 shape and
///         must be confirmed against the deployed verified source on first real run (plan C.8).
contract InProcessForkTest is Test {
    // Confirmed Base mainnet (setup-actions-reference.md §C.1).
    address internal constant FACTORY = 0x540C18B7f99b3b599c6FeB99964498931c211858;
    uint256 internal constant PERMISSION_BIT_MINTER = 4;
    uint256 internal constant TOKEN_ID = 1; // Zora token ids start at 1

    /// @dev Canonical Zora/In Process `IMinter1155` interface id. The Zora 1155
    ///      implementation gates sale-config wiring on
    ///      `minter.supportsInterface(type(IMinter1155).interfaceId)`, where
    ///      `IMinter1155 is IERC165` declares exactly `requestMint(...)`. Solidity's
    ///      `type(I).interfaceId` XORs the declared selectors and (per EIP-165) excludes
    ///      the inherited `IERC165.supportsInterface` selector, so the id collapses to the
    ///      `requestMint` selector alone: `bytes4(keccak256(
    ///      "requestMint(address,uint256,uint256,uint256,bytes)")) == 0x6890e5b3`.
    ///      Source: ourzora/zora-protocol packages/1155-contracts/src/interfaces/IMinter1155.sol.
    bytes4 internal constant CANONICAL_IMINTER1155_INTERFACE_ID = 0x6890e5b3;

    bool internal forked;
    TortoiseShell internal shell;
    TortoiseInProcessMinter internal minter;
    address internal artist = makeAddr("artist");
    address internal collector = makeAddr("collector");

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        shell = new TortoiseShell(makeAddr("tort"), 7 days);
        minter = new TortoiseInProcessMinter(address(shell), makeAddr("platform"), 500, 1_000);
        shell.addAuthorizedCaller(address(minter));
    }

    function test_fork_factoryAndImplHaveCode() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        assertGt(FACTORY.code.length, 0, "factory has code");
        address impl = ICreator1155Factory(FACTORY).zora1155Impl();
        assertGt(impl.code.length, 0, "creator impl has code");
    }

    function test_fork_createCollectionAndCollect() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        // setupActions: create token #1, grant the minter MINTER permission.
        bytes[] memory actions = new bytes[](2);
        actions[0] =
            abi.encodeWithSignature("setupNewToken(string,uint256)", "ar://token-metadata", 100);
        actions[1] = abi.encodeWithSignature(
            "addPermission(uint256,address,uint256)",
            TOKEN_ID,
            address(minter),
            PERMISSION_BIT_MINTER
        );

        address collection = _createCollection(actions);
        assertGt(collection.code.length, 0, "collection deployed");

        // Configure the Tortoise sale and collect with real ETH.
        minter.registerSong(collection, TOKEN_ID, artist);
        minter.setSale(
            collection,
            TOKEN_ID,
            TortoiseInProcessMinter.SaleUpdate({
                saleStart: 0,
                saleEnd: type(uint64).max,
                maxTokensPerAddress: 0,
                pricePerToken: 0.001 ether
            })
        );

        vm.deal(collector, 1 ether);
        vm.prank(collector);
        minter.collect{value: 0.001 ether}(collection, TOKEN_ID, 1, 0.001 ether, collector, "");

        assertEq(IERC1155Balance(collection).balanceOf(collector, TOKEN_ID), 1, "minted on-chain");
    }

    /// @notice C.8 item 6: multi-item `batchCollect` against a real In Process/Zora 1155.
    ///         Creates a collection with two tokens, grants the minter MINTER on both,
    ///         registers songs + sales, then collects both in one tx with the exact
    ///         aggregate native ETH. Asserts each token's balance and zero residual ETH.
    function test_fork_batchCollectTwoTokens() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        uint256 token1 = 1;
        uint256 token2 = 2;

        // setupActions: create two tokens, grant the minter MINTER on each. Token ids are
        // 1..N in setup-action order (setup-actions-reference.md §C.3).
        bytes[] memory actions = new bytes[](4);
        actions[0] =
            abi.encodeWithSignature("setupNewToken(string,uint256)", "ar://token-1-metadata", 100);
        actions[1] = abi.encodeWithSignature(
            "addPermission(uint256,address,uint256)", token1, address(minter), PERMISSION_BIT_MINTER
        );
        actions[2] =
            abi.encodeWithSignature("setupNewToken(string,uint256)", "ar://token-2-metadata", 100);
        actions[3] = abi.encodeWithSignature(
            "addPermission(uint256,address,uint256)", token2, address(minter), PERMISSION_BIT_MINTER
        );

        address collection = _createCollection(actions);
        assertGt(collection.code.length, 0, "collection deployed");

        uint256 price1 = 0.001 ether;
        uint256 price2 = 0.002 ether;
        _registerAndPriceSong(collection, token1, price1);
        _registerAndPriceSong(collection, token2, price2);

        // Two items: 2x token1 + 3x token2.
        uint256 qty1 = 2;
        uint256 qty2 = 3;
        uint256 cost1 = price1 * qty1;
        uint256 cost2 = price2 * qty2;
        uint256 aggregate = cost1 + cost2;

        TortoiseInProcessMinter.CollectItem[] memory items =
            new TortoiseInProcessMinter.CollectItem[](2);
        items[0] = TortoiseInProcessMinter.CollectItem({
            collection: collection,
            tokenId: token1,
            quantity: qty1,
            mintTo: collector,
            maxTotalCost: cost1,
            comment: ""
        });
        items[1] = TortoiseInProcessMinter.CollectItem({
            collection: collection,
            tokenId: token2,
            quantity: qty2,
            mintTo: collector,
            maxTotalCost: cost2,
            comment: ""
        });

        vm.deal(collector, 1 ether);
        vm.prank(collector);
        minter.batchCollect{value: aggregate}(items, aggregate);

        assertEq(
            IERC1155Balance(collection).balanceOf(collector, token1), qty1, "token1 minted on-chain"
        );
        assertEq(
            IERC1155Balance(collection).balanceOf(collector, token2), qty2, "token2 minted on-chain"
        );
        // The minter forwards all proceeds (splits + rewards); it never retains ETH.
        assertEq(address(minter).balance, 0, "minter holds no residual ETH");
    }

    /// @notice C.8: the `IMinter1155` interface id our minter advertises via
    ///         `supportsInterface` must equal the canonical Zora/In Process id, because the
    ///         live stack discovers Tortoise as a minter through exactly that ERC-165 probe.
    function test_fork_interfaceIdMatchesCanonical() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        // Our compiled interface id and the canonical Zora value agree...
        assertEq(
            type(IMinter1155).interfaceId,
            CANONICAL_IMINTER1155_INTERFACE_ID,
            "compiled IMinter1155 id drifted from canonical Zora id"
        );
        // ...and the deployed minter answers the same ERC-165 probe the live stack makes.
        assertTrue(
            minter.supportsInterface(CANONICAL_IMINTER1155_INTERFACE_ID),
            "minter does not advertise canonical IMinter1155 id"
        );
    }

    /// @notice C.8 item 7: `createContract` + `setupActions` are gas-only — the factory
    ///         retains no ETH from collection creation / permission setup.
    function test_fork_factoryConsumesNoEth() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        uint256 factoryBalanceBefore = FACTORY.balance;

        bytes[] memory actions = new bytes[](2);
        actions[0] =
            abi.encodeWithSignature("setupNewToken(string,uint256)", "ar://token-metadata", 100);
        actions[1] = abi.encodeWithSignature(
            "addPermission(uint256,address,uint256)",
            TOKEN_ID,
            address(minter),
            PERMISSION_BIT_MINTER
        );

        address collection = _createCollection(actions);
        assertGt(collection.code.length, 0, "collection deployed");

        assertEq(FACTORY.balance, factoryBalanceBefore, "factory consumed ETH");
    }

    // ============ Helpers ============

    /// @dev Deploy a collection through the live factory with `this` as default admin.
    function _createCollection(bytes[] memory actions) internal returns (address) {
        ICreator1155Factory.RoyaltyConfiguration memory royalty;
        royalty.royaltyBPS = 500;
        royalty.royaltyRecipient = artist;

        return ICreator1155Factory(FACTORY)
            .createContract(
                "ar://contract-metadata",
                "Fork Test Album",
                royalty,
                payable(address(this)),
                actions
            );
    }

    /// @dev Register a Tortoise song and open an always-on, capped-free sale at `price`.
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
