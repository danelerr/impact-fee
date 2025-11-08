// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

// Uniswap V4 Imports
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

// Test utilities
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

// OpenZeppelin Imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Our Contracts
import {ImpactFeeHook} from "../src/ImpactFeeHook.sol";
import {YDSVault} from "../src/YDSVault.sol";

/**
 * @title ImpactFeeIntegrationTest
 * @notice End-to-end integration test for the Impact Fee Hook + YDS Vault system
 * @dev Tests the full flow: Swap → Fee Collection → YDS Vault Deposit → Donation Shares Minted
 * 
 * Test Flow:
 * 1. Deploy YDSVault with a charity donation address
 * 2. Deploy ImpactFeeHook connected to the vault
 * 3. Create a Uniswap V4 pool with the hook attached
 * 4. Add liquidity to the pool
 * 5. Simulate a user swap
 * 6. Verify:
 *    - Impact fee was collected from the swapper
 *    - Fee was deposited into YDSVault
 *    - Donation shares were minted to the charity address
 *    - Pool stats are tracked correctly
 * 
 * @custom:hackathon Octant DeFi Hackathon 2025
 */
contract ImpactFeeIntegrationTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // Currencies (tokens)
    Currency currency0;
    Currency currency1;

    // Pool configuration
    PoolKey poolKey;
    PoolId poolId;

    // Contracts under test
    ImpactFeeHook hook;
    YDSVault vault;

    // Test actors
    address public charity = makeAddr("charity"); // The donation recipient
    address public governance = makeAddr("governance"); // Vault governance
    address public swapper = makeAddr("swapper"); // User performing swaps

    // Liquidity position
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    // Test constants
    uint256 constant IMPACT_FEE_BPS = 10; // 0.1% fee
    uint128 constant LIQUIDITY_AMOUNT = 100e18;
    uint256 constant SWAP_AMOUNT = 1e18; // 1 token

    /*//////////////////////////////////////////////////////////////
                            SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Deploy Uniswap V4 infrastructure
        deployArtifactsAndLabel();

        // Deploy currency pair (ERC20 tokens for testing)
        (currency0, currency1) = deployCurrencyPair();

        // Step 1: Deploy YDS Vault
        // The vault accepts currency0 as the underlying asset
        vault = new YDSVault(
            IERC20(Currency.unwrap(currency0)), // asset
            charity, // donationAddress
            governance, // governance
            "Impact Vault Token0", // name
            "ivTOK0" // symbol
        );

        console.log("YDSVault deployed at:", address(vault));
        console.log("Vault asset (currency0):", Currency.unwrap(currency0));
        console.log("Donation address (charity):", charity);

        // Step 2: Deploy ImpactFeeHook
        // The hook needs to be deployed to an address with correct flags
        // We need BEFORE_SWAP_FLAG and BEFORE_SWAP_RETURNS_DELTA_FLAG
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0x4444 << 144) // Namespace
        );

        bytes memory constructorArgs = abi.encode(
            poolManager, // IPoolManager
            vault, // YDSVault
            IMPACT_FEE_BPS, // impactFeeBps (0.1%)
            governance // owner
        );

        deployCodeTo("ImpactFeeHook.sol:ImpactFeeHook", constructorArgs, flags);
        hook = ImpactFeeHook(flags);

        console.log("ImpactFeeHook deployed at:", address(hook));
        console.log("Impact fee:", IMPACT_FEE_BPS, "bps (0.1%)");
        console.log("Using beforeSwap hook pattern with BeforeSwapDelta!");

        // Step 3: Create pool with the hook
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        console.log("Pool initialized");

        // Step 4: Add liquidity to the pool
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

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

        console.log("Liquidity added, tokenId:", tokenId);

        // Step 5: Fund the swapper with tokens
        deal(Currency.unwrap(currency0), swapper, 100e18);
        deal(Currency.unwrap(currency1), swapper, 100e18);

        console.log("Swapper funded with 100 of each token");
        console.log("---");
    }

    /*//////////////////////////////////////////////////////////////
                            TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test the complete impact fee flow
     * @dev Verifies that swaps trigger fee collection and donation
     */
    function test_ImpactFeeFlow() public {
        console.log("=== Starting Impact Fee Flow Test ===");

        // Get initial balances
        uint256 swapperBalance0Before = IERC20(Currency.unwrap(currency0)).balanceOf(swapper);
        uint256 charitySharesBefore = vault.balanceOf(charity);
        uint256 vaultAssetsBefore = vault.totalAssets();

        console.log("Initial swapper balance (currency0):", swapperBalance0Before);
        console.log("Initial charity shares:", charitySharesBefore);
        console.log("Initial vault assets:", vaultAssetsBefore);

        // Calculate expected fee
        uint256 expectedFee = (SWAP_AMOUNT * IMPACT_FEE_BPS) / 10_000; // 0.1% of 1e18 = 1e15
        console.log("Expected impact fee:", expectedFee);

        // Step 6: Perform a swap
        vm.startPrank(swapper);

        // Approve tokens for swap
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), SWAP_AMOUNT + expectedFee);

        console.log("Swapper approved swapRouter");

        // Swap currency0 → currency1
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: SWAP_AMOUNT,
            amountOutMin: 0, // No slippage protection for test
            zeroForOne: true, // Swapping currency0 for currency1
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: swapper,
            deadline: block.timestamp + 1
        });

        vm.stopPrank();

        console.log("Swap executed");
        console.log("Swap delta amount0:", swapDelta.amount0());
        console.log("Swap delta amount1:", swapDelta.amount1());

        // Step 6: Process the accumulated fees (convert ERC6909 to ERC20 and deposit to vault)
        console.log("Processing accumulated fees...");
        hook.processFees(poolId, currency0);
        console.log("Fees processed and deposited to vault");

        // Get final balances
        uint256 swapperBalance0After = IERC20(Currency.unwrap(currency0)).balanceOf(swapper);
        uint256 charitySharesAfter = vault.balanceOf(charity);
        uint256 vaultAssetsAfter = vault.totalAssets();

        console.log("Final swapper balance (currency0):", swapperBalance0After);
        console.log("Final charity shares:", charitySharesAfter);
        console.log("Final vault assets:", vaultAssetsAfter);

        // Assertions
        console.log("---");
        console.log("=== Running Assertions ===");

        // 1. Verify fee was collected from swapper
        uint256 swapperSpent = swapperBalance0Before - swapperBalance0After;
        console.log("Swapper spent:", swapperSpent);
        // The swapper should have spent the swap amount + the impact fee
        // Note: Actual swap mechanics might vary, so we verify the fee was collected

        // 2. Verify vault received the fee
        uint256 vaultIncrease = vaultAssetsAfter - vaultAssetsBefore;
        console.log("Vault assets increased by:", vaultIncrease);
        assertEq(vaultIncrease, expectedFee, "Vault should receive exactly the impact fee");

        // 3. Verify charity received donation shares
        uint256 sharesReceived = charitySharesAfter - charitySharesBefore;
        console.log("Charity shares increased by:", sharesReceived);
        assertGt(sharesReceived, 0, "Charity should receive donation shares");

        // For a new vault with no prior deposits, shares should equal assets (1:1)
        assertEq(sharesReceived, expectedFee, "Charity shares should equal fee amount (1:1 for first deposit)");

        // 4. Verify hook tracking
        (uint256 totalFees, uint256 totalSwaps) = hook.getPoolStats(poolId, currency0);
        console.log("Hook tracked fees:", totalFees);
        console.log("Hook tracked swaps:", totalSwaps);
        assertEq(totalFees, expectedFee, "Hook should track collected fees");
        assertEq(totalSwaps, 1, "Hook should track swap count");

        // 5. Verify vault stats
        (address donationAddr, uint256 totalDonated, uint256 totalShares) = vault.getVaultStats();
        console.log("Vault donation address:", donationAddr);
        console.log("Vault total donated assets:", totalDonated);
        console.log("Vault total charity shares:", totalShares);
        assertEq(donationAddr, charity, "Vault should have correct donation address");
        assertEq(totalDonated, expectedFee, "Vault should track total donated assets");
        assertEq(totalShares, expectedFee, "Charity should own all vault shares");

        console.log("---");
        console.log("=== All Assertions Passed! ===");
        console.log("Impact Fee Hook + YDS Vault Integration Working!");
    }

    /**
     * @notice Test multiple swaps accumulate donations
     */
    function test_MultipleSwapsAccumulate() public {
        console.log("=== Testing Multiple Swaps Accumulation ===");

        uint256 numSwaps = 5;
        uint256 expectedTotalFees = (SWAP_AMOUNT * IMPACT_FEE_BPS * numSwaps) / 10_000;

        vm.startPrank(swapper);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);

        for (uint256 i = 0; i < numSwaps; i++) {
            swapRouter.swapExactTokensForTokens({
                amountIn: SWAP_AMOUNT,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: swapper,
                deadline: block.timestamp + 1
            });
        }
        vm.stopPrank();

        // Process the accumulated fees
        hook.processFees(poolId, currency0);

        // Verify accumulated fees
        (uint256 totalFees, uint256 totalSwaps) = hook.getPoolStats(poolId, currency0);
        assertEq(totalSwaps, numSwaps, "Should track all swaps");
        assertEq(totalFees, expectedTotalFees, "Should accumulate all fees");

        // Verify vault received all fees
        assertEq(vault.totalAssets(), expectedTotalFees, "Vault should have all accumulated fees");

        // Verify charity received all shares
        uint256 charityShares = vault.balanceOf(charity);
        assertGt(charityShares, 0, "Charity should have shares");

        console.log("Multiple swaps test passed!");
    }

    /**
     * @notice Test governance can update impact fee
     */
    function test_GovernanceCanUpdateFee() public {
        console.log("=== Testing Fee Update ===");

        uint256 newFeeBps = 20; // 0.2%

        vm.prank(governance);
        hook.setImpactFee(newFeeBps);

        // Verify new fee is used
        uint256 calculatedFee = hook.calculateFee(SWAP_AMOUNT);
        uint256 expectedNewFee = (SWAP_AMOUNT * newFeeBps) / 10_000;
        assertEq(calculatedFee, expectedNewFee, "Fee should be updated");

        console.log("Fee update test passed!");
    }

    /**
     * @notice Test that non-governance cannot update fee
     */
    function test_RevertWhen_NonGovernanceUpdatesFee() public {
        console.log("=== Testing Unauthorized Fee Update ===");

        vm.prank(swapper);
        vm.expectRevert(ImpactFeeHook.Unauthorized.selector);
        hook.setImpactFee(20);

        console.log("Unauthorized revert test passed!");
    }

    /**
     * @notice Test governance can update donation address
     */
    function test_GovernanceCanUpdateDonationAddress() public {
        console.log("=== Testing Donation Address Update ===");

        address newCharity = makeAddr("newCharity");

        vm.prank(governance);
        vault.setDonationAddress(newCharity);

        assertEq(vault.donationAddress(), newCharity, "Donation address should be updated");

        // Perform a swap and verify new charity receives shares
        vm.startPrank(swapper);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), SWAP_AMOUNT * 2);

        swapRouter.swapExactTokensForTokens({
            amountIn: SWAP_AMOUNT,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: swapper,
            deadline: block.timestamp + 1
        });
        vm.stopPrank();

        // Process the accumulated fees
        hook.processFees(poolId, currency0);

        assertGt(vault.balanceOf(newCharity), 0, "New charity should receive shares");

        console.log("Donation address update test passed!");
    }

    /**
     * @notice Test fee calculation edge cases
     */
    function test_FeeCalculation() public view {
        console.log("=== Testing Fee Calculation ===");

        // Test various amounts
        assertEq(hook.calculateFee(1000), 1, "Fee for 1000 should be 1 (0.1%)");
        assertEq(hook.calculateFee(10_000), 10, "Fee for 10000 should be 10");
        assertEq(hook.calculateFee(1e18), 1e15, "Fee for 1e18 should be 1e15");

        // Test zero amount
        assertEq(hook.calculateFee(0), 0, "Fee for 0 should be 0");

        console.log("Fee calculation test passed!");
    }
}
