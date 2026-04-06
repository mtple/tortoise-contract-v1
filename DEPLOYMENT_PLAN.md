# Deployment Plan — Tortoise v1

Target network: **Base Mainnet (chain ID 8453)**

---

## Phase 1: Pre-Deploy Checklist

- [ ] Deployer wallet funded with ETH on Base for gas
- [ ] Deployer wallet holds TORT tokens to seed the staking pool
- [ ] `DEPLOYER_PRIVATE_KEY` set in `.env`
- [ ] `BASESCAN_API_KEY` set in `.env` (get one at https://basescan.org/myapikey)
- [ ] `BASE_RPC_URL` set in `.env` (Coinbase, Alchemy, or Infura recommended over public RPC)
- [ ] Fee parameters confirmed in `.env`:
  - `INITIAL_SONG_PRICE=850000` ($0.85)
  - `INITIAL_PLATFORM_FEE=50000` ($0.05)
  - `INITIAL_STAKING_FEE=100000` ($0.10)
- [ ] Decide initial TORT pool size (TORT per copy × expected mints for first funding window)

---

## Phase 2: Deploy Contracts

Run the deploy script:

```bash
source .env
forge script script/Deploy.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast \
  --verify
```

The script handles:
1. Deploy **TortoiseShell** (TORT, USDC, 7-day reward duration)
2. Deploy **TortoiseV1** (USDC, fees, shell address)
3. Register TortoiseV1 as authorized caller on TortoiseShell

Record the deployed addresses from the console output.

---

## Phase 3: Post-Deploy Configuration

These transactions must be sent from the deployer wallet. Use `cast` or a separate script.

### 3a. Fund the TORT pool

```bash
# Approve TortoiseShell to pull TORT
cast send $TORT_ADDRESS \
  "approve(address,uint256)" $SHELL_ADDRESS <AMOUNT_IN_WEI> \
  --rpc-url $BASE_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY

# Fund the pool
cast send $SHELL_ADDRESS \
  "fundTortPool(uint256)" <AMOUNT_IN_WEI> \
  --rpc-url $BASE_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY
```

### 3b. Set TORT reward per collection

```bash
cast send $SHELL_ADDRESS \
  "setTortRewardPerCollection(uint256)" 777777000000000000000000 \
  --rpc-url $BASE_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY
```

### 3c. Verify configuration

```bash
# Confirm TortoiseV1 is authorized
cast call $SHELL_ADDRESS "authorizedCallers(address)(bool)" $TORTOISE_ADDRESS --rpc-url $BASE_RPC_URL

# Confirm TORT pool balance
cast call $SHELL_ADDRESS "tortPoolBalance()(uint256)" --rpc-url $BASE_RPC_URL

# Confirm reward per collection
cast call $SHELL_ADDRESS "tortRewardPerCollection()(uint256)" --rpc-url $BASE_RPC_URL

# Confirm fees
cast call $TORTOISE_ADDRESS "platformFee()(uint128)" --rpc-url $BASE_RPC_URL
cast call $TORTOISE_ADDRESS "stakingFee()(uint128)" --rpc-url $BASE_RPC_URL
cast call $TORTOISE_ADDRESS "defaultPrice()(uint128)" --rpc-url $BASE_RPC_URL
```

---

## Phase 4: Contract Verification

If `--verify` succeeded during deploy, both contracts should already be verified on Basescan. If not, verify manually:

```bash
forge verify-contract $SHELL_ADDRESS TortoiseShell \
  --constructor-args $(cast abi-encode "constructor(address,address,uint256)" $TORT_ADDRESS $USDC_ADDRESS 604800) \
  --chain base --etherscan-api-key $BASESCAN_API_KEY

forge verify-contract $TORTOISE_ADDRESS TortoiseV1 \
  --constructor-args $(cast abi-encode "constructor(address,uint128,uint128,address,uint128)" $USDC_ADDRESS 50000 850000 $SHELL_ADDRESS 100000) \
  --chain base --etherscan-api-key $BASESCAN_API_KEY
```

Confirm both show "Verified" on Basescan.

---

## Phase 5: Smoke Test on Mainnet

Run these checks against the live deployment to confirm the full flow works end-to-end.

### 5a. Create a test song

```bash
cast send $TORTOISE_ADDRESS \
  "createSong(string,uint128,uint128,string)" "Smoke Test" 0 0 "ipfs://smoketest" \
  --rpc-url $BASE_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY
```

Verify it returned song ID 1:
```bash
cast call $TORTOISE_ADDRESS "nextSongId()(uint256)" --rpc-url $BASE_RPC_URL
```

### 5b. Mint a copy

From a separate wallet (or the deployer), approve USDC and mint:

```bash
# Approve USDC spend (total = price + platform fee + staking fee = 1,000,000 = $1.00)
cast send $USDC_ADDRESS \
  "approve(address,uint256)" $TORTOISE_ADDRESS 1000000 \
  --rpc-url $BASE_RPC_URL --private-key $BUYER_PRIVATE_KEY

# Mint 1 copy of song ID 1
cast send $TORTOISE_ADDRESS \
  "mintSong(uint256,uint256,address)" 1 1 $BUYER_ADDRESS \
  --rpc-url $BASE_RPC_URL --private-key $BUYER_PRIVATE_KEY
```

### 5c. Verify the mint

```bash
# NFT balance
cast call $TORTOISE_ADDRESS "balanceOf(address,uint256)(uint256)" $BUYER_ADDRESS 1 --rpc-url $BASE_RPC_URL

# Artist received $0.85
cast call $USDC_ADDRESS "balanceOf(address)(uint256)" $DEPLOYER_ADDRESS --rpc-url $BASE_RPC_URL

# Platform fee held in contract
cast call $USDC_ADDRESS "balanceOf(address)(uint256)" $TORTOISE_ADDRESS --rpc-url $BASE_RPC_URL

# Staking fee deposited to shell
cast call $SHELL_ADDRESS "rewardRate()(uint256)" --rpc-url $BASE_RPC_URL

# Buyer received TORT credit
cast call $SHELL_ADDRESS "stakedBalance(address)(uint256)" $BUYER_ADDRESS --rpc-url $BASE_RPC_URL
```

### 5d. Verify reward accrual

Wait a few minutes, then check earned rewards:
```bash
cast call $SHELL_ADDRESS "earned(address)(uint256)" $BUYER_ADDRESS --rpc-url $BASE_RPC_URL
```

Should return a non-zero value (USDC rewards accruing from the staking fee drip).

---

## Phase 6: Production Readiness

- [ ] **Ownership transfer** — consider transferring ownership of both contracts to a multisig (e.g. Safe) for production
- [ ] **Monitor TORT pool** — watch for `TortPoolDepleted` events; refill before credits stop
- [ ] **Monitor reward rate** — `rewardRate()` should be non-zero whenever staking fees are flowing
- [ ] **Pause plan** — document who can call `pause()` and under what conditions
- [ ] **Update `.env`** with deployed addresses (`TORTOISE_SHELL_ADDRESS`, TortoiseV1 address)
- [ ] **Update README** with deployed contract addresses

---

## Quick Reference

| Item | Value |
|------|-------|
| USDC (Base) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| TORT (Base) | `0x601410d1d3093cF469fCA4e1EfB2Fb67B4E225c6` |
| Reward duration | 604,800 seconds (7 days) |
| TORT per collection | 777,777 TORT (777777000000000000000000 wei) |
| Default song price | 850,000 USDC units ($0.85) |
| Platform fee | 50,000 USDC units ($0.05) |
| Staking fee | 100,000 USDC units ($0.10) |
