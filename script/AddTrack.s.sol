// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {console2} from "forge-std/console2.sol";
import {Config} from "./Config.s.sol";
import {SetupActions} from "./SetupActions.sol";

/// @dev Zora/In Process 1155 collections execute setup-action bundles via `multicall`.
interface IZora1155Multicall {
    function multicall(bytes[] calldata data) external returns (bytes[] memory);
}

/// @notice Add a track (new token) to an existing Tortoise collection (§C.6). The bundle is
///         guarded by `assumeLastTokenIdMatches(LAST_TOKEN_ID)` so stale backend state reverts
///         the whole multicall instead of permissioning the wrong token. The broadcast sender
///         must already hold collection admin (PERMISSION_BIT_ADMIN).
///
/// Required env: COLLECTION, LAST_TOKEN_ID, TOKEN_URI.
/// Optional env: MAX_SUPPLY (open edition), TORTOISE_MINTER / registry.
contract AddTrack is Config {
    function run() external {
        address collection = vm.envAddress("COLLECTION");
        uint256 lastKnownTokenId = vm.envUint("LAST_TOKEN_ID");
        string memory tokenURI = vm.envString("TOKEN_URI");
        uint256 maxSupply = vm.envOr("MAX_SUPPLY", SetupActions.OPEN_EDITION_MAX_SUPPLY);
        address minterAddr = minter();

        bytes[] memory actions =
            SetupActions.addTrackWithMinter(lastKnownTokenId, tokenURI, maxSupply, minterAddr);

        vm.startBroadcast();
        IZora1155Multicall(collection).multicall(actions);
        vm.stopBroadcast();

        console2.log("collection:      ", collection);
        console2.log("expected tokenId:", lastKnownTokenId + 1);
        console2.log("minter:          ", minterAddr);
    }
}
