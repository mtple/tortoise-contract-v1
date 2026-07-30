# Tortoise contracts

Smart contracts for the Tortoise music platform on Base.

> **Status:** v2 is the active custom ERC-1155 + USDC implementation. It is suitable for
> testnet integration but remains pre-audit and has no verified v2 deployment recorded.
> The audited v1 release candidate is frozen under `legacy/v1/`.

## Active contracts

### `Tortoise`

An immutable custom ERC-1155 that is the token, minter, payment router and provenance registry.

- Creates songs atomically with price, supply, URI, splits, royalties and
  `sha256(canonical manifest)`.
- Accepts USDC through `approve`/`transferFrom` or Circle EIP-3009
  `receiveWithAuthorization`.
- Distributes an inclusive 5% platform / 10% staking / 85% artist waterfall.
- Supports all-or-nothing batches of up to 20 items, including repeated songs with cumulative
  supply-cap enforcement.
- Defers USDC transfers rejected by a blocklisted recipient, with permissionless claims and a
  90-day owner reroute.
- Implements ERC-2981 royalties, artist-managed splits, pausing and two-step ownership.

Song creation has two explicitly distinguishable authority modes:

- `createSong`: the owner/operator asserts the artist. `artistAttested(songId)` is `false`.
- `createSongWithArtistSignature`: the artist signs every creation field through EIP-712 or
  EIP-1271. `artistAttested(songId)` is `true`.

The manifest commitment proves content integrity. Artist identity should only be presented as
cryptographically attested when `artistAttested(songId)` is true.

### `TortoiseShell`

TORT staking with USDC rewards:

- Seven-day Synthetix-style reward drip.
- Balance-reconciled reward deposits.
- Fixed TORT credit per collected copy from a prefunded pool.
- Reward queuing while no one is staked and a minimum-deposit dilution guard.
- Emergency withdrawal immediately recycles forfeited rewards to remaining stakers, or queues
  them for the next staker when the pool becomes empty.

## Repository layout

```text
src/                  active v2 contracts
test/unit/            unit and fuzz tests for Tortoise and TortoiseShell
test/invariant/       stateful Tortoise invariants
test/fork/            live Base USDC integration tests
script/               deployment script
addresses/            per-chain token and verified-deployment registry
planning/             architecture and as-built references
legacy/v1/            frozen audited v1 contracts and tests
```

## Build and test

```bash
forge build --sizes
forge test --no-match-contract Fork
forge fmt --check
```

The CI profile runs 10,000 fuzz cases and 512 invariant runs:

```bash
FOUNDRY_PROFILE=ci forge test --no-match-contract Fork
```

Run the real-USDC Base fork tests separately:

```bash
BASE_RPC_URL=https://mainnet.base.org \
  forge test --match-contract TortoiseBaseForkTest -vvv
```

The fork suite exercises:

- Circle USDC EIP-3009 signatures against the deployed Base proxy.
- Full collect → fee distribution → shell credit → reward claim flow.
- Circle blocklisting, deferred artist payment and later claim.

Run the frozen v1 suite with its separate profile:

```bash
FOUNDRY_PROFILE=v1 forge test --no-match-contract Fork
```

## Deployment

Copy `.env.example`, set `DEPLOYER_PRIVATE_KEY`, and optionally override the registry token
addresses with `USDC` or `TORT`.

Dry-run Base Sepolia first:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --sender "$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
```

Broadcast and verify only after reviewing the simulation:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --broadcast \
  --verify
```

The script:

1. Resolves USDC and TORT from environment overrides or `addresses/<chainId>.json`.
2. Deploys `TortoiseShell`.
3. Deploys `Tortoise`.
4. Authorizes `Tortoise` in the shell.
5. Optionally sets `TORT_REWARD_PER_COLLECTION`.

After confirmation:

1. Verify both contracts and ownership.
2. Confirm `shell.authorizedCallers(tortoise)`.
3. Fund the TORT pool.
4. Record the verified `tortoiseShell` and `tortoise` addresses in the chain registry.
5. Run a real end-to-end collect and reward claim.

## Canonical token configuration

| Token | Network | Address |
| --- | --- | --- |
| USDC | Base | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| USDC | Base Sepolia | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| TORT | Base | `0x601410d1d3093cF469fCA4e1EfB2Fb67B4E225c6` |
| TORS test token | Base Sepolia | `0x1c3879b9dabA1B51253b109726C44bb391cae8c5` |

## Production gate

Before a mainnet deployment:

- Complete an independent audit of `Tortoise` and the active `TortoiseShell`.
- Resolve all high/medium findings and rerun the full unit, fuzz, invariant and fork suites.
- Recheck runtime size against EIP-170 after audit changes.
- Verify client/indexer handling of `artistAttested`.
- Perform and document a Base Sepolia deployment rehearsal.

## License

Apache-2.0
