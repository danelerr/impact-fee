// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2 as console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CreatePool is Script {
    using PoolIdLibrary for PoolKey;

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address token0 = vm.envAddress("CURRENCY"); // USDC
        address token1 = vm.envAddress("WETH");
        address hook = vm.envAddress("IMPACT_FEE_HOOK");
        
        console.log("=== Creating Pool ===");
        console.log("Pool Manager:", poolManager);
        console.log("Token0 (USDC):", token0);
        console.log("Token1 (WETH):", token1);
        console.log("Hook:", hook);

        // Ensure token0 < token1
        require(uint160(token0) < uint160(token1), "token0 must be < token1");

        vm.startBroadcast();

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000, // 0.3%
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        // Initialize pool at 1:1 price (sqrtPriceX96 = 2^96)
        IPoolManager(poolManager).initialize(key, 79228162514264337593543950336);

        vm.stopBroadcast();

        PoolId poolId = key.toId();
        console.log("");
        console.log("Pool created!");
        console.log("PoolId:", uint256(PoolId.unwrap(poolId)));
        console.log("");
        console.log("Add to .env:");
        console.log("POOL_ID=0x%s", uint256(PoolId.unwrap(poolId)));
    }
}
