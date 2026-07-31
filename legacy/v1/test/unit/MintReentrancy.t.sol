// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {TortoiseV1} from "../../src/TortoiseV1.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {SplitRecipient} from "../../src/libraries/SplitLib.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockTORT} from "../mocks/MockTORT.sol";

/// @dev Malicious artist contract that receives the ERC1155 mint and attempts
/// to rewrite splits mid-mint. Used to prove H-03 (mint-callback reentrancy)
/// is blocked by the nonReentrant guard on configureSplits.
contract MaliciousArtist is IERC1155Receiver {
    TortoiseV1 public tortoise;
    uint256 public songId;
    SplitRecipient[] public maliciousSplits;
    bool public attackAttempted;
    bool public attackReverted;

    constructor(TortoiseV1 _tortoise) {
        tortoise = _tortoise;
    }

    function setTarget(uint256 _songId, SplitRecipient[] calldata _splits) external {
        songId = _songId;
        delete maliciousSplits;
        for (uint256 i = 0; i < _splits.length; i++) {
            maliciousSplits.push(_splits[i]);
        }
    }

    function createSong(string calldata title, string calldata uri) external returns (uint256) {
        return tortoise.createSong(title, 0, 0, uri);
    }

    function configureOriginalSplits(uint256 _songId, SplitRecipient[] calldata splits) external {
        tortoise.configureSplits(_songId, splits);
    }

    function onERC1155Received(
        address, /*operator*/
        address, /*from*/
        uint256, /*id*/
        uint256, /*value*/
        bytes calldata /*data*/
    ) external returns (bytes4) {
        attackAttempted = true;
        // Attempt to rewrite splits during mint — must revert under nonReentrant.
        try tortoise.configureSplits(songId, maliciousSplits) {
            attackReverted = false;
        } catch {
            attackReverted = true;
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

contract MintReentrancyTest is Test {
    TortoiseV1 public tortoise;
    TortoiseShell public shell;
    MockUSDC public usdc;
    MockTORT public tort;
    MaliciousArtist public attacker;

    address public owner = address(this);
    address public honestCharity = makeAddr("honestCharity");
    address public buyer = makeAddr("buyer");

    uint64 constant PLATFORM_FEE = 50_000;
    uint64 constant STAKING_FEE = 100_000;
    uint128 constant DEFAULT_PRICE = 850_000;
    uint256 constant TORT_PER_COLLECTION = 10e18;

    function setUp() public {
        usdc = new MockUSDC();
        tort = new MockTORT();
        shell = new TortoiseShell(address(tort), address(usdc), 604_800);
        tortoise = new TortoiseV1(
            address(usdc), PLATFORM_FEE, DEFAULT_PRICE, address(shell), STAKING_FEE
        );
        shell.addAuthorizedCaller(address(tortoise));
        shell.setTortRewardPerCollection(TORT_PER_COLLECTION);
        tort.mint(owner, 100_000e18);
        tort.approve(address(shell), type(uint256).max);
        shell.fundTortPool(50_000e18);

        usdc.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdc.approve(address(tortoise), type(uint256).max);

        attacker = new MaliciousArtist(tortoise);
    }

    /// @notice H-03: Malicious artist tries to swap splits inside onERC1155Received.
    /// Two defenses must hold:
    ///   1. nonReentrant on configureSplits blocks the nested call.
    ///   2. CEI ordering in _processMint — _mint runs after _distributePayments,
    ///      so even if configureSplits were somehow reachable, payments would
    ///      already be settled against the original splits.
    function test_maliciousArtistCannotSwapSplitsMidMint() public {
        // Artist (malicious contract) creates a song and configures honest splits.
        uint256 songId = attacker.createSong("MySong", "ipfs://song");

        SplitRecipient[] memory honest = new SplitRecipient[](2);
        honest[0] = SplitRecipient(address(attacker), 5000); // 50% artist
        honest[1] = SplitRecipient(honestCharity, 5000); // 50% charity
        attacker.configureOriginalSplits(songId, honest);

        // Arm the attack: malicious splits would redirect 100% to attacker.
        SplitRecipient[] memory malicious = new SplitRecipient[](1);
        malicious[0] = SplitRecipient(address(attacker), 10000);
        attacker.setTarget(songId, malicious);

        uint256 charityBalBefore = usdc.balanceOf(honestCharity);
        uint256 attackerBalBefore = usdc.balanceOf(address(attacker));

        // Buyer mints; recipient is the attacker contract so its ERC1155 receiver fires.
        vm.prank(buyer);
        tortoise.mintSong(songId, 1, address(attacker));

        // The attack was attempted and was rejected by the reentrancy guard.
        assertTrue(attacker.attackAttempted(), "attack should have fired");
        assertTrue(attacker.attackReverted(), "configureSplits must revert under reentrancy guard");

        // Original splits were honored — charity got paid.
        uint256 charityBalAfter = usdc.balanceOf(honestCharity);
        uint256 attackerBalAfter = usdc.balanceOf(address(attacker));
        uint256 artistRevenue = DEFAULT_PRICE; // totalCost - fees = price*quantity
        assertEq(charityBalAfter - charityBalBefore, artistRevenue / 2, "charity 50%");
        assertEq(attackerBalAfter - attackerBalBefore, artistRevenue - artistRevenue / 2, "attacker 50%");

        // Splits in storage are still the honest ones (malicious rewrite never landed).
        SplitRecipient[] memory stored = tortoise.getSongSplits(songId);
        assertEq(stored.length, 2, "splits length preserved");
        assertEq(stored[1].recipient, honestCharity, "charity still in splits");
    }

    /// @notice Defense in depth: CEI ordering means state+USDC are settled before
    /// the receiver callback fires. Even without the reentrancy guard, the callback
    /// can no longer influence its own payment.
    function test_processMint_cei_mintIsLast() public {
        // Create a song and mint to the attacker.
        uint256 songId = attacker.createSong("Song", "ipfs://s");
        SplitRecipient[] memory splits = new SplitRecipient[](1);
        splits[0] = SplitRecipient(address(attacker), 10000);
        attacker.configureOriginalSplits(songId, splits);

        // Arm attack with different splits.
        SplitRecipient[] memory alt = new SplitRecipient[](1);
        alt[0] = SplitRecipient(honestCharity, 10000);
        attacker.setTarget(songId, alt);

        uint256 attackerBefore = usdc.balanceOf(address(attacker));

        vm.prank(buyer);
        tortoise.mintSong(songId, 1, address(attacker));

        // Attacker received the artist revenue because payment settled before _mint.
        uint256 artistRevenue = DEFAULT_PRICE; // totalCost - fees = price*quantity
        assertEq(
            usdc.balanceOf(address(attacker)) - attackerBefore,
            artistRevenue,
            "payment settled against original splits before callback"
        );
    }
}
