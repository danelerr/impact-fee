// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Uniswap V4 Imports
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

// OpenZeppelin Imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Custom Imports
import {YDSVault} from "./YDSVault.sol";

/**
 * @title ImpactFeeHook
 * @notice A Uniswap V4 Hook that automatically donates a portion of swap fees to Octant V2 YDS Vault
 * @dev Integrates Uniswap V4 with Octant's Yield Donating Strategy to fund public goods
 * 
 * Key Features:
 * - Intercepts swaps via beforeSwap hook with BeforeSwapDelta
 * - Collects impact fee (e.g., 0.1%) as ERC6909 claims during swap
 * - Processes fees via unlock callback to convert claims to ERC20
 * - Deposits fees into YDSVault which mints donation shares to charity
 * 
 * Architecture:
 * - User swaps → beforeSwap() calculates fee
 * - Hook takes fee as ERC6909 claims (stays in PoolManager)
 * - Returns BeforeSwapDelta (user pays swap amount + fee)
 * - Later, processFees() converts claims to ERC20 via unlock callback
 * - Hook deposits ERC20 to YDSVault → charity receives shares
 * 
 * @custom:security-contact For Octant DeFi Hackathon 2025
 */
contract ImpactFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The YDS Vault that receives impact fees
    YDSVault public immutable ydsVault;

    /// @notice Impact fee in basis points (e.g., 10 = 0.1%, 100 = 1%)
    uint256 public impactFeeBps;

    /// @notice Owner/governance address
    address public immutable owner;

    /// @notice Basis points denominator (10000 = 100%)
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum impact fee (1% = 100 bps)
    uint256 public constant MAX_IMPACT_FEE_BPS = 100;

    /// @notice Tracks total fees collected per pool per currency
    mapping(PoolId => mapping(Currency => uint256)) public feesCollected;

    /// @notice Tracks total swaps per pool
    mapping(PoolId => uint256) public swapCount;

    /// @notice Pending fees (as ERC6909 claims) from beforeSwap to be processed later
    mapping(PoolId => mapping(Currency => uint256)) internal _pendingFees;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an impact fee is collected and donated
    /// @param poolId The pool where the swap occurred
    /// @param currency The currency of the fee
    /// @param feeAmount The amount of fee collected
    /// @param swapper The address that performed the swap
    event ImpactFeeCollected(PoolId indexed poolId, Currency indexed currency, uint256 feeAmount, address swapper);

    /// @notice Emitted when the impact fee is updated
    /// @param oldFeeBps The previous fee in basis points
    /// @param newFeeBps The new fee in basis points
    event ImpactFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an unauthorized address tries to update settings
    error Unauthorized();

    /// @notice Thrown when trying to set an invalid fee
    error InvalidFee();

    /// @notice Thrown when the vault asset doesn't match the swap currency
    error CurrencyMismatch();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the Impact Fee Hook
     * @param poolManager_ The Uniswap V4 PoolManager
     * @param ydsVault_ The YDS Vault to receive donations
     * @param impactFeeBps_ Initial impact fee in basis points (e.g., 10 = 0.1%)
     * @param owner_ The owner/governance address
     */
    constructor(IPoolManager poolManager_, YDSVault ydsVault_, uint256 impactFeeBps_, address owner_)
        BaseHook(poolManager_)
    {
        if (impactFeeBps_ > MAX_IMPACT_FEE_BPS) revert InvalidFee();
        ydsVault = ydsVault_;
        impactFeeBps = impactFeeBps_;
        owner = owner_;
    }

    /*//////////////////////////////////////////////////////////////
                        HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the hook's permissions
     * @dev We only need beforeSwap with beforeSwapReturnDelta to collect fees as ERC6909 claims
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                        CORE HOOK LOGIC
    //////////////////////////////////////////////////////////////*/

        /*//////////////////////////////////////////////////////////////
                            HOOK FUNCTIONS
    *//////////////////////////////////////////////////////////////*/

    /**
     * @notice Hook called before each swap
     * @dev Collects impact fee as ERC6909 claims that can be processed later
     * @param key The pool key
     * @param params The swap parameters
     * @return selector The function selector
     * @return beforeSwapDelta The delta representing fee taken
     * @return lpFeeOverride Fee override (0 = no override)
     * 
     * Flow:
     * 1. Calculate impact fee based on swap amount
     * 2. Take fee as ERC6909 claims via BeforeSwapDelta
     * 3. Store accumulated claims for later processing
     * 4. Claims can be converted to ERC20 and deposited via processFees()
     */
    function _beforeSwap(
        address, /* sender */
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Determine the input currency (the one the user is selling)
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        // Skip if currency doesn't match vault asset
        if (ydsVault.asset() != Currency.unwrap(inputCurrency)) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Get the absolute swap amount
        int256 amountSpecified = params.amountSpecified;
        bool exactInput = amountSpecified < 0;
        uint256 swapAmount = exactInput ? uint256(-amountSpecified) : uint256(amountSpecified);

        // Calculate impact fee
        uint256 feeAmount = (swapAmount * impactFeeBps) / BPS_DENOMINATOR;
        
        // Skip if fee is zero
        if (feeAmount == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Take fee as ERC6909 claims to this hook
        // claims=true means we get ERC6909 tokens that stay with the hook
        inputCurrency.take(poolManager, address(this), feeAmount, true);

        // Track accumulated fees (as ERC6909 claims, not yet processed)
        _pendingFees[key.toId()][inputCurrency] += feeAmount;
        
        // Track swap count
        swapCount[key.toId()]++;

        // Return delta indicating hook took feeAmount from user's input currency
        // Positive deltaSpecified means user must pay more (to cover the fee)
        BeforeSwapDelta delta;
        if (params.zeroForOne) {
            // currency0 is input, hook takes from currency0
            delta = toBeforeSwapDelta(int128(uint128(feeAmount)), 0);
        } else {
            // currency1 is input, hook takes from currency1  
            delta = toBeforeSwapDelta(0, int128(uint128(feeAmount)));
        }

        return (this.beforeSwap.selector, delta, 0);
    }

    /**
     * @notice Process accumulated fees: convert ERC6909 claims to ERC20 and deposit to vault
     * @dev Can be called by anyone. Converts all pending fees for a pool/currency pair
     * @param poolId The pool ID
     * @param currency The currency to process
     */
    function processFees(PoolId poolId, Currency currency) external {
        uint256 feeAmount = _pendingFees[poolId][currency];
        if (feeAmount == 0) return;

        // Clear pending fees
        delete _pendingFees[poolId][currency];

        // Encode the unlock callback data
        bytes memory unlockData = abi.encode(poolId, currency, feeAmount);
        
        // Execute burn/take inside unlock callback
        poolManager.unlock(unlockData);
    }

    /**
     * @notice Unlock callback to process fees
     * @dev Called by PoolManager during unlock
     */
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (PoolId poolId, Currency currency, uint256 feeAmount) = abi.decode(data, (PoolId, Currency, uint256));

        // Burn ERC6909 claims
        poolManager.burn(address(this), currency.toId(), feeAmount);
        
        // Take ERC20 tokens from PoolManager
        poolManager.take(currency, address(this), feeAmount);

        // Approve vault
        IERC20(Currency.unwrap(currency)).forceApprove(address(ydsVault), feeAmount);

        // Deposit to vault (sender = address(this) since we're processing in batch)
        ydsVault.deposit(feeAmount, address(this));

        // Update tracking
        feesCollected[poolId][currency] += feeAmount;

        // Emit event
        emit ImpactFeeCollected(poolId, currency, feeAmount, address(this));

        return "";
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE FUNCTIONS
    *//////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the impact fee
     * @dev Only callable by owner
     * @param newFeeBps New fee in basis points
     */
    function setImpactFee(uint256 newFeeBps) external {
        if (msg.sender != owner) revert Unauthorized();
        if (newFeeBps > MAX_IMPACT_FEE_BPS) revert InvalidFee();

        uint256 oldFeeBps = impactFeeBps;
        impactFeeBps = newFeeBps;

        emit ImpactFeeUpdated(oldFeeBps, newFeeBps);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns statistics for a specific pool
     * @param poolId The pool ID
     * @param currency The currency to query
     * @return totalFees Total fees collected
     * @return totalSwaps Total number of swaps
     */
    function getPoolStats(PoolId poolId, Currency currency)
        external
        view
        returns (uint256 totalFees, uint256 totalSwaps)
    {
        return (feesCollected[poolId][currency], swapCount[poolId]);
    }

    /**
     * @notice Calculates the fee for a given swap amount
     * @param amount The swap amount
     * @return The calculated fee
     */
    function calculateFee(uint256 amount) external view returns (uint256) {
        return (amount * impactFeeBps) / BPS_DENOMINATOR;
    }

    /**
     * @notice Returns pending fees (as ERC6909 claims) for a pool/currency
     * @param poolId The pool ID
     * @param currency The currency to query
     * @return The pending fee amount
     */
    function getPendingFees(PoolId poolId, Currency currency) external view returns (uint256) {
        return _pendingFees[poolId][currency];
    }
}
