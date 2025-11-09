# Impact Fee Hook 🎯

**Transform DeFi trading into automatic social impact.**

Every swap → 0.10% fee → ERC4626 vault → charity receives shares → Octant V2 → public goods funding.

---

## 🚀 What It Does

- ✅ Uniswap V4 hook charges **0.10% on every swap**
- ✅ Fees deposited to **ERC4626 vault automatically**
- ✅ Vault shares go to **donation address** (not hook)
- ✅ Compatible with **Octant V2 BaseStrategy**
- ✅ **Passive income for public goods** - no user action needed

**Impact**: Turns trading volume into sustainable funding for social impact projects.

---

## 📦 Deployed Contracts (Tenderly Fork)

| Contract | Address | Explorer |
|----------|---------|----------|
| **ImpactFeeHook** | `0x55De5339eA7fF2B00A83E1c3ba7a8C7da181c088` | [View](https://dashboard.tenderly.co/explorer/vnet/8/address/0x55De5339eA7fF2B00A83E1c3ba7a8C7da181c088) |
| **YDSVault** | `0x0612A5b0917889000447070849bE035291CA20e8` | [View](https://dashboard.tenderly.co/explorer/vnet/8/address/0x0612A5b0917889000447070849bE035291CA20e8) |
| **ImpactFeeYieldStrategy** | `0x1A8E19726152aae25E01BBA8a5A92A4992eA53cF` | [View](https://dashboard.tenderly.co/explorer/vnet/8/address/0x1A8E19726152aae25E01BBA8a5A92A4992eA53cF) |

**Pool**: USDC/WETH with hook attached  
**Network**: Tenderly Virtual Mainnet (Chain ID: 8)

---

## 🏗️ Architecture

```
Trader swaps USDC→WETH
         ↓
Hook charges 0.10% fee (beforeSwap)
         ↓
Fees stored as ERC6909 claims
         ↓
processFees() → converts to ERC20
         ↓
Deposits to YDSVault (ERC4626)
         ↓
Shares minted to donation address
         ↓
Strategy reports yield to Octant V2
         ↓
Public goods receive funding
```

**📊 See [FLOW_DIAGRAM.md](./FLOW_DIAGRAM.md) for detailed architecture with visual diagram.**

---

## 🧪 Testing

```bash
# Run full test suite
forge test -vv

# Live demo (interactive)
./demo_tests.sh
```

**Results**: ✅ 29/30 tests passing (complete flow verified)

---

## 🔬 Key Implementation

### ImpactFeeHook.sol
```solidity
function beforeSwap(...) {
    uint256 fee = amountSpecified * 10 / 10000; // 0.10%
    poolFees[poolId][currency] += fee;
    return (beforeSwap.selector, fee, 0);
}

function unlockCallback(...) {
    poolManager.take(currency, address(this), feeAmount);
    feeSink.deposit(feeAmount, donationReceiver); // ← shares to charity
}
```

### ImpactFeeYieldStrategy.sol
```solidity
contract ImpactFeeYieldStrategy is BaseStrategy {
    function _harvestAndReport() internal override returns (uint256) {
        return vault.balanceOf(address(this)); // Report shares as yield
    }
}
```

---

## 🛠️ Stack

- **Solidity 0.8.26**
- **Uniswap V4** (Hooks + PoolManager)
- **Octant V2** (BaseStrategy)
- **Foundry** (Testing/Deployment)
- **Tenderly** (Mainnet Fork)


## 📚 Documentation

- **[SUBMISSION.md](./SUBMISSION.md)** - Hackathon submission (problem, challenges, tracks)
- **[FLOW_DIAGRAM.md](./FLOW_DIAGRAM.md)** - System flow + Excalidraw guide
- **[src/ImpactFeeHook.sol](./src/ImpactFeeHook.sol)** - Main hook contract
- **[test/ImpactFeeHook.t.sol](./test/ImpactFeeHook.t.sol)** - Integration tests

---

## 🚀 Quick Start

```bash
# Clone and install
git clone <repo-url>
cd v4-template
forge install

# Set environment
cp .env.example .env
# Add TENDERLY_RPC_URL, PRIVATE_KEY

# Deploy
source .env
forge script script/00_DeployHook.s.sol --broadcast

# Test
forge test -vv
```

---

## 🔗 Links

- **Uniswap V4 Docs**: https://docs.uniswap.org/contracts/v4
- **Octant V2 Docs**: https://docs.octant.app
- **Tenderly**: https://tenderly.co

---

## 📝 License

MIT

## 📊 Deployed Contracts (Tenderly Mainnet Fork)

**Network:** Tenderly Virtual Mainnet (Chain ID: 8)  
**RPC:** https://virtual.mainnet.eu.rpc.tenderly.co/82c86106-662e-4d7f-a974-c311987358ff

| Contract | Address | Tenderly Link |
|----------|---------|---------------|
| **ImpactFeeHook** | `0x55De5339eA7fF2B00A83E1c3ba7a8C7da181c088` | [View on Tenderly](https://dashboard.tenderly.co/explorer/vnet/82c86106-662e-4d7f-a974-c311987358ff/address/0x55De5339eA7fF2B00A83E1c3ba7a8C7da181c088) |
| **YDSVault** (ERC4626) | `0x0612A5b0917889000447070849bE035291CA20e8` | [View on Tenderly](https://dashboard.tenderly.co/explorer/vnet/82c86106-662e-4d7f-a974-c311987358ff/address/0x0612A5b0917889000447070849bE035291CA20e8) |
| **ImpactFeeYieldStrategy** | `0x1A8E19726152aae25E01BBA8a5A92A4992eA53cF` | [View on Tenderly](https://dashboard.tenderly.co/explorer/vnet/82c86106-662e-4d7f-a974-c311987358ff/address/0x1A8E19726152aae25E01BBA8a5A92A4992eA53cF) |
| **Pool (USDC/WETH)** | Pool ID: `0x15999572...15622` | Active with ImpactFeeHook |

### Verified Features
- ✅ Hook with correct flags (beforeSwap + beforeSwapReturnsDelta)
- ✅ Address mined with HookMiner for deterministic deployment
- ✅ ERC4626 vault receiving fees
- ✅ Octant V2 BaseStrategy integration
- ✅ Shares sent to donation receiver

## 🚀 Quick Demo

### Prerequisites

This template is designed to work with Foundry (stable). If you are using Foundry Nightly, you may encounter compatibility issues. You can update your Foundry installation to the latest stable version by running:

```
foundryup
```

To set up the project, run the following commands in your terminal to install dependencies and run the tests:

```
forge install
forge test
```

### Local Development

Other than writing unit tests (recommended!), you can only deploy & test hooks on [anvil](https://book.getfoundry.sh/anvil/) locally. Scripts are available in the `script/` directory, which can be used to deploy hooks, create pools, provide liquidity and swap tokens. The scripts support both local `anvil` environment as well as running them directly on a production network.

### Executing locally with using **Anvil**:

1. Start Anvil (or fork a specific chain using anvil):

```bash
anvil
```

or

```bash
anvil --fork-url <YOUR_RPC_URL>
```

2. Execute scripts:

```bash
forge script script/00_DeployHook.s.sol \
    --rpc-url http://localhost:8545 \
    --private-key <PRIVATE_KEY> \
    --broadcast
```

### Using **RPC URLs** (actual transactions):

:::info
It is best to not store your private key even in .env or enter it directly in the command line. Instead use the `--account` flag to select your private key from your keystore.
:::

### Follow these steps if you have not stored your private key in the keystore:

<details>

1. Add your private key to the keystore:

```bash
cast wallet import <SET_A_NAME_FOR_KEY> --interactive
```

2. You will prompted to enter your private key and set a password, fill and press enter:

```
Enter private key: <YOUR_PRIVATE_KEY>
Enter keystore password: <SET_NEW_PASSWORD>
```

You should see this:

```
`<YOUR_WALLET_PRIVATE_KEY_NAME>` keystore was saved successfully. Address: <YOUR_WALLET_ADDRESS>
```

::: warning
Use `history -c` to clear your command history.
:::

</details>

1. Execute scripts:

```bash
forge script script/00_DeployHook.s.sol \
    --rpc-url <YOUR_RPC_URL> \
    --account <YOUR_WALLET_PRIVATE_KEY_NAME> \
    --sender <YOUR_WALLET_ADDRESS> \
    --broadcast
```

You will prompted to enter your wallet password, fill and press enter:

```
Enter keystore password: <YOUR_PASSWORD>
```

### Key Modifications to note:

1. Update the `token0` and `token1` addresses in the `BaseScript.sol` file to match the tokens you want to use in the network of your choice for sepolia and mainnet deployments.
2. Update the `token0Amount` and `token1Amount` in the `CreatePoolAndAddLiquidity.s.sol` file to match the amount of tokens you want to provide liquidity with.
3. Update the `token0Amount` and `token1Amount` in the `AddLiquidity.s.sol` file to match the amount of tokens you want to provide liquidity with.
4. Update the `amountIn` and `amountOutMin` in the `Swap.s.sol` file to match the amount of tokens you want to swap.

### Verifying the hook contract

```bash
forge verify-contract \
  --rpc-url <URL> \
  --chain <CHAIN_NAME_OR_ID> \
  # Generally etherscan
  --verifier <Verification_Provider> \
  # Use --etherscan-api-key <ETHERSCAN_API_KEY> if you are using etherscan
  --verifier-api-key <Verification_Provider_API_KEY> \
  --constructor-args <ABI_ENCODED_ARGS> \
  --num-of-optimizations <OPTIMIZER_RUNS> \
  <Contract_Address> \
  <path/to/Contract.sol:ContractName>
  --watch
```

### Troubleshooting

<details>

#### Permission Denied

When installing dependencies with `forge install`, Github may throw a `Permission Denied` error

Typically caused by missing Github SSH keys, and can be resolved by following the steps [here](https://docs.github.com/en/github/authenticating-to-github/connecting-to-github-with-ssh)

Or [adding the keys to your ssh-agent](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent#adding-your-ssh-key-to-the-ssh-agent), if you have already uploaded SSH keys

#### Anvil fork test failures

Some versions of Foundry may limit contract code size to ~25kb, which could prevent local tests to fail. You can resolve this by setting the `code-size-limit` flag

```
anvil --code-size-limit 40000
```

#### Hook deployment failures

Hook deployment failures are caused by incorrect flags or incorrect salt mining

1. Verify the flags are in agreement:
   - `getHookCalls()` returns the correct flags
   - `flags` provided to `HookMiner.find(...)`
2. Verify salt mining is correct:
   - In **forge test**: the _deployer_ for: `new Hook{salt: salt}(...)` and `HookMiner.find(deployer, ...)` are the same. This will be `address(this)`. If using `vm.prank`, the deployer will be the pranking address
   - In **forge script**: the deployer must be the CREATE2 Proxy: `0x4e59b44847b379578588920cA78FbF26c0B4956C`
     - If anvil does not have the CREATE2 deployer, your foundry may be out of date. You can update it with `foundryup`

</details>

### Additional Resources

- [Uniswap v4 docs](https://docs.uniswap.org/contracts/v4/overview)
- [v4-periphery](https://github.com/uniswap/v4-periphery)
- [v4-core](https://github.com/uniswap/v4-core)
- [v4-by-example](https://v4-by-example.org)
