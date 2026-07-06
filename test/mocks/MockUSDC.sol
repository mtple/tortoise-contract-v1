// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice USDC test double: 6 decimals, `mint`, a Circle-style blocklist (transfers to a
///         blocked address revert), and EIP-3009 `receiveWithAuthorization` (EIP-712) so the
///         sign-to-collect path can be exercised. Not production code.
contract MockUSDC is ERC20 {
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    mapping(address => bool) public blocked;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("USD Coin")),
                keccak256(bytes("2")),
                block.chainid,
                address(this)
            )
        );
    }

    /// @dev Minimal FiatToken-style EIP-3009. Requires msg.sender == to (front-run-safe),
    ///      a fresh nonce, and a signature over the ReceiveWithAuthorization struct by `from`.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        require(msg.sender == to, "MockUSDC: caller must be payee");
        require(block.timestamp > validAfter, "MockUSDC: auth not yet valid");
        require(block.timestamp < validBefore, "MockUSDC: auth expired");
        require(!authorizationState[from][nonce], "MockUSDC: authorization used");

        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
        require(ECDSA.recover(digest, signature) == from, "MockUSDC: invalid signature");

        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "MockUSDC: recipient blocklisted");
        super._update(from, to, value);
    }
}
