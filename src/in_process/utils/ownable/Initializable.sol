// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// Vendored from @zoralabs/openzeppelin-contracts-upgradeable (Zora's fork of OZ Upgradeable).
// Preserves the Zora custom error name INITIALIZABLE_CONTRACT_ALREADY_INITIALIZED()
// because the test suite checks for this exact error signature.
// Standard OZ v4/v5 Initializable uses different error/revert strings — do not substitute.
abstract contract Initializable {
    uint8 private _initialized;
    bool private _initializing;

    error INITIALIZABLE_CONTRACT_ALREADY_INITIALIZED();

    /// @dev Can only be called once. Reverts if called again after initialization completes.
    modifier initializer() {
        bool isTopLevelCall = !_initializing;

        if (isTopLevelCall && _initialized >= 1) {
            revert INITIALIZABLE_CONTRACT_ALREADY_INITIALIZED();
        }

        if (isTopLevelCall) {
            _initializing = true;
            _initialized = 1;
        }

        _;

        if (isTopLevelCall) {
            _initializing = false;
        }
    }

    /// @dev Can only be called from within an `initializer` execution context.
    modifier onlyInitializing() {
        require(_initializing, "Initializable: contract is not initializing");
        _;
    }
}
