// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

/// @title IEIP3009
/// @notice Minimal surface of the EIP-3009 `receiveWithAuthorization` implemented by
///         Circle's USDC (FiatToken v2+). The `bytes signature` overload (FiatToken v2.2)
///         is used so smart-contract wallets (EIP-1271) can authorize collects too.
/// @dev `receiveWithAuthorization` requires `msg.sender == to`, so only this contract can
///      redeem an authorization made out to it — a third party cannot replay the signed
///      authorization into a different context.
interface IEIP3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}
