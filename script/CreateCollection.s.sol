// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {console2} from "forge-std/console2.sol";
import {Config} from "./Config.s.sol";
import {SetupActions} from "./SetupActions.sol";
import {ICreator1155Factory} from "../src/interfaces/ICreator1155Factory.sol";

/// @notice Create a new album collection and its first token (id 1), granting the minter
///         MINTER permission atomically (§C.5). The broadcast sender is the collection
///         `defaultAdmin` (operator). Additional tracks are added later with AddTrack, or
///         composed off-chain by the backend for multi-track initial creation.
///
/// Required env: CONTRACT_URI, COLLECTION_NAME, TOKEN_URI.
/// Optional env: MAX_SUPPLY (open edition), ROYALTY_BPS (500), ROYALTY_RECIPIENT (operator),
///               TORTOISE_MINTER / registry, INPROCESS_FACTORY / registry (fail-closed).
contract CreateCollection is Config {
    function run() external {
        address factory = inProcessFactory(); // reverts if unconfirmed for this chain
        address minterAddr = minter();
        address operator = msg.sender;

        string memory contractURI = vm.envString("CONTRACT_URI");
        string memory name = vm.envString("COLLECTION_NAME");
        string memory tokenURI = vm.envString("TOKEN_URI");
        uint256 maxSupply = vm.envOr("MAX_SUPPLY", SetupActions.OPEN_EDITION_MAX_SUPPLY);
        uint32 royaltyBps = uint32(vm.envOr("ROYALTY_BPS", uint256(500)));
        address royaltyRecipient = vm.envOr("ROYALTY_RECIPIENT", operator);

        // First token is id 1; minter permission granted in the same createContract tx.
        bytes[] memory actions = SetupActions.newTokenWithMinter(tokenURI, maxSupply, 1, minterAddr);

        ICreator1155Factory.RoyaltyConfiguration memory royalty =
            ICreator1155Factory.RoyaltyConfiguration({
                royaltyMintSchedule: 0, royaltyBPS: royaltyBps, royaltyRecipient: royaltyRecipient
            });

        vm.startBroadcast();
        address collection = ICreator1155Factory(factory)
            .createContract(contractURI, name, royalty, payable(operator), actions);
        vm.stopBroadcast();

        // Read the collection from the factory event off-chain; this is a convenience print.
        console2.log("collection (return value):", collection);
        console2.log("first tokenId:            ", uint256(1));
        console2.log("minter (permissioned):    ", minterAddr);
    }
}
