// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

/// @title ICreator1155Factory
/// @notice Minimal surface of the In Process / Zora 1155 factory used by deployment and
///         setup-action scripts to create collections. Not used on the hot collect path.
/// @dev Signatures match the Zora 1155 Factory ABI used by In Process. Verify byte-for-byte
///      against the deployed factory's verified source during Phase-2 fork tests.
interface ICreator1155Factory {
    struct RoyaltyConfiguration {
        uint32 royaltyMintSchedule;
        uint32 royaltyBPS;
        address royaltyRecipient;
    }

    function createContract(
        string calldata newContractURI,
        string calldata name,
        RoyaltyConfiguration calldata defaultRoyaltyConfiguration,
        address payable defaultAdmin,
        bytes[] calldata setupActions
    ) external returns (address);

    function zora1155Impl() external view returns (address);
}
