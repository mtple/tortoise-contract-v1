# ERC20Minter Migration Plan

## Overview

**Source repository**: `/home/misuka/Documents/GitHub/InProcess/in-process-protocol`  
**Destination repository**: `/home/misuka/Documents/GitHub/InProcess/tortoise-contract-v1`  
**Destination directory**: `src/in_process/` (this folder)

The goal is to extract only the `ERC20Minter` contract and its direct dependencies from the
`in-process-protocol` monorepo (a pnpm workspace with 16 packages) and transplant them into
`tortoise-contract-v1`, which is a standalone Foundry project.

---

## Environment Differences

| Item | in-process-protocol (source) | tortoise-contract-v1 (destination) |
|------|------------------------------|-------------------------------------|
| Build system | Foundry + pnpm monorepo | Pure Foundry |
| Dependency management | npm packages via pnpm | git submodules |
| Solc version | 0.8.17 | 0.8.34 |
| OpenZeppelin | v4.x (via npm) | v5.6.1 (lib/openzeppelin-contracts) |
| OZ Upgradeable | @zoralabs fork (npm) | none yet |
| Zora shared-contracts | npm package | none yet |
| Zora protocol-rewards | npm package | none yet |

**Key insight**: No new git submodules are required. All Zora-specific packages
(`@zoralabs/shared-contracts`, `@zoralabs/protocol-rewards`,
`@zoralabs/openzeppelin-contracts-upgradeable`) exist inside the `in-process-protocol`
monorepo itself. We vendor (copy) only the files we actually need.

---

## Zora → InProcess Renaming

`in-process-protocol` is a fork of the Zora protocol. During migration, all identifiers that
describe **our own forked code** are renamed from Zora to InProcess.

### Rule: What to rename vs. what to keep

| Category | Action | Reason |
|----------|--------|--------|
| Our contract/interface names | **RENAME** | These describe InProcess protocol entities |
| Our struct field names | **RENAME** | Part of our own ABI design |
| Our event parameter names | **RENAME** | Part of our own event design |
| Our NatSpec comments | **RENAME** | Describe our own system |
| Our function parameter names | **RENAME** | Describe InProcess concepts |
| Our constant names | **RENAME** | Part of our own reward logic |
| `@zoralabs/*` import paths | **KEEP** | These are dependency packages we consume |
| Zora's own interface/contract names (`IProtocolRewards`, `IMinter1155`, etc.) | **KEEP** | We use but do not own them |
| `IProtocolRewards` contents and field names | **KEEP** | Zora's interface, not ours |

---

### Complete Rename Table

#### `src/in_process/minters/erc20/IZora1155.sol`

| Original | Renamed |
|----------|---------|
| `interface IZora1155` | `interface IInProcess1155` |
| `/// @notice The set of public functions on a Zora 1155 contract` | `/// @notice The set of public functions on an InProcess 1155 contract` |

File is renamed: `IZora1155.sol` → `IInProcess1155.sol`

---

#### `src/in_process/minters/erc20/ERC20MinterRewards.sol`

| Original | Renamed |
|----------|---------|
| `uint256 internal constant ZORA_PAID_MINT_REWARD_PCT` | `IN_PROCESS_PAID_MINT_REWARD_PCT` |
| comment `// 28.5714%, roughly 0.000222 ETH at a 0.000777 value` (on ZORA line) | (same comment, keep) |

---

#### `src/in_process/interfaces/IERC20Minter.sol`

| Original | Renamed |
|----------|---------|
| `uint256 zoraReward` (field in `RewardsSettings` struct) | `inProcessReward` |
| `/// @notice Amount of the zora reward` | `/// @notice Amount of the InProcess protocol reward` |
| `address zoraRewardRecipientAddress` (field in `ERC20MinterConfig` struct) | `inProcessRewardRecipientAddress` |
| `/// @notice The address of the Zora rewards recipient` | `/// @notice The address of the InProcess rewards recipient` |
| `/// @param zora ZORA recipient address` (in `ERC20RewardsDeposit` event NatSpec) | `/// @param inProcess InProcess recipient address` |
| `/// @param zoraReward ZORA amount` (in event NatSpec) | `/// @param inProcessReward InProcess reward amount` |
| `address zora` (event parameter in `ERC20RewardsDeposit`) | `address inProcess` |
| `uint256 zoraReward` (event parameter in `ERC20RewardsDeposit`) | `uint256 inProcessReward` |

---

#### `src/in_process/minters/erc20/ERC20Minter.sol`

| Original | Renamed |
|----------|---------|
| `import {IZora1155} from "./IZora1155.sol"` | `import {IInProcess1155} from "./IInProcess1155.sol"` |
| ASCII art block + `github.com/ourzora/zora-protocol` | Remove the ASCII art block entirely |
| `/// @notice Allows for ZoraCreator Mints to be purchased using ERC20 tokens` | `/// @notice Allows for InProcess Mints to be purchased using ERC20 tokens` |
| `/// @dev While this contract _looks_ like a minter...` (full sentence is fine, no Zora ref) | keep |
| `/// @notice Initializes the contract with a Zora rewards recipient address` | `/// @notice Initializes the contract with an InProcess rewards recipient address` |
| `function initialize(address _zoraRewardRecipientAddress, ...)` | `_inProcessRewardRecipientAddress` |
| `ERC20MinterConfig({zoraRewardRecipientAddress: _zoraRewardRecipientAddress, ...})` | `inProcessRewardRecipientAddress: _inProcessRewardRecipientAddress` |
| `uint256 zoraReward` (local var in `computePaidMintRewards`) | `inProcessReward` |
| `zoraReward: zoraReward` (struct field assignment) | `inProcessReward: inProcessReward` |
| `minterConfig.zoraRewardRecipientAddress` (all occurrences, 6 total) | `minterConfig.inProcessRewardRecipientAddress` |
| `settings.zoraReward` (in `_distributeRewards`) | `settings.inProcessReward` |
| `/// @notice Distributes the ETH rewards to the Zora rewards recipient` | `/// @notice Distributes the ETH rewards to the InProcess rewards recipient` |
| `IZora1155(tokenContract).createReferrals(tokenId)` | `IInProcess1155(tokenContract).createReferrals(tokenId)` |
| `IZora1155(tokenContract).firstMinters(tokenId)` | `IInProcess1155(tokenContract).firstMinters(tokenId)` |
| `IZora1155(tokenContract).getCreatorRewardRecipient(tokenId)` | `IInProcess1155(tokenContract).getCreatorRewardRecipient(tokenId)` |
| `IZora1155(tokenAddress).adminMint(...)` | `IInProcess1155(tokenAddress).adminMint(...)` |
| `return "https://github.com/ourzora/zora-protocol/"` (in `contractURI`) | `return "https://github.com/sweetmantech/in-process-protocol/"` |
| `_config.zoraRewardRecipientAddress` (in `_setERC20MinterConfig`) | `_config.inProcessRewardRecipientAddress` |

`import {IProtocolRewards} from "@zoralabs/protocol-rewards/..."` — **KEEP** (using Zora's package)  
`import {Initializable} from "@zoralabs/openzeppelin-contracts-upgradeable/..."` — **KEEP reference** (import path will change to local vendor, but the concept is unchanged)

---

### Test File Renames (`test/in_process/ERC20Minter.t.sol`)

| Original | Renamed |
|----------|---------|
| `address internal zora` | `address internal inProcess` |
| `zora = makeAddr("zora")` | `inProcess = makeAddr("inProcess")` |
| All `minter.initialize(zora, ...)` | `minter.initialize(inProcess, ...)` |
| All `minter.initialize(address(zora), ...)` | `minter.initialize(address(inProcess), ...)` |
| `currency.balanceOf(address(zora))` (all) | `currency.balanceOf(address(inProcess))` |
| `address(zora).balance` (all) | `address(inProcess).balance` |
| `zoraRewardRecipientAddress: zora` (all) | `inProcessRewardRecipientAddress: inProcess` |
| `minterConfig.zoraRewardRecipientAddress` (all) | `minterConfig.inProcessRewardRecipientAddress` |
| `rewardsSettings.zoraReward` | `rewardsSettings.inProcessReward` |
| `uint256 zoraReward` (local var, in fuzz test) | `inProcessReward` |
| `uint256 zoraEthReward` (fuzz param) | `inProcessEthReward` |
| `assertEq(...zoraReward...)` references | updated to `inProcessReward` |
| `address zora,` in event emit | `address inProcess,` |
| `uint256 zoraReward` in event emit | `uint256 inProcessReward` |
| `function test_ERC20MinterSetZoraRewardsRecipient` | `test_ERC20MinterSetInProcessRewardsRecipient` |
| `function test_ERC20MinterZoraAddrCannotInitializeWithAddressZero` | `test_ERC20MinterInProcessAddrCannotInitializeWithAddressZero` |
| `vm.prank(zora)` | `vm.prank(inProcess)` |
| `"https://zora.co/testing/token.json"` (test URIs, 5 occurrences) | `"https://in-process.xyz/testing/token.json"` |

Event definition in test (copied from IERC20Minter, must match exactly):
```solidity
// OLD:
event ERC20RewardsDeposit(..., address zora, ..., uint256 zoraReward);
// NEW:
event ERC20RewardsDeposit(..., address inProcess, ..., uint256 inProcessReward);
```

`ZoraCreator1155Impl`, `Zora1155`, `IZoraCreator1155Errors` — **REMOVED** (replaced by mocks, not renamed)

---

## Breaking Changes to Handle

### 1. OpenZeppelin v4 → v5 (CRITICAL)

`tortoise-contract-v1` already uses OZ **v5.6.1**. The source uses OZ **v4.x**.

| v4 import path | v5 import path | Affected files |
|----------------|----------------|----------------|
| `@openzeppelin/contracts/security/ReentrancyGuard.sol` | `@openzeppelin/contracts/utils/ReentrancyGuard.sol` | `ERC20Minter.sol` |
| `@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol` | **REMOVED in v5** | test file only → replace with `MockERC20.sol` |

`IERC20`, `SafeERC20` paths are unchanged between v4 and v5.

### 2. Fixed pragma → Range pragma

Six files use `pragma solidity 0.8.17` (exact/fixed version), which is **incompatible** with
the solc 0.8.34 compiler. Change all of them to `pragma solidity ^0.8.17`.

Files that need this change:
- `src/minters/SaleStrategy.sol`
- `src/minters/utils/LimitedMintPerAddress.sol`
- `src/utils/TransferHelperUtils.sol`
- `src/utils/ownable/Ownable2StepUpgradeable.sol`
- `src/utils/ownable/IOwnable2StepUpgradeable.sol`
- `src/utils/ownable/IOwnable2StepStorageV1.sol`

Files that are **already compatible** (`^0.8.17`):
- `ERC20Minter.sol`, `ERC20MinterRewards.sol`, `IZora1155.sol`
- `IERC20Minter.sol`, `IMinterPremintSetup.sol`
- All `shared-contracts` interfaces

### 3. Test dependency: ZoraCreator1155Impl (CRITICAL)

The original test (`ERC20Minter.t.sol`) imports the entire Zora 1155 NFT infrastructure:
- `ZoraCreator1155Impl` — the main 1155 contract (hundreds of dependencies)
- `Zora1155` — proxy contract

These are NOT ERC20Minter code. To keep scope to "ERC20Minter only", we replace them
with a lightweight `MockZora1155` that implements exactly the interface ERC20Minter needs.

`IZora1155` (the interface ERC20Minter actually calls) requires:
```solidity
function createReferrals(uint256 tokenId) external view returns (address);
function firstMinters(uint256 tokenId) external view returns (address);
function getCreatorRewardRecipient(uint256 tokenId) external view returns (address);
function adminMint(address recipient, uint256 tokenId, uint256 quantity, bytes memory data) external;
```

Additionally, the test calls these methods on the 1155 contract directly:
```solidity
target.setupNewTokenWithCreateReferral(uri, maxSupply, createReferral) → uint256 tokenId
target.setupNewToken(uri, maxSupply) → uint256 tokenId
target.addPermission(tokenId, minterAddress, PERMISSION_BIT_MINTER)
target.callSale(tokenId, minterContract, calldata)   // calls minter.setSale(...)
target.balanceOf(account, tokenId) → uint256
target.PERMISSION_BIT_MINTER() → uint256
```

`MockZora1155` must implement all of the above.

### 4. Zora custom Initializable

`@zoralabs/openzeppelin-contracts-upgradeable` is a Zora fork of OZ Upgradeable that uses
a **custom error** instead of a require:
```solidity
error INITIALIZABLE_CONTRACT_ALREADY_INITIALIZED();
```

The test explicitly checks for this error:
```solidity
vm.expectRevert(abi.encodeWithSignature("INITIALIZABLE_CONTRACT_ALREADY_INITIALIZED()"));
```

We vendor a `Initializable.sol` that preserves this exact error name.

---

## Complete File Manifest

### Files to CREATE in `src/in_process/`

#### Contracts (copied from source, with modifications noted)

```
src/in_process/
├── minters/
│   ├── erc20/
│   │   ├── ERC20Minter.sol
│   │   │     SOURCE: packages/1155-contracts/src/minters/erc20/ERC20Minter.sol
│   │   │     CHANGE: pragma unchanged (^0.8.17 already OK)
│   │   │     CHANGE: ReentrancyGuard import: security/ → utils/  (OZ v5)
│   │   │     CHANGE: all @zoralabs/* imports → relative paths within src/in_process/
│   │   │     CHANGE: all ../../ relative imports → adjusted for new directory depth
│   │   │     CHANGE: IZora1155 → IInProcess1155 (import + all call sites)
│   │   │     CHANGE: ASCII art block removed (github.com/ourzora/zora-protocol)
│   │   │     CHANGE: NatSpec "ZoraCreator" → "InProcess"
│   │   │     CHANGE: _zoraRewardRecipientAddress → _inProcessRewardRecipientAddress
│   │   │     CHANGE: zoraRewardRecipientAddress (struct field) → inProcessRewardRecipientAddress
│   │   │     CHANGE: zoraReward (local var) → inProcessReward
│   │   │     CHANGE: contractURI() return value → InProcess GitHub URL
│   │   │
│   │   ├── ERC20MinterRewards.sol
│   │   │     SOURCE: packages/1155-contracts/src/minters/erc20/ERC20MinterRewards.sol
│   │   │     CHANGE: ZORA_PAID_MINT_REWARD_PCT → IN_PROCESS_PAID_MINT_REWARD_PCT
│   │   │
│   │   └── IInProcess1155.sol                               ← renamed from IZora1155.sol
│   │         SOURCE: packages/1155-contracts/src/minters/erc20/IZora1155.sol
│   │         CHANGE: interface name IZora1155 → IInProcess1155
│   │         CHANGE: NatSpec "Zora 1155 contract" → "InProcess 1155 contract"
│   │
│   ├── utils/
│   │   └── LimitedMintPerAddress.sol
│   │         SOURCE: packages/1155-contracts/src/minters/utils/LimitedMintPerAddress.sol
│   │         CHANGE: pragma 0.8.17 → ^0.8.17
│   │         CHANGE: ../../interfaces/ILimitedMintPerAddress.sol → adjusted relative path
│   │
│   └── SaleStrategy.sol
│         SOURCE: packages/1155-contracts/src/minters/SaleStrategy.sol
│         CHANGE: pragma 0.8.17 → ^0.8.17
│         CHANGE: @zoralabs/openzeppelin-contracts-upgradeable → local vendor path
│         CHANGE: @zoralabs/shared-contracts → local vendor path
│         CHANGE: ../interfaces/* → adjusted relative paths
│
├── interfaces/
│   ├── IERC20Minter.sol
│   │     SOURCE: packages/1155-contracts/src/interfaces/IERC20Minter.sol
│   │     CHANGE: RewardsSettings.zoraReward → inProcessReward
│   │     CHANGE: ERC20MinterConfig.zoraRewardRecipientAddress → inProcessRewardRecipientAddress
│   │     CHANGE: ERC20RewardsDeposit event: param `zora` → `inProcess`, `zoraReward` → `inProcessReward`
│   │     CHANGE: all related NatSpec comments updated to say "InProcess" instead of "ZORA"
│   │
│   ├── IMinterPremintSetup.sol
│   │     SOURCE: packages/1155-contracts/src/interfaces/IMinterPremintSetup.sol
│   │     CHANGE: none (self-contained)
│   │
│   ├── ILimitedMintPerAddress.sol
│   │     SOURCE: packages/1155-contracts/src/interfaces/ILimitedMintPerAddress.sol
│   │     CHANGE: @zoralabs/openzeppelin-contracts-upgradeable → local vendor path
│   │     CHANGE: @zoralabs/shared-contracts/interfaces/errors/... → local vendor path
│   │
│   ├── IContractMetadata.sol
│   │     SOURCE: packages/1155-contracts/src/interfaces/IContractMetadata.sol
│   │     CHANGE: none (self-contained)
│   │
│   └── shared/
│       │   (vendor copies of @zoralabs/shared-contracts interfaces)
│       │
│       ├── IERC165Upgradeable.sol
│       │     SOURCE: packages/shared-contracts/src/interfaces/IERC165Upgradeable.sol
│       │     CHANGE: none (self-contained)
│       │
│       ├── IMinter1155.sol
│       │     SOURCE: packages/shared-contracts/src/interfaces/IMinter1155.sol
│       │     CHANGE: import paths → local relative paths
│       │
│       ├── ICreatorCommands.sol
│       │     SOURCE: packages/shared-contracts/src/interfaces/ICreatorCommands.sol
│       │     CHANGE: none (self-contained)
│       │
│       ├── IVersionedContract.sol
│       │     SOURCE: packages/shared-contracts/src/interfaces/IVersionedContract.sol
│       │     CHANGE: none (self-contained)
│       │
│       └── errors/
│           ├── IMinterErrors.sol
│           │     SOURCE: packages/shared-contracts/src/interfaces/errors/IMinterErrors.sol
│           │     CHANGE: none (self-contained)
│           │
│           └── IZoraCreator1155Errors.sol
│                 SOURCE: packages/shared-contracts/src/interfaces/errors/IZoraCreator1155Errors.sol
│                 CHANGE: import IMinterErrors → local relative path
│                 NOTE: used only by test (ILimitedMintPerAddressErrors)
│
└── utils/
    ├── TransferHelperUtils.sol
    │     SOURCE: packages/1155-contracts/src/utils/TransferHelperUtils.sol
    │     CHANGE: pragma 0.8.17 → ^0.8.17
    │
    ├── IProtocolRewards.sol
    │     SOURCE: packages/protocol-rewards/src/interfaces/IProtocolRewards.sol
    │     CHANGE: none (self-contained)
    │     NOTE: ERC20Minter does NOT call IProtocolRewards directly.
    │           This file is vendored only because SaleStrategy.sol's import chain
    │           passes through it in the original. Verify if actually needed at compile time.
    │
    └── ownable/
        ├── Initializable.sol
        │     SOURCE: @zoralabs/openzeppelin-contracts-upgradeable fork (vendored)
        │     CHANGE: self-contained new file
        │     NOTE: Must use Zora custom error INITIALIZABLE_CONTRACT_ALREADY_INITIALIZED()
        │           because the test explicitly checks for this error signature.
        │           Standard OZ v4/v5 Initializable uses different error names.
        │     IMPLEMENTATION:
        │       - uint8 private _initialized storage slot
        │       - bool private _initializing storage slot
        │       - modifier initializer: reverts with INITIALIZABLE_CONTRACT_ALREADY_INITIALIZED()
        │         if _initialized >= 1 && !_initializing
        │       - modifier onlyInitializing: reverts if !_initializing
        │
        ├── Ownable2StepUpgradeable.sol
        │     SOURCE: packages/1155-contracts/src/utils/ownable/Ownable2StepUpgradeable.sol
        │     CHANGE: pragma 0.8.17 → ^0.8.17
        │     CHANGE: @zoralabs/openzeppelin-contracts-upgradeable → local Initializable path
        │
        ├── IOwnable2StepUpgradeable.sol
        │     SOURCE: packages/1155-contracts/src/utils/ownable/IOwnable2StepUpgradeable.sol
        │     CHANGE: pragma 0.8.17 → ^0.8.17
        │
        └── IOwnable2StepStorageV1.sol
              SOURCE: packages/1155-contracts/src/utils/ownable/IOwnable2StepStorageV1.sol
              CHANGE: pragma 0.8.17 → ^0.8.17
```

### Files to CREATE in `test/in_process/`

```
test/in_process/
├── ERC20Minter.t.sol
│     SOURCE: packages/1155-contracts/test/minters/erc20/ERC20Minter.t.sol
│     CHANGE: pragma 0.8.17 → ^0.8.17 (it currently has exact version)
│     CHANGE: Remove import of ZoraCreator1155Impl, Zora1155, ProtocolRewards
│     CHANGE: Remove import of ICreatorRoyaltiesControl, IZoraCreator1155Errors (from nft/)
│     CHANGE: Replace ZoraCreator1155Impl + Zora1155 usage with MockZora1155
│     CHANGE: Replace ERC20PresetMinterPauser with MockERC20
│     CHANGE: All import paths updated to point to src/in_process/
│     LOGIC:  All test functions preserved exactly — only test infrastructure swapped.
│
└── mocks/
    ├── MockERC20.sol
    │     SOURCE: new file
    │     PURPOSE: Replaces ERC20PresetMinterPauser (removed in OZ v5)
    │     INTERFACE REQUIRED BY TEST:
    │       constructor(string name, string symbol)
    │       function mint(address to, uint256 amount) external
    │       function approve(address spender, uint256 amount) external returns (bool)
    │       function balanceOf(address account) external view returns (uint256)
    │       function transfer(address to, uint256 amount) external returns (bool)
    │       function transferFrom(address from, address to, uint256 amount) external returns (bool)
    │     IMPLEMENTATION: inherit OZ v5 ERC20, add unrestricted mint()
    │
    └── MockInProcess1155.sol
          SOURCE: new file
          PURPOSE: Replaces ZoraCreator1155Impl + Zora1155 proxy
          NOTE: Named MockInProcess1155 (not MockZora1155) because it simulates
                our InProcess 1155 contract, which implements IInProcess1155.
          INTERFACE REQUIRED BY TEST (from setUp and setUpTargetSale):
            function setupNewToken(string uri, uint256 maxSupply) → uint256 tokenId
            function setupNewTokenWithCreateReferral(string uri, uint256 maxSupply, address ref) → uint256 tokenId
            function addPermission(uint256 tokenId, address minter, uint256 permissionBit) external
            function callSale(uint256 tokenId, address minter, bytes calldata data) external
            function balanceOf(address account, uint256 tokenId) → uint256
            function PERMISSION_BIT_MINTER() → uint256
          INTERFACE REQUIRED BY ERC20Minter (IInProcess1155):
            function createReferrals(uint256 tokenId) → address
            function firstMinters(uint256 tokenId) → address
            function getCreatorRewardRecipient(uint256 tokenId) → address
            function adminMint(address recipient, uint256 tokenId, uint256 quantity, bytes data) external
          STORAGE NEEDED:
            - tokenIdCounter: uint256
            - createReferrals: mapping(uint256 => address)
            - firstMinters: mapping(uint256 => address)  [set on first adminMint call]
            - balances: mapping(address => mapping(uint256 => uint256))
            - permissions: mapping(uint256 => mapping(address => uint256))
            - creatorRewardRecipient: address (set in constructor or setupNewToken)
          NOTE: callSale() must use low-level call() forwarding to the minter contract,
                because the test checks that minter errors bubble up as CallFailed(bytes).
                Specifically: target.callSale(...) wraps minter errors as CallFailed(minterError)
```

---

## Changes to Existing Files in tortoise-contract-v1

### `foundry.toml`

Add under the `[profile.default]` section:
```toml
# ERC20Minter migration uses the same solc version as the source
# All in_process files have ^0.8.17 pragma which is compatible with 0.8.34
```

No solc version change needed — 0.8.34 already satisfies `^0.8.17`.

### `remappings.txt`

No changes needed. All imports within `src/in_process/` use relative paths.
The existing remappings cover `@openzeppelin/contracts/` via `lib/openzeppelin-contracts/`.

---

## Import Dependency Graph

```
ERC20Minter.sol
├── @openzeppelin/contracts/utils/ReentrancyGuard.sol        [OZ v5, lib/]
├── @openzeppelin/contracts/token/ERC20/IERC20.sol           [OZ v5, lib/]
├── @openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol  [OZ v5, lib/]
├── interfaces/IERC20Minter.sol
│   └── interfaces/IMinterPremintSetup.sol
├── minters/utils/LimitedMintPerAddress.sol
│   └── interfaces/ILimitedMintPerAddress.sol
│       ├── interfaces/shared/IERC165Upgradeable.sol
│       └── interfaces/shared/errors/IZoraCreator1155Errors.sol
│           └── interfaces/shared/errors/IMinterErrors.sol
├── minters/SaleStrategy.sol
│   ├── utils/ownable/../shared/IERC165Upgradeable.sol
│   ├── interfaces/shared/IMinter1155.sol
│   │   ├── interfaces/shared/ICreatorCommands.sol
│   │   └── interfaces/shared/IERC165Upgradeable.sol
│   ├── interfaces/IContractMetadata.sol
│   └── interfaces/shared/IVersionedContract.sol
├── interfaces/ICreatorCommands.sol
│   └── (re-export of interfaces/shared/ICreatorCommands.sol)
├── minters/erc20/ERC20MinterRewards.sol
├── minters/erc20/IZora1155.sol
├── utils/TransferHelperUtils.sol
├── utils/ownable/Initializable.sol                          [vendored Zora fork]
└── utils/ownable/Ownable2StepUpgradeable.sol
    ├── utils/ownable/IOwnable2StepUpgradeable.sol
    ├── utils/ownable/IOwnable2StepStorageV1.sol
    └── utils/ownable/Initializable.sol
```

---

## Execution Steps

Execute in this exact order:

### ✅ Step 1 — Vendor the shared-contracts interfaces
Copy from `in-process-protocol/packages/shared-contracts/src/interfaces/`:
- `IERC165Upgradeable.sol` → `src/in_process/interfaces/shared/`
- `ICreatorCommands.sol` → `src/in_process/interfaces/shared/`
- `IVersionedContract.sol` → `src/in_process/interfaces/shared/`
- `errors/IMinterErrors.sol` → `src/in_process/interfaces/shared/errors/`
- `errors/IZoraCreator1155Errors.sol` → `src/in_process/interfaces/shared/errors/`
- `IMinter1155.sol` → `src/in_process/interfaces/shared/` (fix import paths)

### ✅ Step 2 — Vendor the protocol-rewards interface
Copy from `in-process-protocol/packages/protocol-rewards/src/interfaces/`:
- `IProtocolRewards.sol` → `src/in_process/utils/`

### ✅ Step 3 — Write the Zora Initializable vendor file
Create `src/in_process/utils/ownable/Initializable.sol` from scratch.
Must define `error INITIALIZABLE_CONTRACT_ALREADY_INITIALIZED()`.
Modifiers needed: `initializer`, `onlyInitializing`.

### ✅ Step 4 — Copy and fix ownable utilities
Copy from `in-process-protocol/packages/1155-contracts/src/utils/ownable/`:
- `IOwnable2StepUpgradeable.sol` — fix pragma
- `IOwnable2StepStorageV1.sol` — fix pragma
- `Ownable2StepUpgradeable.sol` — fix pragma + fix Initializable import path

### ✅ Step 5 — Copy and fix minter utility files
- `TransferHelperUtils.sol` — fix pragma
- `LimitedMintPerAddress.sol` — fix pragma + fix import path
- `SaleStrategy.sol` — fix pragma + fix all import paths

### ✅ Step 6 — Copy and fix interfaces
- `IContractMetadata.sol` — no changes
- `IMinterPremintSetup.sol` — no changes
- `ILimitedMintPerAddress.sol` — fix @zoralabs import paths to local
- `ICreatorCommands.sol` (local re-export) — update to point to shared/
- `IMinter1155.sol` (local re-export) — update to point to shared/
- `IERC20Minter.sol` — no changes

### ✅ Step 7 — Copy and fix core ERC20Minter files
- `ERC20MinterRewards.sol` — no changes
- `IZora1155.sol` — no changes
- `ERC20Minter.sol` — fix OZ ReentrancyGuard import path + fix all relative imports

### ✅ Step 8 — Write MockInProcess1155 and MockERC20
Create `test/in_process/mocks/MockInProcess1155.sol` and `MockERC20.sol`.
MockInProcess1155 implements IInProcess1155 (our renamed interface).

### Step 9 — Write the migrated test file
Create `test/in_process/ERC20Minter.t.sol` with all original test functions intact,
using MockInProcess1155 and MockERC20 instead of the real Zora infrastructure,
and applying all Zora → InProcess renames from the renaming table above.

### Step 10 — Compile and test
```bash
cd /home/misuka/Documents/GitHub/InProcess/tortoise-contract-v1
forge build --contracts src/in_process
forge test --match-path "test/in_process/*" -vvv
```

Fix any compilation errors that arise (most likely import path issues).

---

## What Is NOT Migrated

- `ZoraCreator1155Impl` and `Zora1155` — full 1155 NFT infrastructure, out of scope
- `ZoraCreator1155PremintExecutorImplLib` — uses ERC20Minter but is not ERC20Minter itself
- `ZoraCreator1155Attribution.sol` — same reason
- `PremintERC20.t.sol` — depends on the full premint executor infrastructure, out of scope
- `DeployERC20Minter.s.sol` — deployment script depends on chain config infra
- `ZoraDeployerUtils.sol` — deployment utility, out of scope
- `ERC20MinterMappings.ts` — subgraph TypeScript, unrelated to Solidity migration

---

## Verification Checklist

After completing all steps:

- [ ] `forge build --contracts src/in_process` exits with 0 errors
- [ ] `forge test --match-path "test/in_process/*"` all tests pass
- [ ] `forge test --match-path "test/in_process/*" --match-test test_ERC20MinterAlreadyInitalized` passes (verifies custom Initializable error)
- [ ] `forge test --match-path "test/in_process/*" --match-test test_ERC20MinterSaleFlow` passes (verifies full mint flow through MockZora1155)
- [ ] `forge build` (entire project) still compiles without errors (no regressions to TortoiseV1/TortoiseShell)
- [ ] `forge test` (entire project) original Tortoise tests still pass
