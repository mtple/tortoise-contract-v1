# Tortoise v1

Solidity contracts for the Tortoise music platform on Base. In Process owns ERC-1155
creation and mint infrastructure; Tortoise owns the USDC routing, artist splits,
staking rewards, and collector TORT crediting layer.

## Active Contracts

### TortoiseMintRouter (`src/TortoiseMintRouter.sol`)

Payment router for In Process ERC-20 collects.

- Wraps the allowlisted In Process ERC20 minter
- Pulls USDC from collectors and approves only the exact collect amount
- Requires the In Process sale currency to be Base USDC
- Requires the sale `fundsRecipient` to be the router
- Requires full proceeds after collect: `pricePerToken * quantity`
- Splits USDC into platform fee, staking fee, and artist revenue
- Lets only the registered artist configure or lock song splits
- Defers failed artist/split transfers into pull claims
- Credits collector TORT through `TortoiseShell` once per wallet per song, with try/catch

### TortoiseShell (`src/TortoiseShell.sol`)

Staking contract with USDC rewards and automatic TORT crediting.

- Stake TORT and earn USDC from collection fees
- Synthetix-style 7-day reward drip
- `depositRewards` reconciles actual USDC received from token balance
- `creditStake` moves TORT from a pre-funded pool into the collector's staked balance
- TORT crediting gracefully caps to available pool and never blocks collection
- Emergency withdraw returns TORT and forfeits unclaimed USDC

### Legacy V1 Archive (`legacy/v0.3/`)

The old Tortoise-owned ERC-1155 contract and its V1-specific tests/scripts are archived
for historical reference. They are not part of the active Foundry source, test, or deploy path.

## Collection Flow

```text
Collector calls TortoiseMintRouter.collect(collection, tokenId, quantity, maxTotalCost)
  |
  +-- Router reads the In Process ERC20 sale config
  |     require currency == Base USDC
  |     require fundsRecipient == router
  |     require pricePerToken * quantity <= maxTotalCost
  |
  +-- Router pulls USDC from collector
  +-- Router approves the allowlisted In Process minter for the exact amount
  +-- Router calls In Process mint(...), NFT minted to collector
  +-- Router requires its USDC balance increased by the full sale price
  |
  +-- USDC distribution:
  |     platform fee -> platform fee recipient
  |     staking fee  -> TortoiseShell.depositRewards()
  |     artist rev   -> artist or configured split recipients
  |
  +-- TortoiseShell.creditStake(collector, 1) on the wallet's first eligible collect
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

## Deployment

```bash
cp .env.example .env
# Fill in .env values
forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
```

Deployment order:

1. Deploy `TortoiseShell`.
2. Deploy `TortoiseMintRouter`.
3. Register the router as an authorized caller on `TortoiseShell`.
4. Fund the shell TORT pool via `fundTortPool()`.
5. Set `tortRewardPerCollection` on `TortoiseShell`.
6. Update the backend so new In Process moments use the router as `token.payoutRecipient`.

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| Platform fee | 500 bps | Taken from the inclusive sale price |
| Staking fee | 1000 bps | Forwarded to `TortoiseShell` |
| Reward duration | 604,800 seconds | 7-day USDC drip window |
| TORT per collection | TBD | Fixed TORT credited per collected copy |

Song price is configured in the In Process moment sale config. The router reads it from
the verified In Process minter and does not store song prices.

## Base Mainnet Addresses

| Contract | Address |
|----------|---------|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| TORT | `0x601410d1d3093cF469fCA4e1EfB2Fb67B4E225c6` |
| In Process Factory | `0x540C18B7f99b3b599c6FeB99964498931c211858` |
| In Process ERC20 Minter | `0xE27d9Dc88dAB82ACa3ebC49895c663C6a0CfA014` |

## License

Apache-2.0
