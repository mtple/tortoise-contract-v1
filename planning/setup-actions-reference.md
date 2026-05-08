# Setup Actions Reference

This document pins the In Process / Zora-derived ERC-1155 factory contract addresses, interface stubs, and `setupActions` calldata templates that `TortoiseInProcessMinter` and the deployment scripts depend on. It is the single source of truth for "how Tortoise creates collections and tokens, and how the new minter is granted permission to mint them."

The information here is a precondition for Phase 3 (Direct Creation Scripts) in `minter-architecture-migration-plan.md`. Phase 2 fork tests assert each pinned value before mainnet rollout.

## C.1 — Confirmed addresses

### Base mainnet

| Contract | Address | Source / Verification |
| --- | --- | --- |
| `Creator1155FactoryImpl` (proxy) | `0x540C18B7f99b3b599c6FeB99964498931c211858` | In Process docs and existing migration plan |
| Creator1155 implementation | TBD — read from `Creator1155FactoryImpl.zora1155Impl()` on first fork test, then pinned here | Fork-resolve before audit |
| `PERMISSION_BIT_ADMIN` | `2` | Zora-derived constant |
| `PERMISSION_BIT_MINTER` | `4` | Zora-derived constant |

### Base Sepolia

The factory address differs from mainnet. Pin from the In Process testnet docs before deploying test collections:

| Contract | Address | Source / Verification |
| --- | --- | --- |
| `Creator1155FactoryImpl` | `0x6832A997D8616707C7b68721D6E9332E77da7F6C` | In Process testnet docs; fork-verify before testnet rollout |
| Creator1155 implementation | TBD | `factory.zora1155Impl()` |
| `PERMISSION_BIT_ADMIN` | `2` | Same constant |
| `PERMISSION_BIT_MINTER` | `4` | Same constant |

## C.2 — Interface stubs the minter declares

These are intentionally minimal — only the functions Tortoise actually calls. Add as new files in `src/interfaces/` during Phase 1.

### `src/interfaces/ITortoiseInProcess1155.sol`

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

interface ITortoiseInProcess1155 {
    function adminMint(
        address recipient,
        uint256 tokenId,
        uint256 quantity,
        bytes calldata data
    ) external;
}
```

The production minter should only depend on `adminMint`. Deployment scripts may use the verified creator ABI for `setupNewToken`, `addPermission`, `assumeLastTokenIdMatches`, `updateRoyaltiesForToken`, and `isAdminOrRole`, but those script helpers must be fork-tested against the deployed creator implementation before mainnet use. Do not add unverified convenience methods such as `adminMintBatch` or `nextTokenId` to the production interface.

### `src/interfaces/ICreator1155Factory.sol`

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

interface ICreator1155Factory {
    struct RoyaltyConfiguration {
        uint32 royaltyMintSchedule;
        uint32 royaltyBPS;
        address royaltyRecipient;
    }

    function createContract(
        string calldata newContractURI,
        string calldata name,
        RoyaltyConfiguration calldata defaultRoyaltyConfiguration,
        address payable defaultAdmin,
        bytes[] calldata setupActions
    ) external returns (address);

    function zora1155Impl() external view returns (address);
}
```

These signatures match the Zora 1155 Factory ABI used by In Process. Verify byte-for-byte against the deployed factory's verified source on Basescan during Phase-2 fork tests; correct any drift before mainnet deployment.

## C.3 — `setupActions` template per new token

For each new track, build a `setupActions` array that creates the token and grants `TortoiseInProcessMinter` minter permission in a single transaction. Atomic creation + permission is required so that `setSale` + first `collect` can happen in the same backend orchestration step without an intermediate "token exists but minter cannot mint" window.

### Minimal template (default 5% royalty inherited from collection)

```solidity
bytes[] memory actions = new bytes[](2);

actions[0] = abi.encodeWithSignature(
    "setupNewToken(string,uint256)",
    trackMetadataURI,    // Arweave URI (token metadata)
    maxSupply            // use OPEN_EDITION_MAX_SUPPLY for unlimited; never pass 0
);

actions[1] = abi.encodeWithSignature(
    "addPermission(uint256,address,uint256)",
    expectedTokenId,                  // backend-computed; see below
    address(tortoiseInProcessMinter),
    4                                  // PERMISSION_BIT_MINTER
);
```

`expectedTokenId` is computable by the backend before the call:

- For a brand-new album collection, precompute token ids as `1..N` in setup-action order.
- For an existing collection, compute `expectedTokenId = lastKnownTokenId + 1` from Tortoise's indexed state and prepend an `assumeLastTokenIdMatches(lastKnownTokenId)` action when using a multicall/setup-action bundle. This makes stale backend state revert instead of granting permission on the wrong token.
- The backend reads the actual emitted token id from the `SetupNewToken` event after the tx confirms and persists it. Fork tests must prove the precomputed value matches the event before rollout.

For unlimited/open editions, use the Zora/In Process open-edition sentinel validated in fork tests. Current recommendation is `OPEN_EDITION_MAX_SUPPLY = 18446744073709551615` (`type(uint64).max`), matching the In Process API default. Do not use `0` for unlimited; treat `0` as invalid in Tortoise input validation unless a fork test proves otherwise.

### Per-token royalty override

When the artist requests a non-default royalty, keep `setupNewToken` and add a royalty update action after token creation:

```solidity
bytes[] memory actions = new bytes[](3);

actions[0] = abi.encodeWithSignature(
    "setupNewToken(string,uint256)",
    trackMetadataURI,
    maxSupply
);

ICreator1155Factory.RoyaltyConfiguration memory tokenRoyalty =
    ICreator1155Factory.RoyaltyConfiguration({
        royaltyMintSchedule: 0,
        royaltyBPS: artistRequestedBps,   // <= 10000
        royaltyRecipient: artistWallet
    });

actions[1] = abi.encodeWithSignature(
    "updateRoyaltiesForToken(uint256,(uint32,uint32,address))",
    expectedTokenId,
    tokenRoyalty
);

actions[2] = abi.encodeWithSignature(
    "addPermission(uint256,address,uint256)",
    expectedTokenId,
    address(tortoiseInProcessMinter),
    4
);
```

Fork tests must verify this three-action sequence (`setupNewToken`, optional `updateRoyaltiesForToken`, `addPermission`) on both Base mainnet fork and Base Sepolia before scripts are used operationally.

### What is **not** set in setup actions

- **Sale config** (price, start, end, max-per-address). Sale lives in `TortoiseInProcessMinter.sale[songKey]`, configured via `setSale` after token creation. The In Process ERC-20 minter is never wired up.
- **Comments**. Comments are minter-emitted events; nothing on the underlying token.

## C.4 — Backend operator wallet requirements

- The operator wallet holds `PERMISSION_BIT_ADMIN` (`2`) on every Tortoise-managed collection.
- For new collections, the operator passes its own address as `defaultAdmin` in `createContract`. Subsequent token setup actions inherit admin rights from the collection.
- For "Add Track To Existing Collection," the operator's address must already hold per-collection admin (granted at collection creation). No artist-admin path is supported in v1; all collections are deployed by Tortoise with the operator as default admin.
- Operator wallet must be funded with ETH on Base mainnet for: collection creation gas (~one-time per album), `setupNewToken` per track, and `setSale` per track. Estimate **0.01 ETH per album** for budgeting; refine after Phase-2 gas tests.
- Pending claims are user-claimed (`claimPending`); the operator does not need ETH for those.

## C.5 — Collection creation flow (new album)

1. Backend uploads album artwork and collection-level metadata to Arweave.
2. Backend uploads each track's audio + token metadata to Arweave.
3. Backend constructs `setupActions` for every track using the template in §C.3, with the operator wallet as `defaultAdmin`.
4. Backend calls `factory.createContract(contractURI, name, defaultRoyalty, operator, setupActions)`.
5. Backend reads the new collection address from the return value (and the factory event for cross-check).
6. Backend reads each emitted `SetupNewToken` event for the actual `tokenId`, persists `(collectionAddress, tokenId)` per track row, and issues `setSale` to `TortoiseInProcessMinter` for each.
7. Backend issues `registerSongWithSplits` (or `registerSong`) on the minter to onboard each track for distribution and shell crediting.

## C.6 — Add-track flow (existing album)

1. Backend confirms operator wallet holds `PERMISSION_BIT_ADMIN` on the existing collection (read `isAdminOrRole(operator, 0, 2)`).
2. Backend uploads new track media and metadata.
3. Backend computes `expectedTokenId = lastKnownTokenId + 1` from Tortoise's indexed state.
4. Backend calls the collection directly with a multicall/setup-action pattern that first checks `assumeLastTokenIdMatches(lastKnownTokenId)`, then executes `setupNewToken`, optional `updateRoyaltiesForToken`, and `addPermission`.
5. Backend issues `setSale` and `registerSongWithSplits` on the minter as in §C.5.

## C.7 — "No ETH leaves" invariant during creation

The factory and creator implementation should not consume ETH for `createContract`, `setupNewToken`, `updateRoyaltiesForToken`, or `addPermission`. Phase-2 fork test asserts:

```solidity
uint256 balanceBefore = address(this).balance;
address newCollection = factory.createContract(uri, name, royalty, admin, actions);
assertEq(address(this).balance, balanceBefore, "factory consumed ETH");
```

If a future In Process implementation introduces a creation fee, this test fails loudly and the operator's gas-budget assumptions must be revisited. No silent fund drain.

## C.8 — Fork-test checklist

Phase-2 fork tests assert each of the following before mainnet rollout:

1. `Creator1155FactoryImpl` at the pinned address has nonzero code and is the expected implementation.
2. `factory.zora1155Impl()` returns a creator implementation whose source matches the verified Basescan source.
3. `PERMISSION_BIT_MINTER == 4` and `PERMISSION_BIT_ADMIN == 2`.
4. A fork-deployed test collection produced via `createContract` with the §C.3 `setupActions` template results in `TortoiseInProcessMinter` holding `PERMISSION_BIT_MINTER` on the new tokenId.
5. `adminMint(mintTo, tokenId, quantity, "")` from `TortoiseInProcessMinter` succeeds.
6. Multi-item Tortoise `batchCollect` succeeds by looping `adminMint` once per item and produces the expected balances.
7. `assertEq(address(deployer).balance, balanceBefore)` across the entire creation flow.

## C.9 — Required mocks for unit tests

`test/mocks/MockInProcess1155.sol` — implements `ITortoiseInProcess1155`:

- `mapping(uint256 tokenId => uint256) maxSupply`, `mapping(uint256 tokenId => uint256) totalMinted`.
- `mapping(uint256 tokenId => mapping(address => mapping(uint256 => bool))) permission`.
- `adminMint` reverts on `totalMinted + quantity > maxSupply` when set.
- `adminMint` reverts unless caller has `PERMISSION_BIT_MINTER` for the tokenId.
- ERC-1155 `_balances` map for `balanceOf` reads.
- Test-only setters: `setMaxSupply`, `grantPermission`.

`test/mocks/MockBadInProcess1155.sol` — same surface but `adminMint` reverts unconditionally. Used to verify that `TortoiseInProcessMinter` does not mutate state when the underlying token reverts (whole-batch revert in `batchCollect`).

`test/mocks/MockTortoiseShellETH.sol` — implements:

```solidity
function depositRewards() external payable;
function creditStake(address user, uint256 quantity) external returns (uint256 credited);
function getTortPoolBalance() external view returns (uint256);
function tortRewardPerCollection() external view returns (uint256);
```

Test-only setters: `setNextCreditedAmount(uint256)`, `setShouldRevertOnDeposit(bool)`, `setShouldRevertOnCredit(bool)`. Used to drive the divergence-semantics matrix in §D.8 of the migration plan.
