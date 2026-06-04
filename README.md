# Tortoise

Solidity contracts for the Tortoise music platform on Base.

> **Status: migrating to a native-ETH stack.** The active codebase in `src/` is the v2
> system — `TortoiseInProcessMinter` (mints In Process / Zora-compatible ERC-1155s via
> `adminMint`, paying in **native ETH**) plus an ETH-native `TortoiseShell`, with a
> 5/10/85 platform/staking/artist split. See
> [`planning/eth-minter-implementation-plan.md`](planning/eth-minter-implementation-plan.md).
>
> The original USDC v1 (`TortoiseV1` + USDC `TortoiseShell`, tag `v1.0.0-rc1`, audits
> 6→12) is **archived, frozen, and audited** under [`legacy/v1/`](legacy/README.md). It
> is not migrated to v2 and shares no state.

## Repository layout

```
src/                  v2 (active): native-ETH In Process minter + ETH TortoiseShell
test/                 v2 tests (unit / fuzz / invariant / fork)
script/               v2 deploy + setup-action scripts
planning/             design & implementation docs
legacy/v1/            archived v1 (USDC) — build/test with `--profile v1`
```

The sections below document the archived **v1** contracts.

## Contracts (v1, archived under `legacy/v1/`)

### TortoiseV1 (`legacy/v1/src/TortoiseV1.sol`)

ERC-1155 music NFT collection contract.

- Artists create songs with configurable per-song pricing
- Collectors mint with USDC ($1.00 per copy by default: $0.85 artist + $0.05 platform + $0.10 staking)
- Revenue splits: up to 10 recipients per song, basis points, permanently lockable
- Platform fees accumulate in the contract, withdrawn by the owner via `withdrawPlatformFees()`
- Staking fees forwarded to TortoiseShell for 7-day USDC drip to stakers
- TORT crediting via TortoiseShell on every mint (try/catch so shell issues never block mints)
- Shell integration can be disabled by setting `tortoiseShell` to `address(0)` (auto-zeros staking fee)

### TortoiseShell (`legacy/v1/src/TortoiseShell.sol`)

Staking contract with USDC rewards and automatic TORT crediting.

- Stake $TORT tokens, earn USDC rewards from collection fees
- Synthetix-style 7-day drip: each deposit combines with remaining rewards and resets the window
- Balance-based reward accounting: `depositRewards` reads actual USDC balance rather than trusting caller-provided amounts
- TORT crediting: fixed TORT per copy collected, moved from pre-funded pool into collector's staked balance
- Graceful degradation: `creditStake` never reverts (caps to available pool, no-ops if empty)
- Emergency withdraw: get TORT back, forfeit unclaimed USDC
- Pause-safe: `withdraw`, `emergencyWithdraw`, `depositRewards`, and `creditStake` work when paused

### SplitLib (`legacy/v1/src/libraries/SplitLib.sol`)

Library for revenue split validation and calculation. Enforces basis points summing to 10,000, max 10 recipients, min 1% per recipient, no duplicates, no zero addresses.

## Architecture

```
Buyer calls TortoiseV1.mintSong(songId, quantity, recipient)
  |
  +-- USDC pulled from buyer
  |
  +-- 1. Platform fee ($0.05)  --> held in TortoiseV1 contract
  +-- 2. Staking fee ($0.10)   --> TortoiseShell.depositRewards()
  |                                 (dripped to all stakers over 7 days)
  +-- 3. Artist revenue ($0.85 x qty) --> split recipients or artist
  |
  +-- 4. TortoiseShell.creditStake(recipient, quantity)
  |       --> TORT from pool into recipient's staked balance
  |       --> wrapped in try/catch (mint succeeds even if shell fails)
  |
  +-- ERC-1155 mint
```

Three layers of protection ensure mints never fail due to shell issues:
1. **Shell graceful degradation** -- `creditStake` caps to available pool, never reverts
2. **TortoiseV1 try/catch** -- external shell calls wrapped, mint succeeds on failure
3. **Kill switch** -- owner sets `tortoiseShell` to `address(0)`, disabling all shell integration

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
# All tests (excluding fork tests)
forge test

# Fork tests (requires Base RPC)
forge test --match-contract TortoiseV1ForkTest --fork-url $BASE_RPC_URL

# With gas report
forge test --gas-report

# CI profile (10,000 fuzz runs, 512 invariant runs)
FOUNDRY_PROFILE=ci forge test
```

### Test Suite

| Suite | Tests | Description |
|-------|-------|-------------|
| TortoiseV1Test | 59 | Unit tests: song creation, splits, minting, payments, admin |
| TortoiseShellTest | 53 | Unit tests: staking, rewards, crediting, access control, pause |
| MintToShellTest | 5 | Integration: full mint-to-shell flow with both contracts |
| TortoiseV1FuzzTest | 7 | Fuzz: random prices/quantities/splits, payment sums, supply tracking |
| TortoiseShellFuzzTest | 8 | Fuzz: stake/withdraw/credit sequences, reward proportionality |
| TortoiseV1InvariantTest | 4 | Invariant: fee bounds, platform fee accounting, song ID monotonicity |
| TortoiseShellInvariantTest | 4 | Invariant: totalStaked consistency, TORT pool accounting, USDC solvency |
| TortoiseV1ForkTest | 6 | Fork: real Base USDC/TORT, full lifecycle, splits, reward claims |

## Deployment (v1, archived)

```bash
cp .env.example .env
# Fill in .env values
forge script legacy/v1/script/Deploy.s.sol --profile v1 --rpc-url $BASE_RPC_URL --broadcast --verify
```

Deployment order:
1. Deploy TortoiseShell (TORT address, USDC address, 604800 reward duration)
2. Deploy TortoiseV1 (USDC address, fees, shell address)
3. Register TortoiseV1 as authorized caller on TortoiseShell
4. Fund TortoiseShell TORT pool via `fundTortPool()`
5. Set `tortRewardPerCollection` on TortoiseShell (777,777 TORT per copy)

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| Song price | $0.85 (850,000) | Artist revenue per copy, configurable per song |
| Platform fee | $0.05 (50,000) | Flat per transaction, held in contract |
| Staking fee | $0.10 (100,000) | Flat per transaction, dripped to stakers |
| TORT per collection | 777,777 TORT | Fixed per copy, from pre-funded pool |
| Reward duration | 7 days (604,800s) | USDC drip window, resets on each deposit |

All values in USDC units (6 decimals). TORT values in wei (18 decimals).

## Token Addresses (Base)

| Token | Network | Address |
|-------|---------|---------|
| USDC | Base Mainnet | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| USDC | Base Sepolia | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| $TORT | Base Mainnet | `0x601410d1d3093cF469fCA4e1EfB2Fb67B4E225c6` |

## License

Apache-2.0
