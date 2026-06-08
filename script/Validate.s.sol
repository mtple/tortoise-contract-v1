// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {console2} from "forge-std/console2.sol";
import {Config} from "./Config.s.sol";
import {ICreator1155Factory} from "../src/interfaces/ICreator1155Factory.sol";
import {TortoiseInProcessMinter} from "../src/TortoiseInProcessMinter.sol";
import {IMinter1155} from "../src/interfaces/IMinter1155.sol";

/// @notice Read-only pre-flight validation for a target chain. Resolves the fail-closed
///         factory (reverts if unconfirmed), checks the factory + creator implementation have
///         code, and — if a minter is configured — checks it advertises the IMinter1155 shim.
///         Run with `--rpc-url <chain>` (no broadcast). Reverts on any failed check.
contract Validate is Config {
    function run() external view {
        address factory = inProcessFactory(); // fail-closed
        require(factory.code.length > 0, "Validate: factory has no code");

        address impl = ICreator1155Factory(factory).zora1155Impl();
        require(impl.code.length > 0, "Validate: creator impl has no code");

        console2.log("chainId:        ", block.chainid);
        console2.log("factory:        ", factory);
        console2.log("zora1155Impl:   ", impl);

        address m = vm.envOr("TORTOISE_MINTER", address(0));
        if (m == address(0)) m = _registryAddress("tortoiseInProcessMinter");
        if (m != address(0)) {
            require(m.code.length > 0, "Validate: minter has no code");
            require(
                TortoiseInProcessMinter(payable(m))
                    .supportsInterface(type(IMinter1155).interfaceId),
                "Validate: minter does not advertise IMinter1155"
            );
            console2.log("minter:         ", m);
            console2.log("minter shim OK: ", true);
        } else {
            console2.log("minter:          (not configured)");
        }
    }
}
