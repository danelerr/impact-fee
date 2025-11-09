// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ImpactFeeYieldStrategy} from "../src/strategies/ImpactFeeYieldStrategy.sol";
import {ImpactFeeHook} from "../src/ImpactFeeHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployOctantYDS
 * @notice Deploys the Octant V2 Yield-Donating Strategy integration
 * @dev This script:
 *      1. Deploys ImpactFeeYieldStrategy (our BaseStrategy implementation)
 *      2. Configures it with the ImpactFeeHook
 *      3. Sets up donation address and roles
 * 
 * Environment variables required:
 * - RPC_URL: Network RPC endpoint
 * - PRIVATE_KEY: Deployer private key
 * - ASSET: Token address (e.g., USDC)
 * - DONATION_ADDRESS: Beneficiary address (dragonRouter)
 * - KEEPER: Address that can call report()/tend()
 * - MANAGEMENT: Governance/admin address
 * - IMPACT_FEE_HOOK: Deployed ImpactFeeHook address
 */
contract DeployOctantYDS is Script {
    
    function run() external {
        // Load environment variables
        address asset = vm.envAddress("ASSET");
        address donationAddress = vm.envAddress("DONATION_ADDRESS");
        address keeper = vm.envAddress("KEEPER");
        address management = vm.envAddress("MANAGEMENT");
        address impactFeeHook = vm.envAddress("IMPACT_FEE_HOOK");
        
        console.log("=== Deploying Octant V2 YDS Integration ===");
        console.log("Asset:", asset);
        console.log("Donation Address:", donationAddress);
        console.log("Keeper:", keeper);
        console.log("Management:", management);
        console.log("Impact Fee Hook:", impactFeeHook);
        console.log("");

        vm.startBroadcast();

        
        // Deploy ImpactFeeYieldStrategy
        console.log("=== Deploying Impact Fee Yield Strategy ===");
        ImpactFeeYieldStrategy strategy = new ImpactFeeYieldStrategy(
            impactFeeHook,
            asset
        );
        
        console.log("Strategy deployed at:", address(strategy));
        console.log("Asset:", asset);
        console.log("");
        
        // NOTE: No need to setFeeSink() here - the hook was deployed with the correct feeSink
        // If you want to migrate from YDSVault to Strategy/YDTS later, use SetFeeSink.s.sol script
        console.log("=== Strategy Ready for Octant V2 Integration ===");
        console.log("Current feeSink:", impactFeeHook);
        console.log("To migrate fees to this strategy: forge script script/SetFeeSink.s.sol");
        console.log("");
        
        console.log("=== Next Steps ===");
        console.log("1. Perform swaps to generate fees");
        console.log("2. Call hook.processFees(poolId, currency) to convert claims to ERC20");
        console.log("3. If feeSink = Strategy, fees go to strategy (idle assets)");
        console.log("4. (Future) Deploy YDTS wrapper and call report() to mint shares");
        
        vm.stopBroadcast();
    }
}
