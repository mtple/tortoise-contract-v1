// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Test TORS token for Base Sepolia deployments.
contract TORSTest is ERC20, Ownable2Step {
    uint256 public constant FAUCET_AMOUNT = 1_000 * 1e18;
    uint256 public constant FAUCET_COOLDOWN = 24 hours;

    mapping(address => uint256) public lastFaucetClaim;

    error FaucetCooldownActive(uint256 availableAt);

    constructor(address initialOwner, uint256 initialSupply) ERC20("Tortoise", "TORS") Ownable(initialOwner) {
        if (initialSupply > 0) {
            _mint(initialOwner, initialSupply);
        }
    }

    /// @notice Owner can mint arbitrary amounts.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Anyone can claim FAUCET_AMOUNT once per FAUCET_COOLDOWN.
    function faucet() external {
        uint256 available = lastFaucetClaim[msg.sender] + FAUCET_COOLDOWN;
        if (block.timestamp < available) {
            revert FaucetCooldownActive(available);
        }
        lastFaucetClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
    }

    function renounceOwnership() public view override onlyOwner {
        revert("Renouncing ownership disabled");
    }
}
