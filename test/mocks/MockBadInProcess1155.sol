// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

/// @notice 1155 mock whose adminMint reverts unconditionally. Used to verify the minter
///         does not mutate state or move ETH when the underlying token reverts.
contract MockBadInProcess1155 {
    error AdminMintReverted();

    function adminMint(address, uint256, uint256, bytes calldata) external pure {
        revert AdminMintReverted();
    }
}
