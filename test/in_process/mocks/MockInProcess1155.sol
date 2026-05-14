// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IInProcess1155} from "../../../src/in_process/minters/erc20/IInProcess1155.sol";

/// @notice Minimal mock replacing ZoraCreator1155Impl + Zora1155 proxy.
/// Implements IInProcess1155 (called by ERC20Minter) and the test-facing
/// surface (setupNewToken, addPermission, callSale, balanceOf).
///
/// callSale() wraps minter revert data as CallFailed(bytes) — the test
/// suite relies on this exact error shape when checking for minter errors.
contract MockInProcess1155 is IInProcess1155 {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error CallFailed(bytes reason);

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    uint256 private tokenIdCounter;

    /// @dev IInProcess1155.createReferrals — public getter satisfies the interface
    mapping(uint256 => address) public createReferrals;

    /// @dev IInProcess1155.firstMinters — set to msg.sender at token creation
    mapping(uint256 => address) public firstMinters;

    mapping(uint256 => address) private _creatorRewardRecipient;
    mapping(address => mapping(uint256 => uint256)) private _balances;
    mapping(uint256 => mapping(address => uint256)) private _permissions;

    // -------------------------------------------------------------------------
    // Test-facing surface (mirrors ZoraCreator1155Impl API used by the tests)
    // -------------------------------------------------------------------------

    function PERMISSION_BIT_MINTER() external pure returns (uint256) {
        return 4;
    }

    function setupNewToken(string calldata, uint256) external returns (uint256 tokenId) {
        tokenId = ++tokenIdCounter;
        firstMinters[tokenId] = msg.sender;
        _creatorRewardRecipient[tokenId] = msg.sender;
    }

    function setupNewTokenWithCreateReferral(
        string calldata,
        uint256,
        address createReferral
    ) external returns (uint256 tokenId) {
        tokenId = ++tokenIdCounter;
        createReferrals[tokenId] = createReferral;
        firstMinters[tokenId] = msg.sender;
        _creatorRewardRecipient[tokenId] = msg.sender;
    }

    function addPermission(uint256 tokenId, address minter, uint256 permissionBit) external {
        _permissions[tokenId][minter] = permissionBit;
    }

    /// @notice Forwards arbitrary calldata to a minter contract.
    /// On failure wraps the revert data as CallFailed(bytes) — matching
    /// the error shape the test suite expects from ZoraCreator1155Impl.
    function callSale(uint256, address minter, bytes calldata data) external {
        (bool success, bytes memory returnData) = minter.call(data);
        if (!success) {
            revert CallFailed(returnData);
        }
    }

    function balanceOf(address account, uint256 tokenId) external view returns (uint256) {
        return _balances[account][tokenId];
    }

    // -------------------------------------------------------------------------
    // IInProcess1155 (called by ERC20Minter)
    // -------------------------------------------------------------------------

    /// @notice adminMint is called by ERC20Minter after payment is processed.
    /// Updates balances and records the first minter if not yet set.
    function adminMint(address recipient, uint256 tokenId, uint256 quantity, bytes memory) external override {
        _balances[recipient][tokenId] += quantity;
    }

    function getCreatorRewardRecipient(uint256 tokenId) external view override returns (address) {
        return _creatorRewardRecipient[tokenId];
    }
}
