// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {TortoiseInProcessMinter} from "../../src/TortoiseInProcessMinter.sol";
import {SplitRecipient} from "../../src/libraries/SplitLib.sol";

/// @notice External EIP-712 signature-vector cross-check (plan §S.3).
///
/// The signatures in test/fixtures/eip712-vectors.json were produced OFF-CHAIN by an
/// independent EIP-712 implementation (Foundry `cast wallet sign --data`) — the same role
/// the backend signer plays. Asserting them against the live contract verifier catches any
/// mismatch in the domain separator or the typehash strings (the highest-risk off-chain ↔
/// on-chain divergence). The on-chain digest depends on the verifyingContract address and
/// chainId, so both are pinned: the minter is deployed via CREATE from a fixed deployer at
/// nonce 0 (CREATE address depends only on deployer + nonce, not bytecode, so the vectors
/// survive contract changes) and the default chainId 31337 is used.
///
/// Regenerate the fixture (domain/message fields are documented in the JSON):
///   cast wallet sign --private-key <signerPrivateKey> --data --from-file <typed-data>.json
contract MinterEIP712VectorsTest is Test {
    using stdStorage for StdStorage;

    TortoiseInProcessMinter internal minter;
    string internal fixture;

    // Pinned domain — must match test/fixtures/eip712-vectors.json.
    address internal constant OWNER = address(0xD004); // CREATE deployer, nonce 0
    address internal constant EXPECTED_MINTER = 0x5330831D6A3ae8950acd57eA509eDBD1428fBcc6;
    address internal constant ARTIST = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant COLLECTION = address(0xCAFE);
    address internal constant PAYOUT_TO = address(0xD00D);
    address internal constant PLATFORM = address(0xBEEF);
    uint256 internal constant DEADLINE = 4102444800;

    function setUp() public {
        vm.setNonce(OWNER, 0);
        vm.prank(OWNER);
        minter = new TortoiseInProcessMinter(address(0), PLATFORM, 500, 0);
        // If this fails, the pinned verifyingContract drifted and the vectors are stale.
        assertEq(address(minter), EXPECTED_MINTER, "minter address must match pinned domain");

        fixture = vm.readFile("test/fixtures/eip712-vectors.json");
    }

    function test_vector_setSaleWithArtistSignature() public {
        vm.prank(OWNER);
        minter.registerSong(COLLECTION, 7, ARTIST);

        bytes memory sig = vm.parseJsonBytes(fixture, ".setSale.signature");
        TortoiseInProcessMinter.SaleUpdate memory cfg = TortoiseInProcessMinter.SaleUpdate({
            saleStart: 0, saleEnd: type(uint64).max, maxTokensPerAddress: 0, pricePerToken: 1 ether
        });

        // Relayed by an arbitrary caller; only the artist's external signature authorizes it.
        minter.setSaleWithArtistSignature(COLLECTION, 7, cfg, 0, DEADLINE, sig);

        TortoiseInProcessMinter.SaleConfig memory s = minter.sale(COLLECTION, 7);
        assertTrue(s.exists, "sale applied from external signature");
        assertEq(s.pricePerToken, 1 ether, "price");
        assertEq(minter.saleUpdateNonces(minter.songKey(COLLECTION, 7)), 1, "nonce advanced");
    }

    function test_vector_registerSongWithSplits() public {
        bytes memory sig = vm.parseJsonBytes(fixture, ".registerSongWithSplits.signature");
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient({recipient: ARTIST, percentage: 10_000});

        vm.prank(OWNER);
        minter.registerSongWithSplits(COLLECTION, 8, ARTIST, splits, true, 0, DEADLINE, sig);

        bytes32 key = minter.songKey(COLLECTION, 8);
        assertEq(minter.songArtist(key), ARTIST, "registered from external signature");
        assertTrue(minter.splitsLocked(key), "splits locked");
        assertEq(minter.splitAuthorizationNonces(ARTIST), 1, "split nonce advanced");
    }

    function test_vector_claimPendingTo() public {
        bytes32 key = minter.songKey(COLLECTION, 9);
        uint256 amount = 0.5 ether;

        // Seed a pending claim for the artist directly (the collect→defer flow can't produce
        // one for an EOA recipient, which always accepts ETH). Back it with real ETH.
        stdstore.target(address(minter)).sig("pendingClaims(bytes32,address)").with_key(key)
            .with_key(ARTIST).checked_write(amount);
        stdstore.target(address(minter)).sig("totalPendingClaims()").checked_write(amount);
        vm.deal(address(minter), amount);

        bytes memory sig = vm.parseJsonBytes(fixture, ".claimPendingTo.signature");
        // Relayer (msg.sender != recipient) submits the artist's externally signed claim.
        minter.claimPendingTo(COLLECTION, 9, ARTIST, PAYOUT_TO, amount, 0, DEADLINE, sig);

        assertEq(PAYOUT_TO.balance, amount, "paid out from external signature");
        assertEq(minter.pendingClaims(key, ARTIST), 0, "claim cleared");
        assertEq(minter.totalPendingClaims(), 0, "accounting cleared");
    }
}
