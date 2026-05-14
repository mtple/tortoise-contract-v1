// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {MockInProcess1155} from "./mocks/MockInProcess1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IMinter1155} from "../../src/in_process/interfaces/IMinter1155.sol";
import {
    ILimitedMintPerAddressErrors
} from "../../src/in_process/interfaces/ILimitedMintPerAddress.sol";
import {TortoiseMinter} from "../../src/in_process/minters/TortoiseMinter.sol";
import {ITortoiseMinter} from "../../src/in_process/interfaces/ITortoiseMinter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockTortoiseShell {
    uint256 public depositedAmount;
    uint256 public creditedQuantity;
    address public creditedUser;
    uint256 public tortRewardPerCollection = 1e18;
    uint256 public tortPoolBalance = 1000e18;

    function depositRewards(uint256 amount) external {
        depositedAmount += amount;
    }

    function creditStake(address user, uint256 quantity) external returns (uint256) {
        creditedUser = user;
        creditedQuantity += quantity;
        return quantity * tortRewardPerCollection;
    }

    function getTortPoolBalance() external view returns (uint256) {
        return tortPoolBalance;
    }
}

contract TortoiseMinterTest is Test {
    MockInProcess1155 internal target;
    MockERC20 internal currency;
    MockERC20 internal rewardToken;
    MockTortoiseShell internal shell;

    address payable internal admin = payable(address(0x999));
    address internal tokenRecipient;
    address internal fundsRecipient;
    address internal owner;
    TortoiseMinter internal minter;
    ITortoiseMinter.TortoiseMinterConfig internal minterConfig;

    uint256 internal constant PLATFORM_FEE = 1_000_000; // 1 USDC (6 decimals)
    uint256 internal constant TORTOISE_FEE_BPS = 2_500;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    event Collected(
        address indexed artist,
        address indexed collector,
        address indexed collection,
        uint256 tokenId,
        uint256 quantity,
        uint256 torsAwarded
    );


    event TortoiseMinterConfigSet(ITortoiseMinter.TortoiseMinterConfig config);

    event MintComment(
        address indexed sender,
        address indexed tokenContract,
        uint256 indexed tokenId,
        uint256 quantity,
        string comment
    );

    function setUp() external {
        tokenRecipient = makeAddr("tokenRecipient");
        fundsRecipient = makeAddr("fundsRecipient");
        owner = makeAddr("owner");

        target = new MockInProcess1155();
        shell = new MockTortoiseShell();

        vm.prank(admin);
        currency = new MockERC20("Sale Currency", "SALE");
        rewardToken = new MockERC20("Reward Token", "USDC");

        minter = new TortoiseMinter();
        minter.initialize(address(shell), address(rewardToken), PLATFORM_FEE, owner);
        minterConfig = minter.getTortoiseMinterConfig();
    }

    function setUpTargetSale(
        uint256 price,
        address tokenFundsRecipient,
        address tokenCurrency,
        uint256 quantity,
        TortoiseMinter minterContract
    ) internal returns (uint256) {
        vm.startPrank(admin);
        uint256 newTokenId = target.setupNewToken("https://in-process.xyz/testing/token.json", quantity);
        target.addPermission(newTokenId, address(minterContract), target.PERMISSION_BIT_MINTER());
        target.callSale(
            newTokenId,
            address(minterContract),
            abi.encodeWithSelector(
                TortoiseMinter.setSale.selector,
                newTokenId,
                ITortoiseMinter.SalesConfig({
                    pricePerToken: price,
                    saleStart: 0,
                    saleEnd: type(uint64).max,
                    maxTokensPerAddress: 0,
                    fundsRecipient: tokenFundsRecipient,
                    currency: tokenCurrency
                })
            )
        );
        vm.stopPrank();
        return newTokenId;
    }

    function _approveAndMint(
        address minter_,
        address recipient,
        uint256 quantity,
        address tokenAddress,
        uint256 tokenId,
        uint256 totalValue,
        address saleCurrency,
        uint256 totalFee
    ) internal {
        vm.startPrank(recipient);
        IERC20(saleCurrency).approve(minter_, totalValue);
        IERC20(address(rewardToken)).approve(minter_, totalFee);
        TortoiseMinter(minter_).mint(recipient, quantity, tokenAddress, tokenId, totalValue, saleCurrency, address(0), "");
        vm.stopPrank();
    }

    // ============ Initialize ============

    function test_InitializeEmitsEvent() external {
        vm.expectEmit(true, true, true, true);
        ITortoiseMinter.TortoiseMinterConfig memory newConfig = ITortoiseMinter.TortoiseMinterConfig({
            tortoiseShell: address(shell),
            rewardToken: address(rewardToken),
            platformFee: PLATFORM_FEE
        });
        emit TortoiseMinterConfigSet(newConfig);

        TortoiseMinter newMinter = new TortoiseMinter();
        newMinter.initialize(address(shell), address(rewardToken), PLATFORM_FEE, owner);
    }

    function test_InitializeRevertsIfShellIsZero() external {
        TortoiseMinter newMinter = new TortoiseMinter();
        vm.expectRevert(abi.encodeWithSignature("AddressZero()"));
        newMinter.initialize(address(0), address(rewardToken), PLATFORM_FEE, owner);
    }

    function test_InitializeRevertsIfRewardTokenIsZero() external {
        TortoiseMinter newMinter = new TortoiseMinter();
        vm.expectRevert(abi.encodeWithSignature("AddressZero()"));
        newMinter.initialize(address(shell), address(0), PLATFORM_FEE, owner);
    }

    function test_InitializeRevertsIfOwnerIsZero() external {
        TortoiseMinter newMinter = new TortoiseMinter();
        vm.expectRevert(abi.encodeWithSignature("OWNER_CANNOT_BE_ZERO_ADDRESS()"));
        newMinter.initialize(address(shell), address(rewardToken), PLATFORM_FEE, address(0));
    }

    function test_AlreadyInitialized() external {
        TortoiseMinter newMinter = new TortoiseMinter();
        newMinter.initialize(address(shell), address(rewardToken), PLATFORM_FEE, owner);

        vm.expectRevert(abi.encodeWithSignature("INITIALIZABLE_CONTRACT_ALREADY_INITIALIZED()"));
        newMinter.initialize(address(shell), address(rewardToken), PLATFORM_FEE, owner);
    }

    // ============ Contract Metadata ============

    function test_ContractName() external view {
        assertEq(minter.contractName(), "Tortoise Minter");
    }

    function test_ContractVersion() external view {
        assertEq(minter.contractVersion(), "2.0.0");
    }

    // ============ SetSale ============

    function test_SaleConfigPriceTooLow() external {
        vm.startPrank(admin);
        uint256 newTokenId = target.setupNewToken("https://in-process.xyz/testing/token.json", 10);
        target.addPermission(newTokenId, address(minter), target.PERMISSION_BIT_MINTER());

        bytes memory minterError = abi.encodeWithSignature("PricePerTokenTooLow()");
        vm.expectRevert(abi.encodeWithSignature("CallFailed(bytes)", minterError));
        target.callSale(
            newTokenId,
            address(minter),
            abi.encodeWithSelector(
                TortoiseMinter.setSale.selector,
                newTokenId,
                ITortoiseMinter.SalesConfig({
                    pricePerToken: 1,
                    saleStart: 0,
                    saleEnd: type(uint64).max,
                    maxTokensPerAddress: 0,
                    fundsRecipient: address(0x123),
                    currency: address(currency)
                })
            )
        );
        vm.stopPrank();
    }

    function test_RevertIfFundsRecipientZero() external {
        vm.startPrank(admin);
        uint256 newTokenId = target.setupNewToken("https://in-process.xyz/testing/token.json", 1);
        target.addPermission(newTokenId, address(minter), target.PERMISSION_BIT_MINTER());

        bytes memory minterError = abi.encodeWithSignature("AddressZero()");
        vm.expectRevert(abi.encodeWithSignature("CallFailed(bytes)", minterError));
        target.callSale(
            newTokenId,
            address(minter),
            abi.encodeWithSelector(
                TortoiseMinter.setSale.selector,
                newTokenId,
                ITortoiseMinter.SalesConfig({
                    pricePerToken: 10_000,
                    saleStart: 0,
                    saleEnd: type(uint64).max,
                    maxTokensPerAddress: 0,
                    fundsRecipient: address(0),
                    currency: address(currency)
                })
            )
        );
        vm.stopPrank();
    }

    function test_RevertIfCurrencyZero() external {
        vm.startPrank(admin);
        uint256 newTokenId = target.setupNewToken("https://in-process.xyz/testing/token.json", 1);
        target.addPermission(newTokenId, address(minter), target.PERMISSION_BIT_MINTER());

        bytes memory minterError = abi.encodeWithSignature("AddressZero()");
        vm.expectRevert(abi.encodeWithSignature("CallFailed(bytes)", minterError));
        target.callSale(
            newTokenId,
            address(minter),
            abi.encodeWithSelector(
                TortoiseMinter.setSale.selector,
                newTokenId,
                ITortoiseMinter.SalesConfig({
                    pricePerToken: 10_000,
                    saleStart: 0,
                    saleEnd: type(uint64).max,
                    maxTokensPerAddress: 0,
                    fundsRecipient: fundsRecipient,
                    currency: address(0)
                })
            )
        );
        vm.stopPrank();
    }

    // ============ Mint ============

    function test_RevertIfCurrencyMismatch() external {
        setUpTargetSale(10_000, fundsRecipient, address(currency), 1, minter);

        vm.expectRevert(abi.encodeWithSignature("InvalidCurrency()"));
        minter.mint(tokenRecipient, 1, address(target), 1, 10_000, makeAddr("wrong"), address(0), "");
    }

    function test_RevertIfWrongValue() external {
        setUpTargetSale(10_000, fundsRecipient, address(currency), 1, minter);

        vm.expectRevert(abi.encodeWithSignature("WrongValueSent()"));
        minter.mint(tokenRecipient, 1, address(target), 1, 9_999, address(currency), address(0), "");
    }

    function test_RequestMintInvalid() external {
        vm.expectRevert(abi.encodeWithSignature("RequestMintInvalidUseMint()"));
        minter.requestMint(address(0), 1, 1, 1, "");
    }

    function test_MintFlow() external {
        uint256 pricePerToken = 10_000;
        uint256 quantity = 2;
        uint256 newTokenId = setUpTargetSale(pricePerToken, fundsRecipient, address(currency), quantity, minter);

        uint256 totalValue = pricePerToken * quantity;
        uint256 totalFee = PLATFORM_FEE * quantity;

        vm.prank(admin);
        currency.mint(tokenRecipient, totalValue);
        vm.prank(admin);
        rewardToken.mint(tokenRecipient, totalFee);

        _approveAndMint(address(minter), tokenRecipient, quantity, address(target), newTokenId, totalValue, address(currency), totalFee);

        // NFT minted
        assertEq(target.balanceOf(tokenRecipient, newTokenId), quantity);

        // Artist receives 100% of sale price + 75% of fee
        uint256 tortoiseAmount = totalFee * TORTOISE_FEE_BPS / BPS_DENOMINATOR;
        uint256 artistFeeAmount = totalFee - tortoiseAmount;
        assertEq(currency.balanceOf(fundsRecipient), totalValue);
        assertEq(rewardToken.balanceOf(fundsRecipient), artistFeeAmount);

        // TortoiseShell receives 25% of fee
        assertEq(rewardToken.balanceOf(address(shell)), tortoiseAmount);
        assertEq(shell.depositedAmount(), tortoiseAmount);

        // Collector gets TORS credit
        assertEq(shell.creditedUser(), tokenRecipient);
        assertEq(shell.creditedQuantity(), quantity);
    }

    function test_MintSplit25_75() external {
        uint256 pricePerToken = 10_000;
        uint256 quantity = 1;
        uint256 newTokenId = setUpTargetSale(pricePerToken, fundsRecipient, address(currency), quantity, minter);

        uint256 totalValue = pricePerToken * quantity;
        uint256 totalFee = PLATFORM_FEE * quantity; // 1_000_000

        vm.prank(admin);
        currency.mint(tokenRecipient, totalValue);
        vm.prank(admin);
        rewardToken.mint(tokenRecipient, totalFee);

        _approveAndMint(address(minter), tokenRecipient, quantity, address(target), newTokenId, totalValue, address(currency), totalFee);

        uint256 tortoiseAmount = totalFee * TORTOISE_FEE_BPS / BPS_DENOMINATOR; // 250_000
        uint256 artistFeeAmount = totalFee - tortoiseAmount;                      // 750_000

        assertEq(rewardToken.balanceOf(address(shell)), tortoiseAmount);
        assertEq(rewardToken.balanceOf(fundsRecipient), artistFeeAmount);
        assertEq(tortoiseAmount + artistFeeAmount, totalFee);
    }

    function test_MintEmitsCollectedEvent() external {
        uint256 pricePerToken = 10_000;
        uint256 quantity = 1;
        uint256 newTokenId = setUpTargetSale(pricePerToken, fundsRecipient, address(currency), quantity, minter);

        uint256 totalValue = pricePerToken * quantity;
        uint256 totalFee = PLATFORM_FEE * quantity;

        vm.prank(admin);
        currency.mint(tokenRecipient, totalValue);
        vm.prank(admin);
        rewardToken.mint(tokenRecipient, totalFee);

        vm.startPrank(tokenRecipient);
        currency.approve(address(minter), totalValue);
        rewardToken.approve(address(minter), totalFee);

        uint256 tortoiseAmount = totalFee * TORTOISE_FEE_BPS / BPS_DENOMINATOR;
        uint256 artistFeeAmount = totalFee - tortoiseAmount;
        uint256 torsAwarded = quantity * shell.tortRewardPerCollection();

        vm.expectEmit(true, true, true, true);
        emit Collected(
            fundsRecipient,
            tokenRecipient,
            address(target),
            newTokenId,
            quantity,
            torsAwarded
        );
        minter.mint(tokenRecipient, quantity, address(target), newTokenId, totalValue, address(currency), address(0), "");
        vm.stopPrank();
    }

    function test_MintEmitsCommentEvent() external {
        uint256 pricePerToken = 10_000;
        uint256 quantity = 1;
        uint256 newTokenId = setUpTargetSale(pricePerToken, fundsRecipient, address(currency), quantity, minter);

        uint256 totalValue = pricePerToken;
        uint256 totalFee = PLATFORM_FEE;

        vm.prank(admin);
        currency.mint(tokenRecipient, totalValue);
        vm.prank(admin);
        rewardToken.mint(tokenRecipient, totalFee);

        vm.startPrank(tokenRecipient);
        currency.approve(address(minter), totalValue);
        rewardToken.approve(address(minter), totalFee);

        vm.expectEmit(true, true, true, true);
        emit MintComment(tokenRecipient, address(target), newTokenId, quantity, "hello");
        minter.mint(tokenRecipient, quantity, address(target), newTokenId, totalValue, address(currency), address(0), "hello");
        vm.stopPrank();
    }

    function test_MintSkipsFeeIfShellIsZeroOrFeeIsZero() external {
        TortoiseMinter zeroFeeMinter = new TortoiseMinter();
        // platformFee = 0, shell still set
        zeroFeeMinter.initialize(address(shell), address(rewardToken), 0, owner);

        uint256 pricePerToken = 10_000;
        uint256 quantity = 1;
        uint256 newTokenId = setUpTargetSale(pricePerToken, fundsRecipient, address(currency), quantity, zeroFeeMinter);

        uint256 totalValue = pricePerToken;
        vm.prank(admin);
        currency.mint(tokenRecipient, totalValue);

        vm.startPrank(tokenRecipient);
        currency.approve(address(zeroFeeMinter), totalValue);
        zeroFeeMinter.mint(tokenRecipient, quantity, address(target), newTokenId, totalValue, address(currency), address(0), "");
        vm.stopPrank();

        // No fee pulled, artist gets full sale price
        assertEq(currency.balanceOf(fundsRecipient), totalValue);
        assertEq(rewardToken.balanceOf(address(shell)), 0);
    }

    // ============ Config ============

    function test_SetTortoiseMinterConfig() external {
        MockTortoiseShell newShell = new MockTortoiseShell();
        MockERC20 newRewardToken = new MockERC20("New USDC", "USDC2");

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        ITortoiseMinter.TortoiseMinterConfig memory newConfig = ITortoiseMinter.TortoiseMinterConfig({
            tortoiseShell: address(newShell),
            rewardToken: address(newRewardToken),
            platformFee: 2_000_000
        });
        emit TortoiseMinterConfigSet(newConfig);
        minter.setTortoiseMinterConfig(newConfig);

        ITortoiseMinter.TortoiseMinterConfig memory stored = minter.getTortoiseMinterConfig();
        assertEq(stored.tortoiseShell, address(newShell));
        assertEq(stored.rewardToken, address(newRewardToken));
        assertEq(stored.platformFee, 2_000_000);
    }

    function test_OnlyOwnerCanSetConfig() external {
        vm.expectRevert(abi.encodeWithSignature("ONLY_OWNER()"));
        ITortoiseMinter.TortoiseMinterConfig memory newConfig = ITortoiseMinter.TortoiseMinterConfig({
            tortoiseShell: address(shell),
            rewardToken: address(rewardToken),
            platformFee: PLATFORM_FEE
        });
        minter.setTortoiseMinterConfig(newConfig);
    }

    function test_CannotSetShellToZero() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("AddressZero()"));
        ITortoiseMinter.TortoiseMinterConfig memory newConfig = ITortoiseMinter.TortoiseMinterConfig({
            tortoiseShell: address(0),
            rewardToken: address(rewardToken),
            platformFee: PLATFORM_FEE
        });
        minter.setTortoiseMinterConfig(newConfig);
    }

    function test_CannotSetRewardTokenToZero() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("AddressZero()"));
        ITortoiseMinter.TortoiseMinterConfig memory newConfig = ITortoiseMinter.TortoiseMinterConfig({
            tortoiseShell: address(shell),
            rewardToken: address(0),
            platformFee: PLATFORM_FEE
        });
        minter.setTortoiseMinterConfig(newConfig);
    }

    // ============ PremintSale ============

    function test_SetPremintSale() external {
        ITortoiseMinter.PremintSalesConfig memory newConfig = ITortoiseMinter.PremintSalesConfig({
            duration: 3000,
            maxTokensPerAddress: 200,
            pricePerToken: 50_000,
            fundsRecipient: makeAddr("fundsRecipient"),
            currency: makeAddr("currency")
        });
        address erc1155Contract = makeAddr("contract");
        uint256 tokenId = 10;

        vm.prank(erc1155Contract);
        minter.setPremintSale(10, abi.encode(newConfig));

        ITortoiseMinter.SalesConfig memory salesConfig = minter.sale(erc1155Contract, tokenId);

        assertEq(salesConfig.pricePerToken, newConfig.pricePerToken);
        assertEq(salesConfig.saleStart, block.timestamp);
        assertEq(salesConfig.saleEnd, block.timestamp + newConfig.duration);
        assertEq(salesConfig.maxTokensPerAddress, newConfig.maxTokensPerAddress);
        assertEq(salesConfig.fundsRecipient, newConfig.fundsRecipient);
        assertEq(salesConfig.currency, newConfig.currency);
    }
}
