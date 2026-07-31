// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Tortoise} from "../../src/Tortoise.sol";
import {TortoiseShell} from "../../src/TortoiseShell.sol";
import {SplitRecipient} from "../../src/libraries/SplitLib.sol";
import {MockTORT} from "../mocks/MockTORT.sol";

interface IBaseUSDC is IERC20 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function unBlacklist(address account) external;
}

contract TortoiseBaseForkTest is Test {
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    IBaseUSDC internal usdc;
    MockTORT internal tort;
    TortoiseShell internal shell;
    Tortoise internal tortoise;

    address internal artist = makeAddr("artist");
    address internal collector;
    uint256 internal collectorPk;

    uint128 internal constant PRICE = 10e6;
    uint256 internal constant TORT_REWARD = 100e18;

    function setUp() public {
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true, "BASE_RPC_URL is not configured");
            return;
        }
        vm.createSelectFork(rpcUrl);

        (collector, collectorPk) = makeAddrAndKey("collector");
        usdc = IBaseUSDC(BASE_USDC);
        tort = new MockTORT();
        shell = new TortoiseShell(address(tort), BASE_USDC, 7 days);
        tortoise = new Tortoise(BASE_USDC, address(shell));
        shell.addAuthorizedCaller(address(tortoise));

        tort.mint(address(this), 10_000e18);
        tort.approve(address(shell), type(uint256).max);
        shell.fundTortPool(10_000e18);
        shell.setTortRewardPerCollection(TORT_REWARD);
    }

    function _params() internal view returns (Tortoise.CreateSongParams memory p) {
        p.artist = artist;
        p.price = PRICE;
        p.maxSupply = 100;
        p.tokenUri = "ipfs://base-fork";
        p.manifest = '{"artSha256":"0xaa","artist":"base-fork","audioSha256":"0xbb","title":"Fork"}';
        p.splits = new SplitRecipient[](0);
    }

    function _signReceive(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(collectorPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function testFork_realUsdcAuthorizationCollectAndShellClaim() public {
        uint256 songId = tortoise.createSong(_params());
        uint256 quantity = 2;
        uint256 total = uint256(PRICE) * quantity;
        deal(BASE_USDC, collector, total, true);

        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 salt = keccak256("base-fork-collect");
        bytes32 nonce =
            tortoise.collectNonce(songId, quantity, collector, total, keccak256("gm"), salt);
        bytes memory signature =
            _signReceive(collector, address(tortoise), total, validAfter, validBefore, nonce);
        Tortoise.Eip3009Auth memory auth = Tortoise.Eip3009Auth({
            validAfter: validAfter, validBefore: validBefore, salt: salt, signature: signature
        });

        tortoise.collectWithAuthorization(songId, quantity, collector, collector, total, auth, "gm");

        assertEq(tortoise.balanceOf(collector, songId), quantity);
        assertEq(usdc.balanceOf(artist), 17e6);
        assertEq(tortoise.platformFeesAccrued(), 1e6);
        assertEq(usdc.balanceOf(address(shell)), 2e6);
        assertEq(shell.stakedBalance(collector), quantity * TORT_REWARD);

        vm.warp(block.timestamp + 7 days);
        vm.prank(collector);
        shell.claimRewards();
        assertApproxEqAbs(usdc.balanceOf(collector), 2e6, 2);
    }

    function testFork_realUsdcBlocklistDefersThenClaimsArtistPayment() public {
        uint256 songId = tortoise.createSong(_params());
        uint256 total = uint256(PRICE);
        deal(BASE_USDC, collector, total, true);

        address blacklister = usdc.blacklister();
        vm.prank(blacklister);
        usdc.blacklist(artist);

        vm.startPrank(collector);
        assertTrue(usdc.approve(address(tortoise), total));
        tortoise.collect(songId, 1, collector, total, "");
        vm.stopPrank();

        assertEq(usdc.balanceOf(artist), 0);
        assertEq(tortoise.pendingClaims(songId, artist), 8_500_000);

        vm.prank(blacklister);
        usdc.unBlacklist(artist);
        tortoise.claimPending(songId, artist);

        assertEq(usdc.balanceOf(artist), 8_500_000);
        assertEq(tortoise.pendingClaims(songId, artist), 0);
    }
}
