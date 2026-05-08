# Tortoise v1

Solidity contracts and planning docs for the Tortoise music platform on Base.

The target v1 architecture is a custom Tortoise minter for In Process/Zora-compatible
ERC-1155 collections. In Process provides the deployed ERC-1155 creator collection
system; Tortoise owns the collect path, native ETH payments, sale config, artist
splits, comments, indexing events, staking rewards, and collector TORT crediting.

## Architecture Status

The custom minter architecture is the production direction:

```text
Collector pays ETH to TortoiseInProcessMinter
  |
  +-- Tortoise minter validates Tortoise-owned sale config
  +-- Tortoise minter calls In Process ERC-1155 adminMint(...)
  +-- NFT is minted to mintTo
  +-- ETH is distributed to platform, shell rewards, artist, and split recipients
  +-- Tortoise emits indexing/comment/payment events for the Tortoise UI
```

The older `TortoiseMintRouter` / USDC architecture in `src/` is a prototype and is
now superseded. It wrapped the standard In Process ERC-20 minter, which would have
made the In Process ERC-20 minter the real sale contract. That is not the planned
production shape.

Keep router-era code only long enough to port useful patterns into the custom minter:

- fee math
- split validation and locking
- EIP-712 artist authorization patterns
- pending claims for failed payouts
- shell-credit behavior
- batch-collect validation
- pause/reentrancy controls

Once the custom minter and ETH-native shell pass Phase 1 tests, router-era code that
is no longer needed should be deleted.

## Planned Contracts

### TortoiseInProcessMinter

Custom payable minter owned by Tortoise.

- Uses native ETH for collects and payouts.
- Stores Tortoise-owned sale config per `(collection, tokenId)`.
- Mints by calling `adminMint(mintTo, tokenId, quantity, "")` on the In Process ERC-1155 collection.
- Requires the minter to hold `PERMISSION_BIT_MINTER` on the token.
- Supports artist-signed/operator-submitted sale updates.
- Supports single collect and batch collect.
- Emits Tortoise-native events for indexing, including comments.
- Handles platform fees, staking fees, artist revenue, splits, and pending claims.

### TortoiseShell

ETH-native staking and collector-credit contract.

- Users stake TORT and earn native ETH rewards from collection fees.
- `depositRewards()` is payable.
- `creditStake(user, quantity)` credits collectors from a pre-funded TORT pool.
- Reward claims pay native ETH.
- The existing USDC shell in `src/` is a prototype reference and will be replaced.

### In Process ERC-1155 Collections

In Process/Zora-compatible creator collections remain the ERC-1155 source of truth.

- One ERC-1155 collection per album.
- Each track is a token ID inside the album collection.
- Tortoise creates collections/tokens directly through factory/setup actions.
- Tortoise does not rely on the In Process hosted API, ERC-20 minter, UI, or indexer for the core collect flow.

## Planning References

- [Minter architecture migration plan](planning/minter-architecture-migration-plan.md)
- [Setup actions reference](planning/setup-actions-reference.md)

## Target Collection Flow

```text
New album
  |
  +-- Backend uploads album artwork, track audio, and metadata
  +-- Backend builds setup actions:
  |     setupNewToken(trackURI, maxSupply)
  |     optional updateRoyaltiesForToken(tokenId, royaltyConfig)
  |     addPermission(tokenId, TortoiseInProcessMinter, PERMISSION_BIT_MINTER)
  |
  +-- Backend calls In Process creator factory directly
  +-- Backend stores collection address, token IDs, metadata URIs, and sale settings
  +-- Backend configures sale and splits in TortoiseInProcessMinter
```

```text
Collect
  |
  +-- Collector calls TortoiseInProcessMinter.collect(...) with native ETH
  +-- Minter validates sale window, price, max-per-wallet, and msg.value
  +-- Minter calls collection.adminMint(mintTo, tokenId, quantity, "")
  +-- Minter credits TortoiseShell when eligible
  +-- Minter distributes ETH to platform, shell rewards, artist, and split recipients
  +-- Tortoise indexer reads Tortoise events plus ERC-1155 TransferSingle/TransferBatch
```

## Setup

```bash
git clone <repo>
cd tortoise-contract-v1
forge install
```

## Build

```bash
forge build
```

## Test

```bash
# Fully local suite
forge test --offline

# With gas report
forge test --offline --gas-report

# CI profile
FOUNDRY_PROFILE=ci forge test --offline
```

`forge test` without `--offline` may crash on some macOS environments when Foundry tries
to initialize network-backed signature lookup. The offline suite is the expected local path.

## Deployment Direction

The deployment scripts are still router-era and should be replaced as part of the custom
minter migration.

Target deployment order:

1. Deploy or reuse ETH-native `TortoiseShell`.
2. Deploy `TortoiseInProcessMinter`.
3. Register the minter as an authorized caller on `TortoiseShell`.
4. Fund the shell TORT pool via `fundTortPool()`.
5. Set `tortRewardPerCollection` on `TortoiseShell`.
6. Create album collections and track tokens through In Process factory/setup actions.
7. Grant the custom minter `PERMISSION_BIT_MINTER` for each token.
8. Configure Tortoise minter sale config and splits.
9. Run fork checks before mainnet rollout.

## Configuration

| Parameter | Direction | Description |
|-----------|-----------|-------------|
| Collect currency | Native ETH | USDC is router-era only |
| Platform fee | 500 bps default | Taken from the inclusive ETH sale price |
| Staking fee | 1000 bps default | Routed to shell rewards only when collector TORT credit succeeds |
| Reward duration | 604,800 seconds | 7-day ETH drip window |
| TORT per eligible wallet/song | TBD | Fixed TORT credited once per wallet per song |
| Open edition max supply | `18446744073709551615` recommended | Fork-test before rollout; do not use `0` for unlimited |

Song price is configured in `TortoiseInProcessMinter`, not in the In Process ERC-20
minter. Collects revert unless `msg.value` exactly matches the current onchain quote.

## Base Addresses

| Contract | Network | Address | Notes |
|----------|---------|---------|-------|
| TORT | Base mainnet | `0x601410d1d3093cF469fCA4e1EfB2Fb67B4E225c6` | Staking token |
| In Process Creator1155FactoryImpl | Base mainnet | `0x540C18B7f99b3b599c6FeB99964498931c211858` | Confirmed mainnet factory; RPC reports `ZORA 1155 Contract Factory` v2.13.2 |
| In Process Creator1155 implementation | Base mainnet | `0x06fb7d2650c308320f6791d0543767735305fec7` | Returned by `zora1155Impl()` on the confirmed mainnet factory |
| In Process Creator1155FactoryImpl | Base Sepolia | TBD | Must be confirmed from In Process docs/team before Tortoise testnet collection creation |
| Candidate Zora-compatible factory | Base Sepolia | `0x6832A997D8616707C7b68721D6E9332E77da7F6C` | RPC reports `ZORA 1155 Contract Factory` v2.13.2; not confirmed as In Process-owned/approved |
| Canonical Zora factory | Base Sepolia | `0x3b82f0910B67Af840bD90bF6E45537c5B72c893e` | RPC reports `ZORA 1155 Contract Factory` v2.13.1; reference only unless Tortoise intentionally chooses canonical Zora |
| In Process ERC-20 minter | Base mainnet | `0xE27d9Dc88dAB82ACa3ebC49895c663C6a0CfA014` | Reference only; not used by the custom minter path |
| USDC | Base mainnet | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | Router-era only |

In Process uses a Zora-derived creator stack, so verified source names and
`contractName()` values may say "ZORA." That proves ABI compatibility, not that an
address is the In Process deployment. Use `planning/setup-actions-reference.md`
as the operational address source.

## License

Apache-2.0
