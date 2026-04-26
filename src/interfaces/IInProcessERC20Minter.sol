// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

struct InProcessSale {
    uint64 saleStart;
    uint64 saleEnd;
    uint64 maxTokensPerAddress;
    uint256 pricePerToken;
    address fundsRecipient;
    address currency;
}

interface IInProcessERC20Minter {
    function sale(
        address tokenContract,
        uint256 tokenId
    ) external view returns (InProcessSale memory);

    function mint(
        address mintTo,
        uint256 quantity,
        address tokenAddress,
        uint256 tokenId,
        uint256 totalValue,
        address currency,
        address mintReferral,
        string calldata comment
    ) external payable;

    function totalRewardPct() external view returns (uint256);
    function ethRewardAmount() external view returns (uint256);

    function getERC20MinterConfig()
        external
        view
        returns (
            address zoraRewardRecipientAddress,
            uint256 rewardRecipientPercentage,
            uint256 ethReward
        );
}
