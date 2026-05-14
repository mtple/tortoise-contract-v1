// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITortoiseMinter} from "../interfaces/ITortoiseMinter.sol";
import {IMinterPremintSetup} from "../interfaces/IMinterPremintSetup.sol";
import {LimitedMintPerAddress} from "./utils/LimitedMintPerAddress.sol";
import {SaleStrategy} from "./SaleStrategy.sol";
import {ICreatorCommands} from "../interfaces/ICreatorCommands.sol";
import {TortoiseMinterRewards} from "./TortoiseMinterRewards.sol";
import {IInProcess1155} from "../interfaces/IInProcess1155.sol";
import {Initializable} from "../utils/ownable/Initializable.sol";
import {Ownable2StepUpgradeable} from "../utils/ownable/Ownable2StepUpgradeable.sol";
import {ITortoiseShell} from "../../interfaces/ITortoiseShell.sol";

/// @title TortoiseMinter
/// @notice Allows for InProcess Mints to be purchased using ERC20 tokens, with a
///         Tortoise platform fee split 25% to TortoiseShell and 75% to the artist.
/// @dev While this contract _looks_ like a minter, we need to be able to directly manage ERC20 tokens. Therefore, we need to establish minter permissions but instead of using the `requestMint` flow we directly request tokens to be minted in order to safely handle the incoming ERC20 tokens.
/// @author @isabellasmallcombe
contract TortoiseMinter is
    ReentrancyGuard,
    ITortoiseMinter,
    SaleStrategy,
    LimitedMintPerAddress,
    TortoiseMinterRewards,
    Initializable,
    Ownable2StepUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice The ERC20 minter configuration
    TortoiseMinterConfig public minterConfig;

    /// @notice The ERC20 sale configuration for a given 1155 token
    /// @dev 1155 token address => 1155 token id => SalesConfig
    mapping(address => mapping(uint256 => SalesConfig)) internal salesConfigs;

    /// @notice Initializes the contract
    /// @dev Allows deterministic contract address, called on deploy
    function initialize(
        address _tortoiseShell,
        address _rewardToken,
        uint256 _platformFee,
        address _owner
    ) external initializer {
        __Ownable_init(_owner);
        _setTortoiseMinterConfig(
            TortoiseMinterConfig({
                tortoiseShell: _tortoiseShell, rewardToken: _rewardToken, platformFee: _platformFee
            })
        );
    }

    /// @notice Gets the TortoiseMinterConfig
    function getTortoiseMinterConfig() external view returns (TortoiseMinterConfig memory) {
        return minterConfig;
    }

    /// @notice Handles the incoming transfer of ERC20 tokens
    /// @param currency The address of the currency to use for the mint
    /// @param totalValue The total value of the mint
    function _handleIncomingTransfer(
        address currency,
        uint256 totalValue
    ) internal {
        uint256 beforeBalance = IERC20(currency).balanceOf(address(this));
        IERC20(currency).safeTransferFrom(msg.sender, address(this), totalValue);
        uint256 afterBalance = IERC20(currency).balanceOf(address(this));

        if ((beforeBalance + totalValue) != afterBalance) {
            revert ERC20TransferSlippage();
        }
    }

    /// @notice Distributes the Tortoise platform fee: 25% to TortoiseShell, 75% to artist
    /// @return torsRewards Amount of TORS credited to the collector
    function _distributeFee(
        uint256 totalFee,
        address fundsRecipient,
        address mintTo,
        uint256 quantity
    ) private returns (uint256 torsRewards) {
        uint256 tortoiseAmount = (totalFee * TORTOISE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 artistFeeAmount = totalFee - tortoiseAmount;

        address shell = minterConfig.tortoiseShell;
        address token = minterConfig.rewardToken;

        IERC20(token).safeTransfer(shell, tortoiseAmount);
        ITortoiseShell(shell).depositRewards(tortoiseAmount);
        torsRewards = ITortoiseShell(shell).creditStake(mintTo, quantity);

        IERC20(token).safeTransfer(fundsRecipient, artistFeeAmount);
    }

    /// @notice Mints a token using an ERC20 currency, note the total value must have been approved prior to calling this function
    /// @param mintTo The address to mint the token to
    /// @param quantity The quantity of tokens to mint
    /// @param tokenAddress The address of the collection to mint
    /// @param tokenId The ID of the token to mint
    /// @param totalValue The total value of the mint
    /// @param currency The address of the currency to use for the mint
    /// @param mintReferral The address of the mint referral
    /// @param comment The optional mint comment
    function mint(
        address mintTo,
        uint256 quantity,
        address tokenAddress,
        uint256 tokenId,
        uint256 totalValue,
        address currency,
        address mintReferral,
        string calldata comment
    ) external nonReentrant {
        SalesConfig storage config = salesConfigs[tokenAddress][tokenId];

        if (config.currency == address(0) || config.currency != currency) {
            revert InvalidCurrency();
        }

        if (totalValue != (config.pricePerToken * quantity)) {
            revert WrongValueSent();
        }

        if (block.timestamp < config.saleStart) {
            revert SaleHasNotStarted();
        }

        if (block.timestamp > config.saleEnd) {
            revert SaleEnded();
        }

        if (config.maxTokensPerAddress > 0) {
            _requireMintNotOverLimitAndUpdate(
                config.maxTokensPerAddress, quantity, tokenAddress, tokenId, mintTo
            );
        }

        // Calculate platform fee upfront
        uint256 totalFee;
        if (minterConfig.platformFee > 0 && minterConfig.tortoiseShell != address(0)) {
            totalFee = minterConfig.platformFee * quantity;
        }

        // Pull all payments before any external calls
        _handleIncomingTransfer(currency, totalValue);
        if (totalFee > 0) {
            _handleIncomingTransfer(minterConfig.rewardToken, totalFee);
        }

        // Distribute: pay artist and split platform fee
        IERC20(currency).safeTransfer(config.fundsRecipient, totalValue);
        uint256 torsRewards;
        if (totalFee > 0) {
            torsRewards = _distributeFee(totalFee, config.fundsRecipient, mintTo, quantity);
        }

        // Mint NFT last — all payments verified and distributed
        IInProcess1155(tokenAddress).adminMint(mintTo, tokenId, quantity, "");

        if (bytes(comment).length > 0) {
            emit MintComment(mintTo, tokenAddress, tokenId, quantity, comment);
        }

        emit Collected(config.fundsRecipient, mintTo, tokenAddress, tokenId, quantity, torsRewards);
    }

    /// @notice The URI of the contract
    function contractURI() external pure returns (string memory) {
        return "";
    }

    /// @notice The name of the contract
    function contractName() external pure returns (string memory) {
        return "Tortoise Minter";
    }

    /// @notice The version of the contract
    function contractVersion() external pure returns (string memory) {
        return "2.0.0";
    }

    /// @notice Sets the sale config for a given token
    /// @param tokenId The ID of the token to set the sale config for
    /// @param salesConfig The sale config to set
    function setSale(
        uint256 tokenId,
        SalesConfig memory salesConfig
    ) public {
        _requireNotAddressZero(salesConfig.currency);
        _requireNotAddressZero(salesConfig.fundsRecipient);

        if (salesConfig.pricePerToken < MIN_PRICE_PER_TOKEN) {
            revert PricePerTokenTooLow();
        }

        salesConfigs[msg.sender][tokenId] = salesConfig;

        emit SaleSet(msg.sender, tokenId, salesConfig);
    }

    /// @notice Dynamically builds a SalesConfig from a PremintSalesConfig taking into consideration the current block timestamp
    /// and the PremintSalesConfig's duration.
    /// @param config The PremintSalesConfig to build the SalesConfig from
    function buildSalesConfigForPremint(
        PremintSalesConfig memory config
    ) public view returns (TortoiseMinter.SalesConfig memory) {
        uint64 saleStart = uint64(block.timestamp);
        uint64 saleEnd = config.duration == 0 ? type(uint64).max : saleStart + config.duration;
        return ITortoiseMinter.SalesConfig({
            saleStart: saleStart,
            saleEnd: saleEnd,
            maxTokensPerAddress: config.maxTokensPerAddress,
            pricePerToken: config.pricePerToken,
            fundsRecipient: config.fundsRecipient,
            currency: config.currency
        });
    }

    /// @notice Sets the sales config based for the msg.sender on the tokenId from the abi encoded premint sales config by
    /// abi decoding it and dynamically building the SalesConfig. The saleStart will be the current block timestamp
    /// and saleEnd will be the current block timestamp + the duration in the PremintSalesConfig.
    /// @param tokenId The ID of the token to set the sale config for
    /// @param encodedPremintSalesConfig The abi encoded PremintSalesConfig
    function setPremintSale(
        uint256 tokenId,
        bytes calldata encodedPremintSalesConfig
    ) external override {
        PremintSalesConfig memory premintSalesConfig =
            abi.decode(encodedPremintSalesConfig, (PremintSalesConfig));
        SalesConfig memory salesConfig = buildSalesConfigForPremint(premintSalesConfig);

        setSale(tokenId, salesConfig);
    }

    /// @notice Deletes the sale config for a given token
    /// @param tokenId The ID of the token to reset the sale config for
    function resetSale(
        uint256 tokenId
    ) external override {
        delete salesConfigs[msg.sender][tokenId];

        emit SaleSet(msg.sender, tokenId, salesConfigs[msg.sender][tokenId]);
    }

    /// @notice Returns the sale config for a given token
    /// @param tokenContract The TokenContract address
    /// @param tokenId The ID of the token to get the sale config for
    function sale(
        address tokenContract,
        uint256 tokenId
    ) external view returns (SalesConfig memory) {
        return salesConfigs[tokenContract][tokenId];
    }

    /// @notice IERC165 interface support
    /// @param interfaceId The interface ID to check
    function supportsInterface(
        bytes4 interfaceId
    ) public pure virtual override(LimitedMintPerAddress, SaleStrategy) returns (bool) {
        return super.supportsInterface(interfaceId)
            || LimitedMintPerAddress.supportsInterface(interfaceId)
            || SaleStrategy.supportsInterface(interfaceId)
            || interfaceId == type(IMinterPremintSetup).interfaceId;
    }

    /// @notice Reverts as `requestMint` is not used in the ERC20 minter. Call `mint` instead.
    function requestMint(
        address,
        uint256,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (ICreatorCommands.CommandSet memory) {
        revert RequestMintInvalidUseMint();
    }

    /// @notice Sets the TortoiseMinterConfig
    /// @param config The TortoiseMinterConfig to set
    function setTortoiseMinterConfig(
        TortoiseMinterConfig memory config
    ) external onlyOwner {
        _setTortoiseMinterConfig(config);
    }

    /// @notice Internal setter for TortoiseMinterConfig
    function _setTortoiseMinterConfig(
        TortoiseMinterConfig memory _config
    ) internal {
        _requireNotAddressZero(_config.tortoiseShell);
        _requireNotAddressZero(_config.rewardToken);

        minterConfig = _config;
        emit TortoiseMinterConfigSet(_config);
    }

    /// @notice Reverts if the address is address(0)
    /// @param _address The address to check
    function _requireNotAddressZero(
        address _address
    ) internal pure {
        if (_address == address(0)) {
            revert AddressZero();
        }
    }
}
