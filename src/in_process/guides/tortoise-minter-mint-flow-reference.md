# TortoiseMinter: End-to-End Mint Flow Reference — Collection Setup to Token Settlement

End-to-end walkthrough from factory deployment through NFT mint,
with concrete numbers (1 USDC token, quantity = 1, rewardPct = 5%).

---

## Assumptions

| Parameter | Raw value | Human-readable |
|-----------|-----------|----------------|
| `pricePerToken` | 1_000_000 | 1 USDC (6 decimals) |
| `quantity` | 1 | 1 token |
| `rewardRecipientPercentage` | 5 | 5% |
| `ethReward` | 111_000_000_000_000 wei | 0.000111 ETH |
| `createReferral` | 0xREFERRAL | — |
| `mintReferral` | 0xMINT_REFERRAL | — |
| `creator / defaultAdmin` | 0xCREATOR | — |
| `treasury` | 0xTREASURY | inProcessRewardRecipient |

---

## Phase 0 — Protocol Deployment (InProcess team, one-time)

```
ZoraCreator1155Impl      ← 1155 logic implementation (UUPS upgradeable)
Zora1155Factory          ← ERC1967Proxy → ZoraCreator1155FactoryImpl
TortoiseMinter.initialize(
    _inProcessRewardRecipientAddress: 0xTREASURY,
    _owner:                           0xOWNER,
    _rewardPct:                       5,         // 5%
    _ethReward:                       0.000111 ether
)
```

The factory does not know about TortoiseMinter. TortoiseMinter is an independent
contract that plugs into any InProcess1155 collection that grants it permission.

---

## Phase 1 — Creator: Deploy Collection

```solidity
Factory.createContract(
    newContractURI:              "ipfs://collection-metadata",
    name:                        "My Music Collection",
    defaultRoyaltyConfiguration: { royaltyRecipient: address(0), royaltyBPS: 0 },
    defaultAdmin:                0xCREATOR,
    setupActions:                []
)
```

**Internals:**

1. `new Zora1155(address(impl))` — deploys ERC1967Proxy; this is the **collection address**
2. `collection.initialize(...)` runs:
   - `permissions[CONTRACT_BASE_ID=0][0xCREATOR]` |= `PERMISSION_BIT_ADMIN (2)`
   - `config.fundsRecipient = 0xCREATOR`
   - tokenId 0 minted internally (contract-level slot, not a user token)

After this call: the collection exists, creator is admin, no user tokens yet.

---

## Phase 2 — Creator: Create Token

```solidity
collection.setupNewTokenWithCreateReferral(
    newURI:         "ipfs://token-metadata",
    maxSupply:      1000,
    createReferral: 0xREFERRAL
)
// returns tokenId = 1
```

**Internals:**

- `tokens[1] = { uri: "ipfs://token-metadata", maxSupply: 1000, totalMinted: 0 }`
- `permissions[1][0xCREATOR]` |= `PERMISSION_BIT_ADMIN`
- `createReferrals[1] = 0xREFERRAL`
- `firstMinters[1]` → **not set (address(0))**
  - `firstMinters` is only recorded via the premint (delegated/signature-based) path.
  - For a regular `setupNewToken`, it remains zero and falls back to
    `getCreatorRewardRecipient(tokenId)` at mint time (see Phase 4).

---

## Phase 3 — Creator: Wire TortoiseMinter (2 steps)

### Step A — Grant MINTER permission

```solidity
collection.addPermission(
    tokenId:    1,
    user:       address(tortoiseMinter),
    permission: PERMISSION_BIT_MINTER  // 2**2 = 4
)
// result: permissions[1][tortoiseMinter] |= 4
```

This allows TortoiseMinter to call `adminMint` on tokenId 1.

### Step B — Register sale config

```solidity
collection.callSale(
    tokenId: 1,
    minter:  address(tortoiseMinter),
    data:    abi.encodeWithSelector(
                 TortoiseMinter.setSale.selector,
                 1,
                 SalesConfig({
                     pricePerToken:       1_000_000,        // 1 USDC
                     saleStart:           0,                // open immediately
                     saleEnd:             type(uint64).max, // no end
                     maxTokensPerAddress: 0,                // unlimited
                     fundsRecipient:      0xCREATOR,
                     currency:            0xUSDC
                 })
             )
)
```

`callSale` internals:
1. Verifies `permissions[1][tortoiseMinter] & PERMISSION_BIT_MINTER` ✓
2. Verifies `tortoiseMinter.supportsInterface(type(IMinter1155).interfaceId)` ✓
3. Calls `tortoiseMinter.setSale(1, config)` via low-level call
4. TortoiseMinter stores: `salesConfigs[address(collection)][1] = SalesConfig{...}`

After Phase 3: TortoiseMinter is fully wired for tokenId 1.
The factory is not involved again from this point forward.

---

## Phase 4 — Collector: Mint

### Required wallet balance

| Token | Minimum amount | Purpose |
|-------|---------------|---------|
| USDC | 1_000_000 units (1 USDC) | mint price (`pricePerToken × quantity`) |
| ETH | 111_000_000_000_000 wei (0.000111 ETH) + gas | `ethReward × quantity` (contract-enforced) + transaction gas |

Both are mandatory. The contract reverts with `InvalidETHValue` if `msg.value`
is anything other than exactly `ethReward × quantity`.

### Pre-step: ERC20 approval

```solidity
USDC.approve(address(tortoiseMinter), 1_000_000)  // approve 1 USDC
```

### Mint call

```solidity
tortoiseMinter.mint{value: 0.000111 ether}(
    mintTo:       0xCOLLECTOR,
    quantity:     1,
    tokenAddress: address(collection),
    tokenId:      1,
    totalValue:   1_000_000,        // 1 USDC
    currency:     0xUSDC,
    mintReferral: 0xMINT_REFERRAL,
    comment:      ""
)
```

### Execution inside `mint()`

**① Validate ETH**
```
msg.value == ethReward × quantity
0.000111 ETH == 0.000111 ETH × 1  ✓
```

**② Validate sale config**
```
salesConfigs[collection][1].currency == 0xUSDC                     ✓
totalValue (1_000_000 / 1 USDC) == pricePerToken (1_000_000) × 1  ✓
block.timestamp in [saleStart=0, saleEnd=max]                       ✓
maxTokensPerAddress == 0 → no per-address limit                     ✓
```

**③ Pull ERC20 from collector**
```
USDC.safeTransferFrom(0xCOLLECTOR → tortoiseMinter, 1_000_000)  // 1 USDC
balance check: before + 1_000_000 == after  ✓
```

**④ Mint NFT**
```
IInProcess1155(collection).adminMint(0xCOLLECTOR, tokenId=1, amount=1, "")
  → tokens[1].totalMinted: 0 → 1
  → ERC1155._mint(0xCOLLECTOR, 1, 1)
  → balanceOf(0xCOLLECTOR, tokenId=1) = 1
```

Note: `adminMint` bypasses the 1155 ETH reward path entirely.
TortoiseMinter handles all reward distribution itself.

**⑤ Compute reward pool**
```
totalReward = totalValue × rewardRecipientPercentage / 100
           = 1_000_000 × 5 / 100
           = 50_000  (0.05 USDC — 5% of 1 USDC)
```

**⑥ Resolve reward recipients**
```
createReferral:
  createReferrals[1] = 0xREFERRAL  ✓

firstMinter:
  firstMinters[1] = address(0)  (regular setupNewToken, not premint)
  → fallback: getCreatorRewardRecipient(1)
      royalties(1).royaltyRecipient = address(0)
      → fallback: config.fundsRecipient = 0xCREATOR
  firstMinter = 0xCREATOR

mintReferral:
  passed as argument = 0xMINT_REFERRAL  ✓
```

**⑦ Compute reward amounts (integer division)**
```
createReferralReward = 50_000 × 28_571_400 / 100_000_000
                     = 14_285  (≈ 0.014285 USDC, 28.5714% of reward pool)

mintReferralReward   = 50_000 × 28_571_400 / 100_000_000
                     = 14_285  (≈ 0.014285 USDC, 28.5714% of reward pool)

firstMinterReward    = 50_000 × 14_228_500 / 100_000_000
                     =  7_114  (≈ 0.007114 USDC, 14.2285% of reward pool)

inProcessReward      = 50_000 − (14_285 + 14_285 + 7_114)
                     = 14_316  (≈ 0.014316 USDC, remainder — absorbs integer division dust)
```

Verify: 14_285 + 14_285 + 7_114 + 14_316 = 50_000 ✓

**⑧ Distribute ERC20 rewards**
```
USDC.safeTransfer(0xREFERRAL,      14_285)  // 0.014285 USDC — createReferral
USDC.safeTransfer(0xCREATOR,        7_114)  // 0.007114 USDC — firstMinter
USDC.safeTransfer(0xMINT_REFERRAL, 14_285)  // 0.014285 USDC — mintReferral
USDC.safeTransfer(0xTREASURY,      14_316)  // 0.014316 USDC — inProcessReward
```

Emits `ERC20RewardsDeposit` event.

**⑨ Distribute ETH reward**
```
ETH.safeSend(0xTREASURY, 111_000_000_000_000 wei)  // 0.000111 ETH
```

**⑩ Pay creator (fundsRecipient)**
```
USDC.safeTransfer(0xCREATOR, 1_000_000 − 50_000)
                            = 950_000  // 0.95 USDC
```

---

## Final Settlement

| Recipient | Raw (USDC units) | Human-readable | ETH | Role |
|-----------|-----------------|----------------|-----|------|
| 0xREFERRAL | 14,285 | 0.014285 USDC | — | createReferral |
| 0xMINT_REFERRAL | 14,285 | 0.014285 USDC | — | mintReferral |
| 0xCREATOR | 7,114 | 0.007114 USDC | — | firstMinter (fallback) |
| 0xTREASURY | 14,316 | 0.014316 USDC | 0.000111 ETH | inProcessReward |
| 0xCREATOR | 950,000 | 0.95 USDC | — | fundsRecipient |
| **Total** | **1,000,000** | **1 USDC** | **0.000111 ETH** | |

Creator total: 7,114 + 950,000 = **957,114 units = 0.957114 USDC**

---

## Key Notes

### Factory involvement
The factory deploys the collection and exits. It plays no role in minting or
sale configuration. TortoiseMinter is wired directly to the collection by the creator.

### firstMinter resolution
`firstMinters[tokenId]` is only recorded when a token is created via the premint
(EIP-712 delegated creation) path. For tokens created with `setupNewToken` or
`setupNewTokenWithCreateReferral`, `firstMinters[tokenId]` is `address(0)` and
the fallback chain is:
```
firstMinters[tokenId]          → address(0)
getCreatorRewardRecipient(id)  → royalties[id].royaltyRecipient  → address(0)
                               → config.fundsRecipient           → 0xCREATOR
                               → address(this)                   (last resort)
```

### inProcessReward absorbs dust
`inProcessReward` is computed as a remainder, not as a percentage multiplication.
Integer division in the other three reward calculations truncates fractions;
the accumulated dust lands in `inProcessReward`, making it slightly larger than
the nominal 28.5714% (14,316 vs theoretical 14,285.7).

### ERC20 vs ETH fee independence
The ERC20 reward split and the flat ETH fee are entirely independent.
The ETH fee is always `ethReward × quantity` regardless of ERC20 price.
Both flow to `inProcessRewardRecipient` but via separate transfer calls.
