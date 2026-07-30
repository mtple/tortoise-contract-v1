# Address registry

Per-chain configuration for the custom Tortoise ERC-1155 + USDC stack. `script/Deploy.s.sol`
resolves token addresses as environment override first, then this registry.

| Key | Env override | Meaning |
| --- | --- | --- |
| `usdc` | `USDC` | USDC payment and shell reward token |
| `stakingToken` | `TORT` | ERC-20 token staked in `TortoiseShell` |
| `tortoiseShell` | — | Verified deployed shell; add only after deployment |
| `tortoise` | — | Verified deployed ERC-1155/minter; add only after deployment |

Do not add `tortoise` or `tortoiseShell` based only on a broadcast attempt. Record them after
the deployment transaction is confirmed, ownership/wiring is checked, and source verification
succeeds.

The tracked registries intentionally contain no deployment addresses yet.
