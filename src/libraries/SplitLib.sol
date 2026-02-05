// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @notice Represents a single revenue split recipient
struct SplitRecipient {
    address recipient; // Address to receive payment
    uint96 percentage; // Percentage in basis points (100 = 1%, 10000 = 100%)
}

/// @title SplitLib - Split calculation and validation library
/// @notice Library for validating and calculating revenue splits
library SplitLib {
    uint256 internal constant BASIS_POINTS = 10_000;
    uint256 internal constant MAX_SPLITS = 10;
    uint96 internal constant MIN_PERCENTAGE = 100; // 1% minimum per recipient

    error InvalidSplitTotal();
    error TooManySplits();
    error ZeroAddressRecipient();
    error PercentageBelowMinimum();
    error DuplicateRecipient();

    /// @notice Validate split configuration
    /// @param splits Array of split recipients to validate
    function validateSplits(SplitRecipient[] calldata splits) internal pure {
        if (splits.length > MAX_SPLITS) revert TooManySplits();

        uint256 totalPercentage;
        for (uint256 i = 0; i < splits.length; i++) {
            if (splits[i].recipient == address(0)) revert ZeroAddressRecipient();
            if (splits[i].percentage < MIN_PERCENTAGE) revert PercentageBelowMinimum();
            totalPercentage += splits[i].percentage;

            // H-2 fix: check for duplicate recipients
            for (uint256 j = i + 1; j < splits.length; j++) {
                if (splits[i].recipient == splits[j].recipient) revert DuplicateRecipient();
            }
        }

        if (totalPercentage != BASIS_POINTS) revert InvalidSplitTotal();
    }

    /// @notice Calculate payment amount for a recipient
    /// @param totalAmount Total amount to split
    /// @param percentage Percentage in basis points
    /// @return The calculated split amount
    function calculateSplitAmount(
        uint256 totalAmount,
        uint96 percentage
    ) internal pure returns (uint256) {
        return (totalAmount * percentage) / BASIS_POINTS;
    }
}
