// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseInProcessMinter} from "../../src/TortoiseInProcessMinter.sol";
import {SplitRecipient} from "../../src/libraries/SplitLib.sol";
import {MockInProcess1155} from "../mocks/MockInProcess1155.sol";
import {MockTortoiseShellETH} from "../mocks/MockTortoiseShellETH.sol";

/// @notice On-chain EIP-712 verification tests using vm.sign against a reconstructed OZ
///         domain separator. (External cross-check vectors per plan S.3 are generated with
///         viem/cast off-chain and are a separate follow-up.)
contract MinterEIP712Test is Test {
    TortoiseInProcessMinter internal minter;
    MockInProcess1155 internal nft;
    MockTortoiseShellETH internal shell;

    uint256 internal artistPk = 0xA11CE;
    address internal artist;
    uint256 internal strangerPk = 0xBADA55;

    address internal platform = makeAddr("platform");
    uint256 internal constant TOKEN_ID = 1;

    bytes32 internal constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 internal constant SET_SALE_TYPEHASH = keccak256(
        "SetSale(address collection,uint256 tokenId,bytes32 saleHash,uint256 nonce,uint256 deadline)"
    );
    bytes32 internal constant REGISTER_TYPEHASH = keccak256(
        "RegisterSongWithSplits(address collection,uint256 tokenId,address artist,bytes32 splitsHash,bool lockSplits,uint256 nonce,uint256 deadline)"
    );

    function setUp() public {
        artist = vm.addr(artistPk);
        shell = new MockTortoiseShellETH();
        minter = new TortoiseInProcessMinter(address(shell), platform, 500, 1_000);
        nft = new MockInProcess1155();
        minter.registerSong(address(nft), TOKEN_ID, artist);
    }

    // ============ helpers ============

    function _domainSep() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("TortoiseInProcessMinter")),
                keccak256(bytes("1")),
                block.chainid,
                address(minter)
            )
        );
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSep(), structHash));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _saleUpdate(uint256 price)
        internal
        pure
        returns (TortoiseInProcessMinter.SaleUpdate memory)
    {
        return TortoiseInProcessMinter.SaleUpdate({
            saleStart: 0, saleEnd: type(uint64).max, maxTokensPerAddress: 0, pricePerToken: price
        });
    }

    function _signSetSale(
        uint256 pk,
        TortoiseInProcessMinter.SaleUpdate memory cfg,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 saleHash = keccak256(
            abi.encode(cfg.saleStart, cfg.saleEnd, cfg.maxTokensPerAddress, cfg.pricePerToken)
        );
        bytes32 structHash = keccak256(
            abi.encode(SET_SALE_TYPEHASH, address(nft), TOKEN_ID, saleHash, nonce, deadline)
        );
        return _sign(pk, _digest(structHash));
    }

    // ============ SetSale ============

    function test_setSaleWithSig_valid() public {
        TortoiseInProcessMinter.SaleUpdate memory cfg = _saleUpdate(1 ether);
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _signSetSale(artistPk, cfg, 0, dl);

        minter.setSaleWithArtistSignature(address(nft), TOKEN_ID, cfg, 0, dl, sig);

        bytes32 k = minter.songKey(address(nft), TOKEN_ID);
        assertEq(minter.sale(address(nft), TOKEN_ID).pricePerToken, 1 ether);
        assertEq(minter.saleUpdateNonces(k), 1, "nonce advanced");
    }

    function test_setSaleWithSig_wrongSigner() public {
        TortoiseInProcessMinter.SaleUpdate memory cfg = _saleUpdate(1 ether);
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _signSetSale(strangerPk, cfg, 0, dl);
        vm.expectRevert(TortoiseInProcessMinter.InvalidSaleSignature.selector);
        minter.setSaleWithArtistSignature(address(nft), TOKEN_ID, cfg, 0, dl, sig);
    }

    function test_setSaleWithSig_expired() public {
        vm.warp(1000);
        TortoiseInProcessMinter.SaleUpdate memory cfg = _saleUpdate(1 ether);
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _signSetSale(artistPk, cfg, 0, deadline);
        vm.expectRevert(TortoiseInProcessMinter.SignatureExpired.selector);
        minter.setSaleWithArtistSignature(address(nft), TOKEN_ID, cfg, 0, deadline, sig);
    }

    function test_setSaleWithSig_wrongNonce() public {
        TortoiseInProcessMinter.SaleUpdate memory cfg = _saleUpdate(1 ether);
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _signSetSale(artistPk, cfg, 5, dl);
        vm.expectRevert(
            abi.encodeWithSelector(TortoiseInProcessMinter.NonceMismatch.selector, 0, 5)
        );
        minter.setSaleWithArtistSignature(address(nft), TOKEN_ID, cfg, 5, dl, sig);
    }

    function test_setSaleWithSig_replayReverts() public {
        TortoiseInProcessMinter.SaleUpdate memory cfg = _saleUpdate(1 ether);
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _signSetSale(artistPk, cfg, 0, dl);
        minter.setSaleWithArtistSignature(address(nft), TOKEN_ID, cfg, 0, dl, sig);
        // nonce is now 1; replaying the nonce-0 signature fails.
        vm.expectRevert(
            abi.encodeWithSelector(TortoiseInProcessMinter.NonceMismatch.selector, 1, 0)
        );
        minter.setSaleWithArtistSignature(address(nft), TOKEN_ID, cfg, 0, dl, sig);
    }

    function test_ownerSetSale_invalidatesInFlightArtistSig() public {
        TortoiseInProcessMinter.SaleUpdate memory cfg = _saleUpdate(1 ether);
        uint256 dl = block.timestamp + 1 hours;
        bytes memory sig = _signSetSale(artistPk, cfg, 0, dl);

        // Owner sets the sale first, bumping the nonce to 1.
        minter.setSale(address(nft), TOKEN_ID, _saleUpdate(2 ether));

        vm.expectRevert(
            abi.encodeWithSelector(TortoiseInProcessMinter.NonceMismatch.selector, 1, 0)
        );
        minter.setSaleWithArtistSignature(address(nft), TOKEN_ID, cfg, 0, dl, sig);
    }

    // ============ RegisterSongWithSplits ============

    function test_registerWithSplits_valid() public {
        uint256 newToken = 7;
        SplitRecipient[] memory splits = new SplitRecipient[](2);
        splits[0] = SplitRecipient({recipient: makeAddr("r1"), percentage: 6000});
        splits[1] = SplitRecipient({recipient: makeAddr("r2"), percentage: 4000});

        uint256 dl = block.timestamp + 1 hours;
        bytes32 splitsHash = keccak256(abi.encode(splits));
        bytes32 structHash = keccak256(
            abi.encode(REGISTER_TYPEHASH, address(nft), newToken, artist, splitsHash, true, 0, dl)
        );
        bytes memory sig = _sign(artistPk, _digest(structHash));

        minter.registerSongWithSplits(address(nft), newToken, artist, splits, true, 0, dl, sig);

        assertEq(minter.songArtist(minter.songKey(address(nft), newToken)), artist);
        assertEq(minter.getSongSplits(address(nft), newToken).length, 2);
        assertTrue(minter.splitsLocked(minter.songKey(address(nft), newToken)));
        assertEq(minter.splitAuthorizationNonces(artist), 1, "per-artist nonce advanced");
    }

    function test_registerWithSplits_wrongSigner() public {
        uint256 newToken = 8;
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient({recipient: makeAddr("r1"), percentage: 10000});

        uint256 dl = block.timestamp + 1 hours;
        bytes32 splitsHash = keccak256(abi.encode(splits));
        bytes32 structHash = keccak256(
            abi.encode(REGISTER_TYPEHASH, address(nft), newToken, artist, splitsHash, false, 0, dl)
        );
        bytes memory sig = _sign(strangerPk, _digest(structHash));

        vm.expectRevert(TortoiseInProcessMinter.InvalidSplitSignature.selector);
        minter.registerSongWithSplits(address(nft), newToken, artist, splits, false, 0, dl, sig);
    }
}
