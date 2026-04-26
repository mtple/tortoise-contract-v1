// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IInProcessERC20Minter, InProcessSale} from "../../src/interfaces/IInProcessERC20Minter.sol";

contract MockInProcessMinter is IInProcessERC20Minter {
    using SafeERC20 for IERC20;

    mapping(bytes32 => InProcessSale) internal _sales;
    mapping(bytes32 => mapping(address => uint256)) public minted;

    uint256 public feeBps;
    address public feeRecipient;
    uint256 public rewardPct;
    uint256 public ethReward;

    function setSale(
        address tokenContract,
        uint256 tokenId,
        uint256 pricePerToken,
        address fundsRecipient,
        address currency
    ) external {
        _sales[_key(tokenContract, tokenId)] = InProcessSale({
            saleStart: 0,
            saleEnd: type(uint64).max,
            maxTokensPerAddress: 0,
            pricePerToken: pricePerToken,
            fundsRecipient: fundsRecipient,
            currency: currency
        });
    }

    function setFee(
        uint256 newFeeBps,
        address newFeeRecipient
    ) external {
        feeBps = newFeeBps;
        feeRecipient = newFeeRecipient;
        rewardPct = newFeeBps;
    }

    function setEthReward(
        uint256 newEthReward
    ) external {
        ethReward = newEthReward;
    }

    function sale(
        address tokenContract,
        uint256 tokenId
    ) external view returns (InProcessSale memory) {
        return _sales[_key(tokenContract, tokenId)];
    }

    function mint(
        address mintTo,
        uint256 quantity,
        address tokenAddress,
        uint256 tokenId,
        uint256 totalValue,
        address currency,
        address,
        string calldata
    ) external payable {
        InProcessSale memory config = _sales[_key(tokenAddress, tokenId)];
        require(currency == config.currency, "wrong currency");
        require(totalValue == config.pricePerToken * quantity, "wrong value");
        require(msg.value == ethReward * quantity, "wrong eth reward");

        uint256 fee = (totalValue * feeBps) / 10_000;
        if (fee > 0) {
            IERC20(currency).safeTransferFrom(msg.sender, feeRecipient, fee);
        }
        IERC20(currency).safeTransferFrom(msg.sender, config.fundsRecipient, totalValue - fee);
        minted[_key(tokenAddress, tokenId)][mintTo] += quantity;
    }

    function totalRewardPct() external view returns (uint256) {
        return rewardPct;
    }

    function ethRewardAmount() external view returns (uint256) {
        return ethReward;
    }

    function getERC20MinterConfig()
        external
        view
        returns (
            address zoraRewardRecipientAddress,
            uint256 rewardRecipientPercentage,
            uint256 ethRewardAmount_
        )
    {
        return (feeRecipient, rewardPct, ethReward);
    }

    function _key(
        address tokenContract,
        uint256 tokenId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(tokenContract, tokenId));
    }
}
