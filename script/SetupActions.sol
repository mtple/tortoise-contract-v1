// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {ICreator1155Factory} from "../src/interfaces/ICreator1155Factory.sol";

/// @title SetupActions
/// @notice Pure builders for the In Process / Zora `setupActions` calldata bundles that create
///         tokens and grant `TortoiseInProcessMinter` mint permission atomically. Single source
///         of truth shared by the Phase-3 deployment scripts and the fork tests, so the bundle
///         that fork tests prove against the live factory is byte-for-byte the one operators run.
///         See planning/setup-actions-reference.md §C.3 / §C.6.
library SetupActions {
    uint256 internal constant PERMISSION_BIT_ADMIN = 2;
    uint256 internal constant PERMISSION_BIT_MINTER = 4;

    /// @dev Open-edition sentinel (type(uint64).max). Never pass 0 for max supply — the
    ///      creator and Tortoise input validation both treat 0 as invalid.
    uint256 internal constant OPEN_EDITION_MAX_SUPPLY = 18446744073709551615;

    error ZeroMaxSupply();
    error ZeroMinter();
    error ZeroRoyaltyRecipient();
    error RoyaltyTooHigh(uint32 bps);

    /// @notice New token + minter permission, inheriting the collection's default royalty.
    /// @param expectedTokenId Backend-precomputed id the new token will get (1..N for a fresh
    ///        album in setup-action order). The `addPermission` targets this id.
    function newTokenWithMinter(
        string memory tokenURI,
        uint256 maxSupply,
        uint256 expectedTokenId,
        address minter
    ) internal pure returns (bytes[] memory actions) {
        actions = new bytes[](2);
        actions[0] = encodeSetupNewToken(tokenURI, maxSupply);
        actions[1] = encodeAddMinterPermission(expectedTokenId, minter);
    }

    /// @notice New token with a per-token royalty override + minter permission.
    function newTokenWithRoyaltyAndMinter(
        string memory tokenURI,
        uint256 maxSupply,
        uint256 expectedTokenId,
        address minter,
        uint32 royaltyBps,
        address royaltyRecipient
    ) internal pure returns (bytes[] memory actions) {
        actions = new bytes[](3);
        actions[0] = encodeSetupNewToken(tokenURI, maxSupply);
        actions[1] = encodeUpdateRoyalties(expectedTokenId, royaltyBps, royaltyRecipient);
        actions[2] = encodeAddMinterPermission(expectedTokenId, minter);
    }

    /// @notice Add-track bundle for an existing collection. Prepends
    ///         `assumeLastTokenIdMatches(lastKnownTokenId)` so stale backend state reverts the
    ///         whole bundle instead of permissioning the wrong token id (§C.6).
    function addTrackWithMinter(
        uint256 lastKnownTokenId,
        string memory tokenURI,
        uint256 maxSupply,
        address minter
    ) internal pure returns (bytes[] memory actions) {
        actions = new bytes[](3);
        actions[0] = encodeAssumeLastTokenIdMatches(lastKnownTokenId);
        actions[1] = encodeSetupNewToken(tokenURI, maxSupply);
        actions[2] = encodeAddMinterPermission(lastKnownTokenId + 1, minter);
    }

    // ---- single-action encoders ----

    function encodeSetupNewToken(string memory tokenURI, uint256 maxSupply)
        internal
        pure
        returns (bytes memory)
    {
        if (maxSupply == 0) revert ZeroMaxSupply();
        return abi.encodeWithSignature("setupNewToken(string,uint256)", tokenURI, maxSupply);
    }

    function encodeAddMinterPermission(uint256 tokenId, address minter)
        internal
        pure
        returns (bytes memory)
    {
        if (minter == address(0)) revert ZeroMinter();
        return abi.encodeWithSignature(
            "addPermission(uint256,address,uint256)", tokenId, minter, PERMISSION_BIT_MINTER
        );
    }

    function encodeUpdateRoyalties(uint256 tokenId, uint32 royaltyBps, address recipient)
        internal
        pure
        returns (bytes memory)
    {
        if (royaltyBps > 10_000) revert RoyaltyTooHigh(royaltyBps);
        if (recipient == address(0)) revert ZeroRoyaltyRecipient();
        ICreator1155Factory.RoyaltyConfiguration memory r = ICreator1155Factory.RoyaltyConfiguration({
            royaltyMintSchedule: 0, royaltyBPS: royaltyBps, royaltyRecipient: recipient
        });
        return abi.encodeWithSignature(
            "updateRoyaltiesForToken(uint256,(uint32,uint32,address))", tokenId, r
        );
    }

    function encodeAssumeLastTokenIdMatches(uint256 lastTokenId)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSignature("assumeLastTokenIdMatches(uint256)", lastTokenId);
    }
}
