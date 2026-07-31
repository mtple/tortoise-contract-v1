# Legacy (archived)

Frozen, audited contracts that predate the active ETH stack in `src/`. **Do not modify.**

## `legacy/v1/` — Tortoise v1 (USDC), tag `v1.0.0-rc1`

The original USDC ERC-1155 music-NFT system: `TortoiseV1`, `TortoiseShell` (USDC
rewards), `SplitLib`, their interfaces, full test suite (unit / fuzz / invariant / fork /
integration), and deploy script. This is the audit-hardened release candidate (audits
6→12, mirrored in `legacy/v1/test/unit/AuditRemediation.t.sol`).

It is preserved for reference and regression safety only. The go-forward product is the
native-ETH stack in `src/` (`TortoiseInProcessMinter` + ETH-native `TortoiseShell`), per
`planning/eth-minter-implementation-plan.md`. v1 is **not** migrated to v2; there is no
shared state.

### Building / testing the archive

v1 lives under its own Foundry profile so it stays runnable without polluting the active
v2 build:

```bash
FOUNDRY_PROFILE=v1 forge build --sizes
FOUNDRY_PROFILE=v1 forge test  -vvv
```

CI runs both the active (`src/`) and archived (`FOUNDRY_PROFILE=v1`) suites on every push.
