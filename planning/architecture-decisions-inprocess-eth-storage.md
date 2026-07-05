# Architecture Decisions — In Process, ETH, and Verifiable Storage

**Status:** decided (strategy session, 2026-07-05). This is a decision record, not
an implementation. It sits alongside and does not supersede:

- `planning/eth-minter-implementation-plan.md` — the full D.1–D.12 spec + phases.
- `planning/setup-actions-reference.md` — fork-verified In Process / Zora factory facts.
- `planning/tortoise-v1-state-review.md` — how the repo got here (v1 + the two v2 tracks).

It records four decisions and one contract delta that refine the plan above, and lists
the external confirmations that gate the build.

---

## Context

The ETH minter work (this branch, PR #9) is the live v2 line: In Process's Zora-derived
ERC-1155 as the token, a custom Tortoise minter in front paying native ETH, with splits,
ETH-native shell crediting, pending claims, and EIP-712 flows — held to v1's fuzz/
invariant/fork test bar.

Two things prompted this record:

1. A **storage/verifiability rethink** (the "Provably the Real Thing" thesis): drop IPFS
   and permanence-as-a-promise; serve audio cheaply from R2/Opus, keep the master in cold
   backup, and make the one load-bearing guarantee a **content hash anchored on Base** that
   lets anyone prove a collection is the real release without trusting Tortoise.
2. Clarifying that **In Process is a strategic partnership** (they pay for the integration,
   have more resources, and an ecosystem is forming) — so the value of using their contracts
   is relationship + alignment + optionality, not only technical distribution.

Together these settle the open architecture questions below.

---

## Decision 1 — Build on In Process (their Zora-1155), keep our own minter

**Decided:** use In Process's Zora-derived 1155 + factory as the token layer, with the
custom `TortoiseInProcessMinter` in front. The operator creates tokens via the factory's
`setupActions`; the minter holds `PERMISSION_BIT_MINTER` and calls `adminMint`. This is the
"maximal integration **without** ceding the payment path" stance already in the plan, and it
is what PR #9 builds.

**Why (updated by the partnership framing):** the earlier lean toward a fully-custom token
contract was driven by the verifiability thesis wanting a single Tortoise-controlled
contract. That concern is real but **cheap to satisfy without going custom** (see Decision 4),
and it is outweighed by a funded, aligned partner plus ecosystem optionality.

**Why it is a low-regret bet:** because ownership lives in the collector's wallet and
provenance lives in a Tortoise-controlled on-chain registry + the master we hold, **none of
the durable value depends on In Process.** If the relationship changes, the token layer can
migrate to a custom Tortoise 1155 later without breaking any existing collector's proof. The
storage architecture de-risks the partnership.

**The one line we hold:** the verifiability commitment (the manifest hash) stays
**Tortoise-controlled and on-chain**, and `collect()` is gated on it. Integration pressure
will try to push the commitment into their contract's opaque storage or into the mutable R2
`tokenURI` JSON — both break the thesis. Neither is allowed.

---

## Decision 2 — Native ETH + percentage fees

**Decided:** payments, artist payouts, staking rewards, and pending claims in **native ETH**;
fee model **5% / 10% / 85%** (platform / staking / artist) in BPS. This is PR #9 as built.

**Why:**
- **On-thesis.** The storage doc's whole argument is "drop dependencies you must trust to
  stay alive." USDC is exactly such a dependency (a centralized issuer that can freeze/
  blocklist). ETH is the trust-minimized native asset of the chain ownership already lives on.
- **UX + no oracle.** ETH is one transaction (`msg.value`), no approve/permit. Percentage
  fees are denomination-agnostic and need no price feed (a feed would re-add a trusted
  dependency).
- **USDC's one advantage is recoverable.** Stable "$3" pricing matters less for a free-to-
  listen support/association product, and the app can display a live USD equivalent while
  charging ETH (PR #9 already re-quotes against the live sale with a `maxTotalCost` guard).

**Contingency:** this holds if "implement In Process's contracts" means **their 1155 + our
minter**. If the partnership specifically requires **their ERC20Minter** in the flow, that
pulls toward USDC and cedes the economics/manifest-gate — see Open Item 1.

---

## Decision 3 — Storage: R2 + Opus, master in cold backup, no permanence promise

**Decided:** adopt the "Provably the Real Thing" storage architecture.

- **Serving:** audio from Cloudflare R2 (zero egress), re-encoded to Opus (~192 kbps). The
  served file is deliberately disposable — bitrate is a dial, not a commitment.
- **Preservation:** the original lossless master kept in cold storage on a **separate
  provider** from R2 (independent failure domain). Hygiene, not an on-chain promise.
- **`tokenURI`:** the In Process/Zora token `uri` is set to an **R2 HTTPS URL, not Arweave.**
  The `uri` is an untyped, mutable string; nothing in the contract forces Arweave. This slots
  our serving layer exactly where their Arweave default would go, with zero contract changes.
- **Explicitly dropped:** IPFS, and the promise "your music lives forever." Permanence
  returns later only as an **opt-in, artist-paid** feature (e.g. push a master to Arweave),
  made safe by the on-chain hash.

**Rule:** never put a mutable URL inside the thing you commit to. The manifest commits to the
master's `audioSha256`, **never** to the R2 URL. Display metadata (R2, mutable) and the
commitment (on-chain, immutable) stay cleanly separated and never reference each other.

---

## Decision 4 — Verifiability: a manifest hash in the Tortoise minter (the load-bearing piece)

**Decided:** the one property that must work without trusting Tortoise — *a collector can
prove they hold the real release* — is delivered by committing a **manifest hash on Base, in
the Tortoise minter.**

- The manifest is a small canonical JSON (`{artSha256, artist, audioSha256, date, title}`,
  sorted keys, fixed whitespace). `sha256(manifest)` is the commitment.
- **It must live in a Tortoise contract.** The In Process/Zora 1155 has **no on-chain slot
  for a content hash** — `setupNewToken` takes only `(uri, maxSupply)`, and no checksum is
  stored. So the commitment is hosted in the minter's storage + event. This is forced by
  their contract shape, not a preference.

**Verification is a two-anchor read** (both known constants a verifier brings; a Base archive
node suffices; Tortoise/R2 are in none of the links):

1. signature over a nonce → controls wallet `W`
2. `IInProcess1155.balanceOf(W, id) >= 1` → `W` holds the token *(In Process 1155)*
3. `minter.releaseManifest(songKey(coll, id))` → token commits to manifest `M` *(Tortoise minter)*
4. `sha256(local master bytes) == manifest.audioSha256` → the audio is the real thing

**Scope of the claim (unchanged from the thesis):** proves ownership of the collectible and
that it is the canonical release — not copyright, not authorship, not that the file is
eternal. The one trusted constant is the contract address.

---

## Contract delta — the manifest registry graft on `TortoiseInProcessMinter`

Small, hot-path-free addition. Folds the manifest into **registration**; because
`_validateAndQuote` already reverts `SongNotRegistered` when `songArtist[key] == 0`, and
artist + manifest are set atomically, **"collectible ⟹ verified manifest" holds for free** —
`collect()` needs no new logic.

### Locked sub-decisions
1. **Registration is write-once** (`AlreadyRegistered`). This makes the commitment immutable;
   note it also removes today's ability to re-`_register` and overwrite `songArtist`.
   Artist-correction, if ever needed, must be a separate manifest-preserving path.
2. **On-chain `sha256` at registration.** The contract derives `manifestHash =
   sha256(bytes(manifest))` (precompile `0x02`, ~150 gas, once per song — not per collect),
   so the stored commitment and the emitted preimage are provably the same object. The
   operator cannot bind a hash whose JSON doesn't match.
3. **One `SongCreated` event** carrying the manifest preimage string (replaces the separate
   `SongRegistered` / `SongManifestSet` events). Storage holds `manifestHash` (cheap live
   read from any RPC); the event holds the preimage (permanent in logs, reconstructs the
   release without Tortoise/R2).
4. **No audio getter.** Audio is verified through the manifest (fetch the preimage → confirm
   `sha256` against `releaseManifest` → read `audioSha256` from the JSON). The getter would be
   an unverified operator mirror with zero added security; it is purely additive and can be
   added later if an app surface ever wants a one-call live check. Not paid for on spec.
5. **Artist attests the manifest.** `registerSongWithSplits`'s EIP-712 digest gains a
   `manifestHash` field, so the artist's signature covers the release, not just the splits.

### Sketch (illustrative — see the plan for the full surface)

```solidity
// State — the 32-byte commitment, write-once, readable live from any Base RPC
mapping(bytes32 => bytes32) public releaseManifest;   // songKey => sha256(manifest)

// The single canonical creation event — preimage lives in `manifest`
event SongCreated(
    address indexed collection,
    uint256 indexed tokenId,
    address indexed artist,
    bytes32 manifestHash,
    string  manifest
);

error AlreadyRegistered();
error EmptyManifest();

function _register(
    address collection,
    uint256 tokenId,
    address artist,
    string calldata manifest
) internal returns (bytes32 key, bytes32 manifestHash) {
    if (artist == address(0)) revert ZeroAddress();
    if (bytes(manifest).length == 0) revert EmptyManifest();          // + a MAX_MANIFEST_BYTES cap
    key = _songKey(collection, tokenId);
    if (releaseManifest[key] != bytes32(0)) revert AlreadyRegistered();  // one-shot commitment

    manifestHash         = sha256(bytes(manifest));   // derive, don't trust a passed-in hash
    songArtist[key]      = artist;
    releaseManifest[key] = manifestHash;

    emit SongCreated(collection, tokenId, artist, manifestHash, manifest);
}
```

Both register entrypoints gain a `string manifest` arg. The signed path's typehash becomes:

```
RegisterSongWithSplits(address collection,uint256 tokenId,address artist,
  bytes32 manifestHash,bytes32 splitsHash,bool lockSplits,uint256 nonce,uint256 deadline)
```

`collect()` / `_validateAndQuote` / `_processCollect`: unchanged.

### Off-chain half (to pin down at implementation time)
A canonical-manifest serializer (sorted keys, fixed whitespace, `0x…` lowercase hex for the
byte32 fields) that provably matches the on-chain `sha256(manifest)`, plus the artist EIP-712
signing snippet. This serialization is the most likely thing to drift — publish it once in the
verification script and never let a formatter touch the manifest between hashing and storage.

### Test additions (~6 unit + 1 fork)
Write-once (second register reverts `AlreadyRegistered`); `sha256(manifest) ==
releaseManifest`; tampered manifest breaks the artist signature; `collect` still reverts
pre-registration; event preimage round-trips to the stored hash; existing `SetupActionsFork`
flow with a manifest-carrying register.

---

## Open items — confirm with In Process before building (empirical, not design)

These gate the build; none change the decisions above.

1. **Depth of "implement their contracts"** — their 1155 + our minter (keeps ETH + our
   economics + the manifest gate) vs. their ERC20Minter (pulls to USDC, cedes economics).
   Push for the former. This also settles Decision 2's contingency.
2. **Does their app/indexer ingest arbitrary HTTPS (R2) metadata**, or gate on Arweave / their
   own uploader? If it gates on Arweave, we may mirror metadata to Arweave **for their-app
   visibility only** — R2 stays canonical.
3. **Does their app/indexer surface tokens minted via a custom minter's `adminMint`** (vs their
   own ERC20Minter)? This is the same open question flagged in the state review; it determines
   how much app-level visibility the partnership actually buys. (Tortoise runs its own indexer
   regardless, per Phase 4.)
4. **Base Sepolia In Process factory address** — still fail-closed / unconfirmed in
   `addresses/84532.json`; creation scripts revert until it is pinned by In Process.

---

## What this means for the build

- No rearchitecture. The manifest graft is a ~contained addition to the existing minter —
  two-ish storage/event changes, a write-once guard, `manifest` threaded through the two
  register entrypoints, one line in the EIP-712 digest. Nothing in the money path, the In
  Process integration, or the R2 serving layer changes.
- Storage/serving (R2 + Opus + cold master) is app/ops work beside the contracts.
- A fresh v2 security review still applies — the audit history (v1 audits 6→12) does not cover
  the ETH minter, shell, or this manifest layer.
