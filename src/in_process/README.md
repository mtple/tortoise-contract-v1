# InProcess — TortoiseMinter

TortoiseMinter is Tortoise's ERC20 minter plugin for the InProcess Protocol.

Built on top of InProcess's ERC20Minter, it is fully compatible with the InProcess
Protocol out of the box. Every existing workflow — contract deployment, token management,
and sale configuration — continues to work exactly as before. At mint time, TortoiseMinter
interacts with the 1155 contract through a single call to `adminMint()` and nothing more.

On top of this foundation, it introduces Tortoise's fee structure: additional revenue
for artists and a TORS airdrop for every collector.

---

## Contract Relationships

```
┌─────────────────────────────────────────────────────────────────┐
│                     InProcess Protocol                          │
│                    (already deployed)                           │
│                                                                 │
│   InProcess1155                                                 │
│   ├── createToken()       ← artist creates NFT token            │
│   ├── addPermission()     ← grants TortoiseMinter minter role   │
│   ├── callSale()          ← registers SalesConfig               │
│   └── adminMint()         ← called by TortoiseMinter at mint    │
└────────────────────────────┬────────────────────────────────────┘
                             │ minter permission
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                       TortoiseMinter                            │
│                                                                 │
│   mint()                                                        │
│   ├── validates SalesConfig (currency, price, timestamps)       │
│   ├── pulls SalesConfig.currency × pricePerToken from buyer     │
│   ├── calls InProcess1155.adminMint()                           │
│   ├── sends 100% of sale price → fundsRecipient (artist)        │
│   └── pulls rewardToken × platformFee from buyer               │
│       ├── 25% → TortoiseShell.depositRewards()                  │
│       ├── 75% → fundsRecipient (artist bonus)                   │
│       └── TortoiseShell.creditStake(collector, quantity)        │
└────────────────────────────┬────────────────────────────────────┘
                             │ authorized caller
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                       TortoiseShell                             │
│                                                                 │
│   depositRewards()   ← receives 25% fee (rewardToken/USDC)      │
│                         distributes to TORS stakers             │
│   creditStake()      ← airdrops TORS to collector               │
│                         from tortPool funded by admin           │
└─────────────────────────────────────────────────────────────────┘
```

---

## Mint Flow

A single `mint()` call triggers two separate payments from the collector:

| Payment | Token | Amount | Destination |
|---------|-------|--------|-------------|
| NFT sale price | `SalesConfig.currency` (any ERC20) | `pricePerToken × quantity` | artist (100%) |
| Tortoise platform fee | `rewardToken` (e.g. USDC) | `platformFee × quantity` | artist 75% + TortoiseShell 25% |

The collector also receives a TORS airdrop via `TortoiseShell.creditStake()` as a thank-you for collecting.

---

## Setup (per token)

The artist wires TortoiseMinter to their InProcess1155 token in two steps:

```solidity
// 1. Grant TortoiseMinter the minter role for this tokenId
InProcess1155.addPermission(tokenId, address(tortoiseMinter), PERMISSION_BIT_MINTER);

// 2. Register the sale config
InProcess1155.callSale(
    tokenId,
    address(tortoiseMinter),
    abi.encodeWithSelector(
        TortoiseMinter.setSale.selector,
        tokenId,
        SalesConfig({
            pricePerToken:       1_000_000,        // e.g. 1 USDC
            saleStart:           0,
            saleEnd:             type(uint64).max,
            maxTokensPerAddress: 0,
            fundsRecipient:      0xARTIST,
            currency:            0xUSDC
        })
    )
);
```

---

## TortoiseMinterConfig

Owner-settable global configuration:

```solidity
struct TortoiseMinterConfig {
    address tortoiseShell;  // TortoiseShell contract address
    address rewardToken;    // ERC20 token for platform fee (e.g. USDC)
    uint256 platformFee;    // Fee per mint in rewardToken units
}
```

The fee split is hardcoded: **25% to TortoiseShell, 75% to artist.**

---

## Off-chain Requirement

TortoiseMinter must be registered in TortoiseShell before going live:

```solidity
TortoiseShell.addAuthorizedCaller(address(tortoiseMinter));
```

---

## Design Principles

- **Tortoise fee is additive.** It is a separate payment on top of the NFT sale price,
  not a deduction from it.
- **TortoiseShell integration is non-blocking.** `depositRewards()` and `creditStake()`
  are wrapped in `try/catch` so any shell failure never prevents an NFT from being minted.

