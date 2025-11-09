// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ImpactFeeHook} from "../src/ImpactFeeHook.sol";

/**
 * @title SetFeeSink
 * @notice Script to migrate Hook's fee sink (from YDSVault to YDTS or vice versa)
 * @dev Usage: forge script script/SetFeeSink.s.sol --broadcast
 * 
 * Required .env variables:
 * - IMPACT_FEE_HOOK: Address of the deployed ImpactFeeHook
 * - NEW_FEE_SINK: Address of the new ERC4626 vault (YDSVault or YDTS)
 * - PRIVATE_KEY: Owner's private key (must be hook.owner())
 * 
 * Example:
 * ```bash
 * # Migrate from YDSVault to YDTS (Octant V2 mode)
 * export NEW_FEE_SINK=$YDTS_ADDRESS
 * forge script script/SetFeeSink.s.sol --broadcast
 * 
 * # Revert back to YDSVault (default mode)
 * export NEW_FEE_SINK=$YDS_VAULT_ADDRESS
 * forge script script/SetFeeSink.s.sol --broadcast
 * ```
 */
contract SetFeeSink is Script {
    function run() external {
        // Load environment variables
        address hookAddress = vm.envAddress("IMPACT_FEE_HOOK");
        address newSinkAddress = vm.envAddress("NEW_FEE_SINK");
        
        require(hookAddress != address(0), "IMPACT_FEE_HOOK not set");
        require(newSinkAddress != address(0), "NEW_FEE_SINK not set");
        
        ImpactFeeHook hook = ImpactFeeHook(hookAddress);
        IERC4626 newSink = IERC4626(newSinkAddress);
        
        console.log("=== Migrating Fee Sink ===");
        console.log("Hook:", hookAddress);
        console.log("Current Fee Sink:", address(hook.feeSink()));
        console.log("New Fee Sink:", newSinkAddress);
        console.log("");
        
        // Validate new sink
        address currentAsset = hook.feeSink().asset();
        address newAsset = newSink.asset();
        console.log("Current Asset:", currentAsset);
        console.log("New Asset:", newAsset);
        require(currentAsset == newAsset, "Asset mismatch! Sinks must use same asset.");
        console.log("Asset validation: OK");
        console.log("");
        
        // Execute migration
        vm.startBroadcast();
        hook.setFeeSink(newSink);
        vm.stopBroadcast();
        
        console.log("=== Migration Complete ===");
        console.log("Fee sink successfully updated to:", newSinkAddress);
        console.log("");
        console.log("=== Next Steps ===");
        console.log("1. Verify migration: cast call $IMPACT_FEE_HOOK 'feeSink()'");
        console.log("2. Process pending fees: forge script script/02_AddLiquidity.s.sol");
        console.log("3. Fees will now flow to the new sink");
    }
}
