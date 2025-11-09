// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {ImpactFeeHook} from "../src/ImpactFeeHook.sol";
import {ImpactFeeYieldStrategy} from "../src/strategies/ImpactFeeYieldStrategy.sol";
import {YDSVault} from "../src/YDSVault.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

/**
 * @title OctantYDSTest
 * @notice Tests for Octant V2 Yield-Donating Strategy integration
 * @dev Tests demonstrate how ImpactFeeYieldStrategy would work with Octant V2
 *      Currently the system uses YDSVault, but this shows the yield calculation logic
 */
contract OctantYDSTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    
    ImpactFeeHook hook;
    ImpactFeeYieldStrategy strategy;
    YDSVault vault;
    
    Currency currency0;
    Currency currency1;
    
    PoolKey poolKey;
    PoolId poolId;
    
    address donationAddress;
    address governance;
    address swapper;
    
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;
    
    uint128 constant LIQUIDITY_AMOUNT = 10e18;
    uint256 constant IMPACT_FEE_BPS = 10;
    
    function setUp() public {
        // Deploy Uniswap V4 infrastructure
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        
        // Setup actors
        donationAddress = makeAddr("donation");
        governance = makeAddr("governance");
        swapper = makeAddr("swapper");
        
        // Deploy vault (current architecture)
        vault = new YDSVault(
            IERC20(Currency.unwrap(currency0)),
            donationAddress,
            governance,
            "Impact Vault Token0",
            "ivTOK0"
        );
        
        // Deploy hook with vault
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0x4444 << 144)
        );
        
        bytes memory constructorArgs = abi.encode(
            address(poolManager), 
            address(vault), 
            IMPACT_FEE_BPS, 
            governance,
            donationAddress
        );
        deployCodeTo("ImpactFeeHook.sol:ImpactFeeHook", constructorArgs, flags);
        hook = ImpactFeeHook(flags);
        
        // Deploy strategy (for demonstration of Octant V2 integration)
        strategy = new ImpactFeeYieldStrategy(
            address(hook),
            Currency.unwrap(currency0)
        );
        
        // Initialize pool
        poolKey = PoolKey(currency0, currency1, 3000, 60, hook);
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        
        // Fund swapper
        deal(Currency.unwrap(currency0), swapper, 100e18);
        deal(Currency.unwrap(currency1), swapper, 100e18);
        
        vm.startPrank(swapper);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }
    
    function test_ProfitPath_DemonstrateYieldCalculation() public {
        // This test demonstrates how the strategy calculates yield
        // In production, fees would be sent directly to the strategy address
        
        // Simulate receiving 100 tokens as fees
        deal(Currency.unwrap(currency0), address(strategy), 100 ether);
        
        // Check strategy stats
        (, uint256 totalAssets, uint256 lastReported, uint256 pendingProfit) = strategy.getStrategyStats();
        
        assertEq(totalAssets, 100 ether, "Strategy should track assets");
        assertEq(lastReported, 0, "No previous report");
        assertEq(pendingProfit, 100 ether, "All assets are profit when starting from 0");
        
        console.log("Strategy demonstrates yield calculation correctly");
        console.log("Total assets:", totalAssets);
        console.log("Pending profit (yield):", pendingProfit);
    }
    
    function test_YieldAccumulation_MultipleDeposits() public {
        // Simulate first deposit of 100 ether
        deal(Currency.unwrap(currency0), address(strategy), 100 ether);
        
        (, uint256 totalAssets1,, uint256 pendingProfit1) = strategy.getStrategyStats();
        assertEq(totalAssets1, 100 ether, "First deposit tracked");
        assertEq(pendingProfit1, 100 ether, "All is profit initially");
        
        // Simulate additional 50 ether in fees
        deal(Currency.unwrap(currency0), address(strategy), 150 ether);
        
        (, uint256 totalAssets2,, uint256 pendingProfit2) = strategy.getStrategyStats();
        assertEq(totalAssets2, 150 ether, "Additional assets tracked");
        // Note: Without actual report(), all assets still count as profit
        assertEq(pendingProfit2, 150 ether, "Pending profit updated");
        
        console.log("Strategy tracks yield accumulation");
    }
    
    function test_CurrentArchitecture_VaultReceivesFees() public {
        // This test shows the CURRENT architecture (not Octant V2 yet)
        // Fees go to YDSVault, not the strategy
        
        hook.setImpactFee(1000);
        
        tickLower = -60;
        tickUpper = 60;
        
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            LIQUIDITY_AMOUNT
        );
        
        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            LIQUIDITY_AMOUNT,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
        
        uint256 vaultBalanceBefore = vault.totalAssets();
        
        // Perform swap
        vm.startPrank(swapper);
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: swapper,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();
        
        // Process fees - currently goes to VAULT
        uint256 pendingFees = hook.getPendingFees(poolId, currency0);
        hook.processFees(poolId, currency0);
        
        uint256 vaultBalanceAfter = vault.totalAssets();
        
        assertGt(vaultBalanceAfter, vaultBalanceBefore, "Vault should receive fees");
        assertEq(vaultBalanceAfter - vaultBalanceBefore, pendingFees, "Vault gets exact fee amount");
        
        console.log("Current architecture: Fees -> Vault -> Donation Shares");
        console.log("Fees sent to vault:", vaultBalanceAfter - vaultBalanceBefore);
    }
    
    function test_LossPath_StrategyLoss_NoShares() public view {
        // Note: In this implementation, strategy holds idle assets (no deployment)
        // Loss scenarios would require:
        // 1. Strategy deploying to external protocol
        // 2. External protocol suffering loss/hack
        // 3. Strategy reporting negative returns
        
        // This strategy uses idle assets only (no external risk)
        // In Octant V2 with YDTS, losses would burn donation address shares
        
        console.log("Loss path requires deployed funds to external protocol");
        console.log("This strategy uses idle assets only (no external risk)");
    }
    
    function test_GetStrategyStats() public view {
        (
            address hookAddr,
            uint256 totalAssets,
            uint256 lastReported,
            uint256 pendingProfit
        ) = strategy.getStrategyStats();
        
        assertEq(hookAddr, address(hook), "Should track hook address");
        assertEq(totalAssets, 0, "Empty strategy");
        assertEq(lastReported, 0, "Never reported");
        assertEq(pendingProfit, 0, "No profit");
    }
}
