# Address registry

Per-chain address registry read by `script/Config.s.sol`. One file per chain id:
`addresses/<chainId>.json`. Keys are resolved as `env override → pinned constant (factory on
mainnet only) → this registry → revert`.

| Key | Meaning |
| --- | --- |
| `inProcessFactory` | In Process / Zora `Creator1155FactoryImpl`. **Fail-closed**: absent ⇒ creation scripts revert. |
| `stakingToken` | ERC-20 staking token backing the ETH `TortoiseShell`. |
| `platformFeeRecipient` | 5% platform-fee recipient (or pass `PLATFORM_FEE_RECIPIENT`). |
| `tortoiseShellEth` | Deployed ETH shell (fill in after `DeployStack`). |
| `tortoiseInProcessMinter` | Deployed minter (fill in after `DeployStack`). |

## Fail-closed factory

Only **Base mainnet (8453)** has a fork-verified factory (`0x540C18B7…`). **Base Sepolia
(84532)** intentionally omits `inProcessFactory` — the In Process Sepolia factory is
unconfirmed, so scripts revert (`FactoryUnconfirmed`) until the In Process team confirms it
and it is pinned here (or passed via `INPROCESS_FACTORY`). The scripts never fall back to the
canonical Zora factory.

## Env overrides

Every value can be overridden by env var, which always wins: `INPROCESS_FACTORY`,
`TORT_TOKEN`, `PLATFORM_FEE_RECIPIENT`, `TORTOISE_MINTER`, `PLATFORM_FEE_BPS`,
`STAKING_FEE_BPS`.
