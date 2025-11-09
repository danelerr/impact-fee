// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2 as console} from "forge-std/Script.sol";
import {ImpactFeeYieldStrategy} from "../src/strategies/ImpactFeeYieldStrategy.sol";
import {YDSVault} from "../src/YDSVault.sol";

contract DeployStrategy is Script {
    function run() external {
        address impactFeeHook = vm.envAddress("IMPACT_FEE_HOOK");
        address vaultAsset = vm.envAddress("VAULT_ASSET");
        address ydsVault = vm.envAddress("YDS_VAULT");
        address management = vm.envAddress("MANAGEMENT");
        address keeper = vm.envAddress("KEEPER");
        address governance = vm.envAddress("GOVERNANCE");

        console.log("=== Deploying Strategy ===");
        console.log("Hook:", impactFeeHook);
        console.log("Vault:", ydsVault);
        console.log("Asset:", vaultAsset);

        vm.startBroadcast();

        // Deploy Strategy
        ImpactFeeYieldStrategy strategy = new ImpactFeeYieldStrategy(
            impactFeeHook,
            vaultAsset
        );
        console.log("Strategy deployed:", address(strategy));

        vm.stopBroadcast();

        console.log("");
        console.log("STRATEGY=%s", address(strategy));
        console.log("");
        console.log("Strategy deployed and connected to vault!");
    }
}
