// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ImpactFeeHook} from "../src/ImpactFeeHook.sol";
import {YDSVault} from "../src/YDSVault.sol";

/**
 * @title DeployImpactFeeHook
 * @notice Deployment script for the Impact Fee Hook and YDS Vault
 * @dev Use with: forge script script/DeployImpactFeeHook.s.sol --rpc-url $RPC_URL --broadcast
 * 
 * Environment Variables Required:
 * - RPC_URL: The RPC endpoint for the network
 * - PRIVATE_KEY: Deployer private key (or use --ledger, --trezor)
 * - POOL_MANAGER: Address of the Uniswap V4 PoolManager
 * - VAULT_ASSET: Address of the ERC20 token for the vault
 * - DONATION_ADDRESS: Address to receive donation shares
 * - GOVERNANCE: Address with governance rights
 */
contract DeployImpactFeeHook is Script {
    // Configuration
    uint256 constant IMPACT_FEE_BPS = 10; // 0.1%
    string constant VAULT_NAME = "Impact Vault";
    string constant VAULT_SYMBOL = "ivToken";

    function run() external {
        // Read environment variables
        address poolManager = vm.envAddress("POOL_MANAGER");
        address vaultAsset = vm.envAddress("VAULT_ASSET");
        address donationAddress = vm.envAddress("DONATION_ADDRESS");
        address governance = vm.envAddress("GOVERNANCE");

        console.log("=== Impact Fee Hook Deployment ===");
        console.log("Pool Manager:", poolManager);
        console.log("Vault Asset:", vaultAsset);
        console.log("Donation Address:", donationAddress);
        console.log("Governance:", governance);
        console.log("Impact Fee:", IMPACT_FEE_BPS, "bps");
        console.log("---");

        // Start broadcasting transactions
        vm.startBroadcast();

        // Step 1: Deploy YDS Vault
        console.log("Deploying YDS Vault...");
        YDSVault vault = new YDSVault(
            IERC20(vaultAsset),
            donationAddress,
            governance,
            VAULT_NAME,
            VAULT_SYMBOL
        );
        console.log("YDS Vault deployed at:", address(vault));

        // Step 2: Calculate hook address with correct flags
        // We need beforeSwap and beforeSwapReturnDelta permissions
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) 
            ^ (0x4444 << 144) // Namespace
        );
        console.log("Target hook address:", flags);

        // Step 3: Deploy Impact Fee Hook to the calculated address
        console.log("Deploying Impact Fee Hook...");
        
        // Note: In production, you'll need to use CREATE2 to deploy to the exact address
        // For now, we'll deploy normally and you'll need to use the mining script
        // See: https://github.com/uniswapfoundation/v4-template#hook-mining
        
        ImpactFeeHook hook = new ImpactFeeHook{salt: bytes32(uint256(0x4444))}(
            IPoolManager(poolManager),
            vault,
            IMPACT_FEE_BPS,
            governance
        );
        
        console.log("Impact Fee Hook deployed at:", address(hook));

        // Verify deployment
        console.log("---");
        console.log("Verifying deployment...");
        
        // Check vault configuration
        require(vault.donationAddress() == donationAddress, "Invalid donation address");
        require(vault.governance() == governance, "Invalid governance");
        require(address(vault.asset()) == vaultAsset, "Invalid vault asset");
        console.log("Vault configuration verified");

        // Check hook configuration
        require(address(hook.feeSink()) == address(vault), "Invalid fee sink reference");
        require(hook.impactFeeBps() == IMPACT_FEE_BPS, "Invalid impact fee");
        require(hook.owner() == governance, "Invalid owner");
        console.log("Hook configuration verified");

        vm.stopBroadcast();

        // Output summary
        console.log("---");
        console.log("=== Deployment Complete ===");
        console.log("YDS Vault:", address(vault));
        console.log("Impact Fee Hook:", address(hook));
        console.log("---");
        console.log("Next Steps:");
        console.log("1. Verify contracts on Etherscan");
        console.log("2. Create a V4 pool with the hook");
        console.log("3. Add liquidity to the pool");
        console.log("4. Test with a swap");
        console.log("---");
        console.log("Pool Creation Example:");
        console.log("  Currency currency0 = Currency.wrap(0x...)");
        console.log("  Currency currency1 = Currency.wrap(0x...)");
        console.log("  PoolKey memory key = PoolKey({");
        console.log("    currency0: currency0,");
        console.log("    currency1: currency1,");
        console.log("    fee: 3000,");
        console.log("    tickSpacing: 60,");
        console.log("    hooks: IHooks(", address(hook), ")");
        console.log("  });");
        console.log("  poolManager.initialize(key, sqrtPriceX96);");
    }
}

/**
 * @title DeployImpactFeeHookWithMining
 * @notice Extended deployment script with hook address mining
 * @dev This script mines for a valid hook address using CREATE2
 */
contract DeployImpactFeeHookWithMining is Script {
    uint256 constant IMPACT_FEE_BPS = 10;
    string constant VAULT_NAME = "Impact Vault";
    string constant VAULT_SYMBOL = "ivToken";

    function run() external {
        // Read environment variables
        address poolManager = vm.envAddress("POOL_MANAGER");
        address vaultAsset = vm.envAddress("VAULT_ASSET");
        address donationAddress = vm.envAddress("DONATION_ADDRESS");
        address governance = vm.envAddress("GOVERNANCE");

        console.log("=== Mining Hook Address ===");
        
        // Calculate required flags
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        
        console.log("Required flags:", flags);
        console.log("Mining for salt...");
        
        // In production, you would mine for a salt off-chain
        // For hackathon purposes, we use a fixed salt
        bytes32 salt = bytes32(uint256(0x4444));
        
        vm.startBroadcast();

        // Deploy vault
        YDSVault vault = new YDSVault(
            IERC20(vaultAsset),
            donationAddress,
            governance,
            VAULT_NAME,
            VAULT_SYMBOL
        );

        // Deploy hook with CREATE2
        ImpactFeeHook hook = new ImpactFeeHook{salt: salt}(
            IPoolManager(poolManager),
            vault,
            IMPACT_FEE_BPS,
            governance
        );

        vm.stopBroadcast();

        console.log("Vault:", address(vault));
        console.log("Hook:", address(hook));
        console.log("Hook flags match:", uint160(address(hook)) & flags == flags);
    }
}
