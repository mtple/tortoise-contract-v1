// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseInProcessMinter} from "../../src/TortoiseInProcessMinter.sol";
import {MockInProcess1155} from "../mocks/MockInProcess1155.sol";
import {MockTortoiseShellETH} from "../mocks/MockTortoiseShellETH.sol";

/// @notice Split recipient / artist that rejects ETH, forcing the deferral path.
contract RejectETH {}

contract MinterInvariantHandler is Test {
    TortoiseInProcessMinter internal minter;
    MockInProcess1155 internal nft;
    uint256[] internal tokenIds;
    address[] internal artists;
    uint256 internal price;

    constructor(
        TortoiseInProcessMinter _minter,
        MockInProcess1155 _nft,
        uint256[] memory _tokenIds,
        address[] memory _artists,
        uint256 _price
    ) {
        minter = _minter;
        nft = _nft;
        tokenIds = _tokenIds;
        artists = _artists;
        price = _price;
    }

    function collect(uint256 songSeed, uint256 qty) public {
        uint256 tid = tokenIds[songSeed % tokenIds.length];
        qty = bound(qty, 1, 5);
        uint256 cost = price * qty;
        vm.deal(address(this), cost);
        try minter.collect{value: cost}(address(nft), tid, qty, cost, address(this), "") {} catch {}
    }

    function claim(uint256 songSeed) public {
        uint256 idx = songSeed % tokenIds.length;
        try minter.claimPending(address(nft), tokenIds[idx], artists[idx]) {} catch {}
    }
}

contract MinterInvariantTest is Test {
    TortoiseInProcessMinter internal minter;
    MockInProcess1155 internal nft;
    MockTortoiseShellETH internal shell;
    MinterInvariantHandler internal handler;
    address internal platform = makeAddr("platform");

    function setUp() public {
        shell = new MockTortoiseShellETH();
        shell.setTortRewardPerCollection(1e18);
        shell.setPool(1_000_000e18);
        shell.setNextCreditedAmount(1e18);
        minter = new TortoiseInProcessMinter(address(shell), platform, 500, 1_000);
        nft = new MockInProcess1155();

        uint256[] memory tids = new uint256[](3);
        address[] memory arts = new address[](3);
        arts[0] = makeAddr("artist0"); // accepting EOA
        arts[1] = address(new RejectETH()); // rejecting → deferrals
        arts[2] = address(new RejectETH());
        for (uint256 i; i < 3; i++) {
            uint256 tid = i + 1;
            tids[i] = tid;
            nft.setMaxSupply(tid, type(uint256).max);
            nft.grantPermission(tid, address(minter), nft.PERMISSION_BIT_MINTER());
            minter.registerSong(address(nft), tid, arts[i]);
            _setSale(tid);
        }

        handler = new MinterInvariantHandler(minter, nft, tids, arts, 1 ether);
        targetContract(address(handler));
    }

    function _setSale(uint256 tid) internal {
        minter.setSale(
            address(nft),
            tid,
            TortoiseInProcessMinter.SaleUpdate({
                saleStart: 0,
                saleEnd: type(uint64).max,
                maxTokensPerAddress: 0,
                pricePerToken: 1 ether
            })
        );
    }

    /// @notice The only ETH the minter ever retains is exactly what is owed as pending claims.
    function invariant_balanceEqualsPendingClaims() public view {
        assertEq(address(minter).balance, minter.totalPendingClaims());
    }
}
