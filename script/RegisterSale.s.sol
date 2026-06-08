// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {console2} from "forge-std/console2.sol";
import {Config} from "./Config.s.sol";
import {TortoiseInProcessMinter} from "../src/TortoiseInProcessMinter.sol";

/// @notice Register a song and set its sale on the minter (§C.5 steps 6–7). Broadcast sender
///         must be the minter owner/operator. Splits are handled separately
///         (registerSongWithSplits via the artist-signed flow); this covers the owner path.
///
/// Required env: COLLECTION, TOKEN_ID, ARTIST, PRICE_WEI.
/// Optional env: SALE_START (0), SALE_END (uint64 max), MAX_PER_ADDRESS (0 = unlimited),
///               TORTOISE_MINTER / registry.
contract RegisterSale is Config {
    function run() external {
        TortoiseInProcessMinter m = TortoiseInProcessMinter(payable(minter()));
        address collection = vm.envAddress("COLLECTION");
        uint256 tokenId = vm.envUint("TOKEN_ID");
        address artist = vm.envAddress("ARTIST");
        uint256 price = vm.envUint("PRICE_WEI");
        uint64 saleStart = uint64(vm.envOr("SALE_START", uint256(0)));
        uint64 saleEnd = uint64(vm.envOr("SALE_END", uint256(type(uint64).max)));
        uint64 maxPerAddr = uint64(vm.envOr("MAX_PER_ADDRESS", uint256(0)));

        vm.startBroadcast();
        m.registerSong(collection, tokenId, artist);
        m.setSale(
            collection,
            tokenId,
            TortoiseInProcessMinter.SaleUpdate({
                saleStart: saleStart,
                saleEnd: saleEnd,
                maxTokensPerAddress: maxPerAddr,
                pricePerToken: price
            })
        );
        vm.stopBroadcast();

        console2.log("registered + sale set:");
        console2.log("  collection:", collection);
        console2.log("  tokenId:   ", tokenId);
        console2.log("  price wei: ", price);
    }
}
