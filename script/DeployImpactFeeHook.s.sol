// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2 as console} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {ImpactFeeHook} from "../src/ImpactFeeHook.sol";
import {YDSVault} from "../src/YDSVault.sol";

contract DeployImpactFeeHook is Script {
    // Deployer determinístico de Foundry para CREATE2 en scripts
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        // === Lee ENV ===
        address poolManager     = vm.envAddress("POOL_MANAGER");
        address vaultAsset      = vm.envAddress("VAULT_ASSET");
        address donationAddress = vm.envAddress("DONATION_ADDRESS");
        address governance      = vm.envAddress("GOVERNANCE");
        uint256 impactFeeBps    = vm.envUint("IMPACT_FEE_BPS");

        console.log("PM:", poolManager);
        console.log("Vault asset:", vaultAsset);
        console.log("Donation receiver:", donationAddress);
        console.log("Gov:", governance);
        console.log("Impact fee (bps):", impactFeeBps);

        vm.startBroadcast();

        // 1) Despliega un ERC4626 (YDSVault) para recibir fees
        YDSVault vault = new YDSVault(
            IERC20(vaultAsset),
            donationAddress,
            governance,
            "Impact Vault",
            "ivToken"
        );
        IERC4626 feeSink = IERC4626(address(vault));

        // 2) Flags necesarios: beforeSwap + beforeSwapReturnsDelta
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

        // 3) Prepara constructor args del hook (ahora con donationReceiver)
        bytes memory ctorArgs = abi.encode(
            IPoolManager(poolManager),
            feeSink,
            impactFeeBps,
            governance,
            donationAddress  // shares van al donation receiver
        );

        // 4) Mina salt + dirección con HookMiner (sobre el deployer CREATE2 de Foundry)
        (address predicted, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(ImpactFeeHook).creationCode,
            ctorArgs
        );
        console.log("Predicted hook addr:", predicted);

        // 5) Deploy con CREATE2 y verifica que coincide la dirección
        ImpactFeeHook hook = new ImpactFeeHook{salt: salt}(
            IPoolManager(poolManager),
            feeSink,
            impactFeeBps,
            governance,
            donationAddress  // shares receiver
        );
        require(address(hook) == predicted, "Hook address mismatch");
        require((uint160(uint256(uint160(address(hook)))) & flags) == flags, "Flags not encoded");

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT SUCCESSFUL ===");
        console.log("YDS Vault       :", address(vault));
        console.log("ImpactHook      :", address(hook));
        console.log("Donation Receiver:", donationAddress);
        console.log("");
        console.log("Vault shares will be sent to:", donationAddress);
    }
}
