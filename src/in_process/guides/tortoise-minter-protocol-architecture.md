# TortoiseMinter & InProcess Protocol: Contract Architecture and Integration Boundaries

## Overview

TortoiseMinter is an external plugin minter for the InProcess 1155 protocol
(a fork of the Zora 1155 protocol). It is not embedded in the 1155 contract —
it must be granted permission and registered before it can mint.

---

## Role Separation

| Layer  | Contract          | Responsibility                                          |
|--------|-------------------|---------------------------------------------------------|
| Minter | `TortoiseMinter`  | Accept ERC20 payment, distribute rewards, request mint  |
| 1155   | `InProcess1155`   | Issue NFTs, manage permissions, store sale configs      |

---

## Setup (Creator Must Do Before Any Mint)

```solidity
// 1. Grant TortoiseMinter the MINTER role for this tokenId
InProcess1155.addPermission(tokenId, address(tortoiseMinter), PERMISSION_BIT_MINTER);

// 2. Store the sale config inside TortoiseMinter
InProcess1155.callSale(
    tokenId,
    address(tortoiseMinter),
    abi.encodeWithSelector(TortoiseMinter.setSale.selector, tokenId, salesConfig)
);
```

`PERMISSION_BIT_MINTER = 2**2 = 4` (bitmask permission system)

---

## Mint Call Flow

```
user
 └─▶ TortoiseMinter.mint(mintTo, quantity, tokenAddress, tokenId,
                          totalValue, currency, mintReferral, comment)
       │
       ├─ validate: msg.value == ethReward * quantity
       ├─ validate: salesConfigs entry exists, price, timestamps, per-address limit
       ├─ _handleIncomingTransfer()   ← pull ERC20 from user into TortoiseMinter
       │
       ├─▶ IInProcess1155(tokenAddress).adminMint(mintTo, tokenId, quantity, "")
       │     └─ InProcess1155 issues NFT (no fee logic here — pure mint)
       │
       ├─ computeTotalReward()        ← calculate ERC20 reward slice
       ├─ _distributeRewards()        ← split ERC20 reward to 4 recipients
       ├─ _distributeEthRewards()     ← ETH → inProcessRewardRecipient
       └─ safeTransfer(fundsRecipient, totalValue - totalReward)
```

---

## ERC20 Reward Distribution

```
totalReward = totalValue × rewardRecipientPercentage%

  28.5714% → createReferral          (falls back to inProcessRewardRecipient if zero)
  28.5714% → mintReferral            (falls back to inProcessRewardRecipient if zero)
  14.2285% → firstMinter             (falls back to inProcessRewardRecipient if zero)
  remainder → inProcessRewardRecipient (always receives)

ETH:
  ethReward × quantity → inProcessRewardRecipient (always)

Remaining ERC20:
  totalValue - totalReward → fundsRecipient (creator revenue)
```

---

## Why `adminMint` Instead of `mint`

| Path               | Function       | 1155 Fee Logic                              |
|--------------------|----------------|---------------------------------------------|
| Via TortoiseMinter | `adminMint()`  | **None** — TortoiseMinter handles fees      |
| Direct ETH mint    | `mint()`       | `_handleRewardsAndGetValueRemaining()` runs |

TortoiseMinter calls `adminMint()` to intentionally bypass the 1155 ETH reward
path, so it can handle ERC20-denominated fee distribution itself.

---

## `inProcessRewardRecipient`

- Set once at deploy time via `initialize(_inProcessRewardRecipientAddress, ...)`
- Can only be changed later by the owner via `setTortoiseMinterConfig()`
- In production this is the protocol treasury / multisig address
- Acts as the final fallback recipient for every reward category

---

## IInProcess1155 — Functions TortoiseMinter Calls on the 1155

```solidity
// src/in_process/minters/erc20/IInProcess1155.sol
function createReferrals(uint256 tokenId) external view returns (address);
function firstMinters(uint256 tokenId) external view returns (address);
function getCreatorRewardRecipient(uint256 tokenId) external view returns (address);
function adminMint(address recipient, uint256 tokenId, uint256 quantity, bytes memory data) external;
```

TortoiseMinter calls only these four functions on the 1155 contract.
