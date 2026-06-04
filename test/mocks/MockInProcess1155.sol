// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {ITortoiseInProcess1155} from "../../src/interfaces/ITortoiseInProcess1155.sol";

/// @notice Minimal In Process / Zora-compatible 1155 mock: adminMint gated on
///         PERMISSION_BIT_MINTER + finite max supply, with balance tracking and
///         test-only setters. Mirrors the surface in setup-actions-reference.md §C.9.
contract MockInProcess1155 {
    uint256 public constant PERMISSION_BIT_MINTER = 4;

    mapping(uint256 => uint256) public maxSupply;
    mapping(uint256 => uint256) public totalMinted;
    mapping(uint256 => mapping(address => uint256)) public permissions; // tokenId => addr => bits
    mapping(uint256 => mapping(address => uint256)) public balances; // tokenId => owner => amount

    error MissingMinterPermission();
    error ExceedsMaxSupply();
    error InvalidMaxSupply();

    function setMaxSupply(uint256 tokenId, uint256 supply) external {
        if (supply == 0) revert InvalidMaxSupply();
        maxSupply[tokenId] = supply;
    }

    function grantPermission(uint256 tokenId, address account, uint256 bits) external {
        permissions[tokenId][account] = bits;
    }

    function adminMint(address recipient, uint256 tokenId, uint256 quantity, bytes calldata)
        external
    {
        if (permissions[tokenId][msg.sender] & PERMISSION_BIT_MINTER == 0) {
            revert MissingMinterPermission();
        }
        if (totalMinted[tokenId] + quantity > maxSupply[tokenId]) revert ExceedsMaxSupply();
        totalMinted[tokenId] += quantity;
        balances[tokenId][recipient] += quantity;
    }

    function balanceOf(address account, uint256 tokenId) external view returns (uint256) {
        return balances[tokenId][account];
    }
}
