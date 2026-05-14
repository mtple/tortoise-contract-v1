// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {MockInProcess1155} from "./mocks/MockInProcess1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IMinter1155} from "../../src/in_process/interfaces/IMinter1155.sol";
import {ILimitedMintPerAddressErrors} from "../../src/in_process/interfaces/ILimitedMintPerAddress.sol";
import {TortoiseMinter} from "../../src/in_process/minters/erc20/TortoiseMinter.sol";
import {ITortoiseMinter} from "../../src/in_process/interfaces/ITortoiseMinter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TortoiseMinterTest is Test {
    MockInProcess1155 internal target;
    MockERC20 currency;
    address payable internal admin = payable(address(0x999));
    address internal inProcess;
    address internal tokenRecipient;
    address internal fundsRecipient;
    address internal createReferral;
    address internal mintReferral;
    address internal owner;
    TortoiseMinter internal minter;
    ITortoiseMinter.TortoiseMinterConfig internal minterConfig;

    uint256 internal constant TOTAL_REWARD_PCT = 5;
    uint256 immutable BPS_TO_PERCENT = 100;
    uint256 internal constant CREATE_REFERRAL_PAID_MINT_REWARD_PCT = 28_571400;
    uint256 internal constant MINT_REFERRAL_PAID_MINT_REWARD_PCT = 28_571400;
    uint256 internal constant IN_PROCESS_PAID_MINT_REWARD_PCT = 28_571400;
    uint256 internal constant FIRST_MINTER_REWARD_PCT = 14_228500;
    uint256 immutable BPS_TO_PERCENT_8_DECIMAL_PERCISION = 100_000_000;
    uint256 internal constant ethReward = 0.000111 ether;

    event ERC20RewardsDeposit(
        address indexed createReferral,
        address indexed mintReferral,
        address indexed firstMinter,
        address inProcess,
        address collection,
        address currency,
        uint256 tokenId,
        uint256 createReferralReward,
        uint256 mintReferralReward,
        uint256 firstMinterReward,
        uint256 inProcessReward
    );

    event TortoiseMinterConfigSet(ITortoiseMinter.TortoiseMinterConfig config);

    event OwnerSet(address indexed prevOwner, address indexed owner);

    event MintComment(address indexed sender, address indexed tokenContract, uint256 indexed tokenId, uint256 quantity, string comment);

    function setUp() external {
        inProcess = makeAddr("inProcess");
        tokenRecipient = makeAddr("tokenRecipient");
        fundsRecipient = makeAddr("fundsRecipient");
        createReferral = makeAddr("createReferral");
        mintReferral = makeAddr("mintReferral");
        owner = makeAddr("owner");

        target = new MockInProcess1155();
        minter = new TortoiseMinter();
        minter.initialize(inProcess, owner, 5, ethReward);
        vm.prank(admin);
        currency = new MockERC20("Test currency", "TEST");
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
        uint256 newTokenId = target.setupNewTokenWithCreateReferral("https://in-process.xyz/testing/token.json", quantity, createReferral);
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

    function test_TortoiseMinterInitializeEventIsEmitted() external {
        vm.expectEmit(true, true, true, true);
        ITortoiseMinter.TortoiseMinterConfig memory newConfig = ITortoiseMinter.TortoiseMinterConfig({
            inProcessRewardRecipientAddress: inProcess,
            rewardRecipientPercentage: 5,
            ethReward: ethReward
        });
        emit TortoiseMinterConfigSet(newConfig);

        minter = new TortoiseMinter();
        minter.initialize(inProcess, owner, 5, ethReward);
    }

    function test_TortoiseMinterInProcessAddrCannotInitializeWithAddressZero() external {
        minter = new TortoiseMinter();

        vm.expectRevert(abi.encodeWithSignature("AddressZero()"));
        minter.initialize(address(0), owner, 5, ethReward);
    }

    function test_TortoiseMinterOwnerAddrCannotInitializeWithAddressZero() external {
        minter = new TortoiseMinter();

        vm.expectRevert(abi.encodeWithSignature("OWNER_CANNOT_BE_ZERO_ADDRESS()"));
        minter.initialize(inProcess, address(0), 5, ethReward);
    }

    function test_TortoiseMinterRewardPercentageCannotBeGreaterThan100() external {
        minter = new TortoiseMinter();

        vm.expectRevert(abi.encodeWithSignature("InvalidValue()"));
        minter.initialize(inProcess, owner, 101, ethReward);
    }

    function test_TortoiseMinterContractName() external view {
        assertEq(minter.contractName(), "ERC20 Minter");
    }

    function test_TortoiseMinterContractVersion() external view {
        assertEq(minter.contractVersion(), "2.0.0");
    }

    function test_TortoiseMinterAlreadyInitalized() external {
        minter = new TortoiseMinter();
        minter.initialize(inProcess, owner, 5, ethReward);

        vm.expectRevert(abi.encodeWithSignature("INITIALIZABLE_CONTRACT_ALREADY_INITIALIZED()"));
        minter.initialize(inProcess, owner, 5, ethReward);
    }

    function test_TortoiseMinterSaleConfigPriceTooLow() external {
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

    function test_TortoiseMinterRevertIfFundsRecipientAddressZero() external {
        vm.startPrank(admin);
        uint256 newTokenId = target.setupNewTokenWithCreateReferral("https://in-process.xyz/testing/token.json", 1, createReferral);
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

    function test_TortoiseMinterRevertIfCurrencyZero() external {
        vm.startPrank(admin);
        uint256 newTokenId = target.setupNewTokenWithCreateReferral("https://in-process.xyz/testing/token.json", 1, createReferral);
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

    function test_TortoiseMinterRevertIfCurrencyDoesNotMatchSalesConfigCurrency() external {
        setUpTargetSale(10_000, fundsRecipient, address(currency), 1, minter);

        vm.deal(tokenRecipient, ethReward);

        vm.expectRevert(abi.encodeWithSignature("InvalidCurrency()"));
        minter.mint{value: ethReward}(tokenRecipient, 1, address(target), 1, 1, makeAddr("0x123"), address(0), "");
    }

    function test_TortoiseMinterRequestMintInvalid() external {
        vm.expectRevert(abi.encodeWithSignature("RequestMintInvalidUseMint()"));
        minter.requestMint(address(0), 1, 1, 1, "");
    }

    function test_TortoiseMinterComputePaidMintRewards() external view {
        uint256 totalValue = 500000000000000000; // 0.5 when converted from wei
        TortoiseMinter.RewardsSettings memory rewardsSettings = minter.computePaidMintRewards(totalValue);

        assertEq(rewardsSettings.createReferralReward, 142857000000000000);
        assertEq(rewardsSettings.mintReferralReward, 142857000000000000);
        assertEq(rewardsSettings.firstMinterReward, 71142500000000000);
        assertEq(rewardsSettings.inProcessReward, 143143500000000000);
        assertEq(
            rewardsSettings.createReferralReward + rewardsSettings.mintReferralReward + rewardsSettings.inProcessReward + rewardsSettings.firstMinterReward,
            totalValue
        );
    }

    function test_TortoiseMinterSaleFlow() external {
        uint96 pricePerToken = 10_000;
        uint256 quantity = 2;
        uint256 newTokenId = setUpTargetSale(pricePerToken, fundsRecipient, address(currency), quantity, minter);

        vm.deal(tokenRecipient, 1 ether);
        vm.prank(admin);
        uint256 totalValue = pricePerToken * quantity;
        currency.mint(address(tokenRecipient), totalValue);

        vm.prank(tokenRecipient);
        currency.approve(address(minter), totalValue);

        vm.deal(tokenRecipient, ethReward * quantity);

        vm.startPrank(tokenRecipient);
        minter.mint{value: ethReward * quantity}(
            tokenRecipient,
            quantity,
            address(target),
            newTokenId,
            pricePerToken * quantity,
            address(currency),
            mintReferral,
            ""
        );
        vm.stopPrank();

        assertEq(target.balanceOf(tokenRecipient, newTokenId), quantity);
        assertEq(currency.balanceOf(fundsRecipient), 19000);
        assertEq(currency.balanceOf(address(inProcess)), 288);
        assertEq(currency.balanceOf(mintReferral), 285);
        assertEq(currency.balanceOf(admin), 142);
        assertEq(currency.balanceOf(createReferral), 285);
        assertEq(
            currency.balanceOf(address(inProcess)) +
                currency.balanceOf(fundsRecipient) +
                currency.balanceOf(mintReferral) +
                currency.balanceOf(admin) +
                currency.balanceOf(createReferral),
            totalValue
        );
        assertEq(address(inProcess).balance, ethReward * quantity);
    }

    function test_TortoiseMinterSaleWithRewardsAddresses() external {
        uint96 pricePerToken = 100000000000000000; // 0.1 when converted from wei
        uint256 quantity = 5;
        uint256 newTokenId = setUpTargetSale(pricePerToken, fundsRecipient, address(currency), quantity, minter);

        vm.deal(tokenRecipient, ethReward * quantity);
        vm.prank(admin);
        uint256 totalValue = pricePerToken * quantity;
        currency.mint(address(tokenRecipient), totalValue);

        vm.prank(tokenRecipient);
        currency.approve(address(minter), totalValue);

        vm.startPrank(tokenRecipient);
        minter.mint{value: ethReward * quantity}(
            tokenRecipient,
            quantity,
            address(target),
            newTokenId,
            pricePerToken * quantity,
            address(currency),
            mintReferral,
            ""
        );
        vm.stopPrank();

        assertEq(target.balanceOf(tokenRecipient, newTokenId), quantity);
        assertEq(currency.balanceOf(fundsRecipient), 475000000000000000);
        assertEq(currency.balanceOf(address(inProcess)), 7157175000000000);
        assertEq(currency.balanceOf(createReferral), 7142850000000000);
        assertEq(currency.balanceOf(mintReferral), 7142850000000000);
        assertEq(
            currency.balanceOf(address(inProcess)) +
                currency.balanceOf(fundsRecipient) +
                currency.balanceOf(createReferral) +
                currency.balanceOf(mintReferral) +
                currency.balanceOf(admin),
            totalValue
        );
        assertEq(address(inProcess).balance, ethReward * quantity);
    }

    function test_TortoiseMinterSaleFuzz(uint96 pricePerToken, uint256 quantity, uint8 rewardPct, uint256 inProcessEthReward) external {
        vm.assume(quantity > 0 && quantity < 1_000_000_000);
        vm.assume(pricePerToken > 10_000 && pricePerToken < type(uint96).max);
        vm.assume(rewardPct > 0 && rewardPct < 100);
        vm.assume(inProcessEthReward > 0 ether && inProcessEthReward < 1 ether);

        TortoiseMinter newMinter = new TortoiseMinter();
        newMinter.initialize(address(inProcess), owner, rewardPct, inProcessEthReward);

        uint256 tokenId = setUpTargetSale(pricePerToken, fundsRecipient, address(currency), quantity, newMinter);

        vm.prank(admin);
        uint256 totalValue = pricePerToken * quantity;
        currency.mint(address(tokenRecipient), totalValue);

        vm.prank(tokenRecipient);
        currency.approve(address(newMinter), totalValue);

        uint256 reward = (totalValue * rewardPct) / BPS_TO_PERCENT;
        uint256 createReferralReward = (reward * CREATE_REFERRAL_PAID_MINT_REWARD_PCT) / BPS_TO_PERCENT_8_DECIMAL_PERCISION;
        uint256 mintReferralReward = (reward * MINT_REFERRAL_PAID_MINT_REWARD_PCT) / BPS_TO_PERCENT_8_DECIMAL_PERCISION;
        uint256 firstMinterReward = (reward * FIRST_MINTER_REWARD_PCT) / BPS_TO_PERCENT_8_DECIMAL_PERCISION;
        uint256 inProcessReward = reward - (createReferralReward + mintReferralReward + firstMinterReward);

        vm.startPrank(tokenRecipient);
        vm.expectEmit(true, true, true, true);
        emit ERC20RewardsDeposit(
            createReferral,
            mintReferral,
            address(admin),
            inProcess,
            address(target),
            address(currency),
            tokenId,
            createReferralReward,
            mintReferralReward,
            firstMinterReward,
            inProcessReward
        );
        vm.deal(tokenRecipient, inProcessEthReward * quantity);

        uint256 amount = pricePerToken * quantity;
        newMinter.mint{value: inProcessEthReward * quantity}(tokenRecipient, quantity, address(target), tokenId, amount, address(currency), mintReferral, "");
        vm.stopPrank();

        assertEq(target.balanceOf(tokenRecipient, tokenId), quantity);
        assertEq(currency.balanceOf(address(inProcess)), inProcessReward);
        assertEq(currency.balanceOf(createReferral), createReferralReward);
        assertEq(currency.balanceOf(mintReferral), mintReferralReward);
        assertEq(currency.balanceOf(admin), firstMinterReward);
        assertEq(currency.balanceOf(address(inProcess)) + currency.balanceOf(mintReferral) + currency.balanceOf(admin) + currency.balanceOf(createReferral), reward);
        assertEq(
            currency.balanceOf(address(inProcess)) +
                currency.balanceOf(fundsRecipient) +
                currency.balanceOf(createReferral) +
                currency.balanceOf(mintReferral) +
                currency.balanceOf(admin),
            totalValue
        );
        assertEq(address(inProcess).balance, inProcessEthReward * quantity);
    }

    function test_TortoiseMinterCreateReferral() public {
        vm.startPrank(admin);
        uint256 newTokenId = target.setupNewTokenWithCreateReferral("https://in-process.xyz/testing/token.json", 1, createReferral);
        target.addPermission(newTokenId, address(minter), target.PERMISSION_BIT_MINTER());
        vm.stopPrank();

        address targetCreateReferral = minter.getCreateReferral(address(target), newTokenId);
        assertEq(targetCreateReferral, createReferral);

        address fallbackCreateReferral = minter.getCreateReferral(address(this), 1);
        assertEq(fallbackCreateReferral, minterConfig.inProcessRewardRecipientAddress);
    }

    function test_TortoiseMinterFirstMinterFallback() public {
        uint256 pricePerToken = 1e18;
        uint256 quantity = 11;
        uint256 totalValue = pricePerToken * quantity;

        uint256 tokenId = setUpTargetSale(pricePerToken, fundsRecipient, address(currency), quantity, minter);
        address collector = makeAddr("collector");

        vm.prank(admin);
        currency.mint(collector, totalValue);

        vm.deal(collector, ethReward * quantity);

        vm.startPrank(collector);
        currency.approve(address(minter), totalValue);
        minter.mint{value: ethReward * quantity}(collector, quantity, address(target), tokenId, totalValue, address(currency), address(0), "");
        vm.stopPrank();

        address firstMinter = minter.getFirstMinter(address(target), tokenId);
        assertEq(firstMinter, admin);

        address fallbackFirstMinter = minter.getFirstMinter(address(this), 1);
        assertEq(fallbackFirstMinter, minterConfig.inProcessRewardRecipientAddress);
    }

    function test_TortoiseMinterSetInProcessRewardsRecipient() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        ITortoiseMinter.TortoiseMinterConfig memory newConfig = ITortoiseMinter.TortoiseMinterConfig({
            inProcessRewardRecipientAddress: address(this),
            rewardRecipientPercentage: 5,
            ethReward: ethReward
        });
        emit TortoiseMinterConfigSet(newConfig);
        minter.setTortoiseMinterConfig(newConfig);

        minterConfig = minter.getTortoiseMinterConfig();
        assertEq(minterConfig.inProcessRewardRecipientAddress, address(this));
    }

    function test_TortoiseMinterOnlyRecipientAddressCanSet() public {
        vm.expectRevert(abi.encodeWithSignature("ONLY_OWNER()"));
        ITortoiseMinter.TortoiseMinterConfig memory newConfig = ITortoiseMinter.TortoiseMinterConfig({
            inProcessRewardRecipientAddress: address(this),
            rewardRecipientPercentage: 5,
            ethReward: ethReward
        });
        minter.setTortoiseMinterConfig(newConfig);
    }

    function test_TortoiseMinterCannotSetRecipientToZero() public {
        vm.expectRevert(abi.encodeWithSignature("AddressZero()"));
        vm.prank(owner);
        ITortoiseMinter.TortoiseMinterConfig memory newConfig = ITortoiseMinter.TortoiseMinterConfig({
            inProcessRewardRecipientAddress: address(0),
            rewardRecipientPercentage: 5,
            ethReward: ethReward
        });
        minter.setTortoiseMinterConfig(newConfig);
    }

    function test_ERC20SetRewardRecipientPercentage(uint256 percentageFuzz) public {
        vm.assume(percentageFuzz > 0 && percentageFuzz < 100);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidValue()"));
        ITortoiseMinter.TortoiseMinterConfig memory newConfig = ITortoiseMinter.TortoiseMinterConfig({
            inProcessRewardRecipientAddress: inProcess,
            rewardRecipientPercentage: 101,
            ethReward: ethReward
        });
        minter.setTortoiseMinterConfig(newConfig);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        newConfig = ITortoiseMinter.TortoiseMinterConfig({inProcessRewardRecipientAddress: inProcess, rewardRecipientPercentage: percentageFuzz, ethReward: ethReward});
        emit TortoiseMinterConfigSet(newConfig);
        minter.setTortoiseMinterConfig(newConfig);
    }

    function test_TortoiseMinterSetEthReward(uint256 ethRewardFuzz) public {
        vm.assume(ethRewardFuzz >= 0 ether && ethRewardFuzz < 10 ether);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        ITortoiseMinter.TortoiseMinterConfig memory newConfig = ITortoiseMinter.TortoiseMinterConfig({
            inProcessRewardRecipientAddress: inProcess,
            rewardRecipientPercentage: minterConfig.rewardRecipientPercentage,
            ethReward: ethRewardFuzz
        });
        emit TortoiseMinterConfigSet(newConfig);
        minter.setTortoiseMinterConfig(newConfig);
    }

    function test_TortoiseMinterSetOwner() public {
        vm.prank(inProcess);
        vm.expectRevert(abi.encodeWithSignature("ONLY_OWNER()"));
        ITortoiseMinter.TortoiseMinterConfig memory newConfig = ITortoiseMinter.TortoiseMinterConfig({
            inProcessRewardRecipientAddress: inProcess,
            rewardRecipientPercentage: minterConfig.rewardRecipientPercentage,
            ethReward: ethReward
        });
        minter.setTortoiseMinterConfig(newConfig);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        newConfig = ITortoiseMinter.TortoiseMinterConfig({
            inProcessRewardRecipientAddress: inProcess,
            rewardRecipientPercentage: minterConfig.rewardRecipientPercentage,
            ethReward: ethReward
        });
        emit TortoiseMinterConfigSet(newConfig);
        minter.setTortoiseMinterConfig(newConfig);
    }

    function test_TortoiseMinterEthRewardTooLow(uint256 ethRewardLow) public {
        vm.assume(ethRewardLow >= 0 ether && ethRewardLow < 0.000111 ether);

        uint96 pricePerToken = 10_000;
        uint256 quantity = 2;
        uint256 newTokenId = setUpTargetSale(pricePerToken, fundsRecipient, address(currency), quantity, minter);

        vm.deal(tokenRecipient, 1 ether);
        vm.prank(admin);
        uint256 totalValue = pricePerToken * quantity;
        currency.mint(address(tokenRecipient), totalValue);

        vm.prank(tokenRecipient);
        currency.approve(address(minter), totalValue);

        vm.deal(tokenRecipient, ethRewardLow);

        vm.startPrank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ITortoiseMinter.InvalidETHValue.selector, 0.000111 ether * quantity, ethRewardLow));
        minter.mint{value: ethRewardLow}(tokenRecipient, quantity, address(target), newTokenId, pricePerToken * quantity, address(currency), mintReferral, "");
        vm.stopPrank();
    }

    function test_TortoiseMinterSetPremintSale() public {
        ITortoiseMinter.PremintSalesConfig memory newConfig = ITortoiseMinter.PremintSalesConfig({
            duration: 3000,
            maxTokensPerAddress: 200,
            pricePerToken: 50000,
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
