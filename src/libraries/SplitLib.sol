// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

struct SplitRecipient {
    address recipient;
    uint96 percentage; // Basis points (10000 = 100%)
}

library SplitLib {
    uint256 constant BASIS_POINTS = 10_000;
    uint256 constant MAX_SPLITS = 10;
    uint96 constant MIN_PERCENTAGE = 100;

    error InvalidSplitTotal();
    error TooManySplits();
    error ZeroAddressRecipient();
    error PercentageBelowMinimum();
    error DuplicateRecipient();

    function validateSplits(SplitRecipient[] calldata splits) internal pure {
        if (splits.length > MAX_SPLITS) revert TooManySplits();

        uint256 totalPercentage;
        for (uint256 i = 0; i < splits.length; i++) {
            if (splits[i].recipient == address(0)) revert ZeroAddressRecipient();
            if (splits[i].percentage < MIN_PERCENTAGE) revert PercentageBelowMinimum();
            totalPercentage += splits[i].percentage;

            for (uint256 j = i + 1; j < splits.length; j++) {
                if (splits[i].recipient == splits[j].recipient) revert DuplicateRecipient();
            }
        }
        if (totalPercentage != BASIS_POINTS) revert InvalidSplitTotal();
    }

    function calculateSplitAmount(
        uint256 totalAmount,
        uint96 percentage
    ) internal pure returns (uint256) {
        return (totalAmount * percentage) / BASIS_POINTS;
    }
}
