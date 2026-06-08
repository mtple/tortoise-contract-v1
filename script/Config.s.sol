// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title Config
/// @notice Per-network address resolution for the Phase-3 deploy + creation scripts.
///
/// FAIL-CLOSED on the In Process factory: it must be confirmed per network via an explicit
/// `INPROCESS_FACTORY` env override or a non-zero `inProcessFactory` in
/// `addresses/<chainId>.json`. Only Base mainnet has a pinned constant (fork-verified, plan
/// C.8 / setup-actions-reference.md §C.1). The scripts NEVER fall back to the canonical Zora
/// factory — an unconfirmed network reverts. Base Sepolia therefore reverts until the In
/// Process team confirms its factory and it is pinned.
///
/// Resolution order for every value: env override → pinned constant (factory/mainnet only) →
/// `addresses/<chainId>.json` registry → revert.
contract Config is Script {
    using stdJson for string;

    uint256 internal constant BASE_MAINNET = 8453;
    uint256 internal constant BASE_SEPOLIA = 84532;

    address internal constant FACTORY_BASE_MAINNET = 0x540C18B7f99b3b599c6FeB99964498931c211858;

    error FactoryUnconfirmed(uint256 chainId);
    error MissingConfig(string key);

    /// @notice In Process factory for the current chain, or revert (fail-closed).
    function inProcessFactory() internal view returns (address f) {
        f = vm.envOr("INPROCESS_FACTORY", address(0));
        if (f != address(0)) return f;
        if (block.chainid == BASE_MAINNET) return FACTORY_BASE_MAINNET;
        f = _registryAddress("inProcessFactory");
        if (f != address(0)) return f;
        revert FactoryUnconfirmed(block.chainid);
    }

    /// @notice ERC-20 staking token backing the ETH TortoiseShell.
    function stakingToken() internal view returns (address t) {
        t = vm.envOr("TORT_TOKEN", address(0));
        if (t == address(0)) t = _registryAddress("stakingToken");
        if (t == address(0)) revert MissingConfig("stakingToken");
    }

    function platformFeeRecipient() internal view returns (address r) {
        r = vm.envOr("PLATFORM_FEE_RECIPIENT", address(0));
        if (r == address(0)) r = _registryAddress("platformFeeRecipient");
        if (r == address(0)) revert MissingConfig("platformFeeRecipient");
    }

    /// @notice Already-deployed minter address (for the creation/sale scripts).
    function minter() internal view returns (address m) {
        m = vm.envOr("TORTOISE_MINTER", address(0));
        if (m == address(0)) m = _registryAddress("tortoiseInProcessMinter");
        if (m == address(0)) revert MissingConfig("tortoiseInProcessMinter");
    }

    function platformFeeBps() internal view returns (uint16) {
        return uint16(vm.envOr("PLATFORM_FEE_BPS", uint256(500))); // 5%
    }

    function stakingFeeBps() internal view returns (uint16) {
        return uint16(vm.envOr("STAKING_FEE_BPS", uint256(1_000))); // 10%
    }

    function _registryPath() internal view returns (string memory) {
        return string.concat("addresses/", vm.toString(block.chainid), ".json");
    }

    /// @dev Reads `.<key>` from the chain's registry file; returns 0 if file/key is absent.
    function _registryAddress(string memory key) internal view returns (address) {
        string memory path = _registryPath();
        if (!vm.exists(path)) return address(0);
        string memory json = vm.readFile(path);
        string memory jsonKey = string.concat(".", key);
        if (!vm.keyExistsJson(json, jsonKey)) return address(0);
        return json.readAddress(jsonKey);
    }
}
