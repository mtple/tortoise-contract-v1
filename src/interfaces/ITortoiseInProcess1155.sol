// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

/// @title ITortoiseInProcess1155
/// @notice Minimal surface of the In Process / Zora-compatible ERC-1155 creator that
///         `TortoiseInProcessMinter` depends on. The production minter only calls
///         `adminMint`; deployment scripts use the richer creator ABI separately.
/// @dev Do not add unverified convenience methods (e.g. `adminMintBatch`, `nextTokenId`)
///      here — `batchCollect` loops `adminMint` once per item by design.
interface ITortoiseInProcess1155 {
    /// @notice Mint `quantity` of `tokenId` to `recipient`. Caller must hold
    ///         `PERMISSION_BIT_MINTER` (4) for the token (or be a collection admin).
    function adminMint(address recipient, uint256 tokenId, uint256 quantity, bytes calldata data)
        external;
}
