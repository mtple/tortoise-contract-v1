// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SetupActions} from "../../script/SetupActions.sol";
import {ICreator1155Factory} from "../../src/interfaces/ICreator1155Factory.sol";

/// @dev External boundary so vm.expectRevert intercepts the library's internal reverts.
contract SetupActionsHarness {
    function setupNewToken(string memory uri, uint256 max) external pure returns (bytes memory) {
        return SetupActions.encodeSetupNewToken(uri, max);
    }

    function addMinter(uint256 tokenId, address minter) external pure returns (bytes memory) {
        return SetupActions.encodeAddMinterPermission(tokenId, minter);
    }

    function updateRoyalties(uint256 tokenId, uint32 bps, address recipient)
        external
        pure
        returns (bytes memory)
    {
        return SetupActions.encodeUpdateRoyalties(tokenId, bps, recipient);
    }
}

contract SetupActionsTest is Test {
    SetupActionsHarness internal harness;
    address internal minter = makeAddr("minter");
    address internal royalty = makeAddr("royalty");

    function setUp() public {
        harness = new SetupActionsHarness();
    }

    function test_constants() public pure {
        assertEq(SetupActions.PERMISSION_BIT_MINTER, 4, "MINTER bit");
        assertEq(SetupActions.PERMISSION_BIT_ADMIN, 2, "ADMIN bit");
        assertEq(SetupActions.OPEN_EDITION_MAX_SUPPLY, type(uint64).max, "open-edition sentinel");
    }

    function test_newTokenWithMinter() public view {
        bytes[] memory a = SetupActions.newTokenWithMinter("ar://track", 100, 1, minter);
        assertEq(a.length, 2, "two actions");
        assertEq(
            a[0],
            abi.encodeWithSignature("setupNewToken(string,uint256)", "ar://track", uint256(100)),
            "setupNewToken"
        );
        assertEq(
            a[1],
            abi.encodeWithSignature(
                "addPermission(uint256,address,uint256)", uint256(1), minter, uint256(4)
            ),
            "addPermission(MINTER) on expected id"
        );
    }

    function test_newTokenWithMinter_openEdition() public view {
        bytes[] memory a = SetupActions.newTokenWithMinter(
            "ar://t", SetupActions.OPEN_EDITION_MAX_SUPPLY, 3, minter
        );
        assertEq(
            a[0],
            abi.encodeWithSignature(
                "setupNewToken(string,uint256)", "ar://t", uint256(type(uint64).max)
            ),
            "open-edition max supply"
        );
    }

    function test_newTokenWithRoyaltyAndMinter() public view {
        bytes[] memory a =
            SetupActions.newTokenWithRoyaltyAndMinter("ar://t", 50, 2, minter, 250, royalty);
        assertEq(a.length, 3, "three actions");

        ICreator1155Factory.RoyaltyConfiguration memory r = ICreator1155Factory.RoyaltyConfiguration({
            royaltyMintSchedule: 0, royaltyBPS: 250, royaltyRecipient: royalty
        });
        assertEq(
            a[0], abi.encodeWithSignature("setupNewToken(string,uint256)", "ar://t", uint256(50))
        );
        assertEq(
            a[1],
            abi.encodeWithSignature(
                "updateRoyaltiesForToken(uint256,(uint32,uint32,address))", uint256(2), r
            ),
            "royalty override on the token"
        );
        assertEq(
            a[2],
            abi.encodeWithSignature(
                "addPermission(uint256,address,uint256)", uint256(2), minter, uint256(4)
            )
        );
    }

    function test_addTrackWithMinter_guardsStaleStateFirst() public view {
        // last known id 7 -> new token is id 8, guarded by assumeLastTokenIdMatches(7).
        bytes[] memory a = SetupActions.addTrackWithMinter(7, "ar://t8", 100, minter);
        assertEq(a.length, 3, "three actions");
        assertEq(
            a[0],
            abi.encodeWithSignature("assumeLastTokenIdMatches(uint256)", uint256(7)),
            "stale-state guard must be first"
        );
        assertEq(
            a[1], abi.encodeWithSignature("setupNewToken(string,uint256)", "ar://t8", uint256(100))
        );
        assertEq(
            a[2],
            abi.encodeWithSignature(
                "addPermission(uint256,address,uint256)", uint256(8), minter, uint256(4)
            ),
            "permission targets lastKnown + 1"
        );
    }

    // ---- input validation ----

    function test_revert_zeroMaxSupply() public {
        vm.expectRevert(SetupActions.ZeroMaxSupply.selector);
        harness.setupNewToken("ar://t", 0);
    }

    function test_revert_zeroMinter() public {
        vm.expectRevert(SetupActions.ZeroMinter.selector);
        harness.addMinter(1, address(0));
    }

    function test_revert_zeroRoyaltyRecipient() public {
        vm.expectRevert(SetupActions.ZeroRoyaltyRecipient.selector);
        harness.updateRoyalties(1, 250, address(0));
    }

    function test_revert_royaltyTooHigh() public {
        vm.expectRevert(
            abi.encodeWithSelector(SetupActions.RoyaltyTooHigh.selector, uint32(10_001))
        );
        harness.updateRoyalties(1, 10_001, royalty);
    }
}
