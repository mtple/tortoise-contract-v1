// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseInProcessMinter} from "../../src/TortoiseInProcessMinter.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {ICreator1155Factory} from "../../src/interfaces/ICreator1155Factory.sol";

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

        ICreator1155Factory.RoyaltyConfiguration memory royalty;
        royalty.royaltyBPS = 500;
        royalty.royaltyRecipient = artist;

        address collection = ICreator1155Factory(FACTORY).createContract(
            "ar://contract-metadata", "Fork Test Album", royalty, payable(address(this)), actions
        );
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
}
