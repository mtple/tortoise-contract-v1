// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IERC165Upgradeable} from "./shared/IERC165Upgradeable.sol";
import {ILimitedMintPerAddressErrors} from "./shared/errors/IInProcessCreator1155Errors.sol";

interface ILimitedMintPerAddress is IERC165Upgradeable, ILimitedMintPerAddressErrors {
    function getMintedPerWallet(address token, uint256 tokenId, address wallet) external view returns (uint256);
}
