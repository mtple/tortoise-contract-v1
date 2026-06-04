// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Zora/In Process creator command types. Declared so `IMinter1155.requestMint`
///         has its exact canonical signature, making `type(IMinter1155).interfaceId`
///         match the value the In Process permission system / indexer checks.
interface ICreatorCommands {
    enum CreatorActions {
        NO_OP,
        SEND_ETH,
        MINT
    }

    struct Command {
        CreatorActions method;
        bytes args;
    }

    struct CommandSet {
        Command[] commands;
        uint256 at;
    }
}

/// @title IMinter1155
/// @notice Minimal, signature-accurate copy of the Zora/In Process minter interface.
/// @dev `TortoiseInProcessMinter` implements this only for recognition/discovery — its
///      `requestMint` reverts. The real paid path is the Tortoise-native `collect()`.
///      Phase-2 fork tests must assert `type(IMinter1155).interfaceId` matches the
///      deployed In Process minter interface id.
interface IMinter1155 is IERC165 {
    function requestMint(
        address sender,
        uint256 tokenId,
        uint256 quantity,
        uint256 ethValueSent,
        bytes calldata minterArguments
    ) external returns (ICreatorCommands.CommandSet memory commands);
}
